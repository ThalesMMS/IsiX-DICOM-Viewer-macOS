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

@objc(WADODownload)
public final class WADODownload: NSObject {
    private var WADOThreads: Int32 = 0
    private var WADOTotal: Int32 = 0
    private var firstReceivedTime: TimeInterval = 0
    private var lastStatusUpdate: TimeInterval = 0
    private var WADODownloadDictionary: NSMutableDictionary?
    private var logEntry: NSMutableDictionary?

    // Read and written on the thread that runs -WADODownload: and its connections;
    // the Objective-C properties were atomic, and a word is read and written whole.
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

    /// The key of a connection in WADODownloadDictionary: its address, in decimal.
    private static func key(for connection: NSURLConnection) -> String {
        return String(format: "%ld", Int(bitPattern: Unmanaged.passUnretained(connection).toOpaque()))
    }

    @objc(connection:didReceiveResponse:)
    public func connection(_ connection: NSURLConnection, didReceive response: URLResponse) {
        // The Objective-C cast: an HTTP response is expected, and anything else
        // answers these messages as it did.
        let httpResponse = unsafeBitCast(response as AnyObject, to: HTTPURLResponse.self)

        if httpResponse.statusCode >= 300 {
            NSLog("***** WADO http status code error: %d", Int32(truncatingIfNeeded: httpResponse.statusCode))
            NSLog("***** WADO URL : %@", (response.url as NSURL?) ?? "(null)" as NSString)

            // The alert waits for the end of the retrieval, where the manifest can
            // say how many instances are missing instead of repeating the status of
            // whichever one failed first.
            if let url = response.url {
                manifest?.recordFailure(forURL: url,
                                        statusCode: httpResponse.statusCode,
                                        reason: String(format: "HTTP %d", Int32(truncatingIfNeeded: httpResponse.statusCode)))
            }

            WADODownloadDictionary?.removeObject(forKey: Self.key(for: connection))
        } else {
            // The response's own dictionary, as Objective-C read it: not a Swift copy.
            let headers = httpResponse.value(forKey: "allHeaderFields") as? NSDictionary
            let length = headers?.value(forKey: "Content-Length") as AnyObject?
            totalData = totalData &+ UInt(bitPattern: Int((length as? NSString)?.longLongValue ?? (length as? NSNumber)?.int64Value ?? 0))
        }
    }

    @objc(connection:didReceiveData:)
    public func connection(_ connection: NSURLConnection?, didReceive data: Data) {
        guard let connection else { return }
        autoreleasepool {
            let d = (WADODownloadDictionary?.object(forKey: Self.key(for: connection)) as? NSDictionary)?.object(forKey: "data") as? NSMutableData
            d?.append(data)

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

    @objc(connection:didFailWithError:)
    public func connection(_ connection: NSURLConnection?, didFailWithError error: Error) {
        if let connection {
            let key = Self.key(for: connection)
            let url = (WADODownloadDictionary?.object(forKey: key) as? NSDictionary)?.object(forKey: "url") as? URL
            WADODownloadDictionary?.removeObject(forKey: key)

            NSLog("***** WADO Retrieve error: %@", error as NSError)

            // No status: the request never got one. That is worth asking again.
            if let url {
                manifest?.recordFailure(forURL: url, statusCode: 0, reason: error.localizedDescription)
            }

            WADOThreads -= 1

            var errors = (logEntry?.value(forKey: "logNumberError") as? NSNumber)?.int32Value ?? 0
            errors += 1
            logEntry?.setValue(NSNumber(value: errors), forKey: "logNumberError")
        } else {
            WADODownloadLogStackTrace("connection == nil")
        }
    }

    @objc(connection:willCacheResponse:)
    public func connection(_ connection: NSURLConnection, willCacheResponse cachedResponse: CachedURLResponse) -> CachedURLResponse? {
        //We dont want to store the images in the cache! Caches/BUNDLE_IDENTIFIER/Cache.db
        return nil
    }

    public override init() {
        super.init()

        showErrorMessage = true

        URLCache.shared.diskCapacity = 0
        URLCache.shared.memoryCapacity = 0
    }

    @objc(connectionDidFinishLoading:)
    public func connectionDidFinishLoading(_ connection: NSURLConnection?) {
        guard let connection else {
            WADODownloadLogStackTrace("connection == nil")
            return
        }
        autoreleasepool {
            let path = DicomDatabase.activeLocal()?.incomingDirPath() ?? ""

            let key = Self.key(for: connection)

            let entry = WADODownloadDictionary?.object(forKey: key) as? NSDictionary
            let d = entry?.object(forKey: "data") as? NSMutableData

            var `extension` = "dcm"

            if let d, d.length > 2 {
                let downloaded = entry?.object(forKey: "url") as? URL

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
                    WADODownloadDictionary?.removeObject(forKey: key)
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
                                        logEntry.setValue(((self.WADODownloadDictionary?.object(forKey: key) as? NSDictionary)?.object(forKey: "url") as? NSURL)?.host, forKey: "logCallingAET")

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
                                        _N2LogExceptionImpl(e, false, "-[WADODownload connectionDidFinishLoading:]")
                                    }
                                }
                            }
                        }
                    } catch {
                        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                            _N2LogExceptionImpl(exception, false, "-[WADODownload connectionDidFinishLoading:]")
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
            WADODownloadDictionary?.removeObject(forKey: key)

            WADOThreads -= 1
        }
    }

    /// A private class method, declared by the former file in a category: sent as
    /// Objective-C sent it. The @try around it caught what it raises, an
    /// unrecognized selector included, and logged it.
    private static func allowAnyHTTPSCertificate(forHost host: String?) {
        let selector = NSSelectorFromString("setAllowsAnyHTTPSCertificate:forHost:")
        guard let method = class_getClassMethod(NSURLRequest.self, selector) else {
            NSLog("***** exception in %s: %@", "-[WADODownload WADODownloadPass:]",
                  "+[NSURLRequest setAllowsAnyHTTPSCertificate:forHost:]: unrecognized selector sent to class" as NSString)
            return
        }
        typealias SetAllowsAnyHTTPSCertificate = @convention(c) (AnyClass, Selector, ObjCBool, NSString?) -> Void
        let setAllows = unsafeBitCast(method_getImplementation(method), to: SetAllowsAnyHTTPSCertificate.self)
        do {
            try HorosObjCException.perform {
                setAllows(NSURLRequest.self, selector, true, host as NSString?)
            }
        } catch {
            let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("***** exception in %s: %@", "-[WADODownload WADODownloadPass:]", e ?? (error as NSError))
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

        let connectionsArray = NSMutableArray()

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
                            self.WADODownloadDictionary = NSMutableDictionary()

                            var WADOMaximumConcurrentDownloads = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "WADOMaximumConcurrentDownloads"))
                            if WADOMaximumConcurrentDownloads < 1 {
                                WADOMaximumConcurrentDownloads = 1
                            }

                            var timeout = UserDefaults.standard.float(forKey: "WADOTimeout")
                            if timeout < 240 { timeout = 240 }

                            #if DEBUG
                            NSLog("------ WADO parameters: timeout:%2.2f [secs] / WADOMaximumConcurrentDownloads:%d [URLRequests]", Double(timeout), WADOMaximumConcurrentDownloads)
                            #endif
                            let passStart = self.countOfSuccesses // successes accumulate across passes
                            self.WADOThreads = Int32(truncatingIfNeeded: urlToDownload.count)
                            self.WADOTotal = self.WADOThreads

                            var retrieveStartingDate = Date.timeIntervalSinceReferenceDate

                            var aborted = false
                            for url in urlToDownload {
                                let url = url as! NSURL
                                while (self.WADODownloadDictionary?.count ?? 0) >= Int(WADOMaximumConcurrentDownloads) { //Dont download more than XXX images at the same time
                                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

                                    if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                        aborted = true
                                        break
                                    }
                                }
                                if aborted || self._abortAssociation || Thread.current.isCancelled { aborted = true; break }
                                retrieveStartingDate = Date.timeIntervalSinceReferenceDate

                                if (url.scheme as NSString?)?.isEqual(to: "https") == true {
                                    Self.allowAnyHTTPSCertificate(forHost: url.host)
                                }

                                let downloadConnection = NSURLConnection(request: URLRequest(url: url as URL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: TimeInterval(timeout)), delegate: self)

                                if let downloadConnection {
                                    self.WADODownloadDictionary?.setObject(NSDictionary(objects: [url, NSMutableData()], forKeys: ["url" as NSString, "data" as NSString]),
                                                                           forKey: Self.key(for: downloadConnection) as NSString)
                                    downloadConnection.start()
                                    connectionsArray.add(downloadConnection)
                                }

                                if downloadConnection == nil {
                                    self.WADOThreads -= 1
                                }

                                if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                    aborted = true
                                    break
                                }
                            }

                            if aborted == false {
                                while self.WADOThreads > 0 {
                                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

                                    if self._abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 || Date.timeIntervalSinceReferenceDate - retrieveStartingDate > Double(timeout) {
                                        aborted = true
                                        break
                                    }
                                }

                                if aborted == false && (self.WADODownloadDictionary?.allKeys.count ?? 0) > 0 {
                                    NSLog("**** [[WADODownloadDictionary allKeys] count] > 0")
                                }

                                DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                            }

                            if aborted { self.logEntry?.setValue("Incomplete", forKey: "logMessage") } else { self.logEntry?.setValue("Complete", forKey: "logMessage") }

                            _ = (LogManager.currentLogManager() as AnyObject?)?.perform(#selector(LogManager.addLogLine(_:)), with: self.logEntry)

                            if aborted {
                                for connection in connectionsArray {
                                    (connection as! NSURLConnection).cancel()
                                }
                            }

                            self.WADODownloadDictionary = nil

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
