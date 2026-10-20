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
import ObjectiveC

/// The download arrows of the Query & Retrieve list turn into a Return arrow
/// while Command is held over the window: a click then queues the retrieve
/// behind the ones under way (see HorosRetrieveQueue). Option keeps its own
/// meaning on the same arrows, asking a node for everything again.
@MainActor @objc(HorosRetrieveQueueArrows)
public final class RetrieveQueueArrows: NSObject {

    private weak var outlineView: NSOutlineView?
    private let cell: NSButtonCell
    private let columnIdentifier: NSUserInterfaceItemIdentifier
    private let arrow: NSImage?
    private let queueArrow: NSImage?
    // Set once in init and read again only by deinit: nonisolated(unsafe)
    // lets the nonisolated deinit remove them.
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    @objc public private(set) var showsQueueArrows = false

    private static var key: UInt8 = 0

    /// Watches Command for the outline view's download column, and keeps the
    /// watcher alive as long as the outline view.
    @discardableResult
    @objc(installOnOutlineView:column:)
    public static func install(on outlineView: NSOutlineView, column identifier: String) -> RetrieveQueueArrows? {
        guard let cell = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.dataCell as? NSButtonCell else { return nil }
        let arrows = RetrieveQueueArrows(outlineView: outlineView, cell: cell, column: NSUserInterfaceItemIdentifier(identifier))
        objc_setAssociatedObject(outlineView, &key, arrows, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return arrows
    }

    private init(outlineView: NSOutlineView, cell: NSButtonCell, column: NSUserInterfaceItemIdentifier) {
        self.outlineView = outlineView
        self.cell = cell
        columnIdentifier = column
        arrow = cell.image
        let symbol = NSImage(systemSymbolName: "return", accessibilityDescription: NSLocalizedString("Queue the download", comment: "Accessibility description of the Return arrow of the Query & Retrieve list, shown while Command is held"))
        queueArrow = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.update(command: event.modifierFlags.contains(.command)) }
            return event
        }
        // A window that stops being key no longer sees Command go up.
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(command: false) }
            })
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Shows the Return arrows while Command is held with the list's window key.
    @objc(updateForCommand:)
    public func update(command: Bool) {
        let show = command && outlineView?.window?.isKeyWindow == true
        guard show != showsQueueArrows, let outlineView else { return }
        showsQueueArrows = show
        cell.image = show ? (queueArrow ?? arrow) : arrow
        let column = outlineView.column(withIdentifier: columnIdentifier)
        outlineView.setNeedsDisplay(column >= 0 ? outlineView.rect(ofColumn: column) : outlineView.visibleRect)
    }
}
