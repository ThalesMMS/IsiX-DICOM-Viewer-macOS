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

import Foundation

// The structuring elements of the brush ROI filters (erode, dilate, open,
// close), as vImage's Planar8 erosion and dilation take them: a square of
// side 2 radius + 1 holding a disc. vImage erodes with the disc's bytes set
// and the rest clear, and dilates with the disc clear and the rest set. The
// filtering itself is the app's (ITKBrushROIFilter, with vImage).

public enum MorphologyKernel {

    /// The side of the element of `radius`: 2 radius + 1, in C int arithmetic.
    public static func side(radius: Int32) -> Int32 {
        radius &* 2 &+ 1
    }

    /// The erosion element of side `side`: the disc set (0xFF), the rest clear.
    public static func erosion(side: Int) -> [UInt8] {
        var element = [UInt8](repeating: 0, count: max(side * side, 0))
        drawDisc(&element, side: side, value: 0xFF)
        return element
    }

    /// The dilation element of side `side`: the disc clear, the rest set.
    public static func dilation(side: Int) -> [UInt8] {
        var element = [UInt8](repeating: 0xFF, count: max(side * side, 0))
        drawDisc(&element, side: side, value: 0)
        return element
    }

    /// Writes `value` over the disc of the `side` x `side` element: the
    /// points of the four quadrants closer to the centre than (side - 1) / 2,
    /// squared distances compared in integers. Side 3 (radius 1) is the cross,
    /// the disc of radius 1 in a 3 x 3 window: the rule would keep only the
    /// centre, an element erosion and dilation leave the mask unchanged with.
    public static func drawDisc(_ element: inout [UInt8], side: Int, value: UInt8) {
        guard side > 0, element.count >= side * side else { return }
        if side == 3 {
            for index in [1, 3, 4, 5, 7] { element[index] = value }
            return
        }
        let inner = side - 1
        let squaredRadius = (inner * inner) / 4
        let centre = side / 2
        for x in 0 ..< centre {
            let squaredX = x * x
            for y in 0 ..< centre where squaredX + y * y < squaredRadius {
                element[centre + x + (centre + y) * side] = value
                element[centre - x + (centre + y) * side] = value
                element[centre + x + (centre - y) * side] = value
                element[centre - x + (centre - y) * side] = value
            }
        }
    }
}
