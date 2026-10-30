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

// Deleting from the study list: what the user is asked, the images of locked
// studies and of albums, the links of files outside the database folder, and
// the series and studies left empty. What decides without the app's classes is
// IsiXDatabase's StudyDeletion. The selectors are those of the former
// Objective-C methods, as the menus, the keyboard, the scripts and the query
// window send them.

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

/// -addObject: of a set, which raises for nil.
private func addToSet(_ set: NSMutableSet, _ object: Any?) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSSetM addObject:]: object cannot be nil").raise()
        return
    }
    set.add(object)
}

extension BrowserController {

    @objc(proceedDeleteObjects:tree:)
    func proceedDelete(_ objectsToDelete: [Any]!, tree treeObjs: NSSet!) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("************ This is a MAIN thread only function")
        }

        let database = horos_databaseIvar
        let context = database?.managedObjectContext
        var refreshComparative = false
        var saveError: NSError?
        var deletionSaved = false

        let seriesSet = NSMutableSet(), studiesSet = NSMutableSet()

        horos_reportFilesToCheck?.removeAllObjects()

        N2ManagedObjectContextPerformAndWait(context) {
            if let raised = BrowserObjC.attempt({
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
                                for case let vc as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? [] {
                                    if series === (rowValue((vc.fileList() as NSArray?)?.object(at: 0), "series") as AnyObject?) {
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
                                    for case let vc as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? [] {
                                        let shown = ((vc.fileList() as NSArray?)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study") as AnyObject?
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
                if o is DicomSeries {
                    addToSet(studiesSet, rowValue(o, "study"))
                } else if o is DicomStudy {
                    studiesSet.add(o)
                }
            }

            if let raised = BrowserObjC.attempt({
                // Remove series without images !
                for case let series as DicomSeries in seriesSet {
                    autoreleasepool {
                        if let raised = BrowserObjC.attempt({
                            if !series.isDeleted {
                                if (series.images?.count ?? 0) == 0 {
                                    context?.delete(series)
                                } else {
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
                        if let raised = BrowserObjC.attempt({
                            if ComparativeHistory.isShownPatient(shown: self.comparativePatientUID, patientUID: study.patientUID) {
                                refreshComparative = true
                            }

                            if !study.isDeleted {
                                if (study.imageSeries()?.count ?? 0) == 0 {
                                    NSLog("Delete Study: %@ - %@", described(study.patientID), described(study.studyInstanceUID))

                                    // Its placeholders of series a node's rule left out go with it.
                                    if let uid = study.studyInstanceUID, !uid.isEmpty, let folder = database?.dataBaseDirPath, !folder.isEmpty {
                                        ExcludedSeries.forget(study: uid, database: folder)
                                    }
                                    context?.delete(study)
                                } else {
                                    study.setValue(NSNumber(value: 0), forKey: "numberOfImages")
                                    study.setValue(study.value(forKey: "modalities"), forKey: "modality")
                                }
                            }
                        }) {
                            BrowserObjC.log(raised, stack: true, "-[BrowserController proceedDeleteObjects:tree:]")
                        }
                    }
                }

                self.horos_previousItem = nil
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController proceedDeleteObjects:tree:]")
            }

            for case let study as DicomStudy in studiesSet {
                _ = study.noFiles
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
            }
        }

        if !deletionSaved && !UserDefaults.standard.bool(forKey: "hideListenerError") {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Delete Failed", comment: ""),
                                        message: String(format: "%@\r\r%@",
                                                        NSLocalizedString("The database could not record this deletion, so nothing was deleted.", comment: ""),
                                                        saveError?.localizedDescription ?? NSLocalizedString("No reason was given.", comment: "")),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        outlineViewRefresh()
        refreshAlbums()

        if refreshComparative {
            let studySelected = studyOfRow(selectedOutlineItem())
            Thread.detachNewThreadSelector(#selector(search(forComparativeStudies:)), toTarget: self, with: comparativeSearchObject(studySelected))
        }
    }

    @objc(proceedDeleteObjects:)
    func proceedDelete(_ objectsToDelete: [Any]!) {
        proceedDelete(objectsToDelete, tree: nil)
    }

    @objc(delObjects:tree:)
    func delObjects(_ objectsToDelete: NSMutableArray!, tree treeObjs: NSMutableSet!) {
        let context = self.database?.managedObjectContext

        N2ManagedObjectContextPerformAndWait(context) {
            // Are some images locked?
            let lockedImages = objectsToDelete.map { objcFiltered($0, NSPredicate(format: "series.study.lockedStudy == YES")) }

            switch StudyDeletion.locked(lockedImages?.count ?? 0, of: objectsToDelete?.count ?? 0) {
            case .all:
                HorosAlertPanel.run(title: NSLocalizedString("Locked Studies", comment: ""),
                                    message: String(format: NSLocalizedString("These images are stored in locked studies. First, unlock these studies to delete them.", comment: "")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            case .some, .none:
                var cancelled = false

                if let lockedImages, lockedImages.count > 0 {
                    objectsToDelete?.removeObjects(in: lockedImages as? [Any] ?? [])

                    HorosAlertPanel.runInformational(title: NSLocalizedString("Locked Studies", comment: ""),
                                                     message: String(format: NSLocalizedString("Some images are stored in locked studies. Only unlocked images will be deleted.", comment: "")),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }

                // Are some images in albums?
                if (self.horos_albumTable?.selectedRow ?? 0) == 0 {
                    if let raised = BrowserObjC.attempt({
                        let albumedImages = objectsToDelete.map { objcFiltered($0, NSPredicate(format: "series.study.albums.@count > 0")) }

                        if let albumedImages, albumedImages.count > 0 {
                            let result = HorosAlertPanel.runInformational(
                                title: NSLocalizedString("Images in Albums", comment: ""),
                                message: String(format: NSLocalizedString("Some or all of these images are stored in albums. Do you really want to delete these images, stored in albums?\r\rDelete all images or only those not stored in an album?", comment: "")),
                                defaultButton: NSLocalizedString("All", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                otherButton: NSLocalizedString("Only if not stored in an album", comment: ""))

                            if result == HorosAlertOtherResponse {
                                objectsToDelete?.removeObjects(in: albumedImages as? [Any] ?? [])
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
                    NSLog("locked images: %d", Int32(truncatingIfNeeded: lockedImages?.count ?? 0))

                    // Try to find images that aren't stored in the local database
                    let wait = WaitRendering(NSLocalizedString("Deleting...", comment: ""))
                    wait?.showWindow(self)

                    let nonLocalImagesPath = objectsToDelete.flatMap {
                        objcFiltered($0, NSPredicate(format: "inDatabaseFolder == NO")).value(forKey: "completePath") as? NSArray
                    }

                    let result: Int
                    if (nonLocalImagesPath?.count ?? 0) > 0 {
                        wait?.window?.orderOut(self)

                        NSLog("non-local images : %d", Int32(truncatingIfNeeded: nonLocalImagesPath?.count ?? 0))

                        result = HorosAlertPanel.runInformational(
                            title: NSLocalizedString("Delete/Remove images", comment: ""),
                            message: String(format: NSLocalizedString("Some of the selected images are not stored in the Database folder. Do you want to only remove the links of these images from the database or also delete the original files?", comment: "")),
                            defaultButton: NSLocalizedString("Remove the links", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                            otherButton: NSLocalizedString("Delete the files", comment: ""))

                        wait?.window?.makeKeyAndOrderFront(self)
                    } else {
                        result = HorosAlertDefaultResponse
                    }

                    if let raised = BrowserObjC.attempt({
                        if result == HorosAlertAlternateResponse {
                            NSLog("Cancel")
                        } else {
                            if result == HorosAlertDefaultResponse || result == HorosAlertOtherResponse {
                                self.proceedDelete(objectsToDelete as? [Any], tree: treeObjs)
                            }

                            if result == HorosAlertOtherResponse {
                                for case let path as String in nonLocalImagesPath ?? [] {
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
                            }
                        }
                    }) {
                        NSLog("***** exception in %@: %@", "-[BrowserController delObjects:tree:]", raised)
                    }
                    wait?.close()
                }
            }
        }

        refreshMatrix(self)

        QueryController.current()?.executeRefresh(self)
        QueryController.currentAuto()?.executeRefresh(self)
    }

    @objc(delObjects:)
    func delObjects(_ objectsToDelete: NSMutableArray!) {
        delObjects(objectsToDelete, tree: nil)
    }

    @objc(delItem:)
    func delItem(_ sender: Any!) {
        if self.database?.isReadOnly ?? false { return }

        var result = 0
        let context = self.database?.managedObjectContext
        let animState = horos_animationCheck?.state ?? .off
        let outline = horos_databaseOutline

        let matrixThumbnails = StudyDeletion.deletesThumbnails(hasSender: sender != nil, listAsked: {
            (sender is NSMenuItem && (sender as? NSMenuItem)?.menu === outline?.menu)
                || self.window?.firstResponder === outline || self.window?.firstResponder === self.horos_comparativeTable
        })

        if !matrixThumbnails && (outline?.selectedRow ?? 0) == -1 { return }

        let level = matrixThumbnails ? NSLocalizedString("Selected Thumbnails", comment: "") : NSLocalizedString("Selected Lines", comment: "")

        if !matrixThumbnails {
            var onlyDistantStudy = true

            for index in outline?.selectedRowIndexes ?? IndexSet() where !isDistantRow(outline?.item(atRow: index)) {
                onlyDistantStudy = false
                break
            }

            if onlyDistantStudy {
                HorosAlertPanel.runInformational(title: NSLocalizedString("Delete images", comment: ""),
                                                 message: String(format: NSLocalizedString("These studies are not stored locally, you cannot delete them", comment: "")),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        horos_animationCheck?.state = .off

        let albumArray = self.albumArray() as NSArray?
        let albumRow = horos_albumTable?.selectedRow ?? 0

        switch StudyDeletion.question(albumRow: albumRow, thumbnails: matrixThumbnails,
                                      smartAlbum: { objcBoolValue(rowValue(albumArray?.object(at: albumRow), "smartAlbum")) }) {
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
            let database = self.horos_databaseIvar

            if result == HorosAlertOtherResponse { // REMOVE FROM CURRENT ALBUMS, BUT DONT DELETE IT FROM THE DATABASE
                let selectedRows = outline?.selectedRowIndexes ?? IndexSet()
                if let firstRow = selectedRows.first {
                    let studiesToRemove = NSMutableArray()
                    let album = albumArray?.object(at: albumRow) as? DicomAlbum

                    for row in selectedRows {
                        if let study = outline?.item(atRow: row) as? DicomStudy {
                            if (album?.value(forKey: "studies") as? NSSet)?.contains(study) ?? false, !studiesToRemove.contains(study) {
                                studiesToRemove.add(study)
                            }
                        }
                    }

                    let albumStudies = album?.mutableSetValue(forKey: "studies")
                    for case let study as DicomStudy in studiesToRemove {
                        albumStudies?.remove(study)
                        study.archiveAnnotationsAsDICOMSR()
                    }

                    if !(database?.isLocal() ?? false) { // notify the remote database about the removal of the selected studies from the current album
                        (database as? RemoteDicomDatabase)?.removeStudies(studiesToRemove as? [Any], fromAlbum: album)
                    }

                    outline?.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
                }

                let wait = WaitRendering(NSLocalizedString("Updating database...", comment: ""))
                wait?.showWindow(self)

                if let raised = BrowserObjC.attempt({
                    _ = database?.save(nil)

                    self.outlineViewRefresh()
                    self.refreshAlbums()
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController delItem:]")
                }

                wait?.close()

                self.refreshMatrix(self)

                QueryController.current()?.executeRefresh(self)
                QueryController.currentAuto()?.executeRefresh(self)
            } else if !(database?.isLocal() ?? false) {
                HorosAlertPanel.run(title: NSLocalizedString("Distant Database", comment: ""),
                                    message: String(format: NSLocalizedString("You cannot modify a Distant Database.", comment: "")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)

                self.horos_animationCheck?.state = animState

                return
            }

            if result == HorosAlertDefaultResponse { // REMOVE AND DELETE IT FROM THE DATABASE
                let objectsToDelete = NSMutableArray()
                let objectsToDeleteTree = NSMutableSet()

                if matrixThumbnails {
                    _ = self.files(forDatabaseMatrixSelection: objectsToDelete, onlyImages: false)
                } else {
                    _ = self.files(forDatabaseOutlineSelection: objectsToDelete, treeObjects: objectsToDeleteTree, onlyImages: false)
                }

                if (outline?.selectedRow ?? 0) >= 0 {
                    let selectedRows = outline?.selectedRowIndexes ?? IndexSet()

                    self.delObjects(objectsToDelete, tree: objectsToDeleteTree)

                    if let firstRow = selectedRows.first {
                        outline?.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
                    }
                }
            }
        }

        horos_animationCheck?.state = animState
    }
}
