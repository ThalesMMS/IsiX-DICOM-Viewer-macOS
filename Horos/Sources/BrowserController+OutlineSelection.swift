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

// The selection of the study list: the thumbnails of the selected row, which
// BrowserPreviewPane shows, and the selectors through which the selection, the
// timers and the notifications reach the history of its patient (the
// comparative studies), which is PatientHistoryList's. What decides without the app's classes is
// IsiXDatabase's ComparativeHistory and OutlineSelection. The selectors are
// those of the former Objective-C methods, as the nib, the timers, the
// notifications and the plugins send them.

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

    @objc(refreshPACSOnDemandResults:)
    func refreshPACSOnDemandResults(_ sender: Any!) {
        comparativePatientUID = nil
        comparativeStudies = nil

        pacsOnDemand.listStudies.replace(with: nil)

        smartAlbumDistantName = nil

        horos_previousItem = nil

        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: horos_albumTable, userInfo: nil)
        NotificationCenter.default.post(name: NSOutlineView.selectionDidChangeNotification, object: horos_databaseOutline, userInfo: nil)
    }

    // The history beside the thumbnails is PatientHistoryList's; these are
    // the selectors the timer, the notifications and the searches send.

    func refreshComparativeStudiesAndCheck(_ newStudies: [Any]!) {
        refreshComparativeStudies(newStudies)
        checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: nil)
    }

    @objc(refreshComparativeStudies:)
    func refreshComparativeStudies(_ newStudies: [Any]!) {
        patientHistory.show(newStudies)
    }

    @objc(refreshComparativeStudiesIfNeeded:)
    func refreshComparativeStudiesIfNeeded(_ timer: Any!) {
        patientHistory.refreshIfNeeded(fromTimer: timer != nil)
    }

    @objc(_newStudiesRefreshComparativeStudies:)
    func _newStudiesRefreshComparativeStudies(_ aNotification: Notification!) {
        patientHistory.add(newStudies: aNotification?.userInfo?[OsirixAddToDBNotificationImagesArray] as? [Any] ?? [])
    }

    @objc(outlineViewSelectionDidChange:)
    func outlineViewSelectionDidChange(_ aNotification: Notification!) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("***** We must be on MAIN thread")
        }

        HorosObjCException.synchronized(self) {
            horos_cachedAlbumsContext = nil
        }

        if !BrowserController.horos_loadingIsOver { return }

        if let raised = HorosObjCException.caught({ self.showOutlineSelection() }) {
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

        if PreferencesSource.process.preferences[DatabasePreferences.displaySamePatientWithColorBackground] {
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
            patientHistory.clear()

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
            previewPane.showThumbnails(of: item, sameRow: sameRow)
        }

        if (horos_previousItem as AnyObject?) !== (item as AnyObject) {
            horos_previousItem = item
            patientHistory.selectionChanged(to: studyOfRow(item))
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
