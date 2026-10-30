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
import CoreData
import UniformTypeIdentifiers

/// The list of results: the outline's data and cells, its order, its columns,
/// and what of each study or series is already in the local database.
extension QueryController {
    // MARK: The outline's data

    @objc(outlineView:child:ofItem:)
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any? {
        var child: Any?
        do {
            try HorosObjCException.perform {
                QueryController.synchronized(self) {
                    guard let node = item as? DCMTKQueryNode else {
                        child = self.resultArray.count > index ? self.resultArray[index] : nil
                        return
                    }

                    var children = node.children() ?? []
                    if let last = children.last, !(last is DCMTKStudyQueryNode), !(last is DCMTKSeriesQueryNode) {
                        node.purgeChildren()
                        children = node.children() ?? []
                    }

                    child = (children as NSArray).object(at: index)
                }
            }
        } catch {
            QueryController.log(error, "-[QueryController outlineView:child:ofItem:]")
        }
        return child
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
        return false
    }

    @objc(outlineView:isItemExpandable:)
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any?) -> Bool {
        return QueryController.synchronized(self) {
            guard let item = item as AnyObject? else { return resultArray.count != 0 }
            return type(of: item) == DCMTKStudyQueryNode.self || type(of: item) == DCMTKRootQueryNode.self
        }
    }

    @objc(outlineView:numberOfChildrenOfItem:)
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        var count = resultArray.count
        do {
            try HorosObjCException.perform {
                QueryController.synchronized(self) {
                    guard let node = item as? DCMTKQueryNode else {
                        count = self.resultArray.count
                        return
                    }

                    if let last = node.children()?.last, !(last is DCMTKStudyQueryNode), !(last is DCMTKSeriesQueryNode) {
                        node.purgeChildren()
                    }

                    if node.children() == nil {
                        if !self.performingCFind {
                            // to avoid re-entries during WaitRendering window,
                            // and separate thread for cFind
                            self.performingCFind = true

                            self.progressIndicator.startAnimation(nil)
                            node.query(withValues: nil)
                            self.progressIndicator.stopAnimation(nil)
                            self.performingCFind = false

                            if node.children() == nil { // It failed... put an empty children...
                                node.setChildren([])
                            }
                        }
                    }
                    if node is DCMTKStudyQueryNode {
                        // Sort before the outline asks for its rows, including
                        // the first expansion when parentForItem: is not
                        // available yet.
                        var descriptors = [NSSortDescriptor(key: "time", ascending: true)]
                        if outlineView.sortDescriptors.first?.key == "localCompleteness", let local = self.sortArray().first {
                            descriptors.insert(local, at: 0)
                        }
                        node.setChildren((node.children() as NSArray?)?.sortedArray(using: descriptors))
                    }
                    count = node.children()?.count ?? 0
                }
            }
        } catch {
            QueryController.log(error, "-[QueryController outlineView:numberOfChildrenOfItem:]")
        }
        return count
    }

    @objc(outlineView:objectValueForTableColumn:byItem:)
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        var value: Any?
        do {
            try HorosObjCException.perform {
                QueryController.synchronized(self) {
                    guard let identifier = tableColumn?.identifier.rawValue, let item = item as AnyObject? else { return }
                    let study = type(of: item) == DCMTKStudyQueryNode.self
                    let series = type(of: item) == DCMTKSeriesQueryNode.self

                    switch identifier {
                    case "stateText":
                        let state = self.localStateForItem(item)?.stateText as AnyObject?
                        if state?.responds(to: #selector(getter: NSNumber.intValue)) == true && QueryController.int32(state) != 0 {
                            value = state
                        }
                    case "serverStateText":
                        if study {
                            let state = (item as? DCMTKQueryNode)?.stateText()
                            value = state?.int32Value == 0 ? nil : state
                        } else if !series {
                            NSLog("***** unknown class in QueryController outlineView: %@", String(describing: type(of: item)))
                        }
                    case "comment":
                        value = self.localStateForItem(item)?.comment
                    case "serverComment":
                        if study || series {
                            value = item.value(forKey: "comments")
                        } else {
                            NSLog("***** unknown class in QueryController outlineView: %@", String(describing: type(of: item)))
                        }
                    case "localCompleteness":
                        value = self.displayedCompletenessForItem(item)?.text
                    case "Button":
                        break
                    default:
                        if study || series {
                            if identifier == "numberImages" {
                                value = NSNumber(value: QueryController.int32(item.value(forKey: identifier)))
                            } else {
                                value = item.value(forKey: identifier)
                            }
                        } else {
                            NSLog("***** unknown class in QueryController outlineView: %@", String(describing: type(of: item)))
                        }
                    }
                }
            }
        } catch {
            QueryController.log(error, "-[QueryController outlineView:objectValueForTableColumn:byItem:]")
        }
        return value
    }

    public func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?,
                            item: Any, mouseLocation: NSPoint) -> String {
        let identifier = tableColumn?.identifier.rawValue
        if identifier == "name" || identifier == "localCompleteness", let completeness = displayedCompletenessForItem(item) {
            return String(format: "%@\n%@", cell.title, completeness.explanation)
        }
        return ""
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? DCMTKQueryNode, item.children() != nil {
            item.purgeChildren()
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, item: Any) {
        guard let cell = cell as? NSCell else { return }
        do {
            try HorosObjCException.perform {
                let identifier = tableColumn?.identifier.rawValue
                if identifier == "name" { // Is this study already available in our local database?
                    if UserDefaults.standard.bool(forKey: "displaySamePatientWithColorBackground") &&
                        self.window?.firstResponder === outlineView && outlineView.selectedRow >= 0 {
                        let selStudy = outlineView.item(atRow: outlineView.selectedRow) as AnyObject?

                        let curUid = String(format: "%@ %@", QueryController.text((item as AnyObject).value(forKey: "patientID")),
                                            QueryController.text((item as AnyObject).value(forKey: "name")))
                        let selUid = String(format: "%@ %@", QueryController.text(selStudy?.value(forKey: "patientID")),
                                            QueryController.text(selStudy?.value(forKey: "name")))

                        if (item as AnyObject) !== selStudy && !curUid.isEmpty &&
                            (curUid as NSString).compare(selUid, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame {
                            (cell as? NSTextFieldCell)?.drawsBackground = true
                            (cell as? NSTextFieldCell)?.backgroundColor = .lightGray
                        } else {
                            (cell as? NSTextFieldCell)?.drawsBackground = false
                        }
                    }

                    // A pie is a proportion. When the node did not say how many
                    // it holds there is no proportion to draw, and an empty pie
                    // would say none of it had arrived: a study that is here
                    // gets its own mark instead.
                    if let completeness = self.displayedCompletenessForItem(item), completeness.localCount > 0 {
                        (cell as? ImageAndTextCell)?.image = completeness.remoteCountIsKnown
                            ? NSImage.pieChartImage(withPercentage: Float(completeness.fraction)) : NSImage.localPresenceImage()
                    } else {
                        (cell as? ImageAndTextCell)?.image = nil
                    }

                    cell.font = NSFont.boldSystemFont(ofSize: 13)
                    cell.lineBreakMode = .byTruncatingMiddle
                } else if identifier == "numberImages" {
                    if let number = (item as AnyObject).value(forKey: "numberImages") {
                        cell.integerValue = Int(QueryController.int32(number))
                    } else {
                        cell.stringValue = "n/a"
                    }
                }
            }
        } catch {
            QueryController.log(error, "-[QueryController outlineView:willDisplayCell:forTableColumn:item:]")
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        let index = outlineView.selectedRowIndexes
        if let first = index.first, let item = outlineView.item(atRow: first) as AnyObject? {
            selectedResultSource.stringValue = String(format: "%@  /  %@:%d", QueryController.text(item.value(forKey: "calledAET")),
                                                      QueryController.text(item.value(forKey: "hostname")),
                                                      QueryController.int32(item.value(forKey: "port")))
        } else {
            selectedResultSource.stringValue = ""
        }

        if UserDefaults.standard.bool(forKey: "displaySamePatientWithColorBackground") {
            outlineView.needsDisplay = true
        }
    }

    // MARK: Order

    /// The sort descriptors of the outline, as the results are sorted on any
    /// thread: the Local column compares the rows' completeness, read once per
    /// row and sort; a date is followed by the time.
    @objc(sortArray)
    nonisolated func sortArray() -> [NSSortDescriptor] {
        nonisolated(unsafe) var outlineDescriptors = [NSSortDescriptor]()
        if Thread.isMainThread {
            MainActor.assumeIsolated { outlineDescriptors = self.outlineView?.sortDescriptors ?? [] }
        } else {
            outlineDescriptors = windowState.sortDescriptors
        }
        var descriptors: [NSSortDescriptor] = []
        for descriptor in outlineDescriptors {
            // AppKit keeps previous columns as tie breakers. Translate Local at
            // every position: it is a database comparison, not a query-node key.
            if descriptor.key == "localCompleteness" {
                // Freeze each row's value for this sort, avoiding repeated
                // database and inventory lookups inside the O(n log n)
                // comparisons.
                nonisolated(unsafe) let values = NSMapTable<AnyObject, LocalCompleteness>.strongToStrongObjects()
                descriptors.append(NSSortDescriptor(key: "self", ascending: descriptor.ascending) { a, b in
                    guard let first = QueryController.frozenCompleteness(of: a, in: values, controller: self),
                          let second = QueryController.frozenCompleteness(of: b, in: values, controller: self) else { return .orderedSame }
                    return first.compare(second)
                })
            } else {
                descriptors.append(descriptor)
                if descriptor.key == "date" {
                    descriptors.append(NSSortDescriptor(key: "time", ascending: descriptor.ascending))
                }
            }
        }
        return descriptors
    }

    /// The completeness of `row` for one sort, read once.
    nonisolated static func frozenCompleteness(of row: Any, in values: NSMapTable<AnyObject, LocalCompleteness>,
                                               controller: QueryController) -> LocalCompleteness? {
        if let known = values.object(forKey: row as AnyObject) { return known }
        let computed = controller.displayedCompletenessForItem(row)
        if let computed { values.setObject(computed, forKey: row as AnyObject) }
        return computed
    }

    @objc(sortResultsPreservingSelection)
    func sortResultsPreservingSelection() {
        let selectedItems = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }

        resultArray.sort(using: sortArray())
        outlineView.reloadData()

        var selection = IndexSet()
        for item in selectedItems {
            let row = outlineView.row(forItem: item)
            if row >= 0 { selection.insert(row) }
        }
        outlineView.selectRowIndexes(selection, byExtendingSelection: false)
    }

    /// Imports change the values, not the order: rows move only when the user
    /// clicks a column header.
    @objc(reloadResultsAfterLocalChange)
    func reloadResultsAfterLocalChange() {
        outlineView.reloadData()
    }

    @objc(outlineView:sortDescriptorsDidChange:)
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        captureWindowState()
        sortResultsPreservingSelection()
        if self.outlineView.selectedRow >= 0 {
            self.outlineView.scrollRowToVisible(self.outlineView.selectedRow)
        }
    }

    // MARK: The list as text

    /// The rows (or the selected ones) as tab-separated text, a header first.
    @objc(exportDBListOnlySelected:)
    func exportDBList(onlySelected: Bool) -> String {
        let rowIndex = onlySelected ? outlineView.selectedRowIndexes : IndexSet(integersIn: 0..<outlineView.numberOfRows)

        var string = ""
        let columns = outlineView.tableColumns.map(\.identifier.rawValue)
        let descriptions = outlineView.tableColumns.map(\.headerCell)

        for r in rowIndex {
            guard let aFile = outlineView.item(atRow: r) as AnyObject?, type(of: aFile) == DCMTKStudyQueryNode.self else { continue }

            if !string.isEmpty {
                string += "\r"
            } else {
                var i = 0
                for (index, s) in descriptions.enumerated() {
                    try? HorosObjCException.perform {
                        if aFile.value(forKey: columns[index]) != nil {
                            string += s.stringValue
                            i += 1
                            if i != columns.count {
                                string += "\t"
                            }
                        }
                    }
                }
                string += "\r"
            }

            var i = 0
            for identifier in columns {
                try? HorosObjCException.perform {
                    if let value = aFile.value(forKey: identifier) {
                        string += QueryController.text(value)
                    }
                    i += 1
                    if i != columns.count {
                        string += "\t"
                    }
                }
            }
        }

        return string
    }

    @IBAction @objc(saveDBListAs:)
    func saveDBListAs(_ sender: Any?) {
        let list = exportDBList(onlySelected: false)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "txt")!]
        panel.nameFieldStringValue = NSLocalizedString("IsiX DICOM Viewer Database List", comment: "")

        panel.begin { result in
            if result != .OK {
                return
            }
            if let url = panel.url {
                try? list.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Columns

    /// The Local % column, the header menu that shows and hides columns, and
    /// the saved order, widths and sort.
    func installResultColumns() {
        // The percentage already existed in the tooltip and as a pie next to
        // the name; what was missing was a value that can be compared and
        // sorted. Added here rather than in the nib so it joins the header
        // context menu and the saved column order below.
        if outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("localCompleteness")) == nil {
            let completenessColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("localCompleteness"))
            completenessColumn.headerCell.stringValue = NSLocalizedString("Local %", comment: "")
            completenessColumn.width = 110
            completenessColumn.minWidth = 60
            completenessColumn.isEditable = false
            completenessColumn.sortDescriptorPrototype = NSSortDescriptor(key: "localCompleteness", ascending: true)
            outlineView.addTableColumn(completenessColumn)
        }

        // build table header context menu
        guard (outlineView.autosaveName ?? "").isEmpty else { return }

        let cols = UserDefaults.standard.array(forKey: autoQueryValue ? "NewQueryControllerTableColumnsAutoQR" : "NewQueryControllerTableColumns")

        let tableHeaderContextMenu = NSMenu(title: "")
        outlineView.headerView?.menu = tableHeaderContextMenu
        for column in outlineView.tableColumns {
            let identifier = column.identifier.rawValue
            if identifier != "Button" && identifier != "name" {
                let item = tableHeaderContextMenu.addItem(withTitle: column.headerCell.title, action: #selector(contextMenuSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column
                item.state = cols != nil ? .off : .on

                if cols != nil {
                    outlineView.removeTableColumn(column) // initially want to show all columns
                }
            }
        }
        // add columns in correct order with correct width, ensure menu items are in correct state
        for case let colinfo as NSDictionary in cols ?? [] {
            let identifier = colinfo.object(forKey: "identifier") as? String
            let width = CGFloat(QueryController.double(colinfo.object(forKey: "width")))
            let item = tableHeaderContextMenu.items.first { ($0.representedObject as? NSTableColumn)?.identifier.rawValue == identifier }

            if let item, let column = item.representedObject as? NSTableColumn {
                item.state = .on
                column.width = width
                outlineView.addTableColumn(column)
            } else if identifier == "Button" || identifier == "name" {
                outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier ?? ""))?.width = width
            } else {
                NSLog("QR: item not found: %@", identifier ?? "(null)")
            }
        }

        let prefsSortKey = autoQueryValue ? "QueryControllerTableColumnsSortDescriptorAutoQR" : "QueryControllerTableColumnsSortDescriptor"

        let byName = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]
        if let sort = UserDefaults.standard.object(forKey: prefsSortKey) as? NSDictionary {
            let key = sort.object(forKey: "key") as? String ?? ""
            if outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(key)) != -1 {
                let prototype = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.sortDescriptorPrototype
                outlineView.sortDescriptors = [NSSortDescriptor(key: key, ascending: QueryController.bool(sort.object(forKey: "order")),
                                                                selector: prototype?.selector)]
            } else {
                outlineView.sortDescriptors = byName
            }
        } else {
            outlineView.sortDescriptors = byName
        }

        // listen for changes so know when to save
        NotificationCenter.default.addObserver(self, selector: #selector(saveTableColumns), name: NSOutlineView.columnDidMoveNotification, object: outlineView)
        NotificationCenter.default.addObserver(self, selector: #selector(saveTableColumns), name: NSOutlineView.columnDidResizeNotification, object: outlineView)
    }

    @objc(saveTableColumns)
    func saveTableColumns() {
        guard let outlineView else { return }
        let cols = outlineView.tableColumns.map { column -> NSDictionary in
            ["identifier": column.identifier.rawValue, "width": NSNumber(value: Float(column.width))]
        }
        UserDefaults.standard.set(cols, forKey: autoQueryValue ? "NewQueryControllerTableColumnsAutoQR" : "NewQueryControllerTableColumns")
        if let first = outlineView.sortDescriptors.first, let key = first.key {
            let sort: NSDictionary = ["order": NSNumber(value: first.ascending), "key": key]
            UserDefaults.standard.set(sort, forKey: autoQueryValue ? "QueryControllerTableColumnsSortDescriptorAutoQR" : "QueryControllerTableColumnsSortDescriptor")
        }
    }

    @objc(contextMenuSelected:)
    func contextMenuSelected(_ sender: NSMenuItem) {
        let on = sender.state == .on
        sender.state = on ? .off : .on

        if let column = sender.representedObject as? NSTableColumn {
            if on {
                outlineView.removeTableColumn(column)
            } else {
                outlineView.addTableColumn(column)
            }
        }

        outlineView.needsDisplay = true
        saveTableColumns()
    }

    // MARK: What is here

    /// How much of one row is already here. Four places used to work this out,
    /// each reading a remote total of zero as 0% and more files locally than
    /// the node reports as 100%. LocalCompleteness keeps those apart; this is
    /// the only place that reads the two counts.
    @objc(inventoryCompletenessForItem:inventory:)
    nonisolated func inventoryCompleteness(forItem item: Any?, inventory: RetrieveInventory) -> LocalCompleteness {
        let node = item as? DCMTKQueryNode
        node?.refreshRetrieveInventoryWithoutWaiting()
        let current = inventory.matchesReportedCount(Int(QueryController.int32((item as AnyObject?)?.value(forKey: "numberImages"))))
        // Local instances against what the peer reports, complete when only its
        // expected absences are missing; the detail says what they are.
        let remote = inventory.reportedCount > 0 ? inventory.reportedCount : inventory.expectedCount
        let value = LocalCompleteness(localCount: current ? inventory.importedCount : inventory.localUniqueCount,
                                      remoteCount: current ? NSNumber(value: remote) : nil)
        value.completeButExpectedAbsences = current && inventory.isSatisfied
        value.inventoryDetail = String(format: "%@%@\nInventory queried: %@\nManifest: %@",
                                       inventory.inventoryConfirmed && !current ? "The remote count changed; retrieve again to refresh the inventory.\n" : "",
                                       inventory.summary, QueryController.text(inventory.queriedAt as NSDate), inventory.path)
        if current { value.unsendableCount = inventory.unsendableUIDs.count }
        return value
    }

    /// The completeness of a row, read from the database: on the main thread
    /// from the UI context's objects, elsewhere on a private queue.
    @objc(localCompletenessForItem:)
    nonisolated func localCompleteness(forItem item: Any?) -> LocalCompleteness? {
        if let node = item as? DCMTKQueryNode, let inventory = node.retrieveInventory {
            return inventoryCompleteness(forItem: item, inventory: inventory)
        }
        guard let item = item as AnyObject?, QueryController.isStudyOrSeries(item) else { return nil }

        // The table repaints read the UI context's objects on the main thread;
        // a sort run by a query thread reads the count on a private queue.
        var localFiles = 0
        if Thread.isMainThread {
            let local = type(of: item) == DCMTKStudyQueryNode.self ? localStudy(item, context: nil) : localSeries(item, context: nil)
            if let first = local?.first as AnyObject? {
                localFiles = Int(QueryController.int32(first.value(forKey: "rawNoFiles")))
            }
        } else {
            localFiles = localFileCount(forItem: item)
        }

        return LocalCompleteness(localCount: localFiles, remoteCount: remoteCount(ofItem: item))
    }

    /// A node answers with a number, but the value has arrived as a string
    /// often enough elsewhere to be worth not assuming.
    @objc(remoteCountOfItem:)
    nonisolated func remoteCount(ofItem item: Any?) -> NSNumber? {
        let total = (item as AnyObject?)?.value(forKey: "numberImages") as AnyObject?
        guard let total, total.responds(to: #selector(getter: NSNumber.intValue)) else { return nil }
        return NSNumber(value: (total as? NSNumber)?.intValue ?? (total as? NSString)?.integerValue ?? 0)
    }

    /// The local study or series of a row, as the last snapshot read it.
    @objc(localStateForItem:)
    nonisolated func localStateForItem(_ item: Any?) -> HorosLocalRowState? {
        guard let item = item as AnyObject? else { return nil }
        if type(of: item) == DCMTKStudyQueryNode.self {
            return localSnapshot?.state(ofStudy: (item as? DCMTKStudyQueryNode)?.studyInstanceUID())
        }
        if type(of: item) == DCMTKSeriesQueryNode.self {
            return localSnapshot?.state(ofStudy: (item as? DCMTKSeriesQueryNode)?.studyInstanceUID(), series: item.value(forKey: "uid") as? String)
        }
        return nil
    }

    /// What the window paints and sorts on, on the main thread: the inventory
    /// when one was found, otherwise the snapshot. Neither reads the database
    /// here.
    @objc(displayedCompletenessForItem:)
    nonisolated func displayedCompletenessForItem(_ item: Any?) -> LocalCompleteness? {
        if !Thread.isMainThread {
            return localCompleteness(forItem: item)
        }
        guard let node = item as? DCMTKQueryNode, QueryController.isStudyOrSeries(node) else { return nil }
        if let inventory = node.retrieveInventoryForDisplay() {
            return inventoryCompleteness(forItem: item, inventory: inventory)
        }
        return LocalCompleteness(localCount: localStateForItem(item)?.fileCount ?? 0, remoteCount: remoteCount(ofItem: item))
    }

    /// isMemberOfClass: a study or a series node.
    nonisolated static func isStudyOrSeries(_ item: AnyObject) -> Bool {
        return type(of: item) == DCMTKStudyQueryNode.self || type(of: item) == DCMTKSeriesQueryNode.self
    }

    @objc(resultStudyInstanceUIDs)
    func resultStudyInstanceUIDs() -> [String] {
        var uids: [String] = []
        for case let item as NSObject in resultArray {
            guard item.responds(to: NSSelectorFromString("studyInstanceUID")) else { continue }
            if let uid = item.value(forKey: "studyInstanceUID") as? String, !uid.isEmpty {
                uids.append(uid)
            }
        }
        return uids
    }

    @objc(scheduleLocalSnapshot)
    func scheduleLocalSnapshot() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(readLocalSnapshot), object: nil)
        perform(#selector(readLocalSnapshot), with: nil, afterDelay: 0.25)
    }

    private nonisolated static let snapshotQueue = DispatchQueue(label: "Horos.queryLocalSnapshot")

    /// Reads what of the results is here, off the main thread.
    @objc(readLocalSnapshot)
    func readLocalSnapshot() {
        guard let database = BrowserController.currentBrowser()?.database else { // During DB rebuild
            return
        }

        let uids = resultStudyInstanceUIDs()
        localSnapshotGeneration += 1
        let generation = localSnapshotGeneration
        nonisolated(unsafe) let reader = database
        QueryController.snapshotQueue.async {
            autoreleasepool {
                var read: HorosLocalQuerySnapshot?
                do {
                    read = try HorosLocalQueryReader.snapshot(ofStudyInstanceUIDs: uids, in: reader)
                } catch {
                    NSLog("******** the local side of the query results could not be read: %@", (error as NSError).localizedDescription)
                }
                nonisolated(unsafe) let snapshot = read
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let snapshot, generation == self.localSnapshotGeneration else { return }
                        self.localSnapshot = snapshot
                        DCMTKQueryNode.forgetMissingRetrieveInventories()
                        if !self.DatabaseIsEdited {
                            self.reloadResultsAfterLocalChange()
                        }
                        self.updateStudyCountLabel()
                    }
                }
            }
        }
    }

    @objc(updateStudyCountLabel)
    func updateStudyCountLabel() {
        var found = QueryController.singularPluralCount(resultArray.count, NSLocalizedString("study found", comment: ""),
                                                        NSLocalizedString("studies found", comment: ""))
        if let localSnapshot, resultArray.count > 0 {
            found = String(format: NSLocalizedString("%@, %ld in database", comment: "Query window footer: the studies found, then how many of them are in the local database"),
                           found, localSnapshot.countOfStudiesHere(among: resultStudyInstanceUIDs()))
        }
        numberOfStudies?.stringValue = found
    }

    /// Only deleting studies or series changes what is here without an import
    /// notification.
    @objc(observeDatabaseSave:)
    nonisolated func observeDatabaseSave(_ notification: Notification) {
        let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        for object in deleted {
            let entity = object.entity.name
            if entity == "Study" || entity == "Series" {
                performSelector(onMainThread: #selector(refresh(_:)), with: self, waitUntilDone: false)
                return
            }
        }
    }

    @objc(observeActiveDatabaseChange:)
    nonisolated func observeActiveDatabaseChange(_ notification: Notification) {
        performSelector(onMainThread: #selector(refresh(_:)), with: self, waitUntilDone: false)
    }

    // MARK: The local database

    /// A refresh of the windows, once the database is quiet: one second when a
    /// query window is in front, ten otherwise.
    @objc(refresh:)
    public func refresh(_ sender: Any?) {
        guard !LocalStudyIndex.refreshScheduled else { return }
        LocalStudyIndex.refreshScheduled = true

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(executeRefresh(_:)), object: nil)

        let delay: TimeInterval = QueryController.current()?.window?.isKeyWindow == true || QueryController.currentAuto()?.window?.isKeyWindow == true ? 1 : 10

        perform(#selector(executeRefresh(_:)), with: self, afterDelay: delay)
    }

    @objc(executeRefresh:)
    public func executeRefresh(_ sender: Any?) {
        for controller in [QueryController.current(), QueryController.currentAuto()] {
            if let controller, !controller.DatabaseIsEdited {
                controller.reloadResultsAfterLocalChange()
            }
        }

        Thread.detachNewThreadSelector(#selector(computeStudyArrayInstanceUID(_:)), toTarget: self, with: nil)
        QueryController.current()?.readLocalSnapshot()
        QueryController.currentAuto()?.readLocalSnapshot()
    }

    @objc(applyNewStudyArray:)
    func applyNewStudyArray(_ d: NSDictionary?) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyNewStudyArray(_:)), object: nil)

        for controller in [QueryController.current(), QueryController.currentAuto()] {
            if let controller, !controller.DatabaseIsEdited {
                controller.reloadResultsAfterLocalChange()
            }
        }
    }

    /// Reads the Study Instance UID and object ID of every local study, on a
    /// private queue, from any thread, without the UI context.
    @objc(computeStudyArrayInstanceUID:)
    nonisolated func computeStudyArrayInstanceUID(_ sender: NSNumber?) {
        // Whatever this read finds, even no database during a rebuild, the
        // refresh that -refresh: scheduled is over: a flag left on would make
        // -refresh: ignore every later change of the database.
        defer { LocalStudyIndex.refreshScheduled = false }

        guard let database = BrowserController.currentBrowser()?.database else { // During DB rebuild
            return
        }

        autoreleasepool {
            var localStudyIDs: [NSManagedObjectID]?
            var localStudyInstanceUIDs: [Any]?

            LocalStudyIndex.computing.lock()
            do {
                let index = try HorosLocalQueryReader.studyIndex(of: database)
                localStudyIDs = index.objectIDs
                localStudyInstanceUIDs = index.studyInstanceUIDs
            } catch {
                NSLog("******** computeStudyArrayInstanceUID: the local studies could not be read: %@", (error as NSError).localizedDescription)
            }
            LocalStudyIndex.computing.unlock()

            if let localStudyIDs, let localStudyInstanceUIDs {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyNewStudyArray(_:)), object: nil)

                // The first study with a UID answers for it, as the linear search did.
                var byUID: [String: NSManagedObjectID] = [:]
                for (id, uid) in zip(localStudyIDs, localStudyInstanceUIDs) {
                    if let uid = uid as? String, byUID[uid] == nil {
                        byUID[uid] = id
                    }
                }

                LocalStudyIndex.set(byUID)

                if Thread.isMainThread {
                    perform(#selector(applyNewStudyArray(_:)), with: nil, afterDelay: 0.001)
                } else {
                    performSelector(onMainThread: #selector(applyNewStudyArray(_:)), with: nil, waitUntilDone: false)
                }
            } else {
                NSLog("******** computeStudyArrayInstanceUID FAILED...")
            }
        }
    }

    @objc(localStudy:)
    public nonisolated func localStudy(_ item: Any?) -> [Any]? {
        return localStudy(item, context: nil)
    }

    /// The local study of a study or series row, in `context`; without one, the
    /// UI context on the main thread.
    @objc(localStudy:context:)
    public nonisolated func localStudy(_ item: Any?, context: NSManagedObjectContext?) -> [Any]? {
        guard let item = item as AnyObject?, QueryController.isStudyOrSeries(item) else { return nil }

        var result: [Any]? = []
        do {
            try HorosObjCException.perform {
                guard let studyID = self.localStudyObjectID(forItem: item) else { return }

                // The objects are resolved in the caller's context. Without one,
                // that is the UI context, on the main thread; off it, what is
                // wanted is a value: -localFileCountForItem:.
                var context = context
                if context == nil {
                    if Thread.isMainThread {
                        context = BrowserController.currentBrowser()?.database?.managedObjectContext
                    } else {
                        QueryController.logStackTrace("localStudy: no context off the main thread; the local count is -localFileCountForItem:")
                    }
                }

                if let study = try? context?.existingObject(with: studyID) as? DicomStudy {
                    result = [study]
                }
            }
        } catch {
            LocalStudyIndex.set(nil)
            result = nil
        }
        return result
    }

    @objc(localSeries:)
    public nonisolated func localSeries(_ item: Any?) -> [Any]? {
        return localSeries(item, context: nil)
    }

    @objc(localSeries:context:)
    public nonisolated func localSeries(_ item: Any?, context: NSManagedObjectContext?) -> [Any]? {
        guard let study = localStudy(item, context: context)?.last as AnyObject? else { return nil }

        guard let item = item as AnyObject?, type(of: item) == DCMTKSeriesQueryNode.self else {
            NSLog("Warning! Not a series class ! %@", String(describing: (item as AnyObject?).map { type(of: $0) }))
            return nil
        }

        var seriesArray: [Any]?
        do {
            try HorosObjCException.perform {
                let series = (study.value(forKey: "series") as? NSSet)?.allObjects as NSArray?
                seriesArray = series?.filtered(using: NSPredicate(format: "(seriesDICOMUID == %@)", argumentArray: [item.value(forKey: "uid") as Any]))
            }
        } catch {
            QueryController.log(error, "-[QueryController localSeries:context:]")
        }
        return seriesArray
    }

    /// The local study of a study or series row, as the object ID the study
    /// index holds: a value any thread can keep.
    @objc(localStudyObjectIDForItem:)
    nonisolated func localStudyObjectID(forItem item: Any?) -> NSManagedObjectID? {
        guard let item = item as AnyObject?, QueryController.isStudyOrSeries(item) else { return nil }

        var index = LocalStudyIndex.get()
        if index == nil {
            computeStudyArrayInstanceUID(nil)
            index = LocalStudyIndex.get()
        }
        guard let uid = item.value(forKey: "studyInstanceUID") as? String else { return nil }
        return index?[uid]
    }

    /// How many files of a study or series row are here, read on a private
    /// queue from any thread. What decides a retrieve reads this, not objects
    /// of the UI context. A read that fails is logged and counts as nothing
    /// here, so the retrieve asks for everything, as it would for a study not
    /// yet here.
    @objc(localFileCountForItem:)
    nonisolated func localFileCount(forItem item: Any?) -> Int {
        guard let studyID = localStudyObjectID(forItem: item), let database = BrowserController.currentBrowser()?.database else {
            return 0
        }

        let node = item as AnyObject?
        let series = node.map { type(of: $0) == DCMTKSeriesQueryNode.self } == true ? node?.value(forKey: "uid") as? String : nil
        do {
            return try HorosLocalQueryReader.fileCount(ofStudy: studyID, seriesInstanceUID: series, in: database).intValue
        } catch {
            NSLog("******** the local files of %@ could not be counted: %@", QueryController.text(node?.value(forKey: "studyInstanceUID")),
                  (error as NSError).localizedDescription)
            return 0
        }
    }
}

/// Study Instance UID -> object ID of every local study, nil until read, and
/// whether a refresh of the windows is waiting: the statics of the former
/// class, which every query window shares.
enum LocalStudyIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byUID: [String: NSManagedObjectID]?
    /// One read of the index at a time.
    static let computing = NSLock()
    /// A refresh is scheduled and not yet read.
    nonisolated(unsafe) static var refreshScheduled = false

    static func get() -> [String: NSManagedObjectID]? {
        lock.lock()
        defer { lock.unlock() }
        return byUID
    }

    static func set(_ index: [String: NSManagedObjectID]?) {
        lock.lock()
        byUID = index
        lock.unlock()
    }
}
