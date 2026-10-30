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

import CoreGraphics
import Foundation

// The docked series list of the 2D viewer: the thickness its divider snaps
// to, and where the mouse keeps an automatically hidden list shown.

public enum SeriesListDock {
    /// The thickness a dragged divider leaves the list: the list's own
    /// thickness (`stripThickness`) or nothing. A strip across the top or
    /// the bottom snaps at half its thickness; down a side, the vertical
    /// scroller (`scrollerWidth`, 0 for an overlay one) is set aside, the
    /// rest rounded to one strip or none, and a shown strip gets the
    /// scroller and two points back, or one point without a scroller.
    public static func snappedThickness(_ thickness: CGFloat, stripThickness: CGFloat, scrollerWidth: CGFloat, across: Bool) -> CGFloat {
        if across { return thickness > stripThickness / 2 ? stripThickness : 0 }
        let rest = thickness - scrollerWidth
        // roundf of a float, converted to an unsigned integer as arm64 does:
        // below zero or NaN is 0.
        let rounded = roundf(Float(rest / stripThickness))
        var strips: UInt = rounded.isNaN || rounded <= 0 ? 0 : (rounded >= Float(UInt.max) ? UInt.max : UInt(rounded))
        if strips > 1 { strips = 1 }
        var snapped = stripThickness * CGFloat(strips)
        if snapped != 0 { snapped += scrollerWidth != 0 ? scrollerWidth + 2 : 1 }
        return snapped
    }

    /// The mouse is where an automatically hidden list shows: along the
    /// list's edge, `cellWidth` plus 13 points wide, over the split view's
    /// height (20 points less while the list is hidden).
    public static func mouseKeepsListShown(x: CGFloat, y: CGFloat, cellWidth: CGFloat, height: CGFloat, listShown: Bool) -> Bool {
        x >= 0 && x <= cellWidth + 13 && y >= 0 && y <= (listShown ? height : height - 20)
    }
}
