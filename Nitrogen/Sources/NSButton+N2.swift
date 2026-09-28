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

// NSButton (N2), implemented in Swift since #709; the selectors and
// <Horos/NSButton+N2.h> are those of the former category.

public extension NSButton {

    @objc(initWithOrigin:title:font:)
    convenience init(origin: NSPoint, title: String, font: NSFont) {
        let size = (title as NSString).size(forWidth: Float.greatestFiniteMagnitude, height: Float.greatestFiniteMagnitude, font: font)
        self.init(frame: NSMakeRect(origin.x, origin.y, size.width + 4 * 2, size.height + 1 * 2))
        self.title = title
        self.font = font
    }

    @objc(optimalSizeForWidth:)
    func optimalSize(forWidth width: CGFloat) -> NSSize {
        var size = cell?.cellSize ?? NSZeroSize
        if size.width > width { size.width = width }

        if bezelStyle == .accessoryBar { // NSRecessedBezelStyle
            if cell?.controlSize == .mini { size.height -= 4 }
        }

        return NSMakeSize(ceil(size.width), ceil(size.height))
    }

    @objc(optimalSize)
    func optimalSize() -> NSSize {
        optimalSize(forWidth: CGFloat.greatestFiniteMagnitude)
    }

    /// Not in the header: N2View and N2Layout send -setTextColor: to the views
    /// they lay out that respond to it.
    @objc(setTextColor:)
    func setTextColor(_ color: NSColor) {
        let text = attributedTitle.mutableCopy() as! NSMutableAttributedString
        let range = NSMakeRange(0, text.length) // -[NSAttributedString(N2) range]

        text.addAttribute(.foregroundColor, value: color, range: range)
        text.fixAttributes(in: range)
        attributedTitle = text

        needsDisplay = true
    }
}
