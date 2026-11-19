//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import PreferencePanes

/// The texts of a nib read from the catalog, in a language that has a catalog
/// and no copy of the nib.
///
/// Spanish and Italian have a Localizable.strings but no copy of the nibs of
/// the preference panes, nor of the settings window's. There a nib loads as
/// its Base (English) copy has it, and each text it shows is read from the
/// catalog with the English text as the key: the titles of windows, boxes,
/// buttons, radio buttons and tabs, labels, placeholders, tooltips, the items
/// of a pop-up (and so the item it shows), the labels of segments and toolbar
/// items, the headers of table columns with the items of their pop-up cells,
/// and the names a search field's predicate bindings give its menu and
/// placeholder. A text the catalog lacks stays as it is.
///
/// What a binding gives is data, not a text of the nib, and is left alone: a
/// label's value, a button's title and the items of a pop-up whose content or
/// selected value is bound. So are the rows of a table. A control's own
/// subviews are left alone too: they are how AppKit draws it (the magnifier of
/// a search field is a button titled "search"; given a title, it shows it).
@MainActor
enum CatalogTranslation {
    /// A text of the main bundle's catalog, by its English text; the English
    /// text itself when the catalog lacks it.
    static func mainCatalog(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    /// Whether the nib named `name` shows its Base texts in the language the
    /// application runs in: that language has no copy of the nib and is not
    /// the language of the Base copy.
    static func isNeeded(forNibNamed name: String, in bundle: Bundle = .main) -> Bool {
        guard let language = bundle.preferredLocalizations.first,
              language != bundle.developmentLocalization else { return false }
        return bundle.url(forResource: name, withExtension: "nib", subdirectory: nil, localization: language) == nil
    }

    /// Reads from `catalog` every text that the windows (their title, content
    /// and toolbar), views and menus among `objects` show.
    static func translate(_ objects: [Any], with catalog: (String) -> String) {
        for object in objects {
            switch object {
            case let window as NSWindow:
                window.title = text(window.title, catalog)
                if let content = window.contentView { translate(view: content, with: catalog) }
                if let toolbar = window.toolbar { translate(toolbar, with: catalog) }
            case let view as NSView:
                translate(view: view, with: catalog)
            case let menu as NSMenu:
                translate(menu, with: catalog)
            default:
                break
            }
        }
    }

    /// The labels, tooltips and views of a toolbar's items.
    static func translate(_ toolbar: NSToolbar, with catalog: (String) -> String) {
        for item in toolbar.items {
            item.label = text(item.label, catalog)
            item.paletteLabel = text(item.paletteLabel, catalog)
            if let tip = item.toolTip { item.toolTip = text(tip, catalog) }
            if let view = item.view { translate(view: view, with: catalog) }
        }
    }

    private static func text(_ english: String, _ catalog: (String) -> String) -> String {
        english.isEmpty ? english : catalog(english)
    }

    private static func isBound(_ object: NSObject, _ names: [NSBindingName]) -> Bool {
        names.contains { object.infoForBinding($0) != nil }
    }

    private static func translate(_ menu: NSMenu, with catalog: (String) -> String) {
        for item in menu.items where !item.isSeparatorItem {
            item.title = text(item.title, catalog)
            if let tip = item.toolTip { item.toolTip = text(tip, catalog) }
            if let submenu = item.submenu { translate(submenu, with: catalog) }
        }
    }

    private static func translate(view: NSView, with catalog: (String) -> String) {
        if let tip = view.toolTip { view.toolTip = text(tip, catalog) }
        switch view {
        case let tabs as NSTabView:
            // Only the selected item's view is a subview: every item is read here.
            for item in tabs.tabViewItems {
                item.label = text(item.label, catalog)
                if let tip = item.toolTip { item.toolTip = text(tip, catalog) }
                if let content = item.view { translate(view: content, with: catalog) }
            }
            return
        case let table as NSTableView:
            // Its rows are data; its headers and the items of its pop-up cells are texts.
            for column in table.tableColumns {
                column.title = text(column.title, catalog)
                if let tip = column.headerToolTip { column.headerToolTip = text(tip, catalog) }
                if let cell = column.dataCell as? NSPopUpButtonCell, let menu = cell.menu { translate(menu, with: catalog) }
            }
            return
        case let box as NSBox:
            if box.titlePosition != .noTitle { box.title = text(box.title, catalog) }
        case let popUp as NSPopUpButton:
            if !isBound(popUp, [.content, .contentObjects, .contentValues, .selectedObject, .selectedValue]), let menu = popUp.menu {
                translate(menu, with: catalog)
            }
        case let segments as NSSegmentedControl:
            for index in 0..<segments.segmentCount {
                if let label = segments.label(forSegment: index) { segments.setLabel(text(label, catalog), forSegment: index) }
                if let tip = segments.toolTip(forSegment: index) { segments.setToolTip(text(tip, catalog), forSegment: index) }
            }
        case let matrix as NSMatrix:
            // The titles of its radio buttons and checkboxes; a form's cells hold values.
            for case let cell as NSButtonCell in matrix.cells {
                cell.title = text(cell.title, catalog)
                if let tip = matrix.toolTip(for: cell) { matrix.setToolTip(text(tip, catalog), for: cell) }
            }
        case let button as NSButton:
            if !isBound(button, [.title]) { button.title = text(button.title, catalog) }
        case let field as NSTextField:
            // Read before the predicate bindings are bound again, which shows the first one's (translated) name.
            let placeholder = field.placeholderString
            if let search = field as? NSSearchField { translatePredicateNames(of: search, with: catalog) }
            if let placeholder { field.placeholderString = text(placeholder, catalog) }
            if !field.isEditable && !isBound(field, [.value]) { field.stringValue = text(field.stringValue, catalog) }
        default:
            break
        }
        if !(view is NSPopUpButton), let menu = view.menu { translate(menu, with: catalog) }
        // What the nib gives a control to show is in its cell, items, segments and placeholder, read above. Its
        // subviews are AppKit's drawing of it: only views that are not controls hold views of the nib. A table's
        // header view draws the headers read from its columns.
        if view is NSControl || view is NSTableHeaderView { return }
        for child in view.subviews { translate(view: child, with: catalog) }
    }

    /// The bindings `predicate`, `predicate2`, ... of a search field name what it searches in its menu, and the
    /// chosen one in its placeholder: their display names are texts of the nib, which AppKit shows as the binding
    /// options have them. They are bound again, to the same object and key path, with the catalog's names.
    private static func translatePredicateNames(of field: NSSearchField, with catalog: (String) -> String) {
        var bindings: [(name: NSBindingName, info: [NSBindingInfoKey: Any])] = []
        while true {
            let name = NSBindingName(bindings.isEmpty ? "predicate" : "predicate\(bindings.count + 1)")
            guard let info = field.infoForBinding(name) else { break }
            bindings.append((name, info))
        }
        func options(_ info: [NSBindingInfoKey: Any]) -> [NSBindingOption: Any] {
            (info[.options] as? [NSBindingOption: Any] ?? [:]).filter { !($0.value is NSNull) }
        }
        let names = bindings.map { options($0.info)[.displayName] as? String }
        guard names.contains(where: { $0.map { !$0.isEmpty && text($0, catalog) != $0 } ?? false }) else { return }
        // Each binding after the first names the one before it: they are unbound from the last and bound again in order.
        for binding in bindings.reversed() { field.unbind(binding.name) }
        for binding in bindings {
            guard let observed = binding.info[.observedObject], let keyPath = binding.info[.observedKeyPath] as? String else { continue }
            var bound = options(binding.info)
            if let shown = bound[.displayName] as? String { bound[.displayName] = text(shown, catalog) }
            field.bind(binding.name, to: observed, withKeyPath: keyPath, options: bound)
        }
    }
}

/// Room for what a translation, or the user's region, makes longer than a
/// nib's frames: the nibs were drawn for English texts and for one format of
/// dates. Each fit takes the room from the row the control stands in, never
/// from a view beside it, and changes nothing where the content already fits.
@MainActor
enum PaneFit {
    /// The width `view` needs to show all of its content, as AppKit measures
    /// it: a pop-up's widest item, a button's or a label's title, a date
    /// picker's widest date; the frame's width for any other view.
    static func neededWidth(of view: NSView) -> CGFloat {
        switch view {
        case let picker as NSDatePicker:
            return neededWidth(of: picker)
        case let popUp as NSPopUpButton:
            return ceil(popUp.cell?.cellSize.width ?? popUp.frame.width)
        case let button as NSButton:
            if button.imagePosition == .imageOnly || button.title.isEmpty { return button.frame.width }
            return ceil(button.cell?.cellSize.width ?? button.frame.width)
        case let field as NSTextField where !field.isEditable:
            return ceil(field.cell?.cellSize.width ?? field.frame.width)
        default:
            return view.frame.width
        }
    }

    /// The width a date picker needs for the widest date or time its format
    /// writes in its own locale ("12:58 p.m." in Spanish outside Spain, "12:58
    /// PM" in English): AppKit measures it from the format, whatever date the
    /// picker shows.
    static func neededWidth(of picker: NSDatePicker) -> CGFloat {
        ceil(picker.cell?.cellSize.width ?? picker.frame.width)
    }

    /// Every text date picker in `view` that needs more than its frame grows
    /// to the right, and the views to its right in its row move by as much,
    /// as far as the row has room before the edge of their superview.
    static func fitDatePickers(in view: NSView) {
        var pickers: [NSDatePicker] = []
        func collect(_ view: NSView) {
            if let picker = view as? NSDatePicker, picker.datePickerStyle != .clockAndCalendar { pickers.append(picker) }
            if let tabs = view as? NSTabView { tabs.tabViewItems.compactMap(\.view).forEach(collect) }
            if !(view is NSControl) { view.subviews.forEach(collect) }
        }
        collect(view)
        for picker in pickers {
            let growth = neededWidth(of: picker) - picker.frame.width
            guard growth > 0, let superview = picker.superview else { continue }
            let row = superview.subviews.filter {
                $0 !== picker && $0.frame.minX >= picker.frame.maxX - 0.5
                    && $0.frame.minY < picker.frame.maxY && $0.frame.maxY > picker.frame.minY
            }
            let end = row.map(\.frame.maxX).max() ?? picker.frame.maxX
            let room = superview.bounds.maxX - 4 - end
            let shift = min(growth, max(0, room))
            guard shift > 0 else { continue }
            picker.setFrameSize(NSSize(width: picker.frame.width + shift, height: picker.frame.height))
            for neighbour in row { neighbour.setFrameOrigin(NSPoint(x: neighbour.frame.minX + shift, y: neighbour.frame.minY)) }
        }
    }

    /// The width a view takes in a row laid out by `flowRow`: what its
    /// content needs when the nib gave it less; for a label aligned to the
    /// side the row starts on, its text's width.
    private static func rowWidth(of view: NSView) -> CGFloat {
        let needed = neededWidth(of: view)
        if let field = view as? NSTextField, !field.isEditable, !field.isBezeled, !field.drawsBackground,
           field.alignment == .left || (field.alignment == .natural && field.userInterfaceLayoutDirection == .leftToRight) {
            return needed
        }
        return max(view.frame.width, needed)
    }

    /// The width a view of a row that lacks room narrows to without a visible
    /// change: a checkbox's or a radio button's content starts at its leading
    /// edge and leaves the rest of its frame empty, and it narrows to that
    /// content; any other view keeps `rowWidth(of:)`.
    private static func compactWidth(of view: NSView) -> CGFloat {
        if let button = view as? NSButton, !(button is NSPopUpButton), !button.isBordered, !button.title.isEmpty,
           button.imagePosition == .imageLeft || button.imagePosition == .imageLeading {
            return min(rowWidth(of: view), neededWidth(of: view))
        }
        return rowWidth(of: view)
    }

    /// Lays out the row that starts with `first`: the siblings that stand in
    /// its row to its right, up to `trailing` (a view at the row's end), go
    /// left to right, each after the one before it with the gap the nib left
    /// between them, and take the width `rowWidth(of:)` gives them. Views that
    /// share one place in the nib (shown one at a time) stay together, and the
    /// next starts after the widest. The row never reaches `trailing` (or,
    /// without one, the superview's edge): when it would, `trailing` narrows
    /// to its content, keeping its trailing edge; then the checkboxes of the
    /// row narrow to theirs (`compactWidth(of:)`); and what is still missing is
    /// taken from the widest view of the row, which then cuts its text rather
    /// than draw over its neighbour.
    static func flowRow(startingAt first: NSView, until trailing: NSView? = nil) {
        guard let superview = first.superview else { return }
        let band = first.frame.minY...first.frame.maxY
        let limit = trailing?.frame.minX ?? superview.bounds.maxX
        let members = superview.subviews.filter {
            $0 === first || ($0 !== trailing && $0.frame.minX >= first.frame.minX && $0.frame.minX < limit
                             && band.contains($0.frame.midY))
        }.sorted { $0.frame.minX < $1.frame.minX }
        // Views whose frames cross share a place.
        var groups: [[NSView]] = []
        for view in members {
            if let last = groups.last, let end = last.map(\.frame.maxX).max(), view.frame.minX < end - 0.5 {
                groups[groups.count - 1].append(view)
            } else {
                groups.append([view])
            }
        }
        let original = Dictionary(uniqueKeysWithValues: members.map { (ObjectIdentifier($0), $0.frame) })
        func before(_ view: NSView) -> NSRect { original[ObjectIdentifier(view)] ?? view.frame }
        let rowStart = first.frame.minX
        var widths = Dictionary(uniqueKeysWithValues: members.map { (ObjectIdentifier($0), rowWidth(of: $0)) })
        /// Places every view of the row with its width in `widths`, and gives where the row ends.
        func layOut() -> CGFloat {
            var end = rowStart
            var previousEnd: CGFloat?
            for group in groups {
                let start = group.map { before($0).minX }.min() ?? end
                let x = previousEnd.map { end + max(0, start - $0) } ?? start
                for view in group {
                    let frame = before(view)
                    view.frame = NSRect(x: x + frame.minX - start, y: frame.minY, width: widths[ObjectIdentifier(view)] ?? frame.width,
                                        height: frame.height)
                }
                previousEnd = group.map { before($0).maxX }.max()
                end = group.map(\.frame.maxX).max() ?? end
            }
            return end
        }
        let gap: CGFloat = 4
        var end = layOut()
        if let trailing, end + gap > trailing.frame.minX {
            let width = max(neededWidth(of: trailing), 0)
            trailing.frame = NSRect(x: trailing.frame.maxX - width, y: trailing.frame.minY, width: width, height: trailing.frame.height)
        }
        let edge = (trailing?.frame.minX ?? superview.bounds.maxX) - gap
        if end > edge {
            for view in members { widths[ObjectIdentifier(view)] = compactWidth(of: view) }
            end = layOut()
        }
        // A view narrowed in a place it shares may leave the place as wide as another of its views: then the next widest.
        var narrowings = members.count
        while end > edge, narrowings > 0,
              let widest = members.max(by: { (widths[ObjectIdentifier($0)] ?? 0) < (widths[ObjectIdentifier($1)] ?? 0) }) {
            let key = ObjectIdentifier(widest)
            widths[key] = max(0, (widths[key] ?? 0) - (end - edge))
            end = layOut()
            narrowings -= 1
        }
    }

    /// Widens the columns of a table whose header, or the widest item of
    /// whose pop-up cells, needs more than the column has, with room taken
    /// from the columns that have more than they need: the table keeps its
    /// width while they have some, and past that grows wider than its view
    /// and scrolls, as no header is cut. A column of text cells holds data,
    /// the text the user types: it needs only its header and its minimum
    /// width, but gives room only when
    /// the columns of controls (pop-ups, checkboxes) have none left. Among
    /// those of one kind, the most spare room goes first.
    static func fitColumns(of table: NSTableView) {
        let columns = table.tableColumns.filter { !$0.isHidden }
        func needed(_ column: NSTableColumn) -> CGFloat {
            var width = column.title.isEmpty ? 0 : column.headerCell.cellSize.width
            if let popUp = column.dataCell as? NSPopUpButtonCell { width = max(width, popUp.cellSize.width) }
            else if let button = column.dataCell as? NSButtonCell { width = max(width, button.cellSize.width) }
            return ceil(width)
        }
        let needs = columns.map(needed)
        let holdsData = columns.map { !($0.dataCell is NSButtonCell) }
        var spare = zip(columns, needs).map { column, need in max(0, column.width - max(need, column.minWidth)) }
        // While room passes from one column to another the table is narrower, then wider, than its clip view: the
        // table's own autoresizing would spread that over every column.
        var resizing = table.columnAutoresizingStyle
        var grown = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        defer { table.columnAutoresizingStyle = resizing }
        for (index, column) in columns.enumerated() where needs[index] > column.width {
            var missing = needs[index] - column.width
            let donors = spare.indices.sorted { holdsData[$0] != holdsData[$1] ? !holdsData[$0] : spare[$0] > spare[$1] }
            for donor in donors where donor != index && missing > 0 && spare[donor] > 0 {
                let taken = min(spare[donor], missing)
                spare[donor] -= taken
                missing -= taken
                columns[donor].width -= taken
                let width = column.width + taken
                if column.maxWidth < width { column.maxWidth = width }
                column.width = width
            }
            if missing > 0 {
                let width = column.width + missing
                if column.maxWidth < width { column.maxWidth = width }
                column.width = width
                grown = true
            }
        }
        // Wider than its view, the table scrolls, and its columns keep the widths they were given.
        if grown {
            resizing = .noColumnAutoresizing
            table.enclosingScrollView?.hasHorizontalScroller = true
            table.enclosingScrollView?.autohidesScrollers = true
        }
    }

    /// Fits the columns of every table in `view` (see `fitColumns(of:)`).
    static func fitTables(in view: NSView) {
        if let table = view as? NSTableView { fitColumns(of: table); return }
        view.subviews.forEach(fitTables)
    }
}

/// The panes in a language written from right to left.
///
/// The nibs of the panes are laid out by frames, from left to right, and
/// their copies keep the frames of the English nib. In Arabic the texts ran
/// from right to left inside controls that stayed where English has them:
/// the label on the left of its pop-up, the box of a checkbox on the left of
/// its title. A loaded pane is mirrored here instead of in each copy: every
/// view goes to the other side of the view it is in, a margin kept on one
/// side is kept on the other, text aligned to one side is aligned to the
/// other, and each control is told the direction, which puts the box of a
/// checkbox, the arrows of a pop-up and the first column of a table on the
/// right.
enum PaneMirror {
    /// Whether `language` is written from right to left.
    static func isNeeded(language: String? = Bundle.main.preferredLocalizations.first) -> Bool {
        guard let language else { return false }
        return Locale.Language(identifier: language).characterDirection == .rightToLeft
    }

    /// Mirrors what is inside `view`, which stays where it is.
    static func mirror(contentsOf view: NSView) {
        let width = view.bounds.width
        for subview in view.subviews {
            if subview.translatesAutoresizingMaskIntoConstraints {
                var frame = subview.frame
                frame.origin.x = view.bounds.minX + width - (frame.maxX - view.bounds.minX)
                subview.frame = frame
                var mask = subview.autoresizingMask
                let (left, right) = (mask.contains(.minXMargin), mask.contains(.maxXMargin))
                mask.remove([.minXMargin, .maxXMargin])
                if left { mask.insert(.maxXMargin) }
                if right { mask.insert(.minXMargin) }
                subview.autoresizingMask = mask
            }
            mirror(subview)
        }
    }

    /// Tells `view` the direction and mirrors what it holds.
    private static func mirror(_ view: NSView) {
        view.userInterfaceLayoutDirection = .rightToLeft
        switch view {
        case let matrix as NSMatrix:
            matrix.cells.forEach(mirror)
        case let table as NSTableView:
            for column in table.tableColumns {
                mirror(column.headerCell)
                if let cell = column.dataCell as? NSCell { mirror(cell) }
            }
        case let scroll as NSScrollView:
            if let document = scroll.documentView {
                if document is NSTableView || document is NSText || document is NSCollectionView { mirror(document) }
                else { mirror(contentsOf: document) }
            }
        case let tabs as NSTabView:
            for item in tabs.tabViewItems { if let content = item.view { mirror(contentsOf: content) } }
        case let box as NSBox:
            if let content = box.contentView { mirror(contentsOf: content) }
        case let control as NSControl:
            if let cell = control.cell { mirror(cell) }
        case is NSText:
            break
        default:
            mirror(contentsOf: view)
        }
    }

    /// Text set to one side goes to the other, and the image of a button to
    /// the side its direction gives it. Centred and natural text stay.
    private static func mirror(_ cell: NSCell) {
        cell.userInterfaceLayoutDirection = .rightToLeft
        switch cell.alignment {
        case .left: cell.alignment = .right
        case .right: cell.alignment = .left
        default: break
        }
        guard let button = cell as? NSButtonCell else { return }
        switch button.imagePosition {
        case .imageLeft: button.imagePosition = .imageLeading
        case .imageRight: button.imagePosition = .imageTrailing
        default: break
        }
    }
}

extension NSPreferencePane {
    /// Loads the nib named `name` with the pane as its owner, keeping its
    /// top-level objects in `topLevelObjects`. Where the language has no copy
    /// of the nib its texts are read from the catalog: those of every window
    /// of the nib, the pane's own and the sheets it opens. In every language,
    /// the date pickers of those windows grow to the dates of the user's region,
    /// and the columns of their tables to their headers, which a translation
    /// makes longer than the nib's column ("Send" is "Отправить"). In a
    /// language written from right to left those windows are mirrored, unless
    /// the pane lays its own rows out afterwards (`mirrors` false).
    @MainActor
    @discardableResult
    func instantiatePaneNib(named name: String, mirrors: Bool = true, topLevelObjects: inout NSArray?) -> Bool {
        guard let nib = NSNib(nibNamed: name, bundle: nil),
              nib.instantiate(withOwner: self, topLevelObjects: &topLevelObjects) else { return false }
        let objects = topLevelObjects.map { Array($0) } ?? []
        if CatalogTranslation.isNeeded(forNibNamed: name) {
            CatalogTranslation.translate(objects, with: CatalogTranslation.mainCatalog)
        }
        for case let window as NSWindow in objects {
            guard let content = window.contentView else { continue }
            PaneFit.fitDatePickers(in: content)
            PaneFit.fitTables(in: content)
            if mirrors && PaneMirror.isNeeded() { PaneMirror.mirror(contentsOf: content) }
        }
        return true
    }
}
