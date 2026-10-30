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
import IsiXDatabase

// DicomDatabase (MediaCopy): -copyFilesThread:, the files of a folder or a
// medium copied into the database folder (or read where they are) and indexed.
// The copying runs on the calling thread, five seconds of it at a time; each
// batch is indexed by an operation of a serial queue, on a private-queue
// context, while the next one is copied. Cancelling stops the copying; what is
// already copied is indexed. An import that took less than it was given says
// so in the log and in an alert.

/// What the copying thread and the indexing operations share: the totals and
/// the files the validation refused, under @synchronized(copyFailureDetails),
/// as before, and whether a study was selected.
private final class MediaCopyTally: @unchecked Sendable {
    let copyFailureDetails = NSMutableArray()
    let refusedSources = NSMutableArray()
    var copiedTotal = 0
    var indexedTotal = 0
    var studySelected = false
}

@objc(MediaCopy) @implementation extension DicomDatabase {

    func copyFilesThread(_ dict: [AnyHashable: Any]!) {
        autoreleasepool {
            let dict = (dict as NSDictionary?) ?? NSDictionary()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1

            let onlyDICOM = (dict.object(forKey: "onlyDICOM") as? NSNumber)?.boolValue ?? false
            let copyFiles = (dict.object(forKey: "copyFiles") as? NSNumber)?.boolValue ?? false
            let mountedVolume = (dict.object(forKey: "mountedVolume") as? NSNumber)?.boolValue ?? false
            var failedCopies = 0
            // What was taken and what became a row. A medium pulled out mid-import
            // leaves the files it managed to copy in the database folder; whether any
            // of them were indexed was not written down anywhere, so the two counts
            // are kept and reported together at the end.
            let tally = MediaCopyTally()
            // The files the validation before importing refused, as the user gave
            // them: copies have a name of the database's own.
            let filesInput = ((dict.object(forKey: "filesInput") as? NSArray)?.sortedArray(using: #selector(NSString.compare(_:))) as NSArray?) ?? NSArray() // sorting the array should make the data access faster on optical media
            // The headers being imported, to know which .img files come with one.
            var inputHeaders = Set<String>()
            for case let path as String in filesInput where ((path as NSString).pathExtension as NSString).lowercased == "hdr" {
                inputHeaders.insert((path as NSString).lowercased)
            }

            var i = 0
            while i < filesInput.count {
                if Thread.current.isCancelled { break }

                let stop: Bool = autoreleasepool {
                    var cancelled = false
                    if let exception = DicomDatabaseObjC.attempt({
                        let copiedFiles = NSMutableArray()
                        let sourceOfCopy = NSMutableDictionary()
                        var lastGUIUpdate: TimeInterval = 0
                        let twentySeconds = Date.timeIntervalSinceReferenceDate + 5 // actually fiveSeconds

                        while i < filesInput.count && twentySeconds > Date.timeIntervalSinceReferenceDate {
                            if Thread.current.isCancelled { break }

                            if Date.timeIntervalSinceReferenceDate - lastGUIUpdate > 1 {
                                lastGUIUpdate = Date.timeIntervalSinceReferenceDate

                                Thread.current.status = DicomDatabaseObjC.localizedCount(filesInput.count - i, NSLocalizedString("file left", comment: ""), NSLocalizedString("files left", comment: ""))
                                Thread.current.progress = CGFloat(Float(i) / Float(filesInput.count))
                            }

                            let srcPath = filesInput.object(at: i) as? String ?? ""

                            if copyFiles {
                                // An image whose header is imported too is copied with it, under
                                // the header's new name: copied on its own, under a number of its
                                // own, neither file could be read.
                                if let imageHeader = HeaderImagePair.headerPath(forImage: srcPath), inputHeaders.contains((imageHeader as NSString).lowercased) {
                                    i += 1
                                    continue
                                }

                                let fileExtension = DataFileExtension.forImportedFile(pathExtension: (srcPath as NSString).pathExtension, isDICOM: false)

                                var dstPath = self.uniquePathForNewDataFile(withExtension: fileExtension)

                                if let exception = DicomDatabaseObjC.attempt({
                                    DicomDatabaseObjC.synchronized(BrowserController.horos_oneCopyAtATimeLock()) {
                                        var copyError: NSError? = nil
                                        let copySucceeded = DicomDatabaseCopyFileForPublication(srcPath, dstPath ?? "", mountedVolume, &copyError)
                                        if !copySucceeded {
                                            failedCopies += 1
                                            if tally.copyFailureDetails.count == 0 {
                                                tally.copyFailureDetails.add(copyError?.localizedDescription ?? NSLocalizedString("The file could not be copied.", comment: ""))
                                            }
                                        }
                                        let pairedImage = copySucceeded ? HeaderImagePair.imagePath(forHeader: srcPath) : nil
                                        if let pairedImage, DicomDatabaseCopyFileForPublication(pairedImage, HeaderImagePair.imagePath(besideStoredHeader: dstPath ?? ""),
                                                                                                mountedVolume, &copyError) == false {
                                            failedCopies += 1
                                            if tally.copyFailureDetails.count == 0 {
                                                tally.copyFailureDetails.add(copyError?.localizedDescription ?? NSLocalizedString("The file could not be copied.", comment: ""))
                                            }
                                        }
                                        if copySucceeded, var copied = dstPath {
                                            if fileExtension != "dcm" {
                                                if DicomFile.isDICOMFile(copied) {
                                                    let newPathExtension = ((copied as NSString).deletingPathExtension as NSString).appendingPathExtension("dcm")
                                                    if let newPathExtension, (try? FileManager.default.moveItem(atPath: copied, toPath: newPathExtension)) != nil {
                                                        copied = newPathExtension
                                                    }
                                                }
                                            }
                                            dstPath = copied

                                            copiedFiles.add(copied)
                                            sourceOfCopy.setObject(srcPath, forKey: copied as NSString)
                                        }
                                    }
                                }) {
                                    DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase copyFilesThread:]")
                                }
                            } else {
                                if FileManager.default.fileExists(atPath: srcPath) {
                                    if mountedVolume {
                                        if let exception = DicomDatabaseObjC.attempt({
                                            if DicomFile(srcPath) != nil { // Pre-load for CD/DVD in cache
                                                copiedFiles.add(srcPath)
                                            } else {
                                                NSLog("**** DicomFile *curFile = nil")
                                            }
                                        }) {
                                            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]")
                                        }
                                    } else {
                                        if UserDefaults.standard.bool(forKey: "validateFilesBeforeImporting") && mountedVolume == false { // mountedVolume : it's too slow to test the files now from a CD
                                            // Pre-load for faster validating
                                            _ = NSData(contentsOfFile: srcPath)
                                        }
                                        copiedFiles.add(srcPath)
                                    }
                                }
                            }

                            if Thread.current.isCancelled {
                                break
                            }
                            i += 1
                        }

                        self.queueIndexing(of: copiedFiles, sourceOfCopy: sourceOfCopy, settings: dict, onlyDICOM: onlyDICOM, copyFiles: copyFiles,
                                           mountedVolume: mountedVolume, tally: tally, on: queue)

                        if Thread.current.isCancelled {
                            cancelled = true
                        }
                    }) {
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]")
                    }
                    return cancelled
                }
                if stop { break }
            }

            // The queued work indexes files that are already in the database folder; it
            // does not touch the medium. Cancelling it threw that away: pulling a disc
            // out cancels the scan thread, which cancels this one, and the operation
            // holding the files copied so far was cancelled before it could run.
            // Measured on a disc of 1200 instances pulled out one second in: 373 files
            // copied, 0 indexed, and 373 files left in the database folder that no row
            // pointed at. Cancelling stops the copying; what is already copied is
            // indexed, so a cut-short import is a smaller import and not a hidden one.
            if queue.operationCount != 0 {
                Thread.current.status = NSLocalizedString("Waiting for subtasks to complete...", comment: "")
                while queue.operationCount != 0 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            // An import that took less than it was given says so, whether the shortfall
            // was in the copying or in the indexing. Both counts matter: files copied
            // into the database folder and never indexed are invisible to the browser
            // and to every clean-up that works from the database.
            let firstFailure = tally.copyFailureDetails.firstObject as? String
            if ImportShortfall.copyIsIncomplete(failedCopies: failedCopies, copied: tally.copiedTotal, indexed: tally.indexedTotal) {
                NSLog("%@", ImportShortfall.copyLogLine(offered: filesInput.count, copied: tally.copiedTotal, indexed: tally.indexedTotal,
                                                        failedCopies: failedCopies, firstFailure: firstFailure))
            }

            // Refused by the validation before importing: how many, why, and the
            // first of them, so that the user knows which files are missing.
            let refusedSources = (tally.refusedSources as? [String]) ?? []
            if !refusedSources.isEmpty {
                NSLog("(copyFilesThread): %lu file(s) refused by the validation before importing: %@", UInt(refusedSources.count), tally.refusedSources)
            }

            if let message = ImportShortfall.alertMessage(
                failedCopies: failedCopies, firstFailure: firstFailure, refusedFiles: refusedSources,
                copyFailed: NSLocalizedString("%lu file(s) could not be copied and were not indexed. Source files were preserved.\n\n%@\n\nFor OneDrive or another cloud provider, make the files available offline and retry. Also check access permissions and free disk space.", comment: ""),
                oneRefused: NSLocalizedString("1 file was not imported: the validation before importing found it damaged or unreadable.", comment: ""),
                manyRefused: NSLocalizedString("%lu files were not imported: the validation before importing found them damaged or unreadable.", comment: "")) {
                self.alertIncompleteImport(message)
            }

            if failedCopies == 0 && (dict.object(forKey: "ejectCDDVD") as? NSNumber)?.boolValue == true && copyFiles == true {
                if UserDefaults.standard.bool(forKey: "EJECTCDDVD"), let first = filesInput.firstObject as? String {
                    _ = NSWorkspace.shared.unmountAndEjectDevice(atPath: first)
                }
            }
        }
    }

    /// Queues the indexing of a batch: validated, indexed on a private-queue
    /// context, added to the browser's album, and its first study selected.
    private final func queueIndexing(of copiedFiles: NSMutableArray, sourceOfCopy: NSMutableDictionary, settings dict: NSDictionary, onlyDICOM: Bool,
                               copyFiles: Bool, mountedVolume: Bool, tally: MediaCopyTally, on queue: OperationQueue) {
        nonisolated(unsafe) let database = self
        nonisolated(unsafe) let copiedFiles = copiedFiles
        nonisolated(unsafe) let sourceOfCopy = sourceOfCopy
        nonisolated(unsafe) let dict = dict
        queue.addOperation {
            let thread = Thread.current
            thread.name = NSLocalizedString("Adding files...", comment: "")
            ThreadsManager.default()?.addThreadAndStart(thread)

            // The files the validation refuses are left out, and only
            // those: the rest of the batch is indexed.
            var acceptedFiles: NSArray = copiedFiles

            #if !OSIRIX_LIGHT
            thread.status = NSLocalizedString("Validating the files...", comment: "")
            if UserDefaults.standard.bool(forKey: "validateFilesBeforeImporting") && mountedVolume == false { // mountedVolume : it's too slow to test the files now from a CD
                let refused = (DicomDatabase.filesRefused(byValidation: copiedFiles as? [Any]) as NSArray?) ?? NSArray()
                if refused.count != 0 {
                    let refusedSet = NSSet(array: refused as? [Any] ?? [])
                    let accepted = NSMutableArray(capacity: copiedFiles.count)
                    for f in copiedFiles where !refusedSet.contains(f) {
                        accepted.add(f)
                    }
                    acceptedFiles = accepted

                    DicomDatabaseObjC.synchronized(tally.copyFailureDetails) {
                        for f in refused {
                            tally.refusedSources.add(sourceOfCopy.object(forKey: f) ?? f)
                        }
                    }

                    if copyFiles {
                        for case let f as String in refused {
                            try? FileManager.default.removeItem(atPath: f)
                        }
                    }
                }
            }
            #endif

            var objects: NSArray? = nil

            if acceptedFiles.count != 0 {
                thread.status = NSLocalizedString("Indexing the files...", comment: "")

                // Indexed on a context of its own queue, and on that queue.
                let idatabase = database.privateQueueIndependentDatabase() as? DicomDatabase
                var indexed: NSArray? = nil
                idatabase?.performBlockAndWait {
                    guard let idatabase else { return }
                    indexed = idatabase.addFiles(atPaths: acceptedFiles as? [Any], postNotifications: true, dicomOnly: onlyDICOM, rereadExistingItems: true,
                                                 generatedByOsiriX: false, importedFiles: true, returnArray: true) as NSArray?

                    let mdatabase = database.isMainDatabase() ? database : (database.mainDatabase as? DicomDatabase)
                    let browser = BrowserController.currentBrowser()
                    if browser?.database === mdatabase && (dict.object(forKey: "addToAlbum") as? NSNumber)?.boolValue == true {
                        if let iAlbum = browser?.currentAlbumID(idatabase) {
                            let album = idatabase.object(withID: iAlbum) as? NSManagedObject
                            let studies = album?.mutableSetValue(forKey: "studies")

                            var change = false
                            for case let mobject as NSManagedObject in (idatabase.objects(withIDs: indexed as? [Any]) as NSArray?) ?? [] {
                                if let s = mobject.value(forKeyPath: "series.study"), studies?.contains(s) == false {
                                    change = true
                                    studies?.add(s)
                                }
                            }

                            if change {
                                _ = idatabase.save()
                            }
                        }
                    }
                }
                objects = indexed

                DicomDatabaseObjC.synchronized(tally.copyFailureDetails) {
                    tally.copiedTotal += acceptedFiles.count
                    tally.indexedTotal += objects?.count ?? 0
                }
            }

            if let objects, objects.count != 0 {
                if let exception = DicomDatabaseObjC.attempt({
                    let bc = BrowserController.currentBrowser()

                    if let exception = DicomDatabaseObjC.attempt({
                        if tally.studySelected == false {
                            tally.studySelected = true
                            if (dict.object(forKey: "selectStudy") as? NSNumber)?.boolValue == true {
                                bc?.performSelector(onMainThread: #selector(BrowserController.selectStudy(withObjectID:)), with: objects.object(at: 0), waitUntilDone: false)
                            }
                        }
                    }) {
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]_block_invoke")
                    }
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]_block_invoke")
                }
            }

            ThreadsManager.default()?.remove(thread) // NSOperationQueue threads don't finish after ablock execution, they're recycled
        }
    }
}
