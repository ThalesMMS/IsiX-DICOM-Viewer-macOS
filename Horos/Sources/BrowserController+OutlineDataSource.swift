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
import UniformTypeIdentifiers
import IsiXDatabase
import IsiXDICOMFile

// The study list's outline: its rows and their children, what each column
// shows and how a row is drawn, editing a value, the header's menu of columns
// and the columns it shows. What decides without the app's classes is
// IsiXDatabase's StudyListCell, StudyListRowStyle, StudyListEdit, StudyListTree
// and StudyListColumns. The selectors are those of the former Objective-C
// methods, as the outline, the nib and the menus send them.

/// The font of the studies of DICOM nodes.
private let DISTANTSTUDYFONT = "Helvetica-BoldOblique"

/// The icons of the report column, made once: the report's, and the
/// downloads' for a link to a web page.
@MainActor private let reportColumnIcons: (local: NSImage?, web: NSImage?) = {
    let local = NSImage(named: "Report.icns")?.copy() as? NSImage
    local?.size = NSSize(width: 16, height: 16)
    var web = NSWorkspace.shared.icon(for: UTType(filenameExtension: "download") ?? .data).copy() as? NSImage
    if web == nil { web = local }
    web?.size = NSSize(width: 16, height: 16)
    return (local, web)
}()

/// The system fonts of the rows, made once per size. +[NSFont
/// boldSystemFontOfSize:] looks the font up again on every call, and was the
/// dearest part of drawing a cell; the font it gives for a size does not
/// change, and a new size (the preference) makes a new font.
@MainActor private enum StudyListFonts {
    static var bold: [CGFloat: NSFont] = [:]
    static var regular: [CGFloat: NSFont] = [:]

    static func bold(ofSize size: CGFloat) -> NSFont {
        if let font = bold[size] { return font }
        let font = NSFont.boldSystemFont(ofSize: size)
        bold[size] = font
        return font
    }

    static func regular(ofSize size: CGFloat) -> NSFont {
        if let font = regular[size] { return font }
        let font = NSFont.systemFont(ofSize: size)
        regular[size] = font
        return font
    }
}

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
        let menu = NSMenu(title: "")
        horos_columnsMenu = menu
        menu.delegate = self

        let columns = horos_databaseOutline?.tableColumns ?? []
        for index in StudyListColumns.menuOrder(titles: columns.map { $0.headerCell.stringValue }) {
            let column = columns[index]
            let item = menu.addItem(withTitle: column.headerCell.stringValue, action: #selector(columnsMenuAction(_:)), keyEquivalent: "")
            item.representedObject = column.identifier.rawValue
        }

        horos_databaseOutline?.headerView?.menu = menu
    }

    @objc(columnsMenuWillOpen)
    func columnsMenuWillOpen() {
        let columns = horos_databaseOutline?.tableColumns ?? []
        let identifiers: [Any?] = columns.map { $0.identifier.rawValue }
        for item in horos_columnsMenu?.items ?? [] {
            let checked = StudyListColumns.isChecked(identifier: item.representedObject,
                                                     hidePatientName: UserDefaults.standard.bool(forKey: "HIDEPATIENTNAME"),
                                                     identifiers: identifiers, hidden: { columns[$0].isHidden })
            item.state = checked ? .on : .off
        }
    }

    @objc(columnsMenuAction:)
    func columnsMenuAction(_ sender: Any!) {
        guard let sender = sender as? NSMenuItem else { return }
        sender.state = sender.state.rawValue == 0 ? .on : .off

        if BrowserObjC.literallyEqual(sender.representedObject as? String, "name") {
            UserDefaults.standard.set(sender.state.rawValue == 0, forKey: "HIDEPATIENTNAME")
        } else {
            let items = horos_columnsMenu?.items ?? []
            let saved = StudyListColumns.saved(titles: items.map(\.title), states: items.map { $0.state.rawValue })
            UserDefaults.standard.set(saved, forKey: "COLUMNSDATABASE")
            refreshColumns()
        }
    }

    @objc(refreshColumns)
    func refreshColumns() {
        if let raised = BrowserObjC.attempt({
            let saved = UserDefaults.standard.object(forKey: "COLUMNSDATABASE")
            if let saved, !(saved is NSDictionary) {
                NSException(name: .invalidArgumentException, reason: "COLUMNSDATABASE is not a dictionary").raise()
            }
            let columnsDatabase = saved as? NSDictionary
            let enumerator = columnsDatabase?.keyEnumerator()
            while let key = enumerator?.nextObject() as? String {
                guard let outline = horos_databaseOutline else { continue }
                let titles = ((outline.tableColumns as NSArray).value(forKey: "headerCell") as? NSArray)?.value(forKey: "title") as? NSArray
                let index = titles?.index(of: key) ?? NSNotFound
                if index == NSNotFound { continue }

                let identifier = outline.tableColumns[index].identifier
                let change = StudyListColumns.change(visible: outline.isColumnWithIdentifierVisible(identifier.rawValue),
                                                     saved: columnsDatabase?.value(forKey: key),
                                                     isSelectedColumn: { outline.column(withIdentifier: identifier) == outline.selectedColumn })
                if let change {
                    if change.selectFirstColumn {
                        outline.selectColumnIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                    outline.setColumnWithIdentifier(identifier.rawValue, visible: change.visible)
                    if change.scrollToColumn {
                        outline.scrollColumnToVisible(outline.column(withIdentifier: identifier))
                    }
                }
            }

            buildColumnsMenu()
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController refreshColumns]")
        }
    }

    // MARK: - Data source

    @objc(outlineView:child:ofItem:)
    func outlineView(_ outlineView: NSOutlineView!, child index: Int, ofItem item: Any!) -> Any! {
        if horos_databaseIvar == nil { return nil }
        // A row of the list itself, asked for every row at each reload: out of
        // the list's bounds, the path below raises and logs as before.
        if item == nil, let row = horos_outlineViewRow(at: index) { return row }

        var returnVal: Any?
        if let raised = BrowserObjC.attempt({
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
            return Int(Int32(truncatingIfNeeded: (horos_outlineViewList as? NSArray)?.count ?? 0))
        }
        if item is SurgicalProcedureOutlineRow { return 0 }

        if isDistantRow(item) {
            var count = 0
            if let raised = BrowserObjC.attempt({
                if let node = item as? DCMTKStudyQueryNode {
                    let children = node.children() as NSArray?
                    if StudyListTree.nodeChildrenAreStale(count: children?.count ?? 0, lastIsQueryNode: {
                        let last = children?.lastObject
                        return last is DCMTKStudyQueryNode || last is DCMTKSeriesQueryNode
                    }) {
                        node.purgeChildren()
                    }
                    if node.children() == nil {
                        node.query(withValues: nil)
                        if node.children() == nil { node.setChildren(NSMutableArray() as? [Any]) }
                    }
                }
                let children = (item as AnyObject).perform(NSSelectorFromString("children"))?.takeUnretainedValue()
                count = (children as? NSArray)?.count ?? 0
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

        return StudyListCell.objectValue(identifier: identifier, reportsMode: BrowserController.horos_reportsMode(),
                                         hidePatientName: { UserDefaults.standard.bool(forKey: "HIDEPATIENTNAME") },
                                         ageDisplay: { UserDefaults.standard.integer(forKey: "yearOldDatabaseDisplay") },
                                         row: StudyListRow(item: item, browser: self))
    }

    /// The date the report plugin gives a study.
    fileprivate func reportPluginDate(of item: Any?) -> Any? {
        let name = UserDefaults.standard.string(forKey: "REPORTSPLUGIN")
        guard let plugin = name.flatMap({ PluginManager.reportPlugins()?.object(forKey: $0) }) as? Bundle else { return nil }
        let principal: AnyClass? = plugin.principalClass
        let filter = (principal as AnyObject?)?.perform(NSSelectorFromString("filter"))?.takeUnretainedValue() as? PluginFilter

        PluginManager.startProtectForCrash(withFilter: filter)
        let date = filter?.reportDate(forStudy: item as? DicomStudy)
        PluginManager.endProtectForCrash()
        return date
    }

    /// A local study's name, with the database it comes from when that is
    /// not the one shown, as a federated search lists it.
    fileprivate func studyListName(_ name: Any?, of item: Any?) -> Any? {
        if let object = item as? NSManagedObject, let database = horos_databaseIvar,
           let origin = object.managedObjectContext.flatMap({ DicomDatabase(for: $0) }),
           origin !== database,
           !BrowserObjC.literallyEqual(origin.baseDirPath, database.baseDirPath),
           !FederatedSearch.pathsEqual(origin.baseDirPath, database.baseDirPath) {
            return FederatedSearch.displayName(name as? String,
                                               origin: FederatedSearch.displayOrigin(name: origin.name, path: origin.baseDirPath),
                                               currentOrigin: database.name)
        }
        return name
    }

    @objc(outlineView:objectValueForTableColumn:byItem:)
    func outlineView(_ outlineView: NSOutlineView!, objectValueFor tableColumn: NSTableColumn!, byItem item: Any!) -> Any! {
        if horos_databaseIvar == nil { return nil }

        var value: Any?
        if let raised = BrowserObjC.attempt({ value = self.intOutlineView(outlineView, objectValueFor: tableColumn, byItem: item) }) {
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
        if let raised = BrowserObjC.attempt({
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
        if isDistantRow(item) {
            return NSLocalizedString("Double-Click to retrieve", comment: "")
        }

        var tip: String?
        _ = BrowserObjC.attempt({
            guard BrowserObjC.literallyEqual(tableColumn?.identifier.rawValue, "name"), let rect else { return }
            let frame = rect.pointee
            let imageFrame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.size.height, height: frame.size.height)
            guard NSPointInRect(mouseLocation, imageFrame) else { return }

            let now = Date().timeIntervalSinceReferenceDate
            let acquired = (rowValue(item, "date") as? Date)?.timeIntervalSinceReferenceDate
            let added = (rowValue(item, "dateAdded") as? Date)?.timeIntervalSinceReferenceDate
            switch StudyListRowStyle.toolTip(now: now, acquired: acquired, added: added) {
            case .tenMinutes: tip = NSLocalizedString("Acquired within the last 10 minutes", comment: "")
            case .hour: tip = NSLocalizedString("Acquired within the last hour", comment: "")
            case .fourHours: tip = NSLocalizedString("Acquired within the last 4 hours", comment: "")
            case .today: tip = NSLocalizedString("Acquired today", comment: "")
            case .addedMinute: tip = NSLocalizedString("Added within the last 60 seconds", comment: "")
            case nil: break
            }
        })
        return tip
    }

    @objc(outlineView:willDisplayCell:forTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView!, willDisplayCell cell: Any!, for tableColumn: NSTableColumn!, item: Any!) {
        // The cell is cast from Any once: a cast per use cost more than
        // the rest of the styling.
        let theCell = cell as? NSCell
        theCell?.isHighlighted = false

        if let imageCell = theCell as? ImageAndTextCell {
            imageCell.image = nil
            imageCell.setLastImage(nil)
        }

        N2ManagedObjectContextPerformAndWait(self.database?.managedObjectContext) {
            if let raised = BrowserObjC.attempt({ self.styleStudyListCell(cell, theCell, column: tableColumn, item: item, outlineView: outlineView) }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineView:willDisplayCell:forTableColumn:item:]")
            }
        }
    }

    /// The font, background, icons and text colour of a cell of the list.
    private func styleStudyListCell(_ cell: Any?, _ theCell: NSCell?, column tableColumn: NSTableColumn?, item: Any?,
                                    outlineView: NSOutlineView?) {
        let identifier = tableColumn?.identifier.rawValue
        // [[tableColumn identifier] isEqualToString: name]: Swift's == gives the
        // same answer for these ASCII names (no other string is canonically
        // equivalent to them), without walking the code units one by one.
        func isColumn(_ name: String) -> Bool { identifier == name }

        if isRowType(item, "Study") {
            if isColumn("lockedStudy") { (theCell as? NSButtonCell)?.isTransparent = false }

            let size = CGFloat(self.horos_studyRowFontSize())
            switch StudyListRowStyle.font(isStudy: true, isDistant: { isDistantRow(item) }, listed: {
                self.horos_hasOriginalOutlineViewArray ? self.horos_originalOutlineViewStudiesContains(item) : nil
            }) {
            case .distant: theCell?.font = NSFont(name: DISTANTSTUDYFONT, size: size)
            case .bold: theCell?.font = StudyListFonts.bold(ofSize: size)
            case .regular: theCell?.font = StudyListFonts.regular(ofSize: size)
            case .series: break
            }

            if isColumn("name") {
                let previous = horos_previousItem
                let background = StudyListRowStyle.samePatientBackground(
                    enabled: UserDefaults.standard.bool(forKey: "displaySamePatientWithColorBackground") && window?.firstResponder === outlineView,
                    selectionIsStudy: { isRowType(previous, "Study") },
                    isSelection: (previous as AnyObject?) === (item as AnyObject?),
                    patientUID: { rowValue(item, "patientUID") },
                    selectedPatientUID: { rowValue(previous, "patientUID") })
                let textCell = theCell as? NSTextFieldCell
                textCell?.drawsBackground = background
                if background {
                    // This was disabledControlTextColor, which is a
                    // *text* colour: pure black at 25% alpha in Aqua and
                    // pure white at 25% in Dark Aqua. Filled behind a
                    // patient name it is the black band over consecutive
                    // studies of one patient, and its mirror image in
                    // dark mode. The commented-out original was
                    // secondarySelectedControlColor, a row background;
                    // this is its modern replacement.
                    textCell?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor
                }

                let date = rowValue(item, "date") as? Date
                let recency = StudyListRowStyle.recency(
                    dateSinceNow: date?.timeIntervalSinceNow, date: date?.timeIntervalSinceReferenceDate,
                    todayStart: { BrowserController.horos_startOfTodayReferenceInterval() },
                    added: {
                        let added = rowValue(item, "dateAdded")
                        return (added != nil, (added as? Date)?.timeIntervalSinceNow)
                    })
                switch recency {
                case .tenMinutes: theCell?.image = NSImage(named: "Realised1.tif")
                case .hour: theCell?.image = NSImage(named: "Realised2.tif")
                case .fourHours: theCell?.image = NSImage(named: "Realised3.tif")
                case .today: theCell?.image = NSImage(named: "Realised4.tif")
                case .received: theCell?.image = NSImage(named: "Receiving.tif")
                case nil: break
                }
            }

            if isColumn("reportURL") {
                // The recorded link, as it is: a file that has gone is found
                // when the report is opened, not by a disk access per row per
                // redraw - nor by editing the study while drawing it.
                switch StudyListRowStyle.reportIcon(url: rowValue(item, "reportURL"), databaseIsLocal: horos_databaseIvar?.isLocal() ?? false) {
                case .web: theCell?.image = reportColumnIcons.web
                case .file: theCell?.image = reportColumnIcons.local
                case nil: break
                }
            }
        } else {
            if isColumn("lockedStudy") { (theCell as? NSButtonCell)?.isTransparent = true }

            theCell?.font = StudyListFonts.bold(ofSize: CGFloat(self.horos_seriesRowFontSize()))
        }
        theCell?.lineBreakMode = .byTruncatingMiddle

        // gray "unknown" values
        let setTextColor = #selector(setter: NSTextFieldCell.textColor)
        if let object = theCell ?? (cell as? NSObject), object.responds(to: setTextColor) {
            let type = rowValue(item, "type")
            let gray = StudyListCell.showsUnknown(type: type, identifier: identifier ?? "", value: {
                rowValue(item, StudyListCell.valueKey(type: type, identifier: identifier ?? ""))
            })
            object.perform(setTextColor, with: gray ? NSColor.disabledControlTextColor : NSColor.controlTextColor)
        }
    }

    @objc(tableView:mouseDownInHeaderOfTableColumn:)
    public func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
    }
}

/// A row of the list as the module's cell rules read it: the row's object
/// asked directly, with nothing built per cell.
@MainActor private struct StudyListRow {
    let item: Any?
    let browser: BrowserController
    /// The item as an object, cast once for the keys a cell reads.
    let object: NSObject?

    init(item: Any?, browser: BrowserController) {
        self.item = item
        self.browser = browser
        self.object = item as? NSObject
    }
}

extension StudyListRow: @MainActor StudyListRowSource {
    func rowValue(_ key: String) -> Any? { object?.value(forKey: key) }
    func rowIsDistant() -> Bool { isDistantRow(item) }
    func rowIsStudyObject() -> Bool { item is DicomStudy }
    func rowReportPluginDate() -> Any? { browser.reportPluginDate(of: item) }
    func rowLatestReportDate() -> Any? { latestReportImageDate(of: item) }
    func rowNote() -> Any? { StudyNote.singleLineText(of: (item as? DicomStudy)?.note) }
    func rowDisplayName(_ name: Any?) -> Any? { browser.studyListName(name, of: item) }
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
    case let array as NSArray: return Array(array)
    case let ordered as NSOrderedSet: return Array(ordered)
    default: return []
    }
}
