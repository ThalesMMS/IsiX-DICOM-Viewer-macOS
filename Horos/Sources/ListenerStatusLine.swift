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

/// The line of the Listener preferences that says whether the DICOM listener
/// is listening: its port, that it is off, or why it is not.
///
/// It is added at runtime, as the XML-RPC network access button is, in the
/// corner the listener's box leaves free beside its two time-outs: the nib has
/// no row to spare, and the box's other rows are full in the longer languages.
@MainActor
@objc(HorosListenerStatusLine)
public final class ListenerStatusLine: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("HorosListenerStatusLine")

    /// The lines on screen, each kept by its own pane.
    private static let lines = NSHashTable<NSTextField>.weakObjects()
    private static var observer: NSObjectProtocol?

    /// Adds the line to the box of `view` that holds the connection time-out,
    /// or returns the one already there. `nil` when that field is not in this
    /// tree or the corner is too narrow: a pane that was rearranged loses the
    /// line rather than have it drawn over something.
    @objc(installInView:)
    @discardableResult
    public static func install(in view: NSView) -> NSTextField? {
        guard let anchor = timeoutField(in: view), let box = anchor.superview else { return nil }
        if let existing = box.subviews.first(where: { $0.identifier == identifier }) as? NSTextField {
            return existing
        }
        // The two rows of time-outs, the lowest of the box, end where the
        // widest of their controls ends.
        let rowsTop = anchor.frame.maxY + 20
        let rowsEnd = box.subviews.filter { $0.frame.minY < rowsTop }.map(\.frame.maxX).max() ?? anchor.frame.maxX
        let left = rowsEnd + 14
        let width = box.bounds.width - left - 10
        guard width >= 150 else { return nil }

        let line = NSTextField(wrappingLabelWithString: "")
        line.frame = NSRect(x: left, y: anchor.frame.minY - 6, width: width, height: 44)
        line.identifier = identifier
        line.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        line.isSelectable = false
        line.maximumNumberOfLines = 3
        line.cell?.truncatesLastVisibleLine = true
        line.autoresizingMask = [.maxXMargin, .minYMargin]
        box.addSubview(line)

        lines.add(line)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ListenerStatus.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh() }
            }
        }
        show(in: line)
        return line
    }

    private static func refresh() {
        for line in lines.allObjects { show(in: line) }
    }

    private static func show(in line: NSTextField) {
        let text = ListenerStatus.summary
        line.stringValue = text
        // The whole text, should a long reason not fit the corner.
        line.toolTip = text
        line.textColor = ListenerStatus.hasFailure ? .systemRed : .secondaryLabelColor
    }

    static func timeoutField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           let observed = field.infoForBinding(.value)?[NSBindingInfoKey.observedKeyPath] as? String,
           observed == "values.DICOMConnectionTimeout" {
            return field
        }
        for child in view.subviews {
            if let field = timeoutField(in: child) { return field }
        }
        return nil
    }
}
