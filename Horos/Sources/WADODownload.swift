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
/// and a user name and password in the URL are
/// used the way the system uses them.
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        //We dont want to store the images in the cache! Caches/BUNDLE_IDENTIFIER/Cache.db
        completionHandler(nil)
    }
}

/// One request of a pass: what was asked for and what has come back so far.
private final class WADOTransfer {
    let url: URL
    let data = NSMutableData()

    init(url: URL) {
        self.url = url
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
    private var logEntry: NSMutableDictionary?

    // Read and written on the thread that runs -WADODownload:, which is also the
    // one that handles what its requests report; the Objective-C properties were
    // atomic, and a word is read and written whole.
    @objc public var _abortAssociation = false
    @objc public var showErrorMessage = true
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
        let alertSuppress = "hideListenerError"

        if UserDefaults.standard.bool(forKey: alertSuppress) == false {
            // NSRunCriticalAlertPanel(msg[0], @"%@", msg[2], nil, nil, msg[1])
            HorosAlertPanel.runCritical(title: msg[0] as? String, message: msg[1] as? String ?? "", defaultButton: msg[2] as? String, alternateButton: nil, otherButton: nil)
        } else {
            NSLog("*** listener error (not displayed - hideListenerError): %@ %@ %@", msg[0] as! NSObject, msg[1] as! NSObject, msg[2] as! NSObject)
        }
    }

    private func handle(_ event: WADOTransferEvent) {
        switch event {
        case let .response(task, response):
            didReceive(response, task: task)
        case let .data(task, data):
            didReceive(data, task: task)
        case let .completion(task, error):
            guard startedTasks.contains(task) else {
                WADODownloadLogStackTrace("a WADO request this pass did not make")
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

        if statusCode >= 300 {
            NSLog("***** WADO http status code error: %d", Int32(truncatingIfNeeded: statusCode))
            NSLog("***** WADO URL : %@", (response.url as NSURL?) ?? "(null)" as NSString)

            // The alert waits for the end of the retrieval, where the manifest can
            // say how many instances are missing instead of repeating the status of
            // whichever one failed first.
            if let url = response.url {
                manifest?.recordFailure(forURL: url,
                                        statusCode: statusCode,
                                        reason: String(format: "HTTP %d", Int32(truncatingIfNeeded: statusCode)))
            }

            WADODownloadDictionary?.removeValue(forKey: task)
        } else {
            var length: Int64 = 0
            if let header = httpResponse?.value(forHTTPHeaderField: "Content-Length") {
                length = (header as NSString).longLongValue
            } else if httpResponse == nil && response.expectedContentLength > 0 {
                length = response.expectedContentLength
            }
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

    private func didFail(task: Int, error: Error) {
        let url = WADODownloadDictionary?[task]?.url
        WADODownloadDictionary?.removeValue(forKey: task)

        NSLog("***** WADO Retrieve error: %@", error as NSError)

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

        var errors = (logEntry?.value(forKey: "logNumberError") as? NSNumber)?.int32Value ?? 0
        errors += 1
        logEntry?.setValue(NSNumber(value: errors), forKey: "logNumberError")
    }

    /// Why a failed request is a TLS trust failure, or nil when it is not one.
    /// The codes are those URL loading uses when the server's certificate or the
    /// secure connection itself is refused.
    static func untrustedServerReason(_ error: Error, host: String?) -> String? {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return nil }
        switch error.code {
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorSecureConnectionFailed:
            return String(format: "the certificate of %@ is not trusted (%@); trust its CA in Keychain Access to retrieve from it",
                          (host ?? "the server") as NSString, error.localizedDescription as NSString)
        default:
            return nil
        }
    }

    public override init() {
        super.init()

        showErrorMessage = true

        URLCache.shared.diskCapacity = 0
        URLCache.shared.memoryCapacity = 0
    }

    private func didFinishLoading(task: Int) {
        autoreleasepool {
            let path = DicomDatabase.activeLocal()?.incomingDirPath() ?? ""

            let entry = WADODownloadDictionary?[task]
            let d = entry?.data

            var `extension` = "dcm"

            if let d, d.length > 2 {
                let downloaded = entry?.url

                if let prefix = NSString(bytes: d.bytes, length: 2, encoding: String.Encoding.utf8.rawValue), prefix.isEqual(to: "PK") {
                    `extension` = "osirixzip"
                }

                // The name has to be unique across every file this process leaves in
                // the incoming directory. It used to be the remaining-thread count
                // and the object pointer, and the count restarts on every call:
                // -WADORetrieve: calls this object again for each batch of more than
                // 50 instances, so a batch overwrote files an earlier one had
                // written and the importer had not yet moved away. That is instances
                // downloaded and then lost, without a word anywhere.
                let filename = (".WADO-" + UUID().uuidString as NSString).appendingPathExtension(`extension`)!
                let file = (path as NSString).appendingPathComponent(filename)

                d.write(toFile: file, atomically: true)

                // A WADO endpoint behind a proxy answers 200 with a login page
                // often enough to be worth one check, and an empty or tiny reply
                // costs nothing to spot: a body with no DICOM magic is not a
                // received instance, whatever the status said. The check is the
                // magic and not a parse, because a parse of every downloaded file
                // would cost more than it saves; a body truncated after the magic
                // still gets through here and is caught by the importer.
                var looksLikeDICOM = false
                if d.length > 132 {
                    looksLikeDICOM = strncmp(d.bytes.assumingMemoryBound(to: CChar.self) + 128, "DICM", 4) == 0
                }

                if (`extension` as NSString).isEqual(to: "dcm") && looksLikeDICOM == false {
                    NSLog("***** WADO: what arrived is not a DICOM object (%d bytes): %@", Int32(truncatingIfNeeded: d.length), (downloaded as NSURL?) ?? "(null)" as NSString)
                    try? FileManager.default.removeItem(atPath: file)
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

                if WADOThreads == WADOTotal { // The first file !
                    DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()

                    do {
                        try HorosObjCException.perform {
                            if self.logEntry == nil && DicomFile.isDICOMFile(file) {
                                let dcmFile = DicomFile(file)

                                do {
                                    try HorosObjCException.perform {
                                        let logEntry = NSMutableDictionary()
                                        self.logEntry = logEntry

                                        logEntry.setValue(String(format: "%lf", Date().timeIntervalSince1970), forKey: "logUID")
                                        logEntry.setValue(Date(), forKey: "logStartTime")
                                        logEntry.setValue("Receive", forKey: "logType")
                                        logEntry.setValue((downloaded as NSURL?)?.host, forKey: "logCallingAET")

                                        if dcmFile?.element(forKey: "patientName") != nil {
                                            logEntry.setValue(dcmFile?.element(forKey: "patientName"), forKey: "logPatientName")
                                        }

                                        if dcmFile?.element(forKey: "studyDescription") != nil {
                                            logEntry.setValue(dcmFile?.element(forKey: "studyDescription"), forKey: "logStudyDescription")
                                        }

                                        logEntry.setValue(NSNumber(value: self.WADOTotal), forKey: "logNumberTotal")
                                    }
                                } catch {
                                    if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                                        _N2LogExceptionImpl(e, false, "-[WADODownload didFinishLoading]")
                                    }
                                }
                            }
                        }
                    } catch {
                        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                            _N2LogExceptionImpl(exception, false, "-[WADODownload didFinishLoading]")
                        }
                    }
                }

                logEntry?.setValue(NSNumber(value: 1 + WADOTotal - WADOThreads), forKey: "logNumberReceived")

                logEntry?.setValue(Date(), forKey: "logEndTime")
                logEntry?.setValue("In Progress", forKey: "logMessage")

                _ = (LogManager.currentLogManager() as AnyObject?)?.perform(#selector(LogManager.addLogLine(_:)), with: logEntry)

                if WADOGrandTotal != 0 {
                    Thread.current.progress = CGFloat(Float((WADOTotal - WADOThreads) + WADOBaseTotal) / Float(WADOGrandTotal))
                } else if WADOTotal != 0 {
                    Thread.current.progress = CGFloat(1.0 - Double(Float(WADOThreads) / Float(WADOTotal)))
                }

                // To remove the '.'
                try? FileManager.default.moveItem(atPath: file, toPath: (path as NSString).appendingPathComponent((filename as NSString).substring(from: 1)))
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
        var urlToDownload = urlToDownload as NSArray
        if urlToDownload.count == 0 {
            NSLog("**** urlToDownload.count == 0 in WADODownload")
            return true
        }

        return autoreleasepool { () -> Bool in
            self.baseStatus = Thread.current.status

            var result = true
            do {
                try HorosObjCException.perform {
                    if urlToDownload.count != 0 {
                        urlToDownload = NSSet(array: urlToDownload as! [Any]).allObjects as NSArray // UNIQUE OBJECTS !
                    }

                    if urlToDownload.count != 0 {
                        result = autoreleasepool { () -> Bool in
                            #if DEBUG
                            NSLog("------ WADO downloading : %d files", Int32(truncatingIfNeeded: urlToDownload.count))
                            #endif
                            self.WADODownloadDictionary = [:]
                            self.startedTasks.removeAll()

                            var WADOMaximumConcurrentDownloads = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "WADOMaximumConcurrentDownloads"))
                            if WADOMaximumConcurrentDownloads < 1 {
                                WADOMaximumConcurrentDownloads = 1
                            }

                            var timeout = UserDefaults.standard.float(forKey: "WADOTimeout")
                            if timeout < 240 { timeout = 240 }

                            #if DEBUG
                            NSLog("------ WADO parameters: timeout:%2.2f [secs] / WADOMaximumConcurrentDownloads:%d [URLRequests]", Double(timeout), WADOMaximumConcurrentDownloads)
                            #endif

                            // A session per pass, whose tasks all end with it. Nothing
                            // is cached, as before: the images go to the database, not
                            // to Caches/BUNDLE_IDENTIFIER/Cache.db.
                            let configuration = URLSessionConfiguration.default
                            configuration.urlCache = nil
                            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                            configuration.timeoutIntervalForRequest = TimeInterval(timeout)
                            let mailbox = WADOTransferMailbox()
                            let delegateQueue = OperationQueue()
                            delegateQueue.maxConcurrentOperationCount = 1
                            delegateQueue.name = "WADODownload"
                            let session = URLSession(configuration: configuration, delegate: mailbox, delegateQueue: delegateQueue)

                            let passStart = self.countOfSuccesses // successes accumulate across passes
                            self.WADOThreads = Int32(truncatingIfNeeded: urlToDownload.count)
                            self.WADOTotal = self.WADOThreads

                            var retrieveStartingDate = Date.timeIntervalSinceReferenceDate

                            var aborted = false
                            for url in urlToDownload {
                                let url = url as! NSURL
                                while (self.WADODownloadDictionary?.count ?? 0) >= Int(WADOMaximumConcurrentDownloads) { //Dont download more than XXX images at the same time
                                    self.handleEvents(from: mailbox)

                                    if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                        aborted = true
                                        break
                                    }
                                }
                                if aborted || self._abortAssociation || Thread.current.isCancelled { aborted = true; break }
                                retrieveStartingDate = Date.timeIntervalSinceReferenceDate

                                let request = URLRequest(url: url as URL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: TimeInterval(timeout))
                                let downloadTask = session.dataTask(with: request)

                                self.WADODownloadDictionary?[downloadTask.taskIdentifier] = WADOTransfer(url: url as URL)
                                self.startedTasks.insert(downloadTask.taskIdentifier)
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

                                DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                            }

                            if aborted { self.logEntry?.setValue("Incomplete", forKey: "logMessage") } else { self.logEntry?.setValue("Complete", forKey: "logMessage") }

                            _ = (LogManager.currentLogManager() as AnyObject?)?.perform(#selector(LogManager.addLogLine(_:)), with: self.logEntry)

                            // The pass is over: what the session still reports is not
                            // read, and whatever did not finish is cancelled. Nothing
                            // it had received was written anywhere, since a download
                            // stays in memory until it completes.
                            mailbox.close()
                            session.invalidateAndCancel()

                            self.WADODownloadDictionary = nil
                            self.startedTasks.removeAll()

                            self.logEntry = nil

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
                result = true
            }

            return result
        }
    }

    @objc(WADODownload:)
    public func WADODownload(_ urlToDownload: [Any]) {
        if urlToDownload.count == 0 {
            NSLog("**** urlToDownload.count == 0 in WADODownload")
            return
        }

        // The list is uniqued here rather than in the pass, so the manifest is built
        // from what will actually be asked for.
        let unique = NSSet(array: urlToDownload).allObjects

        let manifest = RetrieveManifest(urls: unique as! [URL])
        self.manifest = manifest
        self.countOfSuccesses = 0

        // An instance that did not arrive is worth asking for again when the reason
        // was transient; one the server refused is not, and repeating a whole study
        // to collect a handful of instances is what this replaces.
        var attempts = UserDefaults.standard.integer(forKey: "WADORetryAttempts")
        if attempts < 0 { attempts = 0 }
        if attempts > 5 { attempts = 5 }

        var completed = WADODownloadPass(unique)

        var attempt = 0
        while completed && attempt < attempts {
            let again = manifest.retryableURLs
            if again.count == 0 {
                break
            }

            NSLog("------ WADO retrying %d instance(s) that did not arrive (attempt %d of %d)", Int32(truncatingIfNeeded: again.count), Int32(truncatingIfNeeded: attempt + 1), Int32(truncatingIfNeeded: attempts))
            completed = WADODownloadPass(again)
            attempt += 1
        }

        if completed == false {
            // Nothing was heard about the rest, which is not the same as their
            // being absent.
            for url in unique {
                manifest.recordAbandoned(url: url as! URL)
            }
        }

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
