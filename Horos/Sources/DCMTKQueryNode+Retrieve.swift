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

/// The retrieve of a node: by DICOMweb, WADO-URI or DIMSE, the IMAGE level
/// retrieve of what a study is missing, the second pass for omissions, and
/// how the retrieve is judged once it has ended.
extension DCMTKQueryNode {

    /// The retrieve could not start: no listener, and no other destination.
    struct ListenerNotActivated: Error {}

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return (text as NSString).integerValue }
        return 0
    }

    @objc(move:)
    func move(_ dictionary: [AnyHashable: Any]!) {
        move(dictionary, retrieveMode: Int32(DICOMRetrieveMode.cMove.rawValue))
    }

    @objc(move:retrieveMode:)
    func move(_ dictionary: [AnyHashable: Any]!, retrieveMode: Int32) {
        let dict = dictionary ?? [:]
        let childrenCopy = children()
        var semaphore: DispatchSemaphore?
        if isAutoRetrieve {
            semaphore = type(of: self).semaphore(forServerHostAndPort: "\(_hostname ?? "(null)"):\(_port)")
            semaphore?.wait()
        }
        var reportedDICOMwebFailure = false
        var dicomwebLog: DICOMwebRetrieveLog?
        var dicomwebIndexed = true, dicomwebShort = false, incomplete = false
        var counted = 0, here = 0
        lastRetrieveIncomplete = false
        lastRetrieveMissing = -1
        // A DICOMweb node always retrieves into this database, whatever the
        // move destination. Only a node DICOMwebSources made is one: a SERVERS
        // entry left with the former DICOMweb mode stays a DIMSE node.
        let dicomweb = DICOMwebSources.isDICOMwebServer(extraParameters())
        let destination = dict["moveDestination"] as? String
        let askedMode = Self.intValue(dict["retrieveMode"])
        let localRetrieve = dicomweb || Int(retrieveMode) == DICOMRetrieveMode.cGet.rawValue || Int(retrieveMode) == DICOMRetrieveMode.wado.rawValue
            || dict["moveDestination"] == nil || destination == UserDefaults.defaultAETitle()
        let get = askedMode == DICOMRetrieveMode.cGet.rawValue && Int(retrieveMode) == DICOMRetrieveMode.cGet.rawValue
        var listenerMissing = false
        catchingExceptions {
            do {
                // A DICOMweb retrieve lists the node's instances beside its transfer.
                if localRetrieve && !dicomweb { beginRetrieveInventory(forCGET: get) } else { replaceRetrieveInventory(nil) }
                if dicomweb {
                    reportedDICOMwebError = nil
                    // The patient and the study, from the study this series belongs
                    // to when only a series is retrieved.
                    let studyNode = self is DCMTKStudyQueryNode ? self : dict["study"] as? DCMTKQueryNode
                    var description = studyNode?.theDescription()
                    if studyNode !== self, let own = theDescription(), !own.isEmpty {
                        description = (description?.isEmpty == false) ? "\(description ?? "") \(own)" : own
                    }
                    dicomwebLog = DICOMwebRetrieveLog(node: DICOMwebSources.node(forServer: extraParameters())?.name,
                                                      patientName: studyNode?.name(), studyDescription: description)
                    // The activity row names the patient for the whole retrieve; the
                    // count of what has arrived is in its details.
                    retrievePatient = studyNode?.name()?.replacingOccurrences(of: "^", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let patient = retrievePatient, !patient.isEmpty { Thread.current.status = patient }
                    reportedDICOMwebFailure = !retrieveDICOMweb()
                } else if askedMode == DICOMRetrieveMode.wado.rawValue && Int(retrieveMode) == DICOMRetrieveMode.wado.rawValue {
                    // The instances this operation has just listed, when the listing
                    // was confirmed: WADO-URI asks for them without listing the study again.
                    let inventory = currentRetrieveInventory()
                    let listing = inventory?.inventoryConfirmed == true ? inventory?.expectedInstances : nil
                    wadoRetrieve(study: dict["study"] as? DCMTKQueryNode, listing: listing)
                    if Thread.current.isCancelled { reportRetrieveCancellation("WADO", confirmed: true) }
                } else {
                    try retrieveDIMSE(dict, retrieveMode: retrieveMode, get: get, localRetrieve: localRetrieve,
                                      destination: destination, childrenCopy: childrenCopy)
                }
                if localRetrieve && !dicomweb && Int(retrieveMode) != DICOMRetrieveMode.wado.rawValue && !Thread.current.isCancelled {
                    try retryMissingDIMSEInstances(get: get, destination: destination)
                }
            } catch {
                listenerMissing = true
            }
        }

        // How the retrieve ended, once what it received is in the index.
        let inventory = currentRetrieveInventory()
        if localRetrieve, let inventory {
            // What the retrieve received is indexed by the importer's timer, after
            // the transfer has returned: the inventory is judged once those
            // instances are in the index, or when the indexing stops progressing
            // while the import/conversion workers are idle. Not on the main
            // thread, whose run loop drives that timer.
            var receivedIndexed = true
            if !Thread.isMainThread {
                let patience = TimeInterval(max(10, 3 * UserDefaults.standard.integer(forKey: "LISTENERCHECKINTERVAL")))
                // Nudged while it waits, so what arrived last is not left for the
                // importer's next scan.
                receivedIndexed = inventory.waitForReceivedImports(refreshing: { [self] in
                    refreshRetrieveInventory()
                    if inventory.receivedAwaitingImportCount > 0 {
                        DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                    }
                }, importInProgress: { DicomDatabase.activeLocal()?.incomingImportInProgress ?? false },
                   patience: patience, cancelled: { Thread.current.isCancelled })
            }
            refreshRetrieveInventory()
            inventory.finish()
            dicomwebIndexed = receivedIndexed
            // A DICOMweb node that counts more instances than it listed, and than
            // are here now, left some out of its listing: the study is not
            // complete, whatever the listing says. Its rules may leave series
            // out, which the count includes.
            counted = inventory.reportedCount
            here = inventory.localUniqueCount
            dicomwebShort = dicomweb && inventory.inventoryConfirmed && counted > here && inventory.excludedSeries.isEmpty
            incomplete = inventory.needsAttention || !receivedIndexed || dicomwebShort
            if inventory.inventoryConfirmed {
                lastRetrieveMissing = max(inventory.scopeExpectedCount - inventory.scopeImportedCount, dicomwebShort ? counted - here : 0)
            }
            let shortListing = dicomwebShort ? "The node counts \(counted) instances and lists fewer; \(here) are here.\n" : ""
            // An instance received but still not in the index after that wait is not local either.
            if incomplete && showErrorMessageValue && !deferFailureNotice && !reportedDICOMwebFailure && !Thread.current.isCancelled {
                Self.postNotice(NSLocalizedString("Retrieve Incomplete", comment: ""), "\(shortListing)\(inventory.summary)\nManifest: \(inventory.path)")
            }
        }
        lastRetrieveIncomplete = !Thread.current.isCancelled && (incomplete || reportedDICOMwebFailure)
        if let dicomwebLog {
            // Judged as the inventory is, once what arrived is in the index:
            // without a listing, on what was asked for and what arrived.
            let listed = inventory?.inventoryConfirmed ?? false
            var expected = listed ? inventory?.scopeExpectedCount ?? 0 : Int(countOfSuboperations)
            var received = listed ? inventory?.scopeImportedCount ?? 0 : Int(countOfSuccessfulSuboperations)
            var missing = listed || reportedDICOMwebFailure ? max(expected - received, 0) : 0
            // The node's count, when larger than its listing, is what the study
            // holds: what is here of it, instances it did not list included, is
            // what arrived.
            if listed && counted > expected && inventory?.excludedSeries.isEmpty == true {
                expected = counted
                received = min(max(received, here), counted)
                missing = max(missing, expected - received)
            }
            var reason = DICOMwebClient.logReason(for: reportedDICOMwebError)
            if reason == nil && reportedDICOMwebFailure { reason = "Failed" }
            if reason == nil && !dicomwebIndexed { reason = "Not imported" }
            if reason == nil && dicomwebShort { reason = "Listing short" }
            dicomwebLog.finish(received: received, expected: expected, missing: missing, cancelled: Thread.current.isCancelled, reason: reason)
        }
        semaphore?.signal()
        setChildren(childrenCopy)
        if listenerMissing {
            // What the exception raised here said, as the callers logged it.
            NSLog("DICOM Network Failure: %@", NSLocalizedString("DICOM Listener is not activated", comment: ""))
        }
    }

    /// A C-MOVE needs this end's listener, unless it names another destination.
    private func requireListener(destination: String?) throws {
        if !DCMTKQueryRetrieveSCP.store() && destination == nil { throw ListenerNotActivated() }
    }

    /// The DIMSE retrieve: at the IMAGE level, of what a study is missing,
    /// when part of it is here; otherwise, or when that failed, at the study or
    /// series level.
    private func retrieveDIMSE(_ dict: [AnyHashable: Any], retrieveMode: Int32, get: Bool, localRetrieve: Bool,
                               destination: String?, childrenCopy: [Any]?) throws {
        let inventory = currentRetrieveInventory()
        var localObjectUIDs: [String] = []
        // Nothing to ask either when what is missing is only what the peer
        // declared it cannot send: asking again failed each time, then fetched
        // the whole study again.
        var retrievedDone = localRetrieve && !noSmartMode && inventory?.inventoryConfirmed == true
            && (inventory?.isComplete == true || inventory?.nothingLeftToAsk == true)
        let unsendableUIDs = noSmartMode ? Set<String>() : Set(inventory?.unsendableUIDs ?? [])
        let defaults = UserDefaults.standard

        if localRetrieve && !retrievedDone && !noSmartMode
            && (inventory?.inventoryConfirmed == true || defaults.bool(forKey: "TryIMAGELevelDICOMRetrieveIfLocalImages")) {
            var studyInstanceUID: String?
            if self is DCMTKSeriesQueryNode { studyInstanceUID = (dict["study"] as? DCMTKQueryNode)?.uid() }
            if self is DCMTKStudyQueryNode { studyInstanceUID = uid() }
            // A local study with images: a C-MOVE or C-GET at the IMAGE level
            // retrieves only the images it is missing.
            localObjectUIDs.append(contentsOf: localSOPInstanceUIDs(ofStudy: studyInstanceUID, series: nil))
            if (!localObjectUIDs.isEmpty || defaults.bool(forKey: "MultipleAssociationsRetrieve")) && !Thread.current.isCancelled {
                let study = studyInstanceUID
                let cFindThread = Thread { [self] in cFind(study: study) }
                cFindThread.start()
                Thread.sleep(forTimeInterval: 0.1)
                // isFinished, not isExecuting: the worker may not have begun
                // executing after the pause above, and the loop then never ran.
                while (!cFindThread.isFinished || childrenCount() > 0) && !Thread.current.isCancelled {
                    if childrenCount() > 50 || cFindThread.isFinished {
                        var seriesUIDsToRetrieve: [String: [String]] = [:]
                        var seriesOrder: [String] = []
                        var imagesWithoutSeries: [String] = []
                        var childrenArray = drainChildren()
                        catchingExceptions {
                            if self is DCMTKStudyQueryNode {
                                childrenArray = (childrenArray as NSArray).sortedArray(using: [NSSortDescriptor(key: "seriesInstanceUID", ascending: true)])
                            }
                            for case let image as DCMTKImageQueryNode in childrenArray {
                                if let uid = image.uid() {
                                    if !localObjectUIDs.contains(uid) && !unsendableUIDs.contains(uid) {
                                        if let series = image.seriesInstanceUID() {
                                            if seriesUIDsToRetrieve[series] == nil { seriesOrder.append(series) }
                                            seriesUIDsToRetrieve[series, default: []].append(uid)
                                        } else if self is DCMTKStudyQueryNode {
                                            imagesWithoutSeries.append(uid)
                                        } else {
                                            NSLog("****** an image without series in a series' listing: %@", uid)
                                            break
                                        }
                                    }
                                } else {
                                    NSLog("****** no image uid !")
                                }
                                if Thread.current.isCancelled { break }
                            }
                        }
                        if (!seriesUIDsToRetrieve.isEmpty || !imagesWithoutSeries.isEmpty) && !Thread.current.isCancelled {
                            // Each series is retrieved on its own, for peers that
                            // refuse a request across series.
                            let requests: [DICOMQueryIdentifier] = !seriesUIDsToRetrieve.isEmpty
                                ? seriesOrder.map { QueryIdentifiers.retrieve(instances: seriesUIDsToRetrieve[$0] ?? [], series: $0, study: study) }
                                : [QueryIdentifiers.retrieve(instances: imagesWithoutSeries, series: nil, study: study)]
                            nonisolated(unsafe) let owner = Thread.current
                            let listener = !get && !DCMTKQueryRetrieveSCP.store() && destination == nil
                            let threads = [Thread.performBlock(inBackground: { [self] in
                                for request in requests {
                                    let succeeded: Bool
                                    if get {
                                        succeeded = setupNetwork(service: .getStudyRoot, identifier: request, destination: destination)
                                    } else if listener {
                                        NSLog("DICOM Network Failure: %@", NSLocalizedString("DICOM Listener is not activated", comment: ""))
                                        succeeded = false
                                    } else {
                                        succeeded = setupNetwork(service: .moveStudyRoot, identifier: request, destination: destination)
                                    }
                                    if !succeeded {
                                        NSLog("***** IMAGE Level retrieve failed... try STUDY/SERIES Level retrieve")
                                        Thread.current.cancel()
                                    }
                                    if owner.isCancelled { break }
                                }
                            })]
                            // Until every thread has finished. Asking whether one was
                            // still executing ended the wait at once: a thread just
                            // started has not begun executing, so the IMAGE level was
                            // judged, and the move closed, while its images were
                            // still arriving.
                            RetrieveThreadGroup.wait(for: threads, propagatingCancellationOf: Thread.current)
                            // A thread that failed its association cancels itself. A
                            // failure that left out only what the peer cannot send
                            // needs no STUDY level.
                            retrievedDone = !RetrieveThreadGroup.anyCancelled(threads) || currentRetrieveInventory()?.nothingLeftToAsk == true
                        } else if childrenArray.isEmpty {
                            // The IMAGE level did work when it found everything here already.
                            NSLog("***** IMAGE Level retrieve failed... try STUDY/SERIES Level retrieve")
                            localObjectUIDs = []
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if Thread.current.isCancelled {
                    // The worker adds children until it returns: the list is not
                    // purged and restored under it.
                    cFindThread.cancel()
                    while !cFindThread.isFinished { Thread.sleep(forTimeInterval: 0.05) }
                }
                purgeChildren()
                setChildren(childrenCopy)
            }
        }

        // The STUDY or SERIES level.
        if !retrievedDone && !Thread.current.isCancelled {
            setChildren(childrenCopy)
            let request = moveIdentifier()
            if get {
                if !setupNetwork(service: .getStudyRoot, identifier: request, destination: destination) {
                    NSLog("UID_GETStudyRootQueryRetrieveInformationModel failed : %s", "-[DCMTKQueryNode move:retrieveMode:]")
                }
            } else {
                try requireListener(destination: destination)
                if !setupNetwork(service: .moveStudyRoot, identifier: request, destination: destination) {
                    NSLog("UID_MOVEStudyRootQueryRetrieveInformationModel failed : %s", "-[DCMTKQueryNode move:retrieveMode:]")
                }
            }
        }
    }

    /// Keeps the same inventory active while asking again for omissions from a
    /// confirmed listing. The importer runs on the main run loop, so this
    /// recovery only runs on a retrieve worker.
    private func retryMissingDIMSEInstances(get: Bool, destination: String?) throws {
        guard !Thread.isMainThread, let inventory = currentRetrieveInventory(), inventory.inventoryConfirmed else { return }
        for round in 0..<2 {
            if inventory.retrySeries(afterRound: round, cancelled: Thread.current.isCancelled).isEmpty { break }
            let patience = TimeInterval(max(10, 3 * UserDefaults.standard.integer(forKey: "LISTENERCHECKINTERVAL")))
            _ = inventory.waitForReceivedImports(refreshing: { [self] in
                refreshRetrieveInventory()
                if inventory.receivedAwaitingImportCount > 0 {
                    DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                }
            }, importInProgress: { DicomDatabase.activeLocal()?.incomingImportInProgress ?? false },
               patience: patience, cancelled: { Thread.current.isCancelled })
            let series = inventory.retrySeries(afterRound: round, cancelled: Thread.current.isCancelled)
            if series.isEmpty { break }
            for seriesUID in series.keys.sorted() {
                if Thread.current.isCancelled { return }
                // Another retrieve/import may have filled this series while an earlier one ran.
                refreshRetrieveInventory()
                let uids = inventory.retrySeries(afterRound: round, cancelled: Thread.current.isCancelled)[seriesUID] ?? []
                if uids.isEmpty { continue }
                let request = QueryIdentifiers.retrieve(instances: uids, series: seriesUID, study: inventoryStudyUID)
                if !setupNetwork(service: get ? .getStudyRoot : .moveStudyRoot, identifier: request, destination: destination) { return }
            }
        }
    }

    // MARK: Series left out by a rule

    /// Retrieves a series a DICOMweb node's rules left out, as a click on its
    /// placeholder asks for it.
    @objc(retrieveExcludedSeries:)
    class func retrieveExcludedSeries(_ object: Any?) {
        guard let placeholder = object as? ExcludedSeries, let server = placeholder.server else {
            NSSound.beep()
            return
        }
        var identifier = DICOMQueryIdentifier()
        identifier.set(.specificCharacterSet, utf8: "ISO_IR 192")
        identifier.set(.studyInstanceUID, utf8: placeholder.study)
        identifier.set(.seriesInstanceUID, utf8: placeholder.seriesInstanceUID)
        identifier.set(.seriesDescription, utf8: placeholder.seriesDescription)
        if placeholder.numberOfImages > 0 { identifier.set(.numberOfSeriesRelatedInstances, utf8: String(placeholder.numberOfImages)) }
        let series = DCMTKSeriesQueryNode(dataset: identifier.dataset(), callingAET: UserDefaults.defaultAETitle(),
                                          calledAET: server["AETitle"] as? String, hostname: server["Address"] as? String,
                                          port: int32(server["Port"]), transferSyntax: 0, compression: 0, extraParameters: server)
        let description = placeholder.seriesDescription
        let thread = Thread {
            autoreleasepool {
                QueryController.retrieveStudies([series], showErrors: false)
                // A click that brought nothing says so in its Activity row for a
                // while, not in the Network Notices panel the placeholders
                // replaced. The placeholder stays, to be clicked again.
                if series.lastRetrieveIncomplete && !Thread.current.isCancelled {
                    Thread.current.status = String(format: NSLocalizedString("%@: not retrieved. Click its thumbnail to try again.",
                        comment: "Activity, after a click on a DICOMweb placeholder that brought nothing"), description)
                    NSLog("---- excluded series %@ clicked: not retrieved", description)
                    var waited = 0
                    while waited < 100 && !Thread.current.isCancelled {
                        Thread.sleep(forTimeInterval: 0.1)
                        waited += 1
                    }
                }
            }
        }
        thread.name = NSLocalizedString("Retrieving images...", comment: "")
        thread.status = description
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    /// What the node's rules left out of a study, and why: in the activity
    /// status and the log. No notice: a DICOMweb study shows them as placeholders.
    func noteExcludedSeries(_ excluded: [String: [String]], everything: Bool) {
        if excluded.isEmpty { return }
        let names = excluded.keys.sorted().map { uid -> String in
            let info = excluded[uid] ?? []
            return String(format: NSLocalizedString("\"%@\" (rule \"%@\")", comment: ""), info.first ?? "", info.last ?? "")
        }
        let list = names.joined(separator: ", ")
        let text = String(format: everything
            ? NSLocalizedString("Every series of this study is left out by this node's rules: %@. Nothing was retrieved. Retrieve a series by itself, or hold Option while retrieving, to include it.", comment: "")
            : NSLocalizedString("Series left out by this node's rules: %@. Retrieve a series by itself, or hold Option while retrieving, to include it.", comment: ""), list)
        NSLog("---- retrieve: %@", text)
        Thread.current.status = text
    }

    /// A series the node's rules leave out of study retrieves, asked for by
    /// itself, as a placeholder's click asks for it: it is retrieved, and the
    /// activity status and the log say why the rule did not apply.
    func noteExplicitRetrieveOfSeriesExcluded(byRule rule: String) {
        let text = String(format: NSLocalizedString("This series is left out of study retrieves by this node's rule \"%@\". It is retrieved because it was asked for by itself.", comment: ""), rule)
        NSLog("---- retrieve: %@", text)
        Thread.current.status = text
    }

    @discardableResult
    func reportDICOMwebError(_ error: NSError) -> Bool {
        reportedDICOMwebError = error
        Thread.current.status = error.localizedDescription
        if showErrorMessageValue && !deferFailureNotice {
            Self.postNotice(NSLocalizedString("DICOMweb Retrieve Failed", comment: ""), error.localizedDescription)
        }
        return false
    }
}
