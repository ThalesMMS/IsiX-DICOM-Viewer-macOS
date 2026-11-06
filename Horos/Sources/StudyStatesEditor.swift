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
import IsiXDatabase

/// The window that edits the study states: a row per state with its number,
/// its colour, its name and what applying it does. Each change is kept at
/// once (StudyStates.save), and every list that shows the states follows.
@MainActor final class StudyStatesEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = StudyStatesEditor()

    private var window: NSWindow?
    private let table = NSTableView()
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private var list = StudyStates.list

    private enum Column: String, CaseIterable {
        case number, color, name, action

        var title: String {
            switch self {
            case .number: return NSLocalizedString("No.", comment: "")
            case .color: return NSLocalizedString("Color", comment: "")
            case .name: return NSLocalizedString("Name", comment: "")
            case .action: return NSLocalizedString("When Applied", comment: "")
            }
        }

        var width: CGFloat {
            switch self {
            case .number: return 34
            case .color: return 52
            case .name: return 170
            case .action: return 250
            }
        }
    }

    /// The actions, in the order of the pop-up, with their titles.
    private static let actions: [(StudyStateAction, String)] = [
        (.none, NSLocalizedString("None", comment: "")),
        (.openImages, NSLocalizedString("Open images", comment: "")),
        (.reportToPDF, NSLocalizedString("Convert report to PDF", comment: "")),
        (.reportToDICOMPDF, NSLocalizedString("Convert report to DICOM PDF", comment: "")),
        (.saveReportAsPDF, NSLocalizedString("Save report as PDF in EXPORT-REPORTS", comment: "")),
    ]

    func show() {
        list = StudyStates.list
        if window == nil { build() }
        // A state's colour is a solid one.
        NSColorPanel.shared.showsAlpha = false
        table.reloadData()
        updateButtons()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - The window

    private func build() {
        let width: CGFloat = 560, height: CGFloat = 380
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = NSLocalizedString("Study States", comment: "")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.width
            table.addTableColumn(tableColumn)
        }
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 96, width: width - 40, height: height - 116))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        content.addSubview(scroll)

        func place(_ button: NSButton, title: String, action: Selector, x: CGFloat, width: CGFloat) {
            button.title = title
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.frame = NSRect(x: x, y: 58, width: width, height: 28)
            content.addSubview(button)
        }
        place(addButton, title: NSLocalizedString("Add", comment: ""), action: #selector(addState(_:)), x: 16, width: 110)
        place(removeButton, title: NSLocalizedString("Remove Last", comment: ""), action: #selector(removeLastState(_:)), x: 128, width: 150)
        place(clearButton, title: NSLocalizedString("No Color", comment: ""), action: #selector(clearColor(_:)), x: 280, width: 130)

        let note = NSTextField(wrappingLabelWithString: NSLocalizedString("A state keeps its number: a new state goes at the end, and only the last one can be removed. In the database list, Option and a digit give the selected studies the state of that number.", comment: ""))
        note.frame = NSRect(x: 20, y: 12, width: width - 40, height: 42)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        window.contentView = content
        self.window = window
    }

    private func updateButtons() {
        addButton.isEnabled = list.canAppend
        removeButton.isEnabled = list.canRemoveLast
        clearButton.isEnabled = table.selectedRow >= 0 && list.states.indices.contains(table.selectedRow) && list.states[table.selectedRow].color != nil
    }

    private func keep() {
        StudyStates.save(list)
        updateButtons()
    }

    // MARK: - The table

    func numberOfRows(in tableView: NSTableView) -> Int {
        list.states.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }), list.states.indices.contains(row) else { return nil }
        let state = list.states[row]
        switch column {
        case .number:
            let label = NSTextField(labelWithString: String(row))
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            return centred(label, width: column.width)
        case .color:
            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            // No colour is shown as a see-through white: the panel then opens on
            // the bright colours, not on black.
            well.color = state.color.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
            well.tag = row
            well.target = self
            well.action = #selector(colorChanged(_:))
            return well
        case .name:
            let field = NSTextField(string: state.name ?? "")
            field.placeholderString = StudyStateList(states: Array(repeating: StudyState(), count: list.states.count))
                .name(at: row, localized: StudyStates.builtInName, numbered: StudyStates.numberedName)
            field.isBordered = false
            field.drawsBackground = false
            field.tag = row
            field.delegate = self
            return centred(field, width: column.width)
        case .action:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.addItems(withTitles: Self.actions.map(\.1))
            popup.selectItem(at: Self.actions.firstIndex { $0.0 == state.action } ?? 0)
            popup.tag = row
            popup.target = self
            popup.action = #selector(actionChanged(_:))
            return popup
        }
    }

    /// A text field in the middle of its row's height.
    private func centred(_ field: NSTextField, width: CGFloat) -> NSView {
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: width, height: table.rowHeight))
        field.frame = NSRect(x: 0, y: (table.rowHeight - 17) / 2, width: width, height: 17)
        field.autoresizingMask = [.width]
        cell.addSubview(field)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: - Changes

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        list.set(color: StudyStateColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent), at: sender.tag)
        sender.color = color.withAlphaComponent(1)
        keep()
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard Self.actions.indices.contains(sender.indexOfSelectedItem) else { return }
        list.set(action: Self.actions[sender.indexOfSelectedItem].0, at: sender.tag)
        keep()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        list.set(name: field.stringValue, at: field.tag)
        field.stringValue = list.states.indices.contains(field.tag) ? list.states[field.tag].name ?? "" : ""
        keep()
    }

    @objc private func clearColor(_ sender: Any?) {
        guard table.selectedRow >= 0 else { return }
        let row = table.selectedRow
        list.set(color: nil, at: row)
        keep()
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    @objc private func addState(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        list.append()
        keep()
        table.reloadData()
        table.scrollRowToVisible(list.states.count - 1)
    }

    @objc private func removeLastState(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        list.removeLast()
        keep()
        table.reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        NSColorPanel.shared.close()
    }
}
