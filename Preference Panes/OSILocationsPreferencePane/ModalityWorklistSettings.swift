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
import IsiXDICOMNetwork
import IsiXPreferences

/// The Modality Worklist settings of Settings › Locations: a Worklist column in
/// the DICOM nodes table, which marks the nodes the Modality Worklist window
/// asks (the node's "MWL" key), and how often the window asks them again.
///
/// Both are made in code, as QueryRetrieveDownloadSettings is, so that the ten
/// localized nibs keep one structure: the column after Q&R, bound to the same
/// array controller as the nib's columns, and one row under the box's last
/// row, which grows by its height with the pane.
@MainActor
final class ModalityWorklistSettings: NSObject {

    static let rowHeight: CGFloat = 28
    static let tag = 13560

    let refresh = NSPopUpButton(frame: .zero, pullsDown: false)
    private let defaults: UserDefaults

    private static var key: UInt8 = 0

    /// Adds the column to the table of `nodes` and the row under the box that
    /// holds `anchor` (the text encoding popup); once per view.
    @discardableResult
    static func install(below anchor: NSView, in mainView: NSView, nodes: DNDArrayController?,
                        defaults: UserDefaults = .standard) -> ModalityWorklistSettings? {
        guard mainView.viewWithTag(tag) == nil, let content = anchor.superview, let box = content.superview as? NSBox,
              box.superview === mainView else { return nil }
        let settings = ModalityWorklistSettings(defaults: defaults)
        objc_setAssociatedObject(mainView, &key, settings, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let nodes { addColumn(bound: nodes) }

        // The row takes the place of the box's lowest row, which moves up with
        // everything above the box's bottom edge.
        let grow = rowHeight
        let rowY = content.subviews.map(\.frame.minY).min() ?? anchor.frame.minY
        let paneFrames = mainView.subviews.map { ($0, $0.frame) }
        let contentFrames = content.subviews.map { ($0, $0.frame) }
        mainView.setFrameSize(NSSize(width: mainView.frame.width, height: mainView.frame.height + grow))
        for (view, frame) in paneFrames {
            if view === box {
                view.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + grow)
            } else {
                view.frame = frame.minY >= box.frame.minY + 1 ? frame.offsetBy(dx: 0, dy: grow) : frame
            }
        }
        for (view, frame) in contentFrames { view.frame = frame.offsetBy(dx: 0, dy: grow) }
        settings.layOut(in: content, rowY: rowY, popUpX: anchor.frame.minX)
        return settings
    }

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
    }

    /// The Worklist check box of each node, after the Q&R column, enabled
    /// while the node is.
    private static func addColumn(bound nodes: DNDArrayController) {
        guard let table = nodes.tableView() else { return }
        let identifier = NSUserInterfaceItemIdentifier(DICOMNode.Key.modalityWorklist)
        guard table.tableColumn(withIdentifier: identifier) == nil else { return }
        let column = NSTableColumn(identifier: identifier)
        let header = column.headerCell
        header.stringValue = NSLocalizedString("Worklist", comment: "Settings > Locations, header of the column that marks the nodes asked for their Modality Worklist")
        header.alignment = .center
        header.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        column.headerToolTip = NSLocalizedString("Ask this node for its Modality Worklist in Network > Modality Worklist…",
                                                 comment: "Settings > Locations, help of the Worklist column")
        let width = max(40, ceil(header.cellSize.width) + 10)
        column.width = width
        column.minWidth = width
        column.maxWidth = width
        let cell = NSButtonCell()
        cell.setButtonType(.switch)
        cell.title = ""
        cell.imagePosition = .imageOnly
        cell.controlSize = .small
        cell.alignment = .center
        column.dataCell = cell
        column.bind(.value, to: nodes, withKeyPath: "arrangedObjects." + DICOMNode.Key.modalityWorklist, options: nil)
        column.bind(.enabled, to: nodes, withKeyPath: "arrangedObjects." + DICOMNode.Key.activated, options: nil)
        table.addTableColumn(column)
        let queryRetrieve = table.column(withIdentifier: NSUserInterfaceItemIdentifier(DICOMNode.Key.queryRetrieve))
        if queryRetrieve >= 0 { table.moveColumn(table.numberOfColumns - 1, toColumn: queryRetrieve + 1) }
    }

    private func layOut(in content: NSView, rowY: CGFloat, popUpX: CGFloat) {
        let label = NSTextField(labelWithString: NSLocalizedString("Worklist refresh:", comment: "Settings > Locations, before the popup of how often the Modality Worklist window asks its nodes"))
        label.tag = Self.tag
        label.alignment = .right
        label.sizeToFit()

        for minutes in ModalityWorklistRefresh.choices {
            refresh.addItem(withTitle: Self.title(minutes: minutes))
            refresh.lastItem?.tag = minutes
        }
        refresh.sizeToFit()
        refresh.target = self
        refresh.action = #selector(refreshChanged(_:))

        let left: CGFloat = 14
        let labelWidth = max(label.frame.width, popUpX - 4 - left)
        label.frame = NSRect(x: left, y: rowY + (22 - label.frame.height) / 2, width: labelWidth, height: label.frame.height)
        refresh.frame = NSRect(x: label.frame.maxX + 4, y: rowY, width: max(refresh.frame.width, 140), height: 22)
        for view in [label, refresh] as [NSView] {
            view.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(view)
        }
        load()
    }

    private static func title(minutes: Int) -> String {
        switch minutes {
        case 0: return NSLocalizedString("Manually", comment: "Settings > Locations, the Modality Worklist window asks its nodes only when Refresh is clicked")
        case 1: return NSLocalizedString("Every minute", comment: "Settings > Locations, Modality Worklist refresh interval")
        default: return String(format: NSLocalizedString("Every %ld minutes", comment: "Settings > Locations, Modality Worklist refresh interval"), minutes)
        }
    }

    /// The popup as the preference is.
    func load() {
        let stored = defaults.integer(forKey: NetworkPreferences.modalityWorklistRefreshMinutes.name)
        _ = refresh.selectItem(withTag: ModalityWorklistRefresh.choice(forStored: stored))
    }

    @objc func refreshChanged(_ sender: Any?) {
        defaults.set(refresh.selectedTag(), forKey: NetworkPreferences.modalityWorklistRefreshMinutes.name)
    }
}
