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

/// How a ROI being dragged is held to a shape: an oval to a circle, a
/// rectangle to a square, a length to the horizontal, the vertical or a
/// diagonal. The shapes hold in the patient's millimetres, which is also how
/// the view draws the image: with pixels that are not square, as in a
/// reformatted plane, a circle has fewer pixels across one way than the other.
public enum ROIDragConstraint {
    // NSEvent's modifier flags, by value: this module does not use AppKit.
    static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20

    /// Shift and Option together, and neither Command nor Control, constrain
    /// the drag. Shift alone is the lens and Option alone the window level, so
    /// the pair is the one left for it.
    public static func isConstrained(modifierFlags modifier: UInt32) -> Bool {
        let keys = shift | option | command | control
        return UInt(modifier) & keys == shift | option
    }

    /// How many of a pixel's widths make its height: 1 when either spacing is unknown.
    public static func pixelRatio(spacingX: Double, spacingY: Double) -> Double {
        (spacingX > 0 && spacingY > 0) ? spacingY / spacingX : 1.0
    }

    /// The width, in pixels, of a circle or a square of this height, on the
    /// side the width was dragged to.
    public static func constrainedWidth(_ width: Double, height: Double, ratio: Double) -> Double {
        copysign(abs(height) * ratio, width)
    }

    /// The end of a length whose other end is `first`, on the nearest of 0, 45
    /// and 90 degrees. The limits are tangents: under 0.5 horizontal, under
    /// 1.5 diagonal.
    public static func constrainedLengthEnd(from first: CGPoint, to last: CGPoint, ratio: Double) -> CGPoint {
        var last = last
        let dx = Double(last.x - first.x), dy = Double(last.y - first.y)
        let slope = abs(dy * ratio) / abs(dx)
        if slope < 0.5 {
            last.y = first.y
        } else if slope < 1.5 {
            last.y = first.y + CGFloat(copysign(abs(dx) / ratio, dy))
        } else {
            last.x = first.x
        }
        return last
    }
}
