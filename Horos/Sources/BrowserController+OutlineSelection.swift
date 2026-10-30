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

// The selection of the study list: the thumbnails of the selected row, the
// history of its patient (the comparative studies) as the selection, the
// nodes and the new studies change it, and a study retrieved from the history
// that is waited for. What decides without the app's classes is IsiXDatabase's
// ComparativeHistory and OutlineSelection. The selectors are those of the
// former Objective-C methods, as the nib, the timers, the notifications and
// the plugins send them.

/// The NSIndexSet of one row.
private func oneRow(_ row: Int) -> IndexSet {
    IndexSet(integer: row)
}

/// [value boolValue] of a number or a string; NO for nil and the rest.
private func objcBoolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The NSException -addObject: raises for nil.
private func addObject(_ array: NSMutableArray, _ object: Any?) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil").raise()
        return
    }
    array.add(object)
}

extension BrowserController {

    /// The row of the first selected index of the list: nil without one.
    func selectedOutlineItem() -> Any? {
        guard let outline = horos_databaseOutline else { return nil }
        return outline.item(atRow: outline.selectedRowIndexes.first ?? NSNotFound)
    }

    /// The study of a row: the row itself, or its study.
    func studyOfRow(_ item: Any?) -> Any? {
        isRowType(item, "Study") ? item : rowValue(item, "study")
    }

    /// What -searchForComparativeStudies: takes for a study: the object ID of
    /// a local study, a study of a node itself.
    func comparativeSearchObject(_ study: Any?) -> Any? {
        if let study = study as? DicomStudy { return study.objectID }
        return study
    }

    /// The same row as before: the same object, or the same managed object.
    func isSameRow(_ item: Any?, _ previous: Any?) -> Bool {
        if (item as AnyObject?) === (previous as AnyObject?) { return true }
        guard let previous = previous as? NSManagedObject, let item = item as? NSManagedObject else { return false }
        return previous.objectID.isEqual(item.objectID)
    }

    /// The study instance UIDs of the history, nil without one.
    func comparativeStudyUIDs() -> [Any?]? {
        guard let studies = comparativeStudies as NSArray? else { return nil }
        return ((studies.value(forKey: "studyInstanceUID") as? NSArray) as? [Any])?.map { $0 is NSNull ? nil : $0 }
    }

    /// The header of the history's column.
    private func setHistoryHeader(_ title: String) {
        horos_comparativeTable?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Cell"))?.headerCell.stringValue = title
    }

    @objc(refreshPACSOnDemandResults:)
    func refreshPACSOnDemandResults(_ sender: Any!) {
        comparativePatientUID = nil
        comparativeStudies = nil

        BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
            horos_smartAlbumDistantArray = nil
        }

        smartAlbumDistantName = nil

        horos_previousItem = nil

        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: horos_albumTable, userInfo: nil)
        NotificationCenter.default.post(name: NSOutlineView.selectionDidChangeNotification, object: horos_databaseOutline, userInfo: nil)
    }

    @objc(refreshComparativeStudiesAndCheck:)
    func refreshComparativeStudiesAndCheck(_ newStudies: [Any]!) {
        refreshComparativeStudies(newStudies)
        checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: nil)
    }

    @objc(refreshComparativeStudies:)
    func refreshComparativeStudies(_ newStudies: [Any]!) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("***** We must be on MAIN thread")
        }

        if horos_databaseIvar == nil { return }

        let item = selectedOutlineItem()
        let studySelected = studyOfRow(item)
        let table = horos_comparativeTable

        if item != nil {
            horos_dontSelectStudyFromComparativeStudies = true

            let mainContextStudies = NSMutableArray()
            for study in newStudies ?? [] {
                if let study = study as? DicomStudy {
                    if let object = self.database?.object(withID: study.objectID) {
                        mainContextStudies.add(object)
                    }
                } else {
                    mainContextStudies.add(study)
                }
            }

            comparativeStudies = mainContextStudies as? [Any]
            table?.reloadData()

            if let name = rowValue(studySelected, "name") as? String {
                setHistoryHeader(name)
            }

            let index = ComparativeHistory.row(of: rowValue(studySelected, "studyInstanceUID"), in: comparativeStudyUIDs())

            horos_dontSelectStudyFromComparativeStudies = false

            table?.selectRowIndexes(oneRow(index ?? 0), byExtendingSelection: false)

            for case let viewer as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? [] {
                viewer.comparativeRefresh(comparativePatientUID)
            }

            table?.scrollRowToVisible(table?.selectedRow ?? 0)
        } else {
            comparativeStudies = nil
            table?.reloadData()
        }
    }

    @objc(refreshComparativeStudiesIfNeeded:)
    func refreshComparativeStudiesIfNeeded(_ timer: Any!) {
        if timer == nil {
            horos_lastRefreshComparativeStudies = 0
        }

        if ComparativeHistory.refreshDue(now: Date.timeIntervalSinceReferenceDate, last: horos_lastRefreshComparativeStudies) {
            let studySelected = studyOfRow(selectedOutlineItem())

            if let object = comparativeSearchObject(studySelected) {
                Thread.detachNewThreadSelector(#selector(search(forComparativeStudies:)), toTarget: self, with: object)
            }

            computeTimeInterval()
        }

        if UserDefaults.standard.bool(forKey: "searchForSmartAlbumStudiesOnDICOMNodes"), let albumTable = horos_albumTable, albumTable.selectedRow > 0 {
            let albumArray = self.albumArray() as NSArray?

            if (albumArray?.count ?? 0) > albumTable.selectedRow, let album = albumArray?.object(at: albumTable.selectedRow) as? DicomAlbum {
                if objcBoolValue(album.value(forKey: "smartAlbum")) {
                    if ComparativeHistory.refreshDue(now: Date.timeIntervalSinceReferenceDate, last: horos_lastRefreshSmartAlbumDistantStudies) {
                        Thread.detachNewThreadSelector(#selector(search(forSmartAlbumDistantStudies:)), toTarget: self, with: album.name)
                    }
                }
            }
        }

        if let waited = horos_comparativeStudyWaited { // Select it ! And open it if needed...
            if ComparativeHistory.stillWaiting(now: Date.timeIntervalSinceReferenceDate, since: horos_comparativeStudyWaitedTime) {
                DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()

                let request = NSFetchRequest<NSFetchRequestResult>()
                request.entity = self.database?.managedObjectModel?.entitiesByName["Study"]
                request.predicate = comparison("studyInstanceUID", .equalTo, waited.studyInstanceUID)

                var studyArray: [Any]?
                if let raised = BrowserObjC.attempt({ studyArray = try? self.database?.managedObjectContext?.fetch(request) }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController refreshComparativeStudiesIfNeeded:]")
                }

                if let study = studyArray?.first as? DicomStudy, (childrenArray(study)?.count ?? 0) > 0 {
                    if horos_comparativeStudyWaitedToSelect {
                        if selectThisStudy(study) {
                            horos_comparativeStudyWaited = nil

                            if horos_comparativeStudyWaitedToOpen, let viewer = horos_comparativeStudyWaitedViewer {
                                if viewer.window?.isVisible ?? false {
                                    viewer.loadSelectedSeries(study, rightClick: false)
                                }
                            } else if horos_comparativeStudyWaitedToOpen {
                                databaseOpenStudy(study)
                            }

                            if window?.firstResponder !== horos_searchField && window?.firstResponder !== horos_searchField?.currentEditor() {
                                window?.makeFirstResponder(horos_databaseOutline)
                            }

                            horos_comparativeStudyWaitedViewer = nil
                        }
                    } else {
                        horos_comparativeStudyWaited = nil
                        horos_comparativeStudyWaitedViewer = nil
                    }
                }
            } else {
                horos_comparativeStudyWaited = nil
                horos_comparativeStudyWaitedViewer = nil
            }
        }
    }

    @objc(_newStudiesRefreshComparativeStudies:)
    func _newStudiesRefreshComparativeStudies(_ aNotification: Notification!) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("***** We must be on MAIN thread")
        }

        if horos_databaseIvar == nil { return }

        let newStudies = aNotification?.userInfo?[OsirixAddToDBNotificationImagesArray] as? NSArray
        let table = horos_comparativeTable

        for newStudy in newStudies ?? [] {
            guard ComparativeHistory.isShownPatient(shown: comparativePatientUID, patientUID: rowValue(newStudy, "patientUID")) else { continue }

            let current = (comparativeStudies as NSArray?) ?? NSArray()
            let copy = NSMutableArray(array: current as [AnyObject])

            var selectedStudy: Any?
            if (table?.selectedRow ?? 0) >= 0 {
                selectedStudy = copy.object(at: table?.selectedRow ?? 0)
            }

            let history = ComparativeHistory.newStudy(rowValue(newStudy, "studyInstanceUID"),
                                                      uids: (0..<current.count).map { rowValue(current.object(at: $0), "studyInstanceUID") },
                                                      isQueryNode: { current.object(at: $0) is DCMTKStudyQueryNode })
            for index in history.replaced {
                let position = copy.index(of: current.object(at: index))
                if position != NSNotFound {
                    copy.replaceObject(at: position, with: newStudy)
                }
            }

            if !history.found {
                copy.add(newStudy)
                copy.sort(using: [NSSortDescriptor(key: "date", ascending: false)])
            }

            comparativeStudies = copy as? [Any]

            table?.reloadData()

            if let selectedStudy {
                let uids = ((copy.value(forKey: "studyInstanceUID") as? NSArray) as? [Any])?.map { $0 is NSNull ? nil : $0 }
                if let index = ComparativeHistory.row(of: rowValue(selectedStudy, "studyInstanceUID"), in: uids ?? []) {
                    table?.selectRowIndexes(oneRow(index), byExtendingSelection: false)
                }
            }
        }
    }

    @objc(outlineViewSelectionDidChange:)
    func outlineViewSelectionDidChange(_ aNotification: Notification!) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("***** We must be on MAIN thread")
        }

        BrowserObjC.synchronized(self) {
            horos_cachedAlbumsContext = nil
        }

        if !BrowserController.horos_loadingIsOver { return }

        if let raised = BrowserObjC.attempt({ self.showOutlineSelection() }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewSelectionDidChange:]")
        }
    }

    /// The thumbnails and the history of the selected row.
    private func showOutlineSelection() {
        horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles = nil
        horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects = nil
        horos_cachedFilesForDatabaseOutlineSelectionTreeObjects = nil
        horos_cachedFilesForDatabaseOutlineSelectionIndex = nil

        let outline = horos_databaseOutline
        let item = selectedOutlineItem()
        let matrix = horos_oMatrix
        let table = horos_comparativeTable

        if UserDefaults.standard.bool(forKey: "displaySamePatientWithColorBackground") {
            if horos_previousItem != nil {
                outline?.needsDisplay = true
            }
        }

        guard let item else {
            matrix?.selectCell(withTag: 0)
            matrixInit(0)

            horos_previousItem = nil

            horos_ROIsAndKeyImagesButtonAvailable = false

            distantStudyMessage = ""
            comparativePatientUID = nil
            comparativeStudies = nil
            table?.reloadData()
            setHistoryHeader(NSLocalizedString("History", comment: ""))

            resizeSplitViewVert()
            return
        }

        if isDistantRow(item) {
            // Check to see if already in retrieving mode, if not download it
            // Retrieve comparative studies only on double-click.
        } else {
            // Post notification of new selected item. Can be used by plugins to update RIS connection
            if let studySelected = studyOfRow(item) {
                NotificationCenter.default.post(name: .OsirixNewStudySelected, object: self,
                                                userInfo: ["Selected Study": studySelected])
            }
        }

        let sameRow = isSameRow(item, horos_previousItem)
        let nowFiles = Int(BrowserObjC.intValue(rowValue(item, "noFiles")))

        if !sameRow {
            horos_DatabaseIsEdited = false
        }
        let refreshMatrix = OutlineSelection.matrixNeedsRefresh(sameItem: sameRow, files: nowFiles, previousFiles: horos_previousNoOfFiles)

        horos_previousNoOfFiles = nowFiles

        if refreshMatrix {
            showThumbnails(of: item, sameRow: sameRow)
        }

        if (horos_previousItem as AnyObject?) !== (item as AnyObject) {
            horos_previousItem = item

            // COMPARATIVE STUDIES
            let studySelected = studyOfRow(item)

            if ComparativeHistory.patientChanged(selected: rowValue(studySelected, "patientUID"), shown: comparativePatientUID) {
                comparativePatientUID = rowValue(studySelected, "patientUID") as? String
                comparativeStudies = nil
                table?.reloadData()
                setHistoryHeader(NSLocalizedString("History", comment: ""))

                Thread.detachNewThreadSelector(#selector(search(forComparativeStudies:)), toTarget: self, with: comparativeSearchObject(studySelected))
            } else if let index = ComparativeHistory.row(of: rowValue(studySelected, "studyInstanceUID"), in: comparativeStudyUIDs()) {
                table?.selectRowIndexes(oneRow(index), byExtendingSelection: false)
                table?.scrollRowToVisible(table?.selectedRow ?? 0)
            }
        }

        if isDistantRow(item) {
            distantStudyMessage = NSLocalizedString("Double-click on the Study line to retrieve the images", comment: "")
        } else {
            distantStudyMessage = ""
        }

        resetROIsAndKeysButton()

        resizeSplitViewVert()
    }

    /// [self splitView:splitViewVert resizeSubviewsWithOldSize:[splitViewVert bounds].size].
    private func resizeSplitViewVert() {
        if let split = horos_splitViewVert {
            splitView(split, resizeSubviewsWithOldSize: split.bounds.size)
        }
    }

    /// The thumbnails of the selected row, keeping the selected ones when
    /// the row is the same.
    private func showThumbnails(of item: Any, sameRow: Bool) {
        var files: [Any]?
        let selectedRowColumns = NSMutableArray(), selectedCellsIDs = NSMutableArray()
        var imageLevel = false
        let matrix = horos_oMatrix

        N2ManagedObjectContextPerformAndWait(self.database?.managedObjectContext) {
            if let raised = BrowserObjC.attempt({
                let slider = self.horos_animationSlider
                slider?.isEnabled = false
                slider?.maxValue = 0
                slider?.numberOfTickMarks = 1
                slider?.intValue = 0

                if OutlineSelection.showsFrames(type: rowValue(item, "type"),
                                                imageCount: { (rowValue(item, "images") as? NSSet)?.count ?? 0 },
                                                frames: { rowValue((rowValue(item, "images") as? NSSet).flatMap(objcAllObjects)?.firstObject, "numberOfFrames") }) {
                    self.horos_matrixViewArray = [item]
                } else {
                    self.horos_matrixViewArray = self.childrenArray(item)
                }
                self.horosPrepareExcludedSeries(of: item)

                if sameRow {
                    for case let cell as NSButtonCell in matrix?.cells ?? [] {
                        var row = 0, column = 0
                        if cell.state == .on && !cell.isTransparent && (matrix?.getRow(&row, column: &column, of: cell) ?? false) {
                            if let represented = cell.representedObject {
                                selectedCellsIDs.add(represented) // For NSMainThread situation
                                selectedRowColumns.add(["row": NSNumber(value: row), "column": NSNumber(value: column)] as NSDictionary) //For background thread situation
                            }
                        }
                    }
                } else {
                    matrix?.selectCell(withTag: 0)
                }

                self.matrixInit(self.horos_matrixViewArray?.count ?? 0)

                files = self.imagesArray(item, preferredObject: SelectionImages.firstForFirst)
                imageLevel = item is DicomSeries

                if let thumbnails = self.horos_previewPixThumbnails {
                    BrowserObjC.synchronized(thumbnails) {
                        for _ in files ?? [] { addObject(thumbnails, self.horos_notFoundImage) }
                    }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewSelectionDidChange:]")
            }
        }

        // If series level, and less than 5 thumbnails to compute: do it on main thread: faster, and no-blinking icons...
        let separateThread = OutlineSelection.iconsOnSeparateThread(imageLevel: imageLevel, missingThumbnails: {
            var thumbnailsToGenerate = 0
            for image in files ?? [] {
                if (rowValue(image, "series") as? NSManagedObject)?.primitiveValue(forKey: "thumbnail") == nil {
                    thumbnailsToGenerate += 1
                }
            }
            return thumbnailsToGenerate
        })

        BrowserObjC.synchronized(horos_previewPixThumbnails) {
            horos_matrixLoadIconsThread?.cancel()
            horos_matrixLoadIconsThread = nil

            let database = horos_databaseIvar
            let dict = BrowserObjC.dictionary(database, "DicomDatabase", (files as NSArray?)?.value(forKey: "objectID"), "objectIDs",
                                              NSNumber(value: imageLevel), "imageLevel", horos_previewPix, "Context", database, "DicomDatabase",
                                              NSNumber(value: horos_previewPixGeneration), "Generation")
            if separateThread {
                let thread = Thread(target: self, selector: #selector(matrixLoadIcons(_:)), object: dict)
                horos_matrixLoadIconsThread = thread
                thread.start()

                if sameRow {
                    for cell in matrix?.cells ?? [] {
                        cell.state = .off
                        cell.isHighlighted = false
                    }

                    for case let d as NSDictionary in selectedRowColumns {
                        let cell = matrix?.cell(atRow: Int(BrowserObjC.intValue(d.object(forKey: "row"))),
                                                column: Int(BrowserObjC.intValue(d.object(forKey: "column"))))
                        cell?.state = .on
                        cell?.isHighlighted = true
                    }
                }
            } else {
                matrixLoadIcons(dict as? [AnyHashable: Any])
                if sameRow {
                    matrix?.deselectAllCells()
                    var first = true
                    for cell in matrix?.cells ?? [] {
                        if let represented = cell.representedObject, selectedCellsIDs.contains(represented) {
                            if first {
                                matrix?.selectCell(cell)
                                first = false
                            } else {
                                cell.isHighlighted = true
                                cell.state = .on
                            }
                        }
                    }

                    matrixPressed(matrix)
                }
            }
        }
    }

    @objc(selectDatabaseOutline)
    func selectDatabaseOutline() {
        window?.makeFirstResponder(horos_databaseOutline)
    }

    @objc(refreshMatrix:)
    func refreshMatrix(_ sender: Any!) {
        horos_previousItem = nil // This will force the matrix update

        var firstResponderMatrix = false

        if window?.firstResponder === horos_oMatrix && window?.firstResponder !== horos_searchField
            && window?.firstResponder !== horos_searchField?.currentEditor() {
            window?.makeFirstResponder(horos_databaseOutline)
            firstResponderMatrix = true
        }

        NotificationCenter.default.post(name: NSOutlineView.selectionDidChangeNotification, object: horos_databaseOutline, userInfo: nil)

        horos_imageView?.display()

        if firstResponderMatrix && window?.firstResponder !== horos_searchField && window?.firstResponder !== horos_searchField?.currentEditor() {
            window?.makeFirstResponder(horos_oMatrix)
        }
    }
}
