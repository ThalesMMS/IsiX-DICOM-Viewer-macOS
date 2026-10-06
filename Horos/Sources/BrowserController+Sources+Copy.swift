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

import AppKit

// BrowserController (SourcesCopy) is implemented in Swift: a Swift
// extension of BrowserController, which stays Objective-C, with the selectors
// of the former category. Each copy runs on its own thread, as before; an
// @try is HorosObjCException.perform, and an @synchronized is objc_sync on the
// same object.

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// `@synchronized (object) { … }`: the same recursive lock, left before an
/// exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized(_ object: AnyObject, _ body: () -> Void) {
    objc_sync_enter(object)
    let raised = objcTry(body)
    objc_sync_exit(object)
    if let raised { raised.raise() }
}

/// `[NSArray arrayWithObjects: a, b, …, nil]`: the list ends at the first nil.
fileprivate func objcArray(_ items: Any?...) -> NSArray {
    let array = NSMutableArray()
    for item in items {
        guard let item else { break }
        array.add(item)
    }
    return array
}

/// N2LocalizedDecimal(c), the N2Stuff.h macro.
fileprivate func N2LocalizedDecimal(_ c: Int) -> String {
    return NumberFormatter.localizedString(from: NSNumber(value: c), number: .decimal)
}

/// "file" or "files", as the former messages chose them.
fileprivate func filesWord(_ count: Int) -> String {
    return count == 1 ? NSLocalizedString("file", comment: "") : NSLocalizedString("files", comment: "")
}

/// -integerValue of an NSNumber or an NSString, 0 otherwise: what the message
/// to the dictionary's value answered, without reaching NSControl's.
fileprivate func copyIntegerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? NSString { return string.integerValue }
    return 0
}

public extension BrowserController {

    @objc(copyImagesToLocalBrowserSourceThread:)
    nonisolated func copyImagesToLocalBrowserSourceThread(_ io: NSArray!) {
        autoreleasepool {
            if io.count < 4 {
                NSLog("******* copyImagesToLocalBrowserSourceThread : io.count < 4")
                return
            }

            let raised = objcTry {
                let thread = Thread.current

                let srcDatabase = io.object(at: 2) as? DicomDatabase

                // The paths are read on a private-queue context of the source, on
                // its queue; only the paths leave it.
                let imagePaths = NSMutableArray()
                if let reader = srcDatabase?.privateQueueIndependentDatabase() as? DicomDatabase {
                    reader.performBlockAndWait {
                        let dicomImages = reader.objects(withIDs: io.object(at: 0) as? [Any]) as NSArray?
                        for case let image as DicomImage in dicomImages ?? [] {
                            let completePath = image.completePath()
                            if !(completePath.map { imagePaths.contains($0) } ?? false) {
                                imagePaths.perform(#selector(NSMutableArray.add(_:)), with: completePath) // -addObject: raises on nil, as it did
                            }
                        }
                    }
                }

                thread.status = NSLocalizedString("Opening database...", comment: "")
                // The copies are indexed on a private-queue context of the destination, on its queue.
                let dstDatabase = (io.object(at: 3) as? DicomDatabase)?.privateQueueIndependentDatabase() as? DicomDatabase

                thread.status = String(format: NSLocalizedString("Copying %@ %@...", comment: ""), N2LocalizedDecimal(imagePaths.count), filesWord(imagePaths.count))
                let dstPaths = NSMutableArray()

                var fiveSeconds = Date.timeIntervalSinceReferenceDate + 5
                var oneSecond = Date.timeIntervalSinceReferenceDate + 1

                var i = 0
                while i < imagePaths.count {
                    thread.progress = CGFloat(1.0 * Double(i) / Double(imagePaths.count))

                    if thread.isCancelled {
                        break
                    }

                    let srcPath = imagePaths.object(at: i) as! String
                    let dstPath = dstDatabase?.uniquePathForNewDataFile(withExtension: "dcm")

                    if let dstPath, !dstPath.isEmpty {
                        objcSynchronized(BrowserController.horos_oneCopyAtATimeLock()!) {
                            if srcDatabase?.isReadOnly == true {
                                let t = Process.launchedProcess(launchPath: "/bin/cp", arguments: [srcPath, dstPath])
                                while t.isRunning {}
                            } else if (try? FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)) == nil {
                                NSLog("**** copyItemAtPath failed: %@", dstPath)
                            }

                            if FileManager.default.fileExists(atPath: dstPath) {
                                if DicomFile.isDICOMFile(dstPath) == false {
                                    if let renamed = ((dstPath as NSString).deletingPathExtension as NSString).appendingPathExtension((srcPath as NSString).pathExtension) {
                                        try? FileManager.default.moveItem(atPath: dstPath, toPath: renamed)
                                    }
                                }

                                dstPaths.add(dstPath)
                            }
                        }
                    }

                    if fiveSeconds < Date.timeIntervalSinceReferenceDate {
                        thread.status = String(format: NSLocalizedString("Indexing %@ %@...", comment: ""), N2LocalizedDecimal(dstPaths.count), filesWord(dstPaths.count))

                        dstDatabase?.performBlockAndWait {
                            _ = dstDatabase?.addFiles(atPaths: dstPaths as? [Any], postNotifications: true, dicomOnly: UserDefaults.standard.bool(forKey: "onlyDICOM"), rereadExistingItems: false, generatedByOsiriX: false, importedFiles: true, returnArray: false)
                        }

                        dstPaths.removeAllObjects()

                        fiveSeconds = Date.timeIntervalSinceReferenceDate + 5
                    }

                    if oneSecond < Date.timeIntervalSinceReferenceDate {
                        thread.status = String(format: NSLocalizedString("Copying %@ %@...", comment: ""), N2LocalizedDecimal(imagePaths.count - i), filesWord(imagePaths.count - i))

                        oneSecond = Date.timeIntervalSinceReferenceDate + 1
                    }
                    i += 1
                }

                thread.status = String(format: NSLocalizedString("Indexing %@ %@...", comment: ""), N2LocalizedDecimal(dstPaths.count), filesWord(dstPaths.count))
                thread.progress = -1
                dstDatabase?.performBlockAndWait { _ = dstDatabase?.addFiles(atPaths: dstPaths as? [Any]) }
            }
            if let raised {
                _N2LogExceptionImpl(raised, false, "-[BrowserController(SourcesCopy) copyImagesToLocalBrowserSourceThread:]")
            }
        }
    }

    @objc(copyImagesToRemoteBrowserSourceThread:)
    nonisolated func copyImagesToRemoteBrowserSourceThread(_ io: NSArray!) {
        autoreleasepool {
            let thread = Thread.current

            let destination = io.object(at: 1) as? DataNodeIdentifier
            let srcDatabase = io.object(at: 2) as? DicomDatabase
            // The source's images are read on a private-queue context, on its queue,
            // for as long as they are used.
            let srcReader = srcDatabase?.privateQueueIndependentDatabase() as? DicomDatabase
            N2ManagedObjectContextPerformAndWait(srcReader?.managedObjectContext) {
                let dicomImages = srcReader?.objects(withIDs: io.object(at: 0) as? [Any]) as NSArray?
                let imagePaths = NSMutableArray()
                let imagePathsObjs = NSMutableArray()
                for case let image as DicomImage in dicomImages ?? [] {
                    let completePath = image.completePath()
                    if !(completePath.map { imagePaths.contains($0) } ?? false) {
                        imagePaths.perform(#selector(NSMutableArray.add(_:)), with: completePath) // -addObject: raises on nil, as it did
                        imagePathsObjs.add(image)
                    }
                }

                thread.status = NSLocalizedString("Opening database...", comment: "")

                let raised = objcTry {
                    let dstDatabase = RemoteDicomDatabase.database(forLocation: destination?.location, port: destination?.port ?? 0, name: destination?.description, update: false)

                    thread.status = String(format: NSLocalizedString("Sending %@ %@...", comment: ""), N2LocalizedDecimal(imagePaths.count), filesWord(imagePaths.count))

                    dstDatabase?.uploadFiles(atPaths: imagePaths as? [Any], imageObjects: nil)
                }
                if let e = raised {
                    thread.status = NSLocalizedString("Error: destination is unavailable", comment: "")
                    _N2LogExceptionImpl(e, true, "-[BrowserController(SourcesCopy) copyImagesToRemoteBrowserSourceThread:]")
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }

    @objc(copyRemoteImagesToLocalBrowserSourceThread:)
    nonisolated func copyRemoteImagesToLocalBrowserSourceThread(_ io: NSArray!) {
        autoreleasepool {
            let thread = Thread.current

            let destination = io.object(at: 1) as? DataNodeIdentifier
            let srcDatabase = io.object(at: 2) as? RemoteDicomDatabase
            // The source's images are read on a private-queue context, on its queue,
            // for as long as they are used.
            let srcReader = srcDatabase?.privateQueueIndependentDatabase() as? DicomDatabase
            N2ManagedObjectContextPerformAndWait(srcReader?.managedObjectContext) {
                let dicomImages = ((srcReader?.objects(withIDs: io.object(at: 0) as? [Any]) as NSArray?)?.mutableCopy() as? NSMutableArray) ?? NSMutableArray()
                let imagePaths = (((dicomImages.value(forKey: "completePath") as? NSArray)?.mutableCopy()) as? NSMutableArray) ?? NSMutableArray()
                imagePaths.removeDuplicatedStrings(inSyncWithThisArray: dicomImages)

                thread.status = NSLocalizedString("Opening database...", comment: "")

                // Indexed on a private-queue context of the destination, on its queue.
                let idatabase = DicomDatabase(atPath: destination?.location, name: destination?.description)?.privateQueueIndependentDatabase() as? DicomDatabase

                thread.status = String(format: NSLocalizedString("Fetching %@ %@...", comment: ""), N2LocalizedDecimal(dicomImages.count), filesWord(dicomImages.count))
                let dstPaths = NSMutableArray()
                var i = 0
                while i < dicomImages.count {
                    if let exception = objcTry({
                        let dicomImage = dicomImages.object(at: i) as? DicomImage
                        let srcPath = srcDatabase?.cacheData(for: dicomImage, maxFiles: 0)

                        if let srcPath {
                            let ext = DicomFile.isDICOMFile(srcPath) ? "dcm" : (srcPath as NSString).pathExtension
                            let dstPath = idatabase?.uniquePathForNewDataFile(withExtension: ext)

                            if let dstPath, !dstPath.isEmpty {
                                if (try? FileManager.default.moveItem(atPath: srcPath, toPath: dstPath)) != nil {
                                    dstPaths.add(dstPath)
                                }
                            }
                        }
                    }) {
                        _N2LogExceptionImpl(exception, true, "-[BrowserController(SourcesCopy) copyRemoteImagesToLocalBrowserSourceThread:]")
                    }
                    thread.progress = CGFloat(1.0 * Double(i) / Double(dicomImages.count))

                    if thread.isCancelled {
                        break
                    }
                    i += 1
                }

                thread.status = NSLocalizedString("Indexing files...", comment: "")
                thread.progress = -1
                idatabase?.performBlockAndWait { _ = idatabase?.addFiles(atPaths: dstPaths as? [Any]) }
            }
        }
    }

    @objc(copyRemoteImagesToRemoteBrowserSourceThread:)
    nonisolated func copyRemoteImagesToRemoteBrowserSourceThread(_ io: NSArray!) {
        autoreleasepool {
            let thread = Thread.current

            let destination = io.object(at: 1) as? DataNodeIdentifier
            let srcDatabase = io.object(at: 2) as? RemoteDicomDatabase
            // The source's images are read on a private-queue context, on its queue,
            // for as long as they are used.
            let srcReader = srcDatabase?.privateQueueIndependentDatabase() as? DicomDatabase
            N2ManagedObjectContextPerformAndWait(srcReader?.managedObjectContext) {
                let dicomImages = ((srcReader?.objects(withIDs: io.object(at: 0) as? [Any]) as NSArray?)?.mutableCopy() as? NSMutableArray) ?? NSMutableArray()
                let imagePaths = (((dicomImages.value(forKey: "completePath") as? NSArray)?.mutableCopy()) as? NSMutableArray) ?? NSMutableArray()
                imagePaths.removeDuplicatedStrings(inSyncWithThisArray: dicomImages)

                var dstAddress: NSString? = nil
                var dstAET: NSString? = nil
                var dstPort: Int = 0
                var dstSyntax: Int = 0
                if let destination = destination as? RemoteDatabaseNodeIdentifier {
                    _ = RemoteDatabaseNodeIdentifier.location(destination.location, port: destination.port, toAddress: &dstAddress, port: nil)
                    dstPort = copyIntegerValue((destination.dictionary as NSDictionary?)?.object(forKey: "port"))
                    dstAET = (destination.dictionary as NSDictionary?)?.object(forKey: "AETitle") as? NSString
                    if dstAET == nil || dstPort == 0 || dstSyntax == 0 {
                        thread.status = NSLocalizedString("Fetching destination information...", comment: "")
                        var dstInfo: NSDictionary? = nil
                        if let e = objcTry({
                            let dstDatabase = RemoteDicomDatabase.database(forLocation: destination.location, port: destination.port, name: destination.description, update: false)

                            dstInfo = dstDatabase?.fetchDicomDestinationInfo() as NSDictionary?
                        }) {
                            thread.status = NSLocalizedString("Error: destination is unavailable", comment: "")
                            _N2LogExceptionImpl(e, true, "-[BrowserController(SourcesCopy) copyRemoteImagesToRemoteBrowserSourceThread:]")
                            Thread.sleep(forTimeInterval: 1)
                        }
                        if let aet = dstInfo?.object(forKey: "AETitle") { dstAET = aet as? NSString }
                        if let port = dstInfo?.object(forKey: "Port") { dstPort = copyIntegerValue(port) }
                        if let syntax = dstInfo?.object(forKey: "TransferSyntax") { dstSyntax = copyIntegerValue(syntax) }
                    }
                } else if let destination = destination as? DicomNodeIdentifier {
                    // The node's own host, port and AE title. They were read only
                    // from an "AET@host" location: a node entered in the preferences
                    // or resolved through Bonjour, which keeps them in separate
                    // fields, was sent to no address, on port 0, with its address
                    // as AE title.
                    if let node = destination.storeDestination() {
                        dstAddress = node.address as NSString
                        dstPort = node.port
                        dstAET = node.aet as NSString
                    }
                    dstSyntax = copyIntegerValue((destination.dictionary as NSDictionary?)?.object(forKey: "TransferSyntax"))
                }

                // Without an address, a port and an AE title the other Horos would
                // send the images nowhere.
                if (dstAddress?.length ?? 0) == 0 || dstPort == 0 || (dstAET?.length ?? 0) == 0 {
                    thread.status = NSLocalizedString("Error: destination is unavailable", comment: "")
                    return
                }

                thread.status = String(format: NSLocalizedString("Sending SCU request...", comment: ""), dicomImages.count)
                srcDatabase?.storeScuImages(dicomImages as? [Any], toDestinationAETitle: dstAET as String?, address: dstAddress as String?, port: dstPort, transferSyntax: Int32(truncatingIfNeeded: dstSyntax))
            }
        }
    }

    @objc(initiateCopyImages:toSource:)
    func initiateCopyImages(_ dicomImages: [Any]!, toSource destination: DataNodeIdentifier!) -> Bool {
        let database = self.database
        let objectIDs = (dicomImages as NSArray?)?.value(forKey: "objectID")
        if database?.isLocal() == true {
            if destination is LocalDatabaseNodeIdentifier { // local Horos to local Horos

                let dst = DicomDatabase(atPath: destination.location) // Create the mainDatabase on the MAIN thread, if necessary !

                let thread = Thread(target: self, selector: #selector(copyImagesToLocalBrowserSourceThread(_:)), object: objcArray(objectIDs, destination, database, dst))
                thread.name = NSLocalizedString("Copying images...", comment: "")
                thread.supportsCancel = true
                ThreadsManager.default().addThreadAndStart(thread)
                return true
            } else if destination is RemoteDatabaseNodeIdentifier { // local Horos to remote Horos
                let thread = Thread(target: self, selector: #selector(copyImagesToRemoteBrowserSourceThread(_:)), object: objcArray(objectIDs, destination, database))
                thread.supportsCancel = true
                thread.name = NSLocalizedString("Sending images...", comment: "")
                ThreadsManager.default().addThreadAndStart(thread)
                return true
            } else if destination is DicomNodeIdentifier { // local Horos to remote DICOM
                let r = DCMNetServiceDelegate.dicomServersListSendOnly(true, qrOnly: false) as NSArray?
                var i: Int32 = 0
                while Int(i) < (r?.count ?? 0) {
                    if destination.isEqual(to: r!.object(at: Int(i)) as? [AnyHashable: Any]) {
                        UserDefaults.standard.set(Int(i), forKey: "lastSendServer")
                    }
                    i += 1
                }
                self.selectServer(dicomImages)
                return true
            }
        } else {
            if destination is LocalDatabaseNodeIdentifier { // remote Horos to local Horos

                _ = DicomDatabase(atPath: destination.location) // Create the mainDatabase on the MAIN thread, if necessary !

                let thread = Thread(target: self, selector: #selector(copyRemoteImagesToLocalBrowserSourceThread(_:)), object: objcArray(objectIDs, destination, database))
                thread.name = NSLocalizedString("Copying images...", comment: "")
                thread.supportsCancel = true
                ThreadsManager.default().addThreadAndStart(thread)
                return true
            } else if destination is RemoteDatabaseNodeIdentifier || destination is DicomNodeIdentifier { // remote Horos to remote Horos // remote Horos to remote DICOM
                let thread = Thread(target: self, selector: #selector(copyRemoteImagesToRemoteBrowserSourceThread(_:)), object: objcArray(objectIDs, destination, database))
                thread.name = NSLocalizedString("Initiating image transfer...", comment: "")
                thread.supportsCancel = true
                ThreadsManager.default().addThreadAndStart(thread)
                return true
            }
        }

        return false
    }
}
