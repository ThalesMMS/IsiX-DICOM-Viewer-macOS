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
import IsiXPreferences

/// %@ of a value: "(null)" for nil.
private func described(_ value: Any?) -> String {
    guard let value else { return "(null)" }
    return (value as AnyObject).description ?? "(null)"
}

/// [value boolValue] of a number or a string; NO for nil and the rest.
private func objcBoolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The objects a predicate keeps, in their order, as -filteredArrayUsingPredicate:
/// evaluated them.
private func kept(_ objects: [Any], by predicate: NSPredicate) -> [Any] {
    objects.filter { predicate.evaluate(with: $0) }
}

/// Deleting from the study list, and the queue of the files it removed from
/// the database: what the user is asked, the images of locked studies and of
/// albums, the links of files outside the database folder, the series and
/// studies left empty, and the files waiting to be deleted from the disk. What
/// decides without the app's classes is IsiXDatabase's StudyDeletion; the queue
/// itself is DatabaseDeleteQueue, which the browser keeps so that any thread
/// reaches it.
///
/// The study list, its alerts and the viewers live on the main thread, so this
/// does too. The browser keeps the selectors its menus, its toolbar, its
/// keyboard, its timer, the scripts, the query window and the plugins send, and
/// forwards them here. An Objective-C exception raised by a row is caught as the
/// former @try did.
@MainActor final class StudyDeletionJob {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: Deleting the selection

    /// "Delete": the selected rows, or the selected thumbnails, after asking.
    /// In an album that is not smart, the rows can also only leave the album.
    func deleteSelection(sender: Any?) {
        if browser.database?.isReadOnly ?? false { return }

        var result = 0
        let context = browser.database?.managedObjectContext
        let animationCheck = browser.horos_animationCheck
        let animState = animationCheck?.state ?? .off
        let outline = browser.horos_databaseOutline

        let matrixThumbnails = StudyDeletion.deletesThumbnails(hasSender: sender != nil, listAsked: {
            (sender is NSMenuItem && (sender as? NSMenuItem)?.menu === outline?.menu)
                || self.browser.window?.firstResponder === outline || self.browser.window?.firstResponder === self.browser.horos_comparativeTable
        })

        if !matrixThumbnails && (outline?.selectedRow ?? 0) == -1 { return }

        let level = matrixThumbnails ? NSLocalizedString("Selected Thumbnails", comment: "") : NSLocalizedString("Selected Lines", comment: "")

        if !matrixThumbnails {
            let rows = outline?.selectedRowIndexes ?? IndexSet()
            if StudyDeletion.onlyDistant(rows.lazy.map { isDistantRow(outline?.item(atRow: $0)) }) {
                HorosAlertPanel.runInformational(title: NSLocalizedString("Delete images", comment: ""),
                                                 message: String(format: NSLocalizedString("These studies are not stored locally, you cannot delete them", comment: "")),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        animationCheck?.state = .off

        let albums = browser.albumArray() ?? []
        let albumRow = browser.horos_albumTable?.selectedRow ?? 0

        switch StudyDeletion.question(albumRow: albumRow, thumbnails: matrixThumbnails,
                                      smartAlbum: { objcBoolValue(rowValue(albums[albumRow], "smartAlbum")) }) {
        case .deleteOrRemove:
            result = HorosAlertPanel.runInformational(
                title: NSLocalizedString("Delete/Remove images", comment: ""),
                message: String(format: NSLocalizedString("Do you want to only remove the selected images from the current album or delete them from the database? (%@)", comment: ""), level),
                defaultButton: NSLocalizedString("Delete", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                otherButton: NSLocalizedString("Remove from current album", comment: ""))
        case .delete:
            result = HorosAlertPanel.runInformational(
                title: NSLocalizedString("Delete images", comment: ""),
                message: String(format: NSLocalizedString("Are you sure you want to delete the selected images? (%@)", comment: ""), level),
                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
        }

        N2ManagedObjectContextPerformAndWait(context) {
            let database = self.browser.horos_databaseIvar

            if result == HorosAlertOtherResponse { // REMOVE FROM CURRENT ALBUMS, BUT DONT DELETE IT FROM THE DATABASE
                self.removeFromAlbum(albums[albumRow] as? DicomAlbum, in: database)
            } else if !(database?.isLocal() ?? false) {
                HorosAlertPanel.run(title: NSLocalizedString("Distant Database", comment: ""),
                                    message: String(format: NSLocalizedString("You cannot modify a Distant Database.", comment: "")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)

                animationCheck?.state = animState

                return
            }

            if result == HorosAlertDefaultResponse { // REMOVE AND DELETE IT FROM THE DATABASE
                // The browser's selection methods fill the arrays they are handed.
                let objectsToDelete = NSMutableArray()
                let objectsToDeleteTree = NSMutableSet()

                if matrixThumbnails {
                    _ = self.browser.files(forDatabaseMatrixSelection: objectsToDelete, onlyImages: false)
                } else {
                    _ = self.browser.files(forDatabaseOutlineSelection: objectsToDelete, treeObjects: objectsToDeleteTree, onlyImages: false)
                }

                if (outline?.selectedRow ?? 0) >= 0 {
                    let selectedRows = outline?.selectedRowIndexes ?? IndexSet()

                    self.delete(objectsToDelete, tree: objectsToDeleteTree)

                    if let firstRow = selectedRows.first {
                        outline?.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
                    }
                }
            }
        }

        animationCheck?.state = animState
    }

    /// Takes the selected studies out of the album, without deleting them, and
    /// tells a shared database's server.
    private func removeFromAlbum(_ album: DicomAlbum?, in database: DicomDatabase?) {
        let outline = browser.horos_databaseOutline
        let selectedRows = outline?.selectedRowIndexes ?? IndexSet()
        if let firstRow = selectedRows.first {
            var studiesToRemove: [DicomStudy] = []

            for row in selectedRows {
                if let study = outline?.item(atRow: row) as? DicomStudy, album?.studies?.contains(study) ?? false, !studiesToRemove.contains(study) {
                    studiesToRemove.append(study)
                }
            }

            for study in studiesToRemove {
                album?.removeStudiesObject(study)
                study.archiveAnnotationsAsDICOMSR()
            }

            if !(database?.isLocal() ?? false) { // notify the remote database about the removal of the selected studies from the current album
                (database as? RemoteDicomDatabase)?.removeStudies(studiesToRemove, fromAlbum: album)
            }

            outline?.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
        }

        let wait = WaitRendering(NSLocalizedString("Updating database...", comment: ""))
        wait?.showWindow(browser)

        if let raised = HorosObjCException.caught({
            _ = database?.save(nil)

            self.browser.outlineViewRefresh()
            self.browser.refreshAlbums()
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController delItem:]")
        }

        wait?.close()

        browser.refreshMatrix(browser)

        QueryController.current()?.executeRefresh(browser)
        QueryController.currentAuto()?.executeRefresh(browser)
    }

    /// Deletes these images, after the questions: the images of locked studies
    /// stay, the images of albums stay when the user says so, and the files
    /// outside the database folder are only unlinked unless the user deletes
    /// them too. The array loses the images that stay, as it always did.
    func delete(_ objectsToDelete: NSMutableArray?, tree treeObjs: NSMutableSet?) {
        let context = browser.database?.managedObjectContext

        N2ManagedObjectContextPerformAndWait(context) {
            // Are some images locked?
            let lockedImages = (objectsToDelete as? [Any]).map { kept($0, by: NSPredicate(format: "series.study.lockedStudy == YES")) }

            switch StudyDeletion.locked(lockedImages?.count ?? 0, of: objectsToDelete?.count ?? 0) {
            case .all:
                HorosAlertPanel.run(title: NSLocalizedString("Locked Studies", comment: ""),
                                    message: String(format: NSLocalizedString("These images are stored in locked studies. First, unlock these studies to delete them.", comment: "")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            case .some, .none:
                var cancelled = false

                if let lockedImages, !lockedImages.isEmpty {
                    objectsToDelete?.removeObjects(in: lockedImages)

                    HorosAlertPanel.runInformational(title: NSLocalizedString("Locked Studies", comment: ""),
                                                     message: String(format: NSLocalizedString("Some images are stored in locked studies. Only unlocked images will be deleted.", comment: "")),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }

                // Are some images in albums?
                if (self.browser.horos_albumTable?.selectedRow ?? 0) == 0 {
                    if let raised = HorosObjCException.caught({
                        let albumedImages = (objectsToDelete as? [Any]).map { kept($0, by: NSPredicate(format: "series.study.albums.@count > 0")) }

                        if let albumedImages, !albumedImages.isEmpty {
                            let result = HorosAlertPanel.runInformational(
                                title: NSLocalizedString("Images in Albums", comment: ""),
                                message: String(format: NSLocalizedString("Some or all of these images are stored in albums. Do you really want to delete these images, stored in albums?\r\rDelete all images or only those not stored in an album?", comment: "")),
                                defaultButton: NSLocalizedString("All", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                otherButton: NSLocalizedString("Only if not stored in an album", comment: ""))

                            if result == HorosAlertOtherResponse {
                                objectsToDelete?.removeObjects(in: albumedImages)
                            }

                            if result == HorosAlertAlternateResponse {
                                cancelled = true
                            }
                        }
                    }) {
                        NSLog("series.study.albums.@count exception: %@", raised)
                        _ = raised.printStackTrace()
                    }
                }

                if !cancelled {
                    self.deleteAfterAsking(objectsToDelete as? [Any], tree: treeObjs, locked: lockedImages?.count ?? 0)
                }
            }
        }

        browser.refreshMatrix(browser)

        QueryController.current()?.executeRefresh(browser)
        QueryController.currentAuto()?.executeRefresh(browser)
    }

    /// Asks about the images outside the database folder, if any, then deletes:
    /// their links only, or their files too.
    private func deleteAfterAsking(_ objectsToDelete: [Any]?, tree treeObjs: NSSet?, locked: Int) {
        NSLog("locked images: %d", Int32(truncatingIfNeeded: locked))

        // Try to find images that aren't stored in the local database
        let wait = WaitRendering(NSLocalizedString("Deleting...", comment: ""))
        wait?.showWindow(browser)

        // The path of each, nil where an image has none, as -valueForKey: listed them.
        let nonLocalImagesPath = objectsToDelete.map {
            kept($0, by: NSPredicate(format: "inDatabaseFolder == NO")).map { ($0 as? DicomImage)?.completePath() as String? }
        }

        let result: Int
        if (nonLocalImagesPath?.count ?? 0) > 0 {
            wait?.window?.orderOut(browser)

            NSLog("non-local images : %d", Int32(truncatingIfNeeded: nonLocalImagesPath?.count ?? 0))

            result = HorosAlertPanel.runInformational(
                title: NSLocalizedString("Delete/Remove images", comment: ""),
                message: String(format: NSLocalizedString("Some of the selected images are not stored in the Database folder. Do you want to only remove the links of these images from the database or also delete the original files?", comment: "")),
                defaultButton: NSLocalizedString("Remove the links", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                otherButton: NSLocalizedString("Delete the files", comment: ""))

            wait?.window?.makeKeyAndOrderFront(browser)
        } else {
            result = HorosAlertDefaultResponse
        }

        if let raised = HorosObjCException.caught({
            if result == HorosAlertAlternateResponse {
                NSLog("Cancel")
            } else {
                if result == HorosAlertDefaultResponse || result == HorosAlertOtherResponse {
                    self.proceedDelete(objectsToDelete, tree: treeObjs)
                }

                if result == HorosAlertOtherResponse {
                    for path in (nonLocalImagesPath ?? []).compactMap({ $0 }) {
                        Self.deleteFile(atPath: path)
                    }
                }
            }
        }) {
            NSLog("***** exception in %@: %@", "-[BrowserController delObjects:tree:]", raised)
        }
        wait?.close()
    }

    /// Deletes a file outside the database folder, the .img of an ANALYZE
    /// .hdr with it, and its folder when nothing is left in it.
    private static func deleteFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)

        if let companion = StudyDeletion.companionFile(of: path) { // ANALYZE -> DELETE IMG
            try? FileManager.default.removeItem(atPath: companion)
        }

        let currentDirectory = (path as NSString).deletingLastPathComponent + "/"
        let dirContent = try? FileManager.default.contentsOfDirectory(atPath: currentDirectory)

        //Is this directory empty?? If yes, delete it!
        if StudyDeletion.removesFolder(contents: dirContent) {
            try? FileManager.default.removeItem(atPath: currentDirectory)
        }
    }

    /// Deletes these objects from the database, without asking: the viewers
    /// showing their series close, the series and studies left empty go, the
    /// others count their images again. A deletion the database cannot record
    /// is rolled back and reported.
    func proceedDelete(_ objectsToDelete: [Any]?, tree treeObjs: NSSet?) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("************ This is a MAIN thread only function")
        }

        let database = browser.horos_databaseIvar
        let context = database?.managedObjectContext
        var refreshComparative = false
        var saveError: NSError?
        var deletionSaved = false

        let seriesSet = NSMutableSet(), studiesSet = NSMutableSet()

        browser.horos_reportFilesToCheck?.removeAllObjects()

        N2ManagedObjectContextPerformAndWait(context) {
            if let raised = HorosObjCException.caught({
                var study: AnyObject?, series: AnyObject?

                NSLog("objects to delete : %d", Int32(truncatingIfNeeded: objectsToDelete?.count ?? 0))

                for obj in objectsToDelete ?? [] {
                    autoreleasepool {
                        // ********* SERIES
                        let objectSeries = rowValue(obj, "series") as AnyObject?
                        if objectSeries !== series {
                            series = objectSeries

                            if !(series.map { seriesSet.contains($0) } ?? false) {
                                if let series { seriesSet.add(series) }

                                // Is a viewer containing this series opened? -> close it
                                for case let vc as ViewerController in (ViewerController.getDisplayed2DViewers() as? [Any]) ?? [] {
                                    if series === (rowValue(vc.fileList()?.firstObject, "series") as AnyObject?) {
                                        vc.window?.close()
                                    }
                                }
                            }

                            // ********* STUDY
                            let seriesStudy = rowValue(series, "study") as AnyObject?
                            if seriesStudy !== study {
                                study = seriesStudy

                                if !(study.map { studiesSet.contains($0) } ?? false) {
                                    if let study { studiesSet.add(study) }

                                    // Is a viewer containing this series opened? -> close it
                                    for case let vc as ViewerController in (ViewerController.getDisplayed2DViewers() as? [Any]) ?? [] {
                                        let shown = rowValue(rowValue(vc.fileList()?.firstObject, "series"), "study") as AnyObject?
                                        if study === shown {
                                            vc.buildMatrixPreview()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                for obj in objectsToDelete ?? [] {
                    context?.perform(NSSelectorFromString("deleteObject:"), with: obj)
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController proceedDeleteObjects:tree:]")
            }

            for o in treeObjs ?? NSSet() {
                if let series = o as? DicomSeries {
                    if let study = series.study { studiesSet.add(study) }
                } else if o is DicomStudy {
                    studiesSet.add(o)
                }
            }

            if let raised = HorosObjCException.caught({
                // Remove series without images !
                for case let series as DicomSeries in seriesSet {
                    autoreleasepool {
                        if let raised = HorosObjCException.caught({
                            if !series.isDeleted {
                                switch StudyDeletion.series(remainingImages: series.images?.count ?? 0) {
                                case .remove:
                                    context?.delete(series)
                                case .recount:
                                    series.numberOfImages = NSNumber(value: 0)
                                    series.thumbnail = nil
                                }
                            }
                        }) {
                            BrowserObjC.log(raised, stack: true, "-[BrowserController proceedDeleteObjects:tree:]")
                        }
                    }
                }

                // Remove studies without series !
                for case let study as DicomStudy in studiesSet {
                    autoreleasepool {
                        if let raised = HorosObjCException.caught({
                            if ComparativeHistory.isShownPatient(shown: self.browser.comparativePatientUID, patientUID: study.patientUID) {
                                refreshComparative = true
                            }

                            if !study.isDeleted {
                                switch StudyDeletion.study(remainingImageSeries: study.imageSeries()?.count ?? 0) {
                                case .remove:
                                    NSLog("Delete Study: %@ - %@", described(study.patientID), described(study.studyInstanceUID))

                                    // Its placeholders of series a node's rule left out go with it.
                                    if let uid = study.studyInstanceUID, !uid.isEmpty, let folder = database?.dataBaseDirPath, !folder.isEmpty {
                                        ExcludedSeries.forget(study: uid, database: folder)
                                    }
                                    context?.delete(study)
                                case .recount:
                                    study.numberOfImages = NSNumber(value: 0)
                                    study.modality = study.modalities()
                                }
                            }
                        }) {
                            BrowserObjC.log(raised, stack: true, "-[BrowserController proceedDeleteObjects:tree:]")
                        }
                    }
                }

                self.browser.horos_previousItem = nil
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController proceedDeleteObjects:tree:]")
            }

            // The result of this save used to be dropped. On a volume that is full, or
            // read-only, or gone, the rows stayed in the store while the outline was
            // reloaded without them - so the deletion looked done, and the studies were
            // back at the next launch. Put them back in view and say what happened
            // instead of showing a success that did not happen.
            if let database {
                deletionSaved = database.save(&saveError)
            }
            if !deletionSaved {
                NSLog("---- delete: %d object(s) could not be deleted: %@", Int32(truncatingIfNeeded: objectsToDelete?.count ?? 0),
                      described(saveError?.localizedDescription))
                context?.rollback()
            } else if let database {
                // The albums read the count of a study without asking. It is taken
                // after the save: until then every look at a study's series goes
                // through all that was deleted, which in a large deletion takes
                // longer than the deletion. A study that went has no context.
                for case let study as DicomStudy in studiesSet where study.managedObjectContext != nil {
                    _ = study.noFiles()
                }
                var countError: NSError?
                if !database.save(&countError) {
                    NSLog("---- delete: the image counts could not be stored: %@", described(countError?.localizedDescription))
                }
            }
        }

        if !deletionSaved && !preferences[NetworkPreferences.hidesListenerErrors] {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Delete Failed", comment: ""),
                                        message: String(format: "%@\r\r%@",
                                                        NSLocalizedString("The database could not record this deletion, so nothing was deleted.", comment: ""),
                                                        saveError?.localizedDescription ?? NSLocalizedString("No reason was given.", comment: "")),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        browser.outlineViewRefresh()
        browser.refreshAlbums()

        // The history of the patient shown lost a study: it is searched again.
        if refreshComparative && browser.database != nil {
            browser.patientHistory.search(browser.comparativeSearchObject(browser.studyOfRow(browser.selectedOutlineItem())))
        }
    }

    // MARK: The delete queue

    private var queue: DatabaseDeleteQueue { browser.transferState.deleteQueue }

    /// Saves the files still queued, with those of a former saved queue.
    func saveQueue() {
        queue.save(in: browser.horos_databaseBaseDirPath)
    }

    /// Empties the queue now, after a deletion in progress.
    func deleteQueueNow() {
        queue.deleteNow(in: browser.horos_databaseBaseDirPath, report: Self.failureReport(to: browser))
    }

    /// The timer's turn: reads a Q&R listener error, takes back a saved queue,
    /// starts the deletion thread and saves the deletions of the database.
    func timerTurn() {
        // The errors of the Q&R DICOM functions, written by dcmqrsrv.mm. The
        // former code made an alert of the message and never ran it, so the
        // message is only logged when the listener's errors are hidden: that
        // there was one and how long it is, since nothing says what it holds.
        let errorFile = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("error_message")
        var encoding = String.Encoding.utf8
        if let message = try? String(contentsOfFile: errorFile, usedEncoding: &encoding) {
            try? FileManager.default.removeItem(atPath: errorFile)
            if preferences[NetworkPreferences.hidesListenerErrors] {
                NSLog("*** DICOM Network Error (not displayed - hideListenerError): %@", LogText.shape(of: message))
            }
        }

        queue.takeBackSavedQueue(in: browser.horos_databaseBaseDirPath)
        let browser = self.browser
        queue.startDeletion(in: { browser.horos_databaseBaseDirPath }, report: Self.failureReport(to: browser))

        if let context = browser.database?.managedObjectContext, !context.deletedObjects.isEmpty {
            NSLog("---- self.database.managedObjectContext.deletedObjects.count (%d) > 0 -> save db", Int32(context.deletedObjects.count))
            _ = browser.database?.save()
        }
    }

    /// Deletes the queued files of the browser's database on the calling thread.
    nonisolated static func deleteQueued(of browser: BrowserController) {
        browser.transferState.deleteQueue.deleteQueued(in: browser.horos_databaseBaseDirPath, report: failureReport(to: browser))
    }

    /// Tells the browser of the files that could not be deleted, from the deleting thread.
    private nonisolated static func failureReport(to browser: BrowserController) -> @Sendable ([DeleteQueueRules.Failure]) -> Void {
        { failures in onMainActor { browser.deletion.showFailures(failures) } }
    }

    /// Tells the user, in a sheet on the browser window, that files removed
    /// from the database are still on the disk: the first of them and why.
    func showFailures(_ failures: [DeleteQueueRules.Failure]) {
        guard !failures.isEmpty, let window = browser.window else { return }
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
}
