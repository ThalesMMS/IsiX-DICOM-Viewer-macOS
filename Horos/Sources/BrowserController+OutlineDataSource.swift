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
import IsiXDICOMFile

// The study list's outline: its rows and their children and editing a value,
// and the selectors the outline, the nib and the menus send for the cells and
// the columns, which StudyListCellStyler and StudyListColumnController answer.
// What decides without the app's classes is IsiXDatabase's StudyListCell,
// StudyListRowStyle, StudyListEdit, StudyListTree and StudyListColumns. The
// selectors are those of the former Objective-C methods.

/// [item isDistant]: NO for nil.
@MainActor func isDistantRow(_ item: Any?) -> Bool {
    (item as AnyObject?)?.isDistant?() ?? false
}

/// [item valueForKey: key].
@MainActor func rowValue(_ item: Any?, _ key: String) -> Any? {
    (item as? NSObject)?.value(forKey: key)
}

/// [[item valueForKey: @"type"] isEqualToString: type].
@MainActor func isRowType(_ item: Any?, _ type: String) -> Bool {
    guard let value = rowValue(item, "type") as? NSString else { return false }
    return value.isEqual(to: type)
}

/// The words of the study list's cells.
private func studyListText(_ key: String) -> String {
    switch key {
    case "Name hidden": return NSLocalizedString("Name hidden", comment: "")
    case " y": return NSLocalizedString(" y", comment: "y = year")
    case "unknown": return NSLocalizedString("unknown", comment: "")
    default: return key
    }
}

/// An NSRangeException as -objectAtIndex: raises it.
private func rangeException(_ index: Int, _ count: Int) -> NSException {
    NSException(name: .rangeException, reason: "*** -[NSArray objectAtIndex:]: index \(index) beyond bounds [0 .. \(count - 1)]")
}

extension BrowserController {

    // MARK: - Columns

    @objc(buildColumnsMenu)
    func buildColumnsMenu() {
        studyListColumns.buildMenu()
    }

    @objc(columnsMenuWillOpen)
    func columnsMenuWillOpen() {
        studyListColumns.menuWillOpen()
    }

    @objc(columnsMenuAction:)
    func columnsMenuAction(_ sender: Any!) {
        guard let sender = sender as? NSMenuItem else { return }
        studyListColumns.toggle(sender)
    }

    @objc(refreshColumns)
    func refreshColumns() {
        studyListColumns.refresh()
    }

    // MARK: - Data source

    @objc(outlineView:child:ofItem:)
    func outlineView(_ outlineView: NSOutlineView!, child index: Int, ofItem item: Any!) -> Any! {
        if horos_databaseIvar == nil { return nil }
        // A row of the list itself, asked for every row at each reload: out of
        // the list's bounds, the path below raises and logs as before.
        if item == nil, let row = horos_outlineViewRow(at: index) { return row }

        var returnVal: Any?
        if let raised = HorosObjCException.caught({
            if item == nil {
                returnVal = (horos_outlineViewList as? NSArray)?.object(at: index)
            } else if let node = item as? DCMTKStudyQueryNode {
                returnVal = (node.children() as NSArray?)?.object(at: index)
            } else if let children = childrenArray(item) {
                guard index >= 0 && index < children.count else { rangeException(index, children.count).raise(); return }
                returnVal = children[index]
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineView:child:ofItem:]")
        }
        return returnVal
    }

    @objc(outlineView:isItemExpandable:)
    func outlineView(_ outlineView: NSOutlineView!, isItemExpandable item: Any!) -> Bool {
        // Asked for every row of the list at each reload: the item is taken
        // as an object once.
        let object = item.map { $0 as AnyObject }
        return StudyListTree.isExpandable(surgicalRow: object is SurgicalProcedureOutlineRow, isDistant: { object?.isDistant?() ?? false },
                                          isStudyNode: { object is DCMTKStudyQueryNode },
                                          type: { (object as? NSObject)?.value(forKey: "type") })
    }

    @objc(outlineView:numberOfChildrenOfItem:)
    func outlineView(_ outlineView: NSOutlineView!, numberOfChildrenOfItem item: Any!) -> Int {
        if horos_databaseIvar == nil { return 0 }

        guard let item else {
            return Int(Int32(truncatingIfNeeded: horos_outlineViewRowCount))
        }
        if item is SurgicalProcedureOutlineRow { return 0 }

        if isDistantRow(item) {
            var count = 0
            if let raised = HorosObjCException.caught({
                if let node = item as? DCMTKStudyQueryNode {
                    let children = node.children()
                    if StudyListTree.nodeChildrenAreStale(count: children?.count ?? 0, lastIsQueryNode: {
                        let last = children?.last
                        return last is DCMTKStudyQueryNode || last is DCMTKSeriesQueryNode
                    }) {
                        node.purgeChildren()
                    }
                    if node.children() == nil {
                        node.query(withValues: nil)
                        if node.children() == nil { node.setChildren([]) }
                    }
                }
                let children = (item as AnyObject).perform(NSSelectorFromString("children"))?.takeUnretainedValue()
                count = (children as? [Any])?.count ?? 0
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineView:numberOfChildrenOfItem:]")
                return 0
            }
            return count
        }

        return StudyListTree.childCount(type: rowValue(item, "type"), noFiles: { rowValue(item, "noFiles") },
                                        imageSeries: { rowValue(item, "imageSeries") })
    }

    @objc(intOutlineView:objectValueForTableColumn:byItem:)
    func intOutlineView(_ outlineView: NSOutlineView!, objectValueFor tableColumn: NSTableColumn!, byItem item: Any!) -> Any! {
        guard let identifier = tableColumn?.identifier.rawValue else {
            NSException(name: .invalidArgumentException, reason: "no column").raise()
            return nil
        }

        return studyListCells.objectValue(identifier: identifier, item: item)
    }

    @objc(outlineView:objectValueForTableColumn:byItem:)
    func outlineView(_ outlineView: NSOutlineView!, objectValueFor tableColumn: NSTableColumn!, byItem item: Any!) -> Any! {
        if horos_databaseIvar == nil { return nil }

        var value: Any?
        if let raised = HorosObjCException.caught({ value = self.intOutlineView(outlineView, objectValueFor: tableColumn, byItem: item) }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineView:objectValueForTableColumn:byItem:]")
            return nil
        }
        return value
    }

    // MARK: - Editing

    @objc(setDatabaseValue:item:forKey:)
    func setDatabaseValue(_ object: Any!, item: Any!, forKey key: String!) {
        if isDistantRow(item) { return }

        horos_DatabaseIsEdited = false

        // The edit is over as far as this object is concerned, but the outline is
        // still in its editing session; catch up once it is not.
        perform(#selector(_refreshDatabaseDisplayIfDeferred), with: nil, afterDelay: 0)

        let database = horos_databaseIvar
        if let raised = HorosObjCException.caught({
            if !(database?.isLocal() ?? false) {
                (database as? RemoteDicomDatabase)?.object(item as? NSManagedObject, setValue: object, forKey: key)
            }

            guard let key else {
                NSException(name: .invalidArgumentException, reason: "no key").raise()
                return
            }
            for managedObject in databaseSelection() ?? [] {
                switch StudyListEdit.write(key: key, value: object, rowType: { rowValue(managedObject, "type") }) {
                case .skip: break
                case .value: (managedObject as? NSObject)?.setValue(object, forKey: key)
                case .locked(let locked): (managedObject as? NSObject)?.setValue(NSNumber(value: locked), forKey: "lockedStudy")
                }
            }

            horos_refreshTimer?.fireDate = Date(timeIntervalSinceNow: 0.5)
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController setDatabaseValue:item:forKey:]")
        }

        _ = database?.save(nil)

        if let query = QueryController.current() {
            query.refresh(self)
        } else if let query = QueryController.currentAuto() {
            query.refresh(self)
        }

        horos_databaseOutline?.reloadData()
    }

    @objc(outlineView:setObjectValue:forTableColumn:byItem:)
    func outlineView(_ outlineView: NSOutlineView!, setObjectValue object: Any!, for tableColumn: NSTableColumn!, byItem item: Any!) {
        if isDistantRow(item) { return }
        if self.database?.isReadOnly ?? false { return }

        setDatabaseValue(object, item: item, forKey: tableColumn?.identifier.rawValue)
    }

    @objc(outlineView:sortDescriptorsDidChange:)
    func outlineView(_ outlineView: NSOutlineView!, sortDescriptorsDidChange oldDescriptors: [Any]!) {
        // outlineViewRefresh restores selected objects at their new sorted rows.
        outlineViewRefresh()
        let outline = horos_databaseOutline
        if (outline?.selectedRow ?? 0) >= 0 {
            outline?.scrollRowToVisible(outline?.selectedRow ?? 0)
        }
    }

    // MARK: - Drawing

    @objc(outlineView:toolTipForCell:rect:tableColumn:item:mouseLocation:)
    func outlineView(_ outlineView: NSOutlineView!, toolTipFor cell: NSCell!, rect: NSRectPointer!, tableColumn: NSTableColumn!,
                     item: Any!, mouseLocation: NSPoint) -> String! {
        studyListCells.toolTip(column: tableColumn, rect: rect, item: item, mouseLocation: mouseLocation)
    }

    @objc(outlineView:willDisplayCell:forTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView!, willDisplayCell cell: Any!, for tableColumn: NSTableColumn!, item: Any!) {
        studyListCells.willDisplay(cell, column: tableColumn, item: item, outlineView: outlineView)
    }

    @objc(tableView:mouseDownInHeaderOfTableColumn:)
    public func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
    }
}

/// A row of the list as the module's cell rules read it: the row's object
/// asked directly, with nothing built per cell; the report plugin and the
/// federated name are the cells'.
@MainActor struct StudyListRow {
    let item: Any?
    let cells: StudyListCellStyler
    /// The item as an object, cast once for the keys a cell reads.
    let object: NSObject?

    init(item: Any?, cells: StudyListCellStyler) {
        self.item = item
        self.cells = cells
        self.object = item as? NSObject
    }
}

extension StudyListRow: @MainActor StudyListRowSource {
    func rowValue(_ key: String) -> Any? { object?.value(forKey: key) }
    func rowIsDistant() -> Bool { isDistantRow(item) }
    func rowIsStudyObject() -> Bool { item is DicomStudy }
    func rowReportPluginDate() -> Any? { cells.reportPluginDate(of: item) }
    func rowLatestReportDate() -> Any? { latestReportImageDate(of: item) }
    func rowNote() -> Any? { StudyNote.singleLineText(of: (item as? DicomStudy)?.note) }
    func rowDisplayName(_ name: Any?) -> Any? { cells.listName(name, of: item) }
    func rowNumberOfImageSeries() -> Int { Int(truncatingIfNeeded: (item as? DicomStudy)?.numberOfImageSeries() ?? 0) }
    func rowLocalized(_ key: String) -> String { studyListText(key) }
}

/// The date of the latest report image of a study, found without asking the
/// study for its report image: that merges duplicate report series and saves,
/// which drawing a row must not do.
@MainActor private func latestReportImageDate(of item: Any?) -> Any? {
    var latest: Date?
    for case let oneSeries as NSObject in objcElements(rowValue(item, "series")) {
        guard StudyListCell.isReportSeries(id: oneSeries.value(forKey: "id"), name: oneSeries.value(forKey: "name"), isStructuredReport: {
            DICOMSOPClass.isStructuredReport(oneSeries.value(forKey: "seriesSOPClassUID") as? String)
        }) else { continue }

        for case let image as NSObject in objcElements(oneSeries.value(forKey: "images")) {
            let date = image.value(forKey: "date") as? Date
            if StudyListCell.isLater(date, than: latest) { latest = date }
        }
    }
    return latest
}

/// The elements of a set or an array, in the order fast enumeration gives
/// them; none for nil.
func objcElements(_ collection: Any?) -> [Any] {
    switch collection {
    case let set as NSSet: return Array(set)
    case let array as [Any]: return array
    case let ordered as NSOrderedSet: return Array(ordered)
    default: return []
    }
}
