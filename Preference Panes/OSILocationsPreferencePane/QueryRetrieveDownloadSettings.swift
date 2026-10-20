//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// How the Query & Retrieve window downloads, in the DICOM nodes box of
/// Settings › Locations: Parallel or Sequential, and in Parallel, whether the
/// downloads beyond a number at once wait in a queue (HorosRetrieveQueue).
///
/// The two rows are made in code under the box's last row, which grows by
/// their height with the pane, so the ten localized nibs keep one structure.
@MainActor
final class QueryRetrieveDownloadSettings: NSObject, NSTextFieldDelegate {

    static let rowHeight: CGFloat = 28
    static let tag = 13540

    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let queueAbove = NSButton(checkboxWithTitle: NSLocalizedString("Queue the downloads beyond", comment: "Settings > Locations, before the number of simultaneous Query & Retrieve downloads"), target: nil, action: nil)
    let count = NSTextField(frame: .zero)
    let countLabel = NSTextField(labelWithString: NSLocalizedString("simultaneous downloads", comment: "Settings > Locations, after the number of simultaneous Query & Retrieve downloads"))
    private let defaults: UserDefaults

    private static var key: UInt8 = 0

    /// Adds the two rows under the box that holds `anchor` (the text encoding
    /// popup), growing the box and the pane's view; once per view.
    @discardableResult
    static func install(below anchor: NSView, in mainView: NSView, defaults: UserDefaults = .standard) -> QueryRetrieveDownloadSettings? {
        guard mainView.viewWithTag(tag) == nil, let content = anchor.superview, let box = content.superview as? NSBox,
              box.superview === mainView else { return nil }
        let settings = QueryRetrieveDownloadSettings(defaults: defaults)
        objc_setAssociatedObject(mainView, &key, settings, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let grow = 2 * rowHeight
        // Everything above the box's bottom edge moves up; set the frames
        // directly, whatever the autoresizing masks say.
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

        // The rows take the place the box's last row had; the popup lines up
        // with the text encoding popup above when the label leaves room.
        settings.layOut(in: content, firstRowY: anchor.frame.minY - grow, popUpX: anchor.frame.minX)
        return settings
    }

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
    }

    private func layOut(in content: NSView, firstRowY: CGFloat, popUpX: CGFloat) {
        let label = NSTextField(labelWithString: NSLocalizedString("Q&R downloads:", comment: "Settings > Locations, before the Parallel / Sequential popup"))
        label.tag = Self.tag
        label.sizeToFit()

        mode.addItems(withTitles: [NSLocalizedString("In parallel", comment: "Settings > Locations, Query & Retrieve downloads all at once"),
                                   NSLocalizedString("Sequential", comment: "Settings > Locations, Query & Retrieve downloads one after the other")])
        mode.sizeToFit()
        mode.target = self
        mode.action = #selector(modeChanged(_:))

        queueAbove.target = self
        queueAbove.action = #selector(queueAboveChanged(_:))
        queueAbove.sizeToFit()

        count.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = 1
            formatter.maximum = 99
            formatter.allowsFloats = false
            return formatter
        }()
        count.alignment = .right
        count.delegate = self
        count.target = self
        count.action = #selector(countChanged(_:))
        countLabel.sizeToFit()

        // Upper row: the label and the popup. Lower row, indented under the
        // popup: the queue check, the number and its unit.
        let upper = firstRowY + Self.rowHeight
        let left: CGFloat = 14
        label.alignment = .right
        let labelWidth = max(label.frame.width, popUpX - 4 - left)
        label.frame = NSRect(x: left, y: upper + (22 - label.frame.height) / 2, width: labelWidth, height: label.frame.height)
        mode.frame = NSRect(x: label.frame.maxX + 4, y: upper, width: max(mode.frame.width, 140), height: 22)
        queueAbove.setFrameOrigin(NSPoint(x: mode.frame.minX + 2, y: firstRowY + (22 - queueAbove.frame.height) / 2))
        count.frame = NSRect(x: queueAbove.frame.maxX + 4, y: firstRowY, width: 40, height: 22)
        countLabel.setFrameOrigin(NSPoint(x: count.frame.maxX + 6, y: firstRowY + (22 - countLabel.frame.height) / 2))
        for view in [label, mode, queueAbove, count, countLabel] as [NSView] {
            view.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(view)
        }
        load()
    }

    /// The controls as the preferences are.
    func load() {
        let sequential = defaults.integer(forKey: RetrieveQueue.modeKey) == 1
        mode.selectItem(at: sequential ? 1 : 0)
        queueAbove.state = defaults.bool(forKey: RetrieveQueue.limitEnabledKey) ? .on : .off
        let limit = defaults.integer(forKey: RetrieveQueue.limitKey)
        count.integerValue = limit > 0 ? limit : RetrieveQueue.defaultLimit
        showLimitRow()
    }

    /// The limit only means something in Parallel: Sequential is one at a time.
    private func showLimitRow() {
        let parallel = mode.indexOfSelectedItem == 0
        for view in [queueAbove, count, countLabel] as [NSView] { view.isHidden = !parallel }
        count.isEnabled = queueAbove.state == .on
    }

    @objc func modeChanged(_ sender: Any?) {
        defaults.set(mode.indexOfSelectedItem == 1 ? 1 : 0, forKey: RetrieveQueue.modeKey)
        showLimitRow()
    }

    @objc func queueAboveChanged(_ sender: Any?) {
        defaults.set(queueAbove.state == .on, forKey: RetrieveQueue.limitEnabledKey)
        showLimitRow()
    }

    @objc func countChanged(_ sender: Any?) {
        let value = min(max(count.integerValue, 1), 99)
        count.integerValue = value
        defaults.set(value, forKey: RetrieveQueue.limitKey)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        countChanged(nil)
    }
}
