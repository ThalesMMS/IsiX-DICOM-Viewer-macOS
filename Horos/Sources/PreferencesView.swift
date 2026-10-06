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

/// The "Show All" grid of the preferences window: one row per group, one button
/// per pane, each button carrying its context as the cell's represented object.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/PreferencesView.h> are those of the former class.
@objc(PreferencesView)
public final class PreferencesView: NSControl {
    private var groups: [PreferencesViewGroup] = []

    /// Retained, as in the former header.
    @objc public var buttonActionTarget: Any?
    @objc public var buttonActionSelector: Selector?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func group(withName name: String) -> PreferencesViewGroup {
        var group: PreferencesViewGroup?
        for g in groups where g.label.stringValue == name {
            group = g
        }

        if let group = group {
            return group
        }
        let created = PreferencesViewGroup(name: name)
        addSubview(created.label)
        groups.append(created)
        return created
    }

    @objc(removeItemWithBundle:)
    public func removeItem(with bundle: Bundle?) {
        for group in groups {
            for button in group.buttons {
                let context = button.cell?.representedObject as? PreferencesWindowContext
                if context?.parentBundle === bundle {
                    group.buttons.removeAll { $0 === button }
                    layout()
                    return
                }
            }
        }
    }

    @objc(addItemWithTitle:image:toGroupWithName:context:)
    public func addItem(withTitle title: String, image: NSImage?, toGroupWithName groupName: String, context: Any?) {
        let group = self.group(withName: groupName)

        let button = NSButton(frame: .zero)
        button.cell = PreferencesViewButtonCell()
        button.title = title
        button.image = image
        button.alternateImage = image?.shadowImage()
        button.target = self
        button.action = #selector(buttonAction(_:))
        button.cell?.representedObject = context
        addSubview(button)

        group.buttons.append(button)

        layout()
    }

    public override var isOpaque: Bool {
        return false
    }

    @objc(buttonAction:)
    func buttonAction(_ sender: NSButton) {
        guard let target = buttonActionTarget as AnyObject?, let selector = buttonActionSelector else { return }
        if target.responds(to: selector) {
            _ = target.perform(selector, with: sender.cell?.representedObject)
        }
    }

    @objc public func itemsCount() -> UInt {
        var count: UInt = 0
        for group in groups {
            count += UInt(group.buttons.count)
        }
        return count
    }

    @objc(contextForItemAtIndex:)
    public func contextForItem(at index: UInt) -> Any? {
        var count: UInt = 0
        for group in groups {
            let buttons = group.buttons
            if count + UInt(buttons.count) > index {
                return buttons[Int(index - count)].cell?.representedObject
            }
            count += UInt(buttons.count)
        }

        return nil
    }

    @objc(indexOfItemWithContext:)
    public func indexOfItem(withContext context: Any?) -> Int {
        var count = 0
        for group in groups {
            for button in group.buttons {
                if (button.cell?.representedObject as AnyObject?) === (context as AnyObject?) {
                    return count
                }
                count += 1
            }
        }
        return -1
    }

    private static let colWidth: CGFloat = 80
    private static let colSeparator: CGFloat = 1
    private static let rowHeight: CGFloat = 101
    private static let titleHeight: CGFloat = 20
    private static let titleMargin: [CGFloat] = [6, 3]
    private static let padding: [CGFloat] = [0, 16, 1, 6] // top, right, bottom, left

    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()

        let frame = bounds

        NSColor.alternatingContentBackgroundColors[1].setFill()
        NSColor.separatorColor.setStroke()

        NSBezierPath.defaultLineWidth = 1
        let rowHeight = PreferencesView.rowHeight, padding = PreferencesView.padding
        var r = 1
        while r < groups.count {
            let rect = NSRect(x: 0, y: frame.size.height - rowHeight * CGFloat(r) - rowHeight - padding[0],
                              width: frame.size.width, height: rowHeight)
            NSBezierPath.fill(rect)
            NSBezierPath.strokeLine(from: NSPoint(x: rect.origin.x, y: rect.origin.y + 0.5),
                                    to: NSPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + 0.5))
            NSBezierPath.strokeLine(from: NSPoint(x: rect.origin.x, y: rect.origin.y + rect.size.height - 0.5),
                                    to: NSPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height - 0.5))
            r += 2
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    /// Declared in the former (Private) category; it overrides -[NSView layout].
    public override func layout() {
        let colWidth = PreferencesView.colWidth, colSeparator = PreferencesView.colSeparator
        let rowHeight = PreferencesView.rowHeight, titleHeight = PreferencesView.titleHeight
        let titleMargin = PreferencesView.titleMargin, padding = PreferencesView.padding

        var colsCount = 0
        for group in groups {
            colsCount = max(colsCount, group.buttons.count)
        }

        var frame = self.frame
        frame = NSRect(x: frame.origin.x, y: frame.origin.y,
                       width: padding[3] + (colWidth + colSeparator) * CGFloat(colsCount) - colSeparator + padding[1],
                       height: padding[2] + rowHeight * CGFloat(groups.count) + padding[0])
        self.frame = frame

        var r = groups.count - 1
        while r >= 0 {
            let group = groups[r]
            let rowRect = NSRect(x: padding[3], y: frame.size.height - rowHeight * CGFloat(r) - rowHeight - padding[0],
                                 width: frame.size.width - padding[3] - padding[1], height: rowHeight)

            group.label.frame = NSRect(x: rowRect.origin.x + titleMargin[0],
                                       y: rowRect.origin.y + rowRect.size.height - titleHeight - titleMargin[1],
                                       width: rowRect.size.width - titleMargin[0] * 2, height: titleHeight)

            for (i, button) in group.buttons.enumerated() {
                button.frame = NSRect(x: rowRect.origin.x + (colWidth + colSeparator) * CGFloat(i), y: rowRect.origin.y,
                                      width: colWidth, height: rowHeight)
            }
            r -= 1
        }

        super.layout()
    }
}

/// One row of PreferencesView: its title and its buttons.
// Main actor: a row of controls of PreferencesView.
@MainActor
@objc(PreferencesViewGroup)
final class PreferencesViewGroup: NSObject {
    let label: NSTextField
    var buttons: [NSButton] = []

    init(name: String) {
        label = NSTextField(frame: .zero)
        label.stringValue = name
        label.isEditable = false
        label.drawsBackground = false
        label.isBordered = false
        label.isSelectable = false
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        super.init()
    }
}

/// Draws a pane's icon above its title.
@objc(PreferencesViewButtonCell)
final class PreferencesViewButtonCell: NSButtonCell {
    private static let labelHeight: CGFloat = 38
    private static let labelSeparator: CGFloat = 3

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        let labelHeight = PreferencesViewButtonCell.labelHeight
        let labelSeparator = PreferencesViewButtonCell.labelSeparator

        NSGraphicsContext.saveGraphicsState()

        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: frame.size.height)
        transform.scaleX(by: 1, yBy: -1)
        transform.concat()

        let imageRect = NSRect(x: frame.origin.x, y: frame.origin.y + labelHeight + labelSeparator,
                               width: frame.size.width, height: frame.size.height - labelHeight - labelSeparator)

        let image = isHighlighted ? alternateImage : self.image
        var imageSize = image?.size ?? .zero
        if imageSize.width > 32 || imageSize.height > 32 {
            imageSize = NSSize(width: 32, height: 32)
            image?.size = imageSize
        }
        image?.draw(at: NSPoint(x: imageRect.origin.x + (imageRect.size.width - imageSize.width) / 2, y: imageRect.origin.y),
                    from: NSRect(origin: .zero, size: imageSize), operation: .sourceOver, fraction: 1)

        NSGraphicsContext.restoreGraphicsState()

        let labelRect = NSRect(x: frame.origin.x, y: frame.size.height - labelHeight, width: frame.size.width, height: labelHeight)

        let style = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        style.alignment = .center
        let font = NSFont.labelFont(ofSize: NSFont.smallSystemFontSize)

        (title as NSString).draw(in: labelRect, withAttributes: [
            .paragraphStyle: style,
            .font: font,
            .foregroundColor: NSColor.controlTextColor,
        ])
    }
}
