/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXDICOMNetwork

/// One request of a DICOMweb retrieve: a study, a series or an instance.
struct DICOMwebRetrieveRequest: Sendable {
    var path: String
    /// The instance asked for, when it is one.
    var uid: String?
    /// The series it is for, if one.
    var series: String?
    /// Asked for in the fallback syntax alone.
    var fallback = false
    var attempts = 0
    /// The error a request cut after some objects ended on.
    var error: NSError?
}

/// The requests of one DICOMweb retrieve, on a pool of at most the node's
/// limit of threads, each holding one of the node's slots, shared with its
/// other retrieves, while its request runs. A request that fails recovers as
/// DICOMwebRetrieveRecovery says: asked again, resumed with what is still
/// missing, or left missing while the others go on; only a failure no request
/// can get past (authentication, TLS, the node's settings) stops the requests
/// not yet sent.
final class DICOMwebRetrieveSession: @unchecked Sendable {
    struct Pool {
        /// The first failure nothing made up for (it stops the requests not yet sent).
        var firstError: NSError?
        /// A failure left missing while the others went on.
        var unresolved: NSError?
        /// Study and series requests cut after some objects, with their error,
        /// resumed once the listing has ended.
        var interrupted: [DICOMwebRetrieveRequest] = []
        /// The requests that ended without error.
        var completedPaths = Set<String>()
        var pending: [DICOMwebRetrieveRequest] = []
        var workers: [Thread] = []
        var running = 0
    }

    let node: DCMTKQueryNode
    let client: DICOMwebClient
    let inventory: RetrieveInventory
    let plan: RetrievePlan?
    let study: String
    let series: String
    let incoming: String
    let wantedSyntax: String
    let localUIDs: Set<String>
    /// The retrieve's thread: cancelling it cancels the requests.
    let thread: Thread
    let limit: Int
    let adaptive: Bool
    let limiterNode: String

    let pool = QueryNodeShared(Pool())
    /// Every object this retrieve has queued for import, whichever request
    /// brought it: one asked for again, as a cut study or a series its listing
    /// left short is, comes again, and is dropped.
    let taken = QueryNodeShared(Set<String>())
    /// Set once a response in the node's own syntax was cut: what is asked
    /// for from then on is asked for in the fallback syntax alone.
    let fallbackOnly = QueryNodeShared(false)

    init(node: DCMTKQueryNode, client: DICOMwebClient, inventory: RetrieveInventory, plan: RetrievePlan?, study: String, series: String,
         incoming: String, wantedSyntax: String, localUIDs: Set<String>, thread: Thread, limit: Int, adaptive: Bool, limiterNode: String) {
        self.node = node
        self.client = client
        self.inventory = inventory
        self.plan = plan
        self.study = study
        self.series = series
        self.incoming = incoming
        self.wantedSyntax = wantedSyntax
        self.localUIDs = localUIDs
        self.thread = thread
        self.limit = limit
        self.adaptive = adaptive
        self.limiterNode = limiterNode
    }

    var failed: Bool { pool.read { $0.firstError != nil } }

    /// Runs one WADO-RS request: each object is validated and queued for
    /// import as soon as its part has ended, while the rest of the response is
    /// still arriving, so the viewer opens on the first images. One that does
    /// not belong to this request, repeats another or is in another transfer
    /// syntax ends the request; those queued before it stay, and the retrieve
    /// reports itself incomplete.
    func take(_ request: DICOMwebRetrieveRequest) -> NSError? {
        if failed || thread.isCancelled { return nil }
        let staging = (incoming as NSString).appendingPathComponent(".DICOMweb-" + UUID().uuidString)
        var unique = Set<String>()
        let queue: (String) -> String? = { [self] file in
            if thread.isCancelled { return "DICOMweb operation cancelled." }
            // The identifiers and the syntax come before the Pixel Data: the
            // file is read up to there, so that a large object is not read
            // twice, here and when it is imported.
            var syntax: NSString?
            let dataset = try? IsiXDCMTKDataset.dataset(ofFileAtPath: file, transferSyntax: &syntax)
            let actualStudy = dataset?.utf8Value(.studyInstanceUID), actualSeries = dataset?.utf8Value(.seriesInstanceUID)
            let objectUID = dataset?.utf8Value(.sopInstanceUID)
            var valid = dataset != nil && actualStudy != nil && actualSeries != nil && objectUID != nil
            // A server that converts an object to a lossy syntax may give the
            // copy a new SOP Instance UID and name the original in its Source
            // Image Sequence, as Orthanc does: the copy stands for that
            // instance, which is then not asked for again.
            let sources = valid ? (dataset?.stringValues(forTag: DICOMTag.referencedSOPInstanceUID.rawValue,
                                                          inItemsOfSequence: DICOMTag.sourceImageSequence.rawValue) ?? [])
                .map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty } : []
            valid = valid && actualStudy == study && (series.isEmpty || actualSeries == series)
                && (request.series == nil || actualSeries == request.series) && !(objectUID ?? "").isEmpty
                && (request.uid == nil || request.uid == objectUID || sources.contains(request.uid ?? ""))
                && !unique.contains(objectUID ?? "")
            guard valid, let dataset, let objectUID, let actualSeries else {
                return "WADO-RS returned invalid, duplicate or mismatched DICOM identifiers. That object was not imported."
            }
            if !wantedSyntax.isEmpty && !(syntax.map { client.accepts(retrievedTransferSyntax: $0 as String) } ?? false) {
                return "WADO-RS returned an object in a transfer syntax that was not asked for. That object was not imported."
            }
            let known = taken.read { $0.contains(objectUID) } || localUIDs.contains(objectUID)
            if known {
                unique.insert(objectUID)
                try? FileManager.default.removeItem(atPath: file)
                return nil
            }
            let destination = (incoming as NSString).appendingPathComponent(UUID().uuidString + ".dcm")
            do { try FileManager.default.moveItem(atPath: file, toPath: destination) } catch {
                return "A DICOMweb object could not be queued for import. Check available disk space and database folder permissions."
            }
            unique.insert(objectUID)
            taken.modify { $0.insert(objectUID) }
            // Orthanc 1.13.0 gives some objects it converts to a lossy syntax
            // (through GDCM) a new SOP Instance UID and no Source Image
            // Sequence; the series, SOP class and Instance Number stay the
            // original's. Such an object is recorded with those three, and
            // counts for the one listed instance that has them.
            if sources.isEmpty && !wantedSyntax.isEmpty && IsiXDCMTKDataset.isLossyTransferSyntax((syntax as String?) ?? ""),
               let sopClass = dataset.utf8Value(.sopClassUID), !sopClass.isEmpty,
               let number = dataset.utf8Value(.instanceNumber), !number.isEmpty {
                inventory.record(uid: objectUID, status: 0, series: actualSeries, sopClass: sopClass, instanceNumber: number)
            } else {
                inventory.record(uid: objectUID, status: 0, sources: sources)
            }
            // Shown under the same lock as the count, and as the total the
            // listing may give it: a count shown late never replaces a newer one.
            let count: UInt = node.synchronized {
                node.countOfSuccessfulSuboperations += 1
                ActivityProgressCount.set(done: Int(node.countOfSuccessfulSuboperations), total: Int(node.countOfSuboperations),
                                          setsProgress: true, on: thread)
                return node.countOfSuccessfulSuboperations
            }
            let window = adaptive ? NodeRequestLimiter.shared.window(node: limiterNode) : 0
            let status: String
            if let patient = node.retrievePatient, !patient.isEmpty {
                status = window > 0 ? String(format: NSLocalizedString("%@, %ld of %ld requests at once (automatic)", comment: ""), patient, window, limit) : patient
            } else if window > 0 {
                status = String(format: NSLocalizedString("DICOMweb: %lu objects queued for import, %ld of %ld requests at once (automatic)", comment: ""),
                                count, window, limit)
            } else {
                status = String(format: NSLocalizedString("DICOMweb: %lu objects queued for import", comment: ""), count)
            }
            if thread.status != status { thread.status = status }
            // The importer scans the incoming folder on a timer: while a viewer
            // waits for this study, nudge it, at most twice a second, as a C-STORE does.
            if RetrieveViewing.shared.importNudgeWanted(studyUID: study, at: Date.timeIntervalSinceReferenceDate) {
                DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
            }
            return nil
        }
        var requestError: NSError?
        do {
            _ = try client.retrieve(path: request.path, stagingDirectory: staging, fallbackOnly: request.fallback, objectHandler: queue)
        } catch let error as NSError {
            requestError = error
        }
        try? FileManager.default.removeItem(atPath: staging)
        // The nudges above are throttled: the last objects of a burst would
        // otherwise wait for the importer's next scan.
        DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
        return requestError
    }

    /// What a request that failed leads to. An instance that arrived before
    /// its answer failed needs nothing more; a study or series request that is
    /// left missing ends the retrieve, as asking for each of its instances
    /// would fail as it did.
    func recover(_ request: DICOMwebRetrieveRequest, error: NSError) {
        let made = request.attempts + 1
        var action = DICOMwebRetrieveRecovery.action(for: error, attempts: made)
        if action == .resume, let uid = request.uid {
            if taken.read({ $0.contains(uid) }) { return }
            action = .retry
        }
        if action == .skip && request.uid == nil { action = .stop }
        NSLog("---- retrieve: attempt %lu of %@ failed (%@): %@", UInt(made),
              request.uid != nil ? "an instance" : request.series != nil ? "a series" : "the study",
              DICOMwebClient.logReason(for: error) ?? "(null)",
              ["asked again", "resumed with what is missing", "left missing", "retrieve stopped"][action.rawValue])
        var again = request
        again.attempts = made
        switch action {
        case .retry:
            let wait = DICOMwebRetrieveRecovery.delay(beforeAttempt: made + 1, retryAfter: error.userInfo[DICOMwebClient.retryAfterKey] as? String)
            var waited: TimeInterval = 0
            while waited < wait && !thread.isCancelled && !Thread.current.isCancelled && !failed {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }
            pool.modify { $0.pending.append(again) }
        case .resume:
            again.error = error
            pool.modify { $0.interrupted.append(again) }
        case .skip:
            pool.modify { if $0.unresolved == nil { $0.unresolved = error } }
        case .stop:
            pool.modify { if $0.firstError == nil { $0.firstError = error } }
        }
    }

    /// Queues `request`, and starts a worker if the node's limit allows one.
    /// The next request to start is the first of the plan's order, a request
    /// for the whole study before any.
    func queue(_ request: DICOMwebRetrieveRequest) {
        let start: Bool = pool.modify { pool in
            pool.pending.append(request)
            if pool.running >= limit { return false }
            pool.running += 1
            return true
        }
        guard start else { return }
        let worker = Thread { [self] in
            while true {
                let stop: Bool = autoreleasepool {
                    let next: DICOMwebRetrieveRequest? = pool.modify { pool in
                        guard !pool.pending.isEmpty, pool.firstError == nil, !thread.isCancelled, !Thread.current.isCancelled else {
                            pool.pending.removeAll()
                            pool.running -= 1
                            return nil
                        }
                        var index = 0, best = Int.max
                        if pool.pending.count > 1, let ordered = plan?.orderedSeries {
                            for (position, pending) in pool.pending.enumerated() {
                                let rank: Int
                                if let seriesUID = pending.series {
                                    rank = ordered.firstIndex(of: seriesUID).map { $0 + 1 } ?? ordered.count + 1
                                } else {
                                    rank = 0
                                }
                                if rank < best { best = rank; index = position }
                            }
                        }
                        return pool.pending.remove(at: index)
                    }
                    guard let request = next else { return true }
                    if !NodeRequestLimiter.shared.acquire(node: limiterNode, limit: limit, adaptive: adaptive,
                                                         cancelled: { self.thread.isCancelled || Thread.current.isCancelled || self.failed }) {
                        return false
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    let requestError = take(request)
                    NodeRequestLimiter.shared.release(node: limiterNode)
                    if requestError == nil { pool.modify { $0.completedPaths.insert(request.path) } }
                    if requestError == nil && !adaptive { return false }
                    var outcome = RequestOutcome.success
                    if let requestError {
                        let kind = DICOMwebClient.errorKind(for: requestError)
                        outcome = kind == .http ? NodeRequestLimiter.outcome(forStatus: requestError.code)
                            : (kind == .timeout || kind == .network) ? .transient : .neutral
                    }
                    if adaptive {
                        // The latency of one instance tells the node's load; that
                        // of a series or study tells its size, and is not counted.
                        NodeRequestLimiter.shared.report(node: limiterNode, outcome: outcome,
                                                         latency: request.uid != nil ? ProcessInfo.processInfo.systemUptime - started : 0,
                                                         retryAfter: requestError?.userInfo[DICOMwebClient.retryAfterKey] as? String)
                    }
                    // In the automatic mode, a busy or transient answer that brought
                    // nothing is asked again once the node's wait is over, at most
                    // three more times; anything else recovers as the policy says.
                    let handedOver = (requestError?.userInfo["HorosDICOMwebObjectsHandedOver"] as? NSNumber)?.uintValue ?? 0
                    if adaptive && (outcome == .throttled || outcome == .transient) && request.attempts < 3 && handedOver == 0 {
                        var again = request
                        again.attempts += 1
                        pool.modify { $0.pending.append(again) }
                    } else if let requestError {
                        recover(request, error: requestError)
                    }
                    return false
                }
                if stop { break }
            }
        }
        worker.name = "DICOMweb request"
        pool.modify { $0.workers.append(worker) }
        worker.start()
    }

    /// Queues a request for `path`.
    func enqueue(_ path: String, uid: String? = nil, series seriesUID: String? = nil) {
        queue(DICOMwebRetrieveRequest(path: path, uid: uid, series: seriesUID, fallback: fallbackOnly.current))
    }

    /// Waits until no request is left or running; cancelling the retrieve's
    /// thread cancels them.
    func drain() {
        while true {
            let running: Bool = pool.read { pool in
                if pool.running == 0 { return false }
                if thread.isCancelled { pool.workers.forEach { $0.cancel() } }
                return true
            }
            if !running { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func cancelWorkers() {
        pool.read { $0.workers.forEach { $0.cancel() } }
    }
}

/// The DICOMweb retrieve of a study or series.
extension DCMTKQueryNode {

    /// The transfer starts without waiting for the listing of the node's
    /// instances, which runs beside it on a thread of its own. With nothing of
    /// the study here, the study or series is asked for at once in one
    /// multipart request; otherwise each series' missing instances are asked
    /// for as soon as its listing ends, whatever the other series are doing.
    /// The inventory begins empty, "in progress", and receives the listing once
    /// it has ended: confirmed, failed or cancelled. A confirmed listing then
    /// asks for what it names that neither arrived nor is local; a failed one
    /// falls back to asking for everything, so that nothing listed or not is
    /// left out. Completeness is judged on the UIDs, never on a count or on the
    /// viewer having opened.
    func retrieveDICOMweb() -> Bool {
        var error: NSError?
        // The node's WADO path, Retrieve Syntax and credential, as Locations has them now.
        var client: DICOMwebClient?
        do { client = try DICOMwebSources.client(forServer: extraParameters(), timeout: 60) } catch let failure as NSError { error = failure }
        guard let study = inventoryStudyUID, !study.isEmpty else { return false }
        let series = inventorySeriesUID
        var base = "studies/\(study)"
        if !series.isEmpty { base += "/series/\(series)" }
        let incoming = DicomDatabase.activeLocal()?.incomingDirPath() ?? ""
        // Empty for "As stored": any syntax is taken.
        let wantedSyntax = client?.node.retrieveTransferSyntax ?? ""
        let thread = Thread.current
        let localList = noSmartMode ? [] : localSOPInstanceUIDs(ofStudy: study, series: nil)
        let reported = numberImagesValue?.intValue ?? 0
        let inventory = RetrieveInventory.begin(study: study, series: series, endpoint: inventoryEndpoint(),
                                                database: DicomDatabase.activeLocal()?.dataBaseDirPath ?? "", instances: [],
                                                confirmed: false, reported: reported, seriesReported: [:])
        replaceRetrieveInventory(inventory)
        // A local object an earlier retrieve took under a new SOP Instance UID
        // stands for the instance its Source Image Sequence names: that one is
        // not asked for again.
        let localUIDs = Set(localList + inventory.sourceUIDs(ofDerived: localList))
        let whole = localUIDs.isEmpty
        inventory.markDiscovery("in progress")
        if noSmartMode { inventory.forgetPeerFailures() }
        countOfSuccessfulSuboperations = 0
        countOfSuboperations = UInt(max(0, reported))
        guard let client, error == nil else {
            inventory.confirm(instances: [], confirmed: false, reported: reported, seriesReported: [:], discovery: "failed")
            return reportDICOMwebError(error ?? NSError(domain: "HorosDICOMweb", code: 1))
        }

        // The order the requests start in, from the node's setting. A study is
        // asked for in one request unless that order is not the node's own:
        // then each series is asked for on its own, in that order, once the
        // series are listed. A series the operator chooses meanwhile goes first
        // among the requests not yet started; one request for the whole study
        // cannot be reordered once sent.
        let node = DICOMwebSources.node(forServer: extraParameters())
        let plan: RetrievePlan? = series.isEmpty ? RetrievePlan(order: RetrieveOrder(rawValue: node?.seriesOrder ?? 0) ?? .asListed) : nil
        // The node's rules leave out of a study the series whose description
        // matches one, unless this operation asks for everything again; a
        // series asked for by itself is retrieved whatever they say.
        if !noSmartMode { plan?.exclude(matching: node?.excludedSeries ?? []) }
        if !series.isEmpty && !noSmartMode, let rule = RetrievePlan.exclusionRule(for: theDescription() ?? "", rules: node?.excludedSeries ?? []) {
            noteExplicitRetrieveOfSeriesExcluded(byRule: rule)
        }
        let perSeries = whole && plan?.controlsSeries == true
        let endpoint = inventoryEndpoint()
        plan?.begin(endpoint: endpoint, study: study)

        // The listing, on its own thread: only the UIDs, SOP classes and
        // Instance Numbers.
        let collector = sibling(DCMTKStudyQueryNode.self, from: QueryIdentifiers.node(study: study))
        collector.setShowErrorMessage(false)
        collector.retrievePlan = plan
        struct Listing { var succeeded = false, ended = false, notImplemented = false }
        let listingState = QueryNodeShared(Listing())
        let listing = Thread {
            autoreleasepool {
                var succeeded = false, notImplemented = false
                let completed = collector.catchingExceptions {
                    if !series.isEmpty {
                        collector.query(withValues: nil, identifier: QueryIdentifiers.instanceListing(series: series, study: study))
                        succeeded = collector.lastQuerySucceeded
                        notImplemented = !succeeded && collector.lastQueryNotImplemented
                    } else {
                        _ = collector.queryImagesHierarchically(forStudy: study)
                        succeeded = collector.imageInventoryConfirmed
                        notImplemented = !succeeded && collector.imageListingNotImplemented
                    }
                }
                if !completed { notImplemented = false }
                let cancelled = Thread.current.isCancelled
                listingState.modify { state in
                    state.succeeded = succeeded && !cancelled
                    state.notImplemented = notImplemented && !cancelled
                    state.ended = true
                }
            }
        }
        listing.name = "DICOMweb listing"
        listing.start()

        let limit = node?.maximumRequests ?? DICOMwebNode.defaultMaximumRequests
        // The automatic mode: the node's window moves with its answers, and a
        // busy answer is asked again, a few times, once the node's wait is over.
        let adaptive = node?.adaptiveRequests ?? false
        // That loop repeats a busy request itself: the client does not, or each
        // busy answer would be waited out twice. The fixed mode lets the
        // client repeat it, after the node's Retry-After.
        client.repeatsBusyRequests = !adaptive
        let session = DICOMwebRetrieveSession(node: self, client: client, inventory: inventory, plan: plan, study: study, series: series,
                                              incoming: incoming, wantedSyntax: wantedSyntax, localUIDs: localUIDs, thread: thread,
                                              limit: limit, adaptive: adaptive, limiterNode: "DICOMweb " + (node?.identifier ?? base))

        if whole && !perSeries { session.enqueue(base) }
        var listed: [DCMTKImageQueryNode] = []
        var asked = Set<String>()
        var seriesAsked = false
        // Whether the total is what the series say they hold, given before the
        // instances are listed; the listing replaces it once it has ended.
        var counted = false
        while true {
            let ended = listingState.read { $0.ended }
            // A node that gives no instance count with its study gives one with
            // each series, as a rule, long before the instances are listed: a
            // listing as slow as the transfer, or one that fails, left the bar
            // indeterminate to the end.
            if whole && !counted && countOfSuboperations == 0, let plan, plan.countedInstances > 0 {
                synchronized {
                    counted = true
                    countOfSuboperations = UInt(plan.countedInstances)
                    ActivityProgressCount.set(done: Int(countOfSuccessfulSuboperations), total: Int(countOfSuboperations), setsProgress: true, on: thread)
                }
            }
            // Each series in one multipart request, in the plan's order; the
            // whole study when that is enough or no series could be listed;
            // nothing when the rules leave every series out.
            if perSeries && !seriesAsked, let plan, plan.seriesListed || ended {
                seriesAsked = true
                let ordered = plan.orderedSeries
                if plan.wholeStudySuffices || (ordered.isEmpty && !plan.excludesEverything) {
                    session.enqueue(base)
                } else {
                    for seriesUID in ordered { session.enqueue("studies/\(study)/series/\(seriesUID)", series: seriesUID) }
                }
            }
            if thread.isCancelled { listing.cancel() }
            // A series listing adds its children as one batch; the series level
            // purges them first, so it is read once it has ended.
            let batch = (!series.isEmpty && !ended) ? [] : collector.drainChildren()
            for case let image as DCMTKImageQueryNode in batch {
                guard let uid = image.uid(), !uid.isEmpty, let seriesUID = image.seriesInstanceUID(), !seriesUID.isEmpty else { continue }
                listed.append(image)
                if !whole && !localUIDs.contains(uid) && !asked.contains(uid) && !(plan?.isExcluded(series: seriesUID) ?? false) {
                    asked.insert(uid)
                    session.enqueue("studies/\(study)/series/\(seriesUID)/instances/\(uid)", uid: uid, series: seriesUID)
                }
            }
            if ended && batch.isEmpty { break }
            if batch.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
            if thread.isCancelled { session.cancelWorkers() }
        }
        while !listing.isFinished { Thread.sleep(forTimeInterval: 0.02) }
        // A node that gives no instance count with its search left the bar
        // without a total, indeterminate until the last object. The listing has
        // ended while the objects still arrive: the total is what it names of
        // what this retrieve asks for, in place of what the series counted.
        if (countOfSuboperations == 0 || counted) && !thread.isCancelled {
            let listedAll = listingState.read { $0.succeeded }
            var total = asked.count
            if whole { total += listed.filter { !(plan?.isExcluded(series: $0.seriesInstanceUID() ?? "") ?? false) }.count }
            if listedAll && total > 0 {
                synchronized {
                    countOfSuboperations = UInt(total)
                    ActivityProgressCount.set(done: Int(countOfSuccessfulSuboperations), total: total, setsProgress: true, on: thread)
                }
            }
        }
        // What the listing asked for, and the whole request, have ended.
        session.drain()

        let succeeded = listingState.read { $0.succeeded }
        var instances: [[String: String]] = []
        for image in listed {
            var instance = ["uid": image.uid() ?? "", "series": image.seriesInstanceUID() ?? ""]
            if let sopClass = image.sopClassUID(), !sopClass.isEmpty { instance["sopClass"] = sopClass }
            if let number = image.name(), !number.isEmpty { instance["number"] = number }
            instances.append(instance)
        }
        let seriesCounts: [String: NSNumber] = !series.isEmpty
            ? (numberImagesValue.map { [series: $0] } ?? [:])
            : collector.seriesInstanceCounts as? [String: NSNumber] ?? [:]
        let listedNumbers = collector.seriesNumbers, listedDetails = collector.seriesDetails
        let state = thread.isCancelled ? "cancelled" : succeeded ? "confirmed" : "failed"
        inventory.confirm(instances: instances, confirmed: succeeded && !thread.isCancelled, reported: reported,
                          seriesReported: seriesCounts, discovery: state)
        // What the rules left out is an intentional absence, recorded before
        // the second pass so that it does not ask for it.
        let excluded = plan?.excludedSeries ?? [:]
        if !excluded.isEmpty { inventory.exclude(series: excluded) }
        if series.isEmpty && (succeeded || !excluded.isEmpty) && !thread.isCancelled {
            recordPlaceholdersOfExcludedSeries(excluded, study: study, node: node, listed: listed, local: localUIDs,
                                               numbers: listedNumbers, counts: seriesCounts, details: listedDetails)
        }
        refreshRetrieveInventory()

        // A server that converts each object as it streams the response, as
        // Orthanc does, cuts it at the first object it cannot convert to the
        // node's syntax: the client's fallback applies only before any part,
        // so the objects after the cut would never come in that syntax. Once
        // per retrieve, when the listing names what is missing, those are asked
        // for again in the fallback syntax alone (Explicit VR Little Endian).
        // An object it converted under a new SOP Instance UID counts for the
        // listed instance its Source Image Sequence names, or, naming none, for
        // the one listed instance with its series, SOP class and Instance
        // Number; that instance is not asked for.
        let cut = session.pool.read { $0.interrupted.first?.error }
        if let cut, !session.failed, !thread.isCancelled, succeeded, let fallback = client.retrieveFallbackTransferSyntax {
            let kind = DICOMwebClient.errorKind(for: cut)
            if (kind == .network || kind == .invalidResponse)
                && ((cut.userInfo["HorosDICOMwebObjectsHandedOver"] as? NSNumber)?.uintValue ?? 0) > 0 {
                NSLog("---- retrieve: the response in %@ stopped after some objects (%@); asking for the missing ones in %@",
                      wantedSyntax, cut.localizedDescription, fallback)
                session.fallbackOnly.modify { $0 = true }
            }
        }
        if !session.failed && !thread.isCancelled {
            // The listing failed: never leave anything out but what the rules do.
            if !succeeded && !whole && excluded.isEmpty {
                session.enqueue(base)
            } else if !succeeded && !whole {
                for seriesUID in plan?.orderedSeries ?? [] { session.enqueue("studies/\(study)/series/\(seriesUID)", series: seriesUID) }
            } else if succeeded {
                // What the listing names that neither arrived nor is here, which
                // the whole request did not bring, or a series asked for before
                // it was listed; after a cut, what it did not bring.
                let fallbackOnly = session.fallbackOnly.current
                for (seriesUID, uids) in inventory.unreceivedSeries {
                    for uid in uids where !localUIDs.contains(uid) && (whole || fallbackOnly || !asked.contains(uid)) {
                        asked.insert(uid)
                        session.enqueue("studies/\(study)/series/\(seriesUID)/instances/\(uid)", uid: uid, series: seriesUID)
                    }
                }
                // A series the node counts more instances in than it lists, as
                // a node whose pages are shorter than asked without saying so:
                // what is not listed is never asked for by instance. Unless a
                // request for the whole study or that series ended without
                // error, the series is asked for whole; what is here or arrived
                // is dropped.
                var listedInSeries: [String: Int] = [:]
                for instance in instances { listedInSeries[instance["series"] ?? "", default: 0] += 1 }
                let done = session.pool.read { $0.completedPaths }
                for (seriesUID, count) in seriesCounts {
                    let listedCount = listedInSeries[seriesUID] ?? 0
                    let path = !series.isEmpty ? base : "studies/\(study)/series/\(seriesUID)"
                    if count.intValue > listedCount && !(plan?.isExcluded(series: seriesUID) ?? false)
                        && !done.contains(base) && !done.contains(path) {
                        NSLog("---- retrieve: the node counts %ld instances in a series and lists %ld; asking for the series whole",
                              count.intValue, listedCount)
                        session.enqueue(path, series: seriesUID)
                    }
                }
            }
            session.drain()
        }
        // Without a listing, a study or series request cut after some objects
        // is asked for again whole, the objects that already arrived dropped as
        // they come, until it is not cut or has been asked for as many times as
        // the policy allows. With one, the pass above asked for what the cut left.
        while true {
            let resumed: [DICOMwebRetrieveRequest] = session.pool.modify { pool in
                defer { pool.interrupted.removeAll() }
                return pool.interrupted
            }
            if resumed.isEmpty || succeeded || session.failed || thread.isCancelled { break }
            for request in resumed {
                var again = request
                again.error = nil
                session.queue(again)
            }
            session.drain()
        }
        // A node that does not implement the listing of a study's series or
        // instances, as a minimal server that answers only the search for
        // studies and the retrieve of a study does: with no listing, what was
        // asked for was the whole study or series, and the requests that asked
        // for it all ended without error and brought objects. The inventory
        // says the listing is not supported rather than failed, and the
        // retrieve is not reported incomplete for it. An error of any request,
        // a listing that failed in any other way, or nothing received leaves it failed.
        let notImplemented = listingState.read { $0.notImplemented }
        let unresolvedFailure = session.pool.read { $0.unresolved != nil }
        if !succeeded && notImplemented && !session.failed && !unresolvedFailure && !thread.isCancelled && countOfSuccessfulSuboperations > 0 {
            NSLog("---- retrieve: the node does not implement the listing of the study's series or instances; what was asked for was retrieved whole, without error")
            inventory.markDiscovery("not supported")
        }
        plan?.end(endpoint: endpoint, study: study)
        error = session.pool.read { $0.firstError ?? $0.unresolved }
        // What this attempt asked for: the whole listing, or the instances that
        // were not here. The local ones are no failure of the transfer.
        var requested = whole ? max(0, inventory.scopeExpectedCount) : asked.count
        if !whole && !succeeded { requested = max(requested, reported - localUIDs.count) }
        countOfSuboperations = max(UInt(max(0, requested)), countOfSuccessfulSuboperations)
        if Thread.current.isCancelled {
            reportRetrieveCancellation("DICOMweb", confirmed: true)
            return false
        }
        if let error { return reportDICOMwebError(error) }
        noteExcludedSeries(excluded, everything: plan?.excludesEverything ?? false)
        return true
    }

    /// The series a DICOMweb node's rules left out of a study, kept as
    /// placeholders the viewer and the browser show, greyed, and retrieve when
    /// clicked: what they were (number, instances, date, modality) and a
    /// picture, fetched afterwards, one request at a time among the node's
    /// slots. A node that has no picture leaves the placeholder its grey
    /// frame, without a word.
    func recordPlaceholdersOfExcludedSeries(_ excluded: [String: [String]], study: String, node: DICOMwebNode?, listed: [DCMTKImageQueryNode],
                                            local: Set<String>, numbers: [AnyHashable: Any], counts: [String: NSNumber],
                                            details: [AnyHashable: Any]) {
        guard let database = DicomDatabase.activeLocal()?.dataBaseDirPath, !database.isEmpty,
              let identifier = node?.identifier, !identifier.isEmpty else { return }
        var records: [[String: Any]] = []
        for (uid, info) in excluded {
            var record = details[uid] as? [String: Any] ?? [:]
            record["series"] = uid
            record["description"] = info.first ?? ""
            record["rule"] = info.last ?? ""
            if let number = numbers[uid] { record["number"] = number }
            var instances = listed.filter { $0.seriesInstanceUID() == uid }
            let here = instances.allSatisfy { local.contains($0.uid() ?? "") }
            // Retrieved by itself since: no placeholder, no picture.
            if !instances.isEmpty && here { continue }
            let count = counts[uid] ?? (instances.isEmpty ? nil : NSNumber(value: instances.count))
            if let count, count.intValue > 0 { record["instances"] = count }
            instances.sort { (($0.name() ?? "") as NSString).integerValue < (($1.name() ?? "") as NSString).integerValue }
            if !instances.isEmpty { record["middleInstance"] = instances[instances.count / 2].uid() }
            records.append(record)
        }
        ExcludedSeries.record(study: study, node: identifier, database: database, series: records)
        let changed: @Sendable () -> Void = {
            DispatchQueue.main.async { NotificationCenter.default.post(name: ExcludedSeries.didChangeNotification, object: study) }
        }
        changed()
        let missing = ExcludedSeries.seriesWithoutThumbnail(study: study, node: identifier, database: database)
        if missing.isEmpty { return }
        nonisolated(unsafe) let server = extraParameters()
        nonisolated(unsafe) let placeholders = missing
        let limiterNode = "DICOMweb " + identifier
        let limit = node?.maximumRequests ?? DICOMwebNode.defaultMaximumRequests
        let pictures = Thread {
            autoreleasepool {
                let client = try? DICOMwebSources.client(forServer: server, timeout: 30)
                for one in placeholders {
                    guard let client, !Thread.current.isCancelled else { break }
                    if !NodeRequestLimiter.shared.acquire(node: limiterNode, limit: limit, cancelled: { Thread.current.isCancelled }) { break }
                    let data = try? client.previewImage(study: study, series: one.seriesInstanceUID, instance: one.middleInstance)
                    NodeRequestLimiter.shared.release(node: limiterNode)
                    if let data {
                        ExcludedSeries.setThumbnail(data, series: one.seriesInstanceUID, study: study, database: database)
                        changed()
                    }
                }
            }
        }
        pictures.name = "DICOMweb placeholder pictures"
        pictures.start()
    }
}
