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
import IsiXContracts
import IsiXDICOMNetwork

/// What the session reported about one of its tasks, kept for the thread that
/// runs the pass.
private enum WADOTransferEvent {
    case response(Int, URLResponse)
    case data(Int, Data)
    case completion(Int, Error?)
}

/// The URLSession delegate of one pass. It decides nothing: every callback is
/// put in the mailbox, and the thread that called -WADODownload: takes them out
/// and handles them, so the files, the manifest, the counts and the thread's
/// progress are all written on that thread, as they were when the connection
/// callbacks arrived on its run loop. Once the pass closes the mailbox, what
/// the session still reports - the cancellation of what did not finish - is
/// dropped: nothing is written after the end of a pass.
///
/// No authentication challenge is answered here, on purpose: the server's
/// certificate is evaluated the way the system evaluates any https connection,
/// and the node's credential goes in each request's `Authorization` header,
/// never in the URL. A redirect is followed, but one to another origin leaves
/// that header behind.
///
/// @unchecked Sendable, as every URLSession delegate must be: the session's
/// queue posts while the pass's thread takes. `events` and `closed` are read
/// and written only with `condition` locked, the condition the taking thread
/// waits on.
private final class WADOTransferMailbox: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [WADOTransferEvent] = []
    private var closed = false

    private func post(_ event: WADOTransferEvent) {
        condition.lock()
        if closed == false {
            events.append(event)
            condition.signal()
        }
        condition.unlock()
    }

    /// What happened since the last call, waiting up to `interval` for something
    /// if nothing has.
    func take(waitingUpTo interval: TimeInterval) -> [WADOTransferEvent] {
        condition.lock()
        defer { condition.unlock() }
        if events.isEmpty && closed == false {
            _ = condition.wait(until: Date(timeIntervalSinceNow: interval))
        }
        let taken = events
        events.removeAll()
        return taken
    }

    func close() {
        condition.lock()
        closed = true
        events.removeAll()
        condition.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        post(.response(dataTask.taskIdentifier, response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        post(.data(dataTask.taskIdentifier, data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        post(.completion(task.taskIdentifier, error))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(WADOCredentials.redirect(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        //We dont want to store the images in the cache! Caches/BUNDLE_IDENTIFIER/Cache.db
        completionHandler(nil)
    }
}

/// The delegate of the Locations test request: only the redirect rule of a
/// retrieve.
private final class WADORedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(WADOCredentials.redirect(request, from: task.originalRequest))
    }
}

/// What the test request returned, set once before its semaphore is signalled.
private final class WADOProbeOutcome: @unchecked Sendable {
    var error: Error?
}

/// One request of a pass: what was asked for and what has come back so far.
private final class WADOTransfer {
    let url: URL
    /// What was sent, which drops the wildcard for an endpoint that refused it.
    let sent: URL
    let data = NSMutableData()
    /// When the request was sent, for the automatic request limit.
    let started = ProcessInfo.processInfo.systemUptime

    init(url: URL, sent: URL) {
        self.url = url
        self.sent = sent
    }
}

@objc(WADODownload)
public final class WADODownload: NSObject {
    private var WADOThreads: Int32 = 0
    private var WADOTotal: Int32 = 0
    private var firstReceivedTime: TimeInterval = 0
    private var lastStatusUpdate: TimeInterval = 0
    // The requests of the current pass that are still being answered, by task.
    // A request the server refused leaves it as soon as the status arrives.
    private var WADODownloadDictionary: [Int: WADOTransfer]?
    // Every task the current pass created, to tell one of ours from a stray.
    private var startedTasks = Set<Int>()
    // The entry LogManager keeps and reads again: it is filled in place.
    private var logEntry: NSMutableDictionary?
    private var logPolicy: String?
    private var network = WADONetworkTally()
    // Instances refused while asked for with `transferSyntax=*`, asked again
    // without it once the pass has ended.
    private var wildcardRefusedURLs: [URL] = []
    // The pass that asks for those again sends none with the wildcard, whatever
    // the endpoint's mark says by then.
    private var passWithoutWildcard = false

    // One entry for the whole download, including retries and attempts that
    // receive nothing. Diagnostic text never contains URLs, UIDs or error bodies.
    private func beginNetworkLog(_ urls: [URL]) {
        network = WADONetworkTally()
        let entry = NSMutableDictionary()
        entry["logUID"] = UUID().uuidString
        entry["logStartTime"] = Date()
        entry["logType"] = "Receive"
        entry["logCallingAET"] = urls.first?.host ?? "WADO"
        logEntry = entry
        let policy = WADONetworkTally.policy(for: urls)
        logPolicy = policy
        entry["logWADOPolicy"] = policy
        updateNetworkLog()
    }

    /// Bounded, even for a large study with distinct errors.
    private func recordNetworkIssue(_ reason: String) {
        network.record(reason)
    }

    private func updateNetworkLog(finished: Bool = false) {
        guard let entry = logEntry, let manifest else { return }
        entry["logNumberTotal"] = manifest.requestedCount
        entry["logNumberReceived"] = manifest.receivedCount
        entry["logNumberError"] = finished ? manifest.missingObjectUIDs.count : 0
        entry["logMessage"] = network.message(finished: finished, complete: manifest.isComplete)
        if finished {
            entry["logEndTime"] = Date()
            entry["logDetails"] = network.details(received: manifest.receivedCount, requested: manifest.requestedCount,
                                                  missing: manifest.missingObjectUIDs.count, policy: logPolicy)
        }
        (LogManager.currentLogManager() as? LogManager)?.addLogLine(entry)
    }

    private func finishNetworkLog(completed: Bool, urls: [URL]) {
        if !completed {
            for url in urls { manifest?.recordAbandoned(url: url) }
        }
        updateNetworkLog(finished: true)
        logEntry = nil
    }

    // Read and written on the thread that runs -WADODownload:, which is also the
    // one that handles what its requests report; the Objective-C properties were
    // atomic, and a word is read and written whole.
    @objc public var _abortAssociation = false
    @objc public var showErrorMessage = true
    /// The node's limit of requests at once, 1 to 16; 0 reads the former
    /// global setting. With `limiterNode`, the limit is shared by every
    /// retrieve of that node (`NodeRequestLimiter`).
    @objc public var maximumConcurrentDownloads = 0
    @objc public var limiterNode: String?
    /// The `Authorization` value every request carries, from the node's
    /// credential; nil for none. Never logged.
    @objc public var authorization: String?
    /// The node's automatic mode: its window moves with its answers, between
    /// 1 and `maximumConcurrentDownloads` (`NodeRequestLimiter`).
    @objc public var adaptiveRequests = false
    /// The order the requests start in: each one not started yet follows the
    /// plan's order of series, and a series given priority meanwhile goes
    /// first. Nil keeps the order of the list.
    @objc public var retrievePlan: RetrievePlan?
    /// The requests of this pass holding a slot of `limiterNode`.
    private var slotHeld = Set<Int>()
    @objc public var countOfSuccesses: Int32 = 0
    @objc public var WADOGrandTotal: Int32 = 0
    @objc public var WADOBaseTotal: Int32 = 0
    @objc public var totalData: UInt = 0
    @objc public var receivedData: UInt = 0
    @objc public var baseStatus: String?

    // What was asked for and what arrived, by SOP Instance UID. Valid once
    // -WADODownload: has returned; nil before the first call.
    @objc public private(set) var manifest: RetrieveManifest?

    @objc(errorMessage:)
    public class func errorMessage(_ msg: [Any]) {
        if ProcessGraph.process.preferences.bool(forKey: WADORetrieveSettings.hideErrorsKey) == false {
            // NSRunCriticalAlertPanel(msg[0], @"%@", msg[2], nil, nil, msg[1])
            HorosAlertPanel.runCritical(title: msg[0] as? String, message: msg[1] as? String ?? "", defaultButton: msg[2] as? String, alternateButton: nil, otherButton: nil)
        } else {
            NSLog("*** listener error (not displayed - hideListenerError): %@ %@ %@", "\(msg[0])", "\(msg[1])", "\(msg[2])")
        }
    }

    private func handle(_ event: WADOTransferEvent) {
        switch event {
        case let .response(task, response):
            didReceive(response, task: task)
        case let .data(task, data):
            didReceive(data, task: task)
        case let .completion(task, error):
            if slotHeld.remove(task) != nil, let node = limiterNode { NodeRequestLimiter.shared.release(node: node) }
            guard startedTasks.contains(task) else {
                N2LogStackTraceMessage("a WADO request this pass did not make")
                return
            }
            if let error {
                didFail(task: task, error: error)
            } else {
                didFinishLoading(task: task)
            }
        }
    }

    private func didReceive(_ response: URLResponse, task: Int) {
        // Anything that is not HTTP - a file URL in a list of URLs - has no status.
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 200

        if WADORequestRules.refuses(status: statusCode) {
            NSLog("***** WADO http status code error: %d", Int32(truncatingIfNeeded: statusCode))
            recordNetworkIssue("HTTP \(statusCode)")
            report(NodeRequestLimiter.outcome(forStatus: statusCode), task: task, retryAfter: httpResponse?.value(forHTTPHeaderField: "Retry-After"))

            // The alert waits for the end of the retrieval, where the manifest can
            // say how many instances are missing instead of repeating the status of
            // whichever one failed first.
            if let transfer = WADODownloadDictionary?[task] {
                let url = transfer.url
                manifest?.recordFailure(forURL: url,
                                        statusCode: statusCode,
                                        reason: String(format: "HTTP %d", Int32(truncatingIfNeeded: statusCode)))
                // Sent with the wildcard, refused in a way the wildcard explains.
                if WADOOriginalSyntax.carriesWildcard(transfer.sent), WADOOriginalSyntax.refusesWildcard(status: statusCode) {
                    if !WADOOriginalSyntax.refuses(url) {
                        NSLog("------ WADO: the server answered HTTP %d to transferSyntax=*; Original Syntax asks it with useOrig=true alone", Int32(truncatingIfNeeded: statusCode))
                        recordNetworkIssue("transferSyntax=* refused: asked with useOrig=true")
                    }
                    WADOOriginalSyntax.noteRefusal(of: url)
                    wildcardRefusedURLs.append(url)
                } else if WADOOriginalSyntax.carriesWildcard(url), !WADOOriginalSyntax.carriesWildcard(transfer.sent),
                          WADOOriginalSyntax.refusesWildcard(status: statusCode) {
                    WADOOriginalSyntax.noteRefusalWithoutWildcard(of: url)
                }
            }

            WADODownloadDictionary?.removeValue(forKey: task)
        } else {
            let length = WADORequestRules.expectedLength(contentLength: httpResponse?.value(forHTTPHeaderField: "Content-Length"),
                                                         isHTTP: httpResponse != nil, expectedContentLength: response.expectedContentLength)
            totalData = totalData &+ UInt(bitPattern: Int(length))
        }
    }

    private func didReceive(_ data: Data, task: Int) {
        autoreleasepool {
            WADODownloadDictionary?[task]?.data.append(data)

            receivedData = receivedData &+ UInt(data.count)

            if WADOTotal == 1 { // Only one file: display progress in bytes
                if totalData > 0 {
                    Thread.current.progress = CGFloat(Double(receivedData) / Double(totalData))
                }

                if firstReceivedTime == 0 {
                    firstReceivedTime = Date.timeIntervalSinceReferenceDate
                }

                if Date.timeIntervalSinceReferenceDate - lastStatusUpdate > 1 && Date.timeIntervalSinceReferenceDate - firstReceivedTime > 2 {
                    lastStatusUpdate = Date.timeIntervalSinceReferenceDate
                    let rate = Double(receivedData) / (Date.timeIntervalSinceReferenceDate - firstReceivedTime)
                    Thread.current.status = String(format: "%@ - %@/s", (self.baseStatus ?? "(null)") as NSString, NSString.sizeString(UInt64(rate)))
                }
            }
        }
    }

    /// Tells the node's automatic mode what a request showed.
    private func report(_ outcome: RequestOutcome, task: Int, retryAfter: String? = nil) {
        guard adaptiveRequests, let node = limiterNode else { return }
        let started = WADODownloadDictionary?[task]?.started
        let latency = outcome == .success ? started.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0 : 0
        NodeRequestLimiter.shared.report(node: node, outcome: outcome, latency: latency, retryAfter: retryAfter)
    }

    private func didFail(task: Int, error: Error) {
        let failure = error as NSError
        // A timeout or a dropped connection says the node is strained; a
        // certificate refused or a cancellation says nothing of its capacity.
        report(WADORequestRules.strainsNode(domain: failure.domain, code: failure.code) ? .transient : .neutral, task: task)
        let url = WADODownloadDictionary?[task]?.url
        WADODownloadDictionary?.removeValue(forKey: task)

        // NSError descriptions/userInfo can include credentials in a failing URL.
        let reason = WADORequestRules.failureReason(domain: failure.domain, code: failure.code)
        if url != nil { recordNetworkIssue(reason) }
        NSLog("***** WADO Retrieve error: %@", reason)

        // No status: the request never got one. That is worth asking again,
        // unless the server's certificate was not trusted: the system's trust
        // evaluation will say the same thing next time, and nothing it sent
        // was kept.
        if let url {
            if let reason = Self.untrustedServerReason(error, host: url.host) {
                manifest?.recordUntrustedServer(forURL: url, reason: reason)
            } else {
                manifest?.recordFailure(forURL: url, statusCode: 0, reason: error.localizedDescription)
            }
        }

        WADOThreads -= 1

    }

    /// Why a failed request is a TLS trust failure, or nil when it is not one.
    /// The codes are those URL loading uses when the server's certificate or the
    /// secure connection itself is refused.
    static func untrustedServerReason(_ error: Error, host: String?) -> String? {
        let error = error as NSError
        return WADORequestRules.untrustedServerReason(domain: error.domain, code: error.code,
                                                      description: error.localizedDescription, host: host)
    }

    /// The process graph, whose preferences each pass reads.
    private let processGraph: ProcessGraph

    public override convenience init() {
        self.init(processGraph: ProcessGraph.process)
    }

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
        super.init()

        showErrorMessage = true

        URLCache.shared.diskCapacity = 0
        URLCache.shared.memoryCapacity = 0
    }

    private func didFinishLoading(task: Int) {
        autoreleasepool {
            let ingest = processGraph.databaseIngest

            let entry = WADODownloadDictionary?[task]
            let d = entry?.data
            // The start of the body - its preamble and DICOM magic - is all
            // the rules below read; the body itself is not copied.
            let head = d.map { $0.subdata(with: NSRange(location: 0, length: min($0.length, 136))) } ?? Data()
            let carriesObject = WADORequestRules.carriesObject(head)
            if carriesObject { report(.success, task: task) }

            if let d, carriesObject {
                let downloaded = entry?.url
                let `extension` = WADORequestRules.fileExtension(ofBody: head)

                // The name has to be unique across every file this process leaves in
                // the incoming directory. It used to be the remaining-thread count
                // and the object pointer, and the count restarts on every call:
                // -WADORetrieve: calls this object again for each batch of more than
                // 50 instances, so a batch overwrote files an earlier one had
                // written and the importer had not yet moved away. That is instances
                // downloaded and then lost, without a word anywhere.
                let filename = ("WADO-" + UUID().uuidString as NSString).appendingPathExtension(`extension`)!
                let draft = IngestDraft(folder: ingest.admissionFolder(), name: filename)
                let file = draft.path

                d.write(toFile: file, atomically: true)

                // A WADO endpoint behind a proxy answers 200 with a login page
                // often enough to be worth one check, and an empty or tiny reply
                // costs nothing to spot: a body with no DICOM magic is not a
                // received instance, whatever the status said. The check is the
                // magic and not a parse, because a parse of every downloaded file
                // would cost more than it saves; a body truncated after the magic
                // still gets through here and is caught by the importer.
                let looksLikeDICOM = WADORequestRules.looksLikeDICOM(head)

                if (`extension` as NSString).isEqual(to: "dcm") && looksLikeDICOM == false {
                    NSLog("***** WADO: what arrived is not a DICOM object (%d bytes)", Int32(truncatingIfNeeded: d.length))
                    recordNetworkIssue("Invalid DICOM response")
                    ingest.discard(draft)
                    if let downloaded {
                        manifest?.recordFailure(forURL: downloaded, statusCode: 0, reason: String(format: "what arrived is not a DICOM object (%d bytes)", Int32(truncatingIfNeeded: d.length)))
                    }

                    d.length = 0
                    WADODownloadDictionary?.removeValue(forKey: task)
                    WADOThreads -= 1
                    return
                }

                countOfSuccesses += 1
                if let downloaded {
                    manifest?.recordSuccess(forURL: downloaded)
                }

                if countOfSuccesses == 1 {
                    ingest.requestImport()
                    // Retain the normal network log metadata once a valid file arrives.
                    do {
                        try HorosObjCException.perform {
                            if DicomFile.isDICOMFile(file), let dcmFile = DicomFile(file) {
                                logEntry?["logPatientName"] = dcmFile.element(forKey: "patientName")
                                logEntry?["logStudyDescription"] = dcmFile.element(forKey: "studyDescription")
                            }
                        }
                    } catch {
                        recordNetworkIssue("Could not read log metadata")
                    }
                }
                updateNetworkLog()

                if WADOGrandTotal != 0 {
                    Thread.current.progress = CGFloat(Float((WADOTotal - WADOThreads) + WADOBaseTotal) / Float(WADOGrandTotal))
                    ActivityProgressCount.set(done: Int((WADOTotal - WADOThreads) + WADOBaseTotal), total: Int(WADOGrandTotal), on: Thread.current)
                } else if WADOTotal != 0 {
                    Thread.current.progress = CGFloat(1.0 - Double(Float(WADOThreads) / Float(WADOTotal)))
                    ActivityProgressCount.set(done: Int(WADOTotal - WADOThreads), total: Int(WADOTotal), on: Thread.current)
                }

                // To remove the '.'
                _ = ingest.publish(draft, preset: .wado)
            }

            if let entry, !carriesObject {
                recordNetworkIssue("Empty or short response")
                manifest?.recordFailure(forURL: entry.url, statusCode: 0, reason: "Empty or short response")
            }
            d?.length = 0 // Free the memory immediately
            WADODownloadDictionary?.removeValue(forKey: task)

            WADOThreads -= 1
        }
    }

    /// Waits up to a tenth of a second - the slice the run loop used to be run
    /// for - for what the requests report, and handles it on this thread.
    private func handleEvents(from mailbox: WADOTransferMailbox) {
        for event in mailbox.take(waitingUpTo: 0.1) {
            autoreleasepool {
                handle(event)
            }
        }
    }

    // One pass over a list of URLs. Returns NO when it gave up early - aborted,
    // cancelled or timed out - because a pass that did not finish is not evidence
    // that the instances it did not reach are missing.
    @objc(WADODownloadPass:)
    public func WADODownloadPass(_ urlToDownload: [Any]) -> Bool {
        if urlToDownload.count == 0 {
            NSLog("**** urlToDownload.count == 0 in WADODownload")
            return true
        }

        let urls = Self.urls(urlToDownload)
        var urlToDownload = urls
        let standalone = logEntry == nil
        if standalone {
            manifest = RetrieveManifest(urls: urls)
            beginNetworkLog(urls)
        }
        let completed = autoreleasepool { () -> Bool in
            self.baseStatus = Thread.current.status

            var result = true
            do {
                try HorosObjCException.perform {
                    if urlToDownload.count != 0 {
                        urlToDownload = RetrievePlan.unique(urlToDownload) // unique, in order
                    }

                    if urlToDownload.count != 0 {
                        result = autoreleasepool { () -> Bool in
                            #if DEBUG
                            NSLog("------ WADO downloading : %d files", Int32(truncatingIfNeeded: urlToDownload.count))
                            #endif
                            self.WADODownloadDictionary = [:]
                            self.startedTasks.removeAll()

                            let settings = WADORetrieveSettings(nodeLimit: self.maximumConcurrentDownloads,
                                                                preferences: self.processGraph.preferences)
                            let WADOMaximumConcurrentDownloads = settings.maximumConcurrentDownloads
                            let node = self.limiterNode
                            let timeout = settings.timeout

                            #if DEBUG
                            NSLog("------ WADO parameters: timeout:%2.2f [secs] / WADOMaximumConcurrentDownloads:%d [URLRequests]", Double(timeout), WADOMaximumConcurrentDownloads)
                            #endif

                            // A session per pass, whose tasks all end with it. Nothing
                            // is cached, as before: the images go to the database, not
                            // to Caches/BUNDLE_IDENTIFIER/Cache.db. Ephemeral: no cookie,
                            // credential or cache outlives the pass.
                            let configuration = WADORequestRules.sessionConfiguration(timeout: TimeInterval(timeout))
                            let mailbox = WADOTransferMailbox()
                            // No queue given: the session makes a serial one of its own
                            // for the mailbox, which takes one event at a time.
                            let session = URLSession(configuration: configuration, delegate: mailbox, delegateQueue: nil)

                            let passStart = self.countOfSuccesses // successes accumulate across passes
                            self.WADOThreads = Int32(truncatingIfNeeded: urlToDownload.count)
                            self.WADOTotal = self.WADOThreads

                            var retrieveStartingDate = Date.timeIntervalSinceReferenceDate

                            var aborted = false
                            var remaining = urlToDownload
                            var revision = self.retrievePlan?.revision
                            while !remaining.isEmpty {
                                // Dont download more than XXX images at the same time, nor
                                // more than the node's slots shared with its other retrieves.
                                while (self.WADODownloadDictionary?.count ?? 0) >= Int(WADOMaximumConcurrentDownloads)
                                        || (node != nil && !NodeRequestLimiter.shared.tryAcquire(node: node!, limit: Int(WADOMaximumConcurrentDownloads), adaptive: self.adaptiveRequests)) {
                                    self.handleEvents(from: mailbox)

                                    if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                        aborted = true
                                        break
                                    }
                                }
                                if aborted || self._abortAssociation || Thread.current.isCancelled { aborted = true; break }
                                retrieveStartingDate = Date.timeIntervalSinceReferenceDate
                                // A priority given since the last request reorders what has not started.
                                if let plan = self.retrievePlan, plan.revision != revision {
                                    revision = plan.revision
                                    remaining = plan.order(urls: remaining)
                                }
                                let url = remaining.removeFirst()

                                // The URL asked for stays the transfer's identity; what is
                                // sent drops the wildcard for an endpoint that refused it.
                                let sent = WADOOriginalSyntax.request(for: url, withoutWildcard: self.passWithoutWildcard)
                                let request = WADORequestRules.request(for: sent, authorization: self.authorization, timeout: TimeInterval(timeout))
                                let downloadTask = session.dataTask(with: request)

                                self.WADODownloadDictionary?[downloadTask.taskIdentifier] = WADOTransfer(url: url, sent: sent)
                                self.startedTasks.insert(downloadTask.taskIdentifier)
                                if node != nil { self.slotHeld.insert(downloadTask.taskIdentifier) }
                                self.network.requests += 1
                                downloadTask.resume()

                                if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                    aborted = true
                                    break
                                }
                            }

                            if aborted == false {
                                while self.WADOThreads > 0 {
                                    self.handleEvents(from: mailbox)

                                    if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                        aborted = true
                                        break
                                    }
                                }

                                if aborted == false && (self.WADODownloadDictionary?.count ?? 0) > 0 {
                                    NSLog("**** [[WADODownloadDictionary allKeys] count] > 0")
                                }

                                self.processGraph.databaseIngest.requestImport()
                            }

                            if aborted {
                                self.network.cancelled = self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0
                                self.recordNetworkIssue(self.network.cancelled ? "Cancelled" : "Retrieval timed out")
                            }

                            // The pass is over: what the session still reports is not
                            // read, and whatever did not finish is cancelled. Nothing
                            // it had received was written anywhere, since a download
                            // stays in memory until it completes.
                            mailbox.close()
                            session.invalidateAndCancel()
                            if let node { for _ in self.slotHeld { NodeRequestLimiter.shared.release(node: node) } }
                            self.slotHeld.removeAll()

                            self.WADODownloadDictionary = nil
                            self.startedTasks.removeAll()

                            #if DEBUG
                            if aborted {
                                NSLog("------ WADO downloading ABORTED")
                            } else {
                                NSLog("------ WADO downloading : %d files - finished (errors: %d / total: %d)", Int32(truncatingIfNeeded: urlToDownload.count), Int32(truncatingIfNeeded: urlToDownload.count - Int(self.countOfSuccesses - passStart)), Int32(truncatingIfNeeded: urlToDownload.count))
                            }
                            #endif
                            return aborted == false
                        }
                    }
                }
            } catch {
                if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(exception, false, "-[WADODownload WADODownloadPass:]")
                }
                recordNetworkIssue("Internal retrieval error")
                result = false
            }

            return result
        }
        if standalone { finishNetworkLog(completed: completed, urls: urls) }
        return completed
    }

    /// The URLs of a list an Objective-C caller or a plugin gives; anything
    /// else in it is not a request.
    private static func urls(_ list: [Any]) -> [URL] {
        list.compactMap { $0 as? URL }
    }

    @objc(WADODownload:)
    public func WADODownload(_ urlToDownload: [Any]) {
        if urlToDownload.count == 0 {
            NSLog("**** urlToDownload.count == 0 in WADODownload")
            return
        }

        // The list is uniqued here rather than in the pass, so the manifest is built
        // from what will actually be asked for.
        let unique = RetrievePlan.unique(Self.urls(urlToDownload))

        let manifest = RetrieveManifest(urls: unique)
        self.manifest = manifest
        self.countOfSuccesses = 0
        beginNetworkLog(unique)

        // An instance that did not arrive is worth asking for again when the reason
        // was transient; one the server refused is not, and repeating a whole study
        // to collect a handful of instances is what this replaces.
        // In the automatic mode a busy node is asked again, more slowly, a few
        // more times: each pass waits for its Retry-After or backoff, and asks
        // only for what did not arrive.
        let attempts = WADORetrieveSettings.retryAttempts(preferences: processGraph.preferences, adaptive: adaptiveRequests)

        wildcardRefusedURLs = []
        var completed = WADODownloadPass(unique)

        // Instances refused because of the wildcard are asked once more without
        // it, whatever the retry setting: this is a different request, not a
        // repeat. Those the pass already sent without it are not among them.
        if completed {
            // Each instance of the pass was asked for once, so each is here once.
            let received = Set(manifest.receivedObjectUIDs)
            let refused = wildcardRefusedURLs.filter { !received.contains(RetrieveManifest.objectUID(for: $0)) }
            wildcardRefusedURLs = []
            if !refused.isEmpty {
                NSLog("------ WADO asking again for %d instance(s) without transferSyntax=*", Int32(truncatingIfNeeded: refused.count))
                network.retries += 1
                passWithoutWildcard = true
                completed = WADODownloadPass(refused)
                passWithoutWildcard = false
            }
        }

        var attempt = 0
        while completed && attempt < attempts {
            let again = manifest.retryableURLs
            if again.count == 0 {
                break
            }

            NSLog("------ WADO retrying %d instance(s) that did not arrive (attempt %d of %d)", Int32(truncatingIfNeeded: again.count), Int32(truncatingIfNeeded: attempt + 1), Int32(truncatingIfNeeded: attempts))
            network.retries += 1
            completed = WADODownloadPass(again)
            attempt += 1
        }

        finishNetworkLog(completed: completed, urls: unique)

        if manifest.isComplete == false || manifest.duplicateObjectUIDs.count != 0 {
            NSLog("------ WADO retrieve incomplete: %@", manifest.detail(limit: 20))
        }

        if manifest.isComplete == false && showErrorMessage && !Thread.current.isCancelled {
            Self.performSelector(onMainThread: #selector(Self.errorMessage(_:)),
                                         with: [NSLocalizedString("WADO Retrieve Incomplete", comment: ""), manifest.summary, NSLocalizedString("Continue", comment: "")],
                                         waitUntilDone: false)
        }
    }
}

extension WADODownload {
    /// One GET sent the way a retrieve sends it - an ephemeral session, the
    /// credential in its header, none to another origin - for the Locations
    /// test button. Nil when the server answered, as the test UIDs may well be
    /// unknown to it, unless it refused the credential (401 or 403).
    static func probe(_ url: URL, authorization: String?, timeout: TimeInterval) -> Error? {
        let configuration = WADORequestRules.sessionConfiguration(timeout: timeout, ignoresLocalCache: false)
        let session = URLSession(configuration: configuration, delegate: WADORedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let request = WADORequestRules.request(for: url, authorization: authorization, timeout: timeout)
        let finished = DispatchSemaphore(value: 0)
        let outcome = WADOProbeOutcome()
        session.dataTask(with: request) { _, response, error in
            if let error {
                outcome.error = error
            } else if let status = (response as? HTTPURLResponse)?.statusCode, WADORequestRules.refusesCredential(status: status) {
                outcome.error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: status) + " (HTTP \(status))"])
            }
            finished.signal()
        }.resume()
        if finished.wait(timeout: .now() + timeout + 5) == .timedOut {
            session.invalidateAndCancel()
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        }
        return outcome.error
    }
}
