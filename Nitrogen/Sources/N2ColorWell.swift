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

import Cocoa

/// The cell of `N2ColorWell`: draws the well's color as a rounded bar over the bezel.
@objc(N2ColorWellCell)
public final class N2ColorWellCell: NSButtonCell {
    public override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        NSGraphicsContext.saveGraphicsState()

        super.drawBezel(withFrame: frame, in: controlView)

        // The Objective-C messaged a nil color, which set no fill but still
        // filled the paths with the current color.
        let color = (controlView as? N2ColorWell)?.color

        var colorRect = NSInsetRect(frame, max(CGFloat(5), frame.size.width / 10), max(CGFloat(3), frame.size.height / 3))
        color?.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: colorRect, xRadius: colorRect.size.height / 2, yRadius: colorRect.size.height / 2).fill()
        colorRect = NSInsetRect(colorRect, 1, 1)
        color?.setFill()
        NSBezierPath(roundedRect: colorRect, xRadius: colorRect.size.height / 2, yRadius: colorRect.size.height / 2).fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A small recessed button showing a color, which it lets the user change in
/// the shared color panel.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2ColorWell.h>` are those of the former class.
@objc(N2ColorWell)
public final class N2ColorWell: N2Button {
    @objc public var color: NSColor? {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let cell = N2ColorWellCell()
        cell.controlSize = .mini
        self.cell = cell

        bezelStyle = .recessed
        font = NSFont.labelFont(ofSize: NSFont.systemFontSize(for: .mini))

        title = ""
        action = #selector(click(_:))
        target = self
    }

    /// The Objective-C class did not override -initWithCoder:, so a decoded
    /// well keeps its archived cell and settings.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The color panel's action.
    @objc(takeColorFrom:)
    public func takeColor(from sender: Any?) {
        // [sender color], whatever the sender.
        color = (sender as? NSObjectProtocol)?.perform(#selector(getter: NSColorPanel.color))?.takeUnretainedValue() as? NSColor
    }

    /// The well's own action: opens the shared color panel on this well.
    @objc(click:)
    public func click(_ notification: Any?) {
        let panel = NSColorPanel.shared
//      if (![panel isVisible] || [panel target] != self) {
        panel.setTarget(self)
        panel.setAction(#selector(takeColor(from:)))
        panel.showsAlpha = false
        // -setColor: with the well's color as it is, nil included.
        panel.perform(#selector(setter: NSColorPanel.color), with: color)
        panel.isContinuous = true
        panel.orderFront(self)
//      } else [panel orderOut:self];
    }

    /// Overrides NSButton (N2): a well with a frame keeps its size.
    @objc(optimalSizeForWidth:)
    public override func optimalSize(forWidth width: CGFloat) -> NSSize {
        if NSIsEmptyRect(frame) {
            return super.optimalSize(forWidth: width)
        }
        return frame.size
    }
}
