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
import IsiXPreferences

// The albums table and the comparative studies table of BrowserController,
// with the selectors of the former Objective-C methods, which the nib, the
// tables and the plugins send: each method tests which table it was sent for.
// The albums table's rows, drops, selection and the list's order and columns
// for each album are StudyListContent's; a retrieve from the comparative
// table is PatientHistoryList's. The comparative table's cells are drawn
// here: its studies are DicomStudy or DCMTKStudyQueryNode objects, sent the
// same messages by selector.

/// `[object selector]` for a method that returns an object: nil for a nil
/// object, an unrecognized selector exception as before for an object that
/// does not implement it.
fileprivate func objcMessage(_ object: Any?, _ selector: String) -> Any? {
    guard let object = object as AnyObject? else { return nil }
    return object.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// `[object isDistant]`: NO for nil.
fileprivate func objcIsDistant(_ object: Any?) -> Bool {
    return (object as AnyObject?)?.isDistant?() ?? false
}

/// DISTANTSTUDYFONT.
fileprivate let DISTANTSTUDYFONT = "Helvetica-BoldOblique"

extension BrowserController: NSTableViewDelegate {}

public extension BrowserController {

    // MARK: - Albums TableView functions

    //NSTableView delegate and datasource
    @objc(numberOfRowsInTableView:)
    func numberOfRows(in aTableView: NSTableView) -> Int {
        if aTableView.isEqual(horos_albumTable) && self.database != nil {
            return studyList.albumRows().count
        }

        if aTableView.isEqual(horos_comparativeTable) && self.database != nil {
            return horos_comparativeStudies?.count ?? 0
        }

        return 0
    }

    @objc(tableView:objectValueForTableColumn:row:)
    func tableView(_ aTableView: NSTableView, objectValueFor aTableColumn: NSTableColumn?, row rowIndex: Int) -> Any? {
        return nil
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    func tableView(_ aTableView: NSTableView, willDisplayCell aCell: Any, for aTableColumn: NSTableColumn?, row rowIndex: Int) {
        if let exception = HorosObjCException.caught({
            if aTableView.isEqual(self.horos_albumTable) {
                self.studyList.willDisplayAlbumCell(aCell as? PrettyCell, row: rowIndex)
            }

            if aTableView.isEqual(self.horos_comparativeTable) {
                let cell = aCell as? ComparativeCell
                let comparativeStudies = self.horos_comparativeStudies ?? []

                if rowIndex >= 0 && rowIndex < comparativeStudies.count && self.database != nil {
                    let study = comparativeStudies[rowIndex]
                    let size = CGFloat(self.fontSize("dbComparativeFont"))

                    cell?.font = study is DicomStudy ? NSFont.boldSystemFont(ofSize: size) : NSFont(name: DISTANTSTUDYFONT, size: size)
                    cell?.title = "DUMMY" // avoid NIL values here

                    cell?.leftTextFirstLine = objcMessage(study, "studyName") as? NSString
                    cell?.rightTextFirstLine = objcMessage(study, "modality") as? NSString
                    cell?.leftTextSecondLine = (objcMessage(study, "date") as? Date).flatMap { UserDefaults.dateFormatter()?.string(from: $0) } as NSString?
                    let images = abs(Int((objcMessage(study, "numberOfImages") as? NSNumber)?.int32Value ?? 0))
                    cell?.rightTextSecondLine = String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: images), number: .decimal),
                                                       images == 1 ? NSLocalizedString("image", comment: "") : NSLocalizedString("images", comment: "")) as NSString
                } else {
                    cell?.title = ""
                    cell?.leftTextFirstLine = ""
                    cell?.rightTextFirstLine = ""
                    cell?.leftTextSecondLine = ""
                    cell?.rightTextSecondLine = ""
                }
            }
        }) {
            _N2LogExceptionImpl(exception, false, "-[BrowserController tableView:willDisplayCell:forTableColumn:row:]")
        }
    }

    @objc(sendFilesToCurrentBonjourGeneratedByOsiriXDB:)
    func sendFilesToCurrentBonjourGenerated(byOsiriXDB files: [Any]!) {
        autoreleasepool {
            if !(self.database?.isLocal() ?? false) {
                (self.database as? RemoteDicomDatabase)?.uploadFiles(atPaths: files, imageObjects: nil, generatedByOsiriX: true)
            }
        }
    }

    @objc(DatabaseObjectXIDsPasteboardTypes)
    class func databaseObjectXIDsPasteboardTypes() -> [String]! {
        return [O2PasteboardTypeDatabaseObjectXIDs,
                // Compatibility input from older plugins; new drags use the UTI above.
                "BrowserController.database.context.XIDs"]
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        tableView.isEqual(horos_albumTable) && studyList.acceptDrop(info, row: row)
    }

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard operation == .on, tableView.isEqual(horos_albumTable), studyList.acceptsDrop(onRow: row) else { return [] }
        horos_albumTable?.setDropRow(row, dropOperation: .on)
        return .link
    }

    @objc(tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:)
    func tableView(_ tv: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn tc: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        // The row is -1 outside the rows, where -objectAtIndex: raised.
        if tv === horos_comparativeTable, let studies = horos_comparativeStudies, row >= 0, row < studies.count {
            if objcIsDistant(studies[row]) {
                return NSLocalizedString("Double-Click to retrieve", comment: "")
            }
        }

        // The former nil: the protocol's Swift signature returns a String, and
        // an empty tool tip is not shown.
        return ""
    }

    /// Shows the list in the order and with the columns of the album, unless Command is held.
    @objc(loadSortDescriptors:)
    func loadSortDescriptors(_ album: DicomAlbum!) {
        studyList.loadLayout(of: album)
    }

    @objc(saveLoadAlbumsSortDescriptors)
    func saveLoadAlbumsSortDescriptors() {
        studyList.saveLoadSortDescriptors()
    }

    /// The retrieve of a study of the comparative table, on a thread.
    @objc(comparativeRetrieve:)
    internal nonisolated func comparativeRetrieve(_ study: DCMTKStudyQueryNode!) {
        comparativeState.retrieves.retrieveNow(study)
    }

    @objc(retrieveComparativeStudy:select:open:)
    internal func retrieveComparativeStudy(_ study: DCMTKStudyQueryNode!, select: Bool, open: Bool) {
        patientHistory.retrieve(study, select: select, open: open, showGUI: true, viewer: nil)
    }

    @objc(retrieveComparativeStudy:select:open:showGUI:)
    internal func retrieveComparativeStudy(_ study: DCMTKStudyQueryNode!, select: Bool, open: Bool, showGUI: Bool) {
        patientHistory.retrieve(study, select: select, open: open, showGUI: showGUI, viewer: nil)
    }

    @objc(retrieveComparativeStudy:select:open:showGUI:viewer:)
    internal func retrieveComparativeStudy(_ study: DCMTKStudyQueryNode!, select: Bool, open: Bool, showGUI: Bool, viewer: ViewerController!) {
        patientHistory.retrieve(study, select: select, open: open, showGUI: showGUI, viewer: viewer)
    }

    @objc(doubleClickComparativeStudy:)
    func doubleClickComparativeStudy(_ sender: Any!) {
        patientHistory.doubleClick()
    }

    @objc(tableViewSelectionDidChange:)
    func tableViewSelectionDidChange(_ aNotification: Notification) {
        if let e = HorosObjCException.caught({
            if (aNotification.object as AnyObject?) === self.horos_albumTable {
                self.studyList.albumSelectionChanged(clearsSearch: PreferencesSource.process.preferences[DatabasePreferences.clearsSearchWhenSelectingAlbum])
            }

            if (aNotification.object as AnyObject?) === self.horos_comparativeTable {
                let comparativeTable = self.horos_comparativeTable
                let comparativeStudies = self.horos_comparativeStudies ?? []
                let row = comparativeTable?.selectedRow ?? -1
                if row >= 0 && row < comparativeStudies.count && !self.horos_dontSelectStudyFromComparativeStudies {
                    if self.selectThisStudy(comparativeStudies[row]) && self.window?.firstResponder !== self.horos_searchField
                        && self.window?.firstResponder !== self.horos_searchField?.currentEditor() {
                        self.window?.makeFirstResponder(self.horos_databaseOutline)
                    }
                }
            }
        }) {
            NSLog("tableViewSelectionDidChange exception: %@", e)
            _ = e.printStackTrace()
        }
    }
}
