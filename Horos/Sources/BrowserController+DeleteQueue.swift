/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase

// The delete queue of the browser: files removed from the database are
// deleted on a thread, a batch at a time; the queue is saved as
// DeleteQueueFile.plist in the database folder so that a batch interrupted by
// quitting is finished at the next launch. Which folders the deletion leaves
// empty is IsiXDatabase's DeleteQueueRules. The Q&R listener's error file is
// read on the same timer.

extension BrowserController {

    private nonisolated var deleteQueueFile: String {
        return ((horos_databaseBaseDirPath ?? "") as NSString).appendingPathComponent("DeleteQueueFile.plist")
    }

    /// The locks and the list, made the first time a file is queued.
    private nonisolated func prepareDeleteQueue() {
        if horos_deleteQueueArray == nil { horos_deleteQueueArray = NSMutableArray() }
        if horos_deleteQueue == nil { horos_deleteQueue = NSRecursiveLock() }
        if horos_deleteInProgress == nil { horos_deleteInProgress = NSRecursiveLock() }
    }

    /// The files of a former queue saved in the database folder, removed from it.
    private nonisolated func takeSavedDeleteQueue() -> [Any] {
        let path = deleteQueueFile
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let old = NSArray(contentsOfFile: path) as? [Any] ?? []
        NSLog("---- old Delete Queue List found (%d files) add it to current queue.", Int32(old.count))
        try? FileManager.default.removeItem(atPath: path)
        return old
    }

    @available(*, deprecated)
    @objc(resetListenerTimer)
    func resetListenerTimer() {
        DicomDatabase.syncImportFilesFromIncomingDirTimerWithUserDefaults()
    }

    /// Saves the files still queued, with those of a former saved queue.
    @objc(saveDeleteQueue)
    func saveDeleteQueue() {
        horos_deleteQueue?.lock()
        defer { horos_deleteQueue?.unlock() }
        var files = (horos_deleteQueueArray as? [Any]) ?? []
        horos_deleteQueueArray?.removeAllObjects()
        guard !files.isEmpty else { return }
        files += takeSavedDeleteQueue()
        NSLog("---- save delete queue: %d objects", Int32(files.count))
        let path = deleteQueueFile
        try? FileManager.default.removeItem(atPath: path)
        (files as NSArray).write(toFile: path, atomically: true)
    }

    /// Deletes the queued files, saving the queue first: a cancelled thread
    /// leaves it for later. Then removes the folders left empty.
    @objc(emptyDeleteQueueThread)
    nonisolated func emptyDeleteQueueThread() {
        autoreleasepool {
            horos_deleteInProgress?.lock()
            horos_deleteQueue?.lock()
            var files = (horos_deleteQueueArray as? [Any]) ?? []
            horos_deleteQueueArray?.removeAllObjects()
            files += takeSavedDeleteQueue()

            guard !files.isEmpty else {
                horos_deleteQueue?.unlock()
                horos_deleteInProgress?.unlock()
                return
            }
            NSLog("delete Queue start: %d objects", Int32(files.count))
            let path = deleteQueueFile
            try? FileManager.default.removeItem(atPath: path)
            (files as NSArray).write(toFile: path, atomically: true)
            horos_deleteQueue?.unlock()

            let thread = Thread.current
            let paths = files.compactMap { $0 as? String }
            var deleted = 0
            var failures: [DeleteQueueRules.Failure] = []
            var lastReport: TimeInterval = 0
            for file in paths {
                // unlink(2), faster than the file manager.
                if let failure = DeleteQueueRules.deleteFile(file) { failures.append(failure) }
                if Date.timeIntervalSinceReferenceDate - lastReport > 1 {
                    lastReport = Date.timeIntervalSinceReferenceDate
                    thread.progress = CGFloat(Float(deleted) / Float(paths.count))
                    thread.status = BrowserObjC.singularPlural(paths.count - deleted, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
                    // The queue is saved: a cancelled deletion goes on later.
                    if thread.isCancelled { break }
                }
                deleted += 1
            }
            thread.progress = CGFloat(Float(deleted) / Float(paths.count))
            thread.status = BrowserObjC.singularPlural(paths.count - deleted, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))

            if !thread.isCancelled {
                try? FileManager.default.removeItem(atPath: path)
            }
            horos_deleteInProgress?.unlock()

            if !failures.isEmpty {
                NSLog("delete Queue: %d of %d files could not be deleted", Int32(failures.count), Int32(paths.count))
                for failure in failures {
                    NSLog("delete Queue: could not delete %@: %@", failure.path, failure.reason)
                }
                let reported = failures
                onMainActor { BrowserController.currentBrowser()?.showDeleteQueueFailures(reported) }
            }

            thread.status = NSLocalizedString("Cleaning database folders...", comment: "")
            thread.progress = -1
            DeleteQueueRules.removeEmptyFolders(DeleteQueueRules.parentFolders(of: Array(paths.prefix(deleted + (deleted < paths.count ? 1 : 0)))))
            NSLog("delete Queue end")
        }
    }

    /// Tells the user, in a sheet on the browser window, that files removed
    /// from the database are still on the disk: the first of them and why.
    func showDeleteQueueFailures(_ failures: [DeleteQueueRules.Failure]) {
        guard !failures.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Some files could not be deleted", comment: "")
        let count = failures.count == 1
            ? NSLocalizedString("1 file removed from the database could not be deleted from the disk:", comment: "")
            : String(format: NSLocalizedString("%d files removed from the database could not be deleted from the disk:", comment: ""), Int32(failures.count))
        alert.informativeText = count + "\n\n" + DeleteQueueRules.failureList(failures)
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Empties the queue now, after a deletion in progress.
    @objc(emptyDeleteQueueNow:)
    func emptyDeleteQueueNow(_ sender: Any!) {
        horos_deleteInProgress?.lock()
        horos_deleteInProgress?.unlock()
        emptyDeleteQueueThread()
        horos_deleteInProgress?.lock()
        horos_deleteInProgress?.unlock()
    }

    /// The timer's turn: reports a Q&R listener error, takes back a saved
    /// queue, starts the deletion thread and saves the deletions of the
    /// database.
    @objc(emptyDeleteQueue:)
    func emptyDeleteQueue(_ sender: Any!) {
        if (AppController.shared()?.isSessionInactive ?? false) || BrowserController.horos_waitForRunningProcess { return }

        // The errors of the Q&R DICOM functions, written by dcmqrsrv.mm.
        let errorFile = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("error_message")
        var encoding = String.Encoding.utf8
        if let message = try? String(contentsOfFile: errorFile, usedEncoding: &encoding) {
            try? FileManager.default.removeItem(atPath: errorFile)
            let suppression = "hideListenerError"
            if !UserDefaults.standard.bool(forKey: suppression) {
                // The alert is made and never shown, as it always was: the
                // suppression box is read before anyone could tick it.
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("DICOM Network Error", comment: "")
                alert.informativeText = message
                alert.showsSuppressionButton = true
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(true, forKey: suppression)
                }
            } else {
                NSLog("*** DICOM Network Error (not displayed - hideListenerError): %@", message)
            }
        }

        prepareDeleteQueue()
        if horos_deleteInProgress?.try() == true {
            let old = takeSavedDeleteQueue()
            if !old.isEmpty {
                horos_deleteQueue?.lock()
                horos_deleteQueueArray?.addObjects(from: old)
                horos_deleteQueue?.unlock()
            }
            horos_deleteInProgress?.unlock()
        }

        if (horos_deleteQueueArray?.count ?? 0) > 0, horos_deleteInProgress?.try() == true {
            horos_deleteInProgress?.unlock()
            let thread = Thread(target: self, selector: #selector(emptyDeleteQueueThread), object: nil)
            thread.name = NSLocalizedString("Deleting files...", comment: "")
            thread.status = BrowserObjC.singularPlural(horos_deleteQueueArray?.count ?? 0, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
            thread.progress = 0
            thread.supportsCancel = true
            ThreadsManager.default()?.addThreadAndStart(thread)
        }

        if let context = database?.managedObjectContext, !context.deletedObjects.isEmpty {
            NSLog("---- self.database.managedObjectContext.deletedObjects.count (%d) > 0 -> save db", Int32(context.deletedObjects.count))
            _ = database?.save()
        }
    }

    /// Queues a file for deletion; from any thread.
    @objc(addFileToDeleteQueue:)
    nonisolated func addFile(toDeleteQueue file: String!) {
        prepareDeleteQueue()
        horos_deleteQueue?.lock()
        if let file { horos_deleteQueueArray?.add(file) }
        horos_deleteQueue?.unlock()
    }
}
