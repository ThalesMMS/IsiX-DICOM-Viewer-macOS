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

/// A sheet laid out as a column of right-aligned labels beside a column of
/// controls, with frames drawn for the English text. A translation longer than
/// the English one would be clipped by its fixed frame; this widens the label
/// column to the longest label of the sheet's own language and moves the
/// controls right by as much, so every language gets the width its text needs
/// and no nib carries a size of its own.
enum SheetLabelColumn {
    /// Space between the sheet's leading edge and the longest label.
    static let leadingMargin: CGFloat = 17
    /// Space kept on the trailing side of the widest control.
    static let trailingMargin: CGFloat = 12

    /// The text fields that only label something: not editable, not bezeled.
    @MainActor
    static func isLabel(_ view: NSView) -> Bool {
        guard let field = view as? NSTextField else { return false }
        return !field.isEditable && !field.isBezeled && !field.drawsBackground
    }

    /// Lays out `sheet`: labels whose trailing edge is at or before
    /// `controlColumn` form the label column; every other view is a control.
    /// The column's labels end at one edge, the column's own or further right
    /// when a label needs it; labels beside the controls take their text's
    /// width. Running it again changes nothing.
    @MainActor
    static func fit(_ sheet: NSWindow, controlColumn: CGFloat) {
        guard let content = sheet.contentView else { return }
        let views = content.subviews
        let column = views.filter { isLabel($0) && $0.frame.maxX <= controlColumn }
        guard let columnEnd = column.map(\.frame.maxX).max() else { return }
        let needed = column.map { ceil(($0 as! NSTextField).fittingSize.width) }.max() ?? 0
        let shift = max(0, leadingMargin + needed - columnEnd)
        for view in views {
            if column.contains(where: { $0 === view }) {
                // One trailing edge for the whole column.
                let label = view as! NSTextField
                label.frame = NSRect(x: leadingMargin, y: label.frame.minY, width: columnEnd + shift - leadingMargin,
                                     height: label.frame.height)
            } else {
                view.frame = view.frame.offsetBy(dx: shift, dy: 0)
                if isLabel(view), let label = view as? NSTextField, label.alignment != .right {
                    label.frame.size.width = max(label.frame.width, ceil(label.fittingSize.width))
                }
            }
        }
        // Wide enough for the moved controls and the labels beside them,
        // keeping the sheet's own right margin when nothing grows.
        let contentEnd = views.map(\.frame.maxX).max() ?? 0
        let width = max(content.bounds.width + shift, contentEnd + trailingMargin)
        if width > content.bounds.width {
            var frame = sheet.frame
            frame.size.width += width - content.bounds.width
            // Content views keep their positions: the sheet grows to the right.
            let frames = views.map { ($0, $0.frame) }
            sheet.setFrame(frame, display: false)
            for (view, original) in frames { view.frame = original }
        }
    }
}
