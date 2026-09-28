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

// SelectionView is implemented in Swift since #714. The Objective-C name and
// <Horos/SelectionView.h> are those of the former class.

@objc(SelectionView)
public final class SelectionView: NSView {

    public override init(frame: NSRect) {
        super.init(frame: frame)
        _ = acceptsFirstMouse(for: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func draw(_ aRect: NSRect) {
        // The selection frame follows the view, not the area needing redraw: a
        // partial redraw drew it in the wrong place, and since macOS 14 NSView no
        // longer clips drawing to its bounds, an oversized one drew it outside.
        let aRect = bounds
        let insideRect = NSRect(x: aRect.origin.x + 1, y: aRect.origin.y + 1, width: aRect.size.width - 2, height: aRect.size.height - 2)
        let outsidePath = NSBezierPath(rect: aRect)
        let insidePath = NSBezierPath(rect: insideRect)

        outsidePath.lineWidth = 2.0

        NSColor.black.set()
        insidePath.stroke()

        NSColor.selectedTextBackgroundColor.set()
        outsidePath.stroke()
    }

    public override func isMousePoint(_ aPoint: NSPoint, in aRect: NSRect) -> Bool {
        false
    }

    public override var acceptsFirstResponder: Bool {
        false
    }
}
