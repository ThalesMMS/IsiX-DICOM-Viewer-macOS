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

/// An ordinary text field with a separate label, including dynamically titled
/// segmentation parameters. Values, formatters and bindings belong to the field.
@objc(HorosFormField) @objcMembers
final class HorosFormField: NSTextField {
    var title: String {
        get { label?.stringValue ?? "" }
        set { label?.stringValue = newValue; (superview as? HorosFormView)?.layoutRows() }
    }
    private var label: NSTextField? {
        superview?.subviews.compactMap { $0 as? NSTextField }.first {
            !($0 is HorosFormField) && $0.identifier?.rawValue == "label-\(identifier?.rawValue ?? "")"
        }
    }
}

/// NSTextField composition replacing the old single-column form. The lookup
/// selectors remain available to existing callers, but return modern controls.
@objc(HorosFormView) @objcMembers
final class HorosFormView: NSView {
    private var rowHeight: CGFloat = 19
    private var rowSpacing: CGFloat = 8
    private var prototype: NSTextFieldCell?
    private weak var prototypeTarget: AnyObject?
    private var prototypeAction: Selector?
    private var fields: [HorosFormField] { subviews.compactMap { $0 as? HorosFormField } }
    var numberOfRows: Int { fields.count }
    override var acceptsFirstResponder: Bool { !fields.isEmpty }
    override func becomeFirstResponder() -> Bool {
        guard let first = fields.first else { return false }
        return window?.makeFirstResponder(first) ?? false
    }
    nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        // AppKit awakens these UI objects on the main thread. Keep the
        // superclass's nonisolated callback and verify that contract at runtime.
        MainActor.assumeIsolated { configureDecodedRows() }
    }
    private func configureDecodedRows() {
        if let first = fields.first {
            rowHeight = first.frame.height
            prototype = first.cell?.copy() as? NSTextFieldCell
            prototypeTarget = first.target
            prototypeAction = first.action
        }
        if fields.count > 1 { rowSpacing = max(0, fields[0].frame.minY - fields[1].frame.maxY) }
        layoutRows()
    }
    @objc(cellAtIndex:) func cell(at index: Int) -> HorosFormField? {
        fields.indices.contains(index) ? fields[index] : nil
    }
    @objc(cellAtRow:column:) func cell(atRow row: Int, column: Int) -> HorosFormField? {
        column == 0 ? cell(at: row) : nil
    }
    @objc(cellWithTag:) func cell(withTag tag: Int) -> HorosFormField? { fields.first { $0.tag == tag } }
    func addRow() {
        let field = HorosFormField(frame: NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight))
        if let prototype { field.cell = prototype.copy() as? NSTextFieldCell }
        field.identifier = NSUserInterfaceItemIdentifier("dynamic-\(fields.count)")
        let label = NSTextField(labelWithString: "")
        label.identifier = NSUserInterfaceItemIdentifier("label-\(field.identifier!.rawValue)")
        label.font = field.font
        field.target = prototypeTarget
        field.action = prototypeAction
        addSubview(label)
        addSubview(field)
        layoutRows()
    }
    @objc(removeRow:) func removeRow(_ row: Int) {
        guard let field = cell(at: row) else { return }
        for view in subviews where view.identifier?.rawValue == "label-\(field.identifier?.rawValue ?? "")" { view.removeFromSuperview() }
        field.unbind(.value)
        field.removeFromSuperview()
        layoutRows()
    }
    func sizeToCells() { setFrameSize(NSSize(width: frame.width, height: CGFloat(fields.count) * (rowHeight + rowSpacing) - (fields.isEmpty ? 0 : rowSpacing))) }
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); layoutRows() }
    fileprivate func layoutRows() {
        let controls = fields
        let labels = subviews.compactMap { $0 as? NSTextField }.filter { !($0 is HorosFormField) }
        let labelWidth = min(bounds.width * 0.7, labels.map { $0.cell?.cellSize.width ?? 0 }.max() ?? 0)
        for (index, field) in controls.enumerated() {
            let y = bounds.height - rowHeight - CGFloat(index) * (rowHeight + rowSpacing)
            field.frame = NSRect(x: labelWidth + 8, y: y, width: max(20, bounds.width - labelWidth - 8), height: rowHeight)
            if let label = labels.first(where: { $0.identifier?.rawValue == "label-\(field.identifier?.rawValue ?? "")" }) {
                label.frame = NSRect(x: 0, y: y, width: labelWidth, height: rowHeight)
            }
            field.nextKeyView = index + 1 < controls.count ? controls[index + 1] : nextKeyView
        }
    }
}

/// A resizable child panel for the CLUT editor. The historic drawer getter and
/// basic selectors are retained for plugins without constructing an NSDrawer.
@objc(HorosCLUTPanel) @objcMembers
@MainActor
final class HorosCLUTPanel: NSObject, NSWindowDelegate {
    @IBOutlet var contentView: NSView?
    @IBOutlet weak var parentWindow: NSWindow?
    @IBOutlet weak var delegate: NSObject?
    var leadingOffset: CGFloat = 15
    var trailingOffset: CGFloat = 15
    var contentSize = NSSize(width: 200, height: 200)
    var minContentSize = NSSize(width: 50, height: 50)
    var maxContentSize = NSSize(width: 600, height: 400)
    private var panel: NSPanel?
    private var parentObserver: NSObjectProtocol?
    var state: Int { panel?.isVisible == true ? 2 : 0 }
    var isOpen: Bool { state == 2 }
    var isClosed: Bool { state == 0 }
    isolated deinit { if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) } }
    func open() { open(onEdge: .minY) }
    @objc(openOnEdge:) func open(onEdge edge: NSRectEdge) {
        guard let parentWindow, let contentView else { return }
        let firstOpening = panel == nil
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = NSLocalizedString("16-bit CLUT", comment: "")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.backgroundColor = .black
            panel.contentMinSize = minContentSize
            panel.contentMaxSize = maxContentSize
            panel.delegate = self
            panel.contentView = contentView
            contentView.autoresizingMask = [.width, .height]
            self.panel = panel
            parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        guard let panel, state == 0 else { return }
        let desiredWidth = firstOpening ? parentWindow.frame.width - leadingOffset - trailingOffset : contentSize.width
        let width = min(maxContentSize.width, max(minContentSize.width, desiredWidth))
        panel.setContentSize(NSSize(width: width, height: contentSize.height))
        var origin = NSPoint(x: parentWindow.frame.minX + leadingOffset, y: parentWindow.frame.minY - panel.frame.height)
        if edge == .maxY { origin.y = parentWindow.frame.maxY }
        if let screen = parentWindow.screen { origin.y = max(screen.visibleFrame.minY, min(origin.y, screen.visibleFrame.maxY - panel.frame.height)); origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - panel.frame.width)) }
        panel.setFrameOrigin(origin)
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        notify("drawerDidOpen:", name: "NSDrawerDidOpenNotification")
    }
    func close() {
        guard let panel, state != 0 else { return }
        contentSize = panel.contentView?.frame.size ?? contentSize
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        notify("drawerDidClose:", name: "NSDrawerDidCloseNotification")
    }
    func toggle(_ sender: Any?) { state == 0 ? open() : close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    private func notify(_ selector: String, name: String) {
        let notification = Notification(name: Notification.Name(name), object: self)
        NotificationCenter.default.post(notification)
        let action = NSSelectorFromString(selector)
        if delegate?.responds(to: action) == true { _ = delegate?.perform(action, with: notification as NSNotification) }
    }
}
