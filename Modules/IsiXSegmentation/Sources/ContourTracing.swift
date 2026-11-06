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

// How the outline VTK traces around a mask becomes the points of a ROI: in
// which order its points make a polygon, how many are kept, and the empty
// border a grown region's slice gets first so that its outline closes. VTK's
// tracing is the app's adapter.

public enum ContourTracing {

    /// The order in which the points of an outline of `lineCount` lines make
    /// a polygon: the even indices up, then the odd ones down. VTK's
    /// connectivity filter leaves the outline's points alternating between its
    /// two halves.
    public static func pointOrder(lineCount: Int) -> [Int] {
        var order: [Int] = []
        guard lineCount > 0 else { return order }
        order.reserveCapacity(lineCount)
        var index = 0
        while index < lineCount {
            order.append(index)
            index += 2
        }
        index -= 1
        if index >= lineCount { index -= 2 }
        while index >= 0 {
            order.append(index)
            index -= 2
        }
        return order
    }

    /// Whether an outline of `lineCount` lines makes a ROI: more than three.
    public static func makesPolygon(lineCount: Int) -> Bool {
        lineCount > 3
    }

    /// One point in how many is kept so that an outline of `pointCount`
    /// points has about `numPoints`, at least `resolution`: the count divided
    /// by `numPoints` (as an arm64 integer division, 0 for a division by 0),
    /// plus 1, when the count is above it.
    public static func resolution(pointCount: Int, numPoints: Int, resolution: Int = 1) -> Int {
        guard pointCount > numPoints, pointCount >= 0 else { return resolution }
        let quotient = numPoints == 0 ? 0 : pointCount / numPoints
        let candidate = quotient &+ 1
        return candidate > resolution ? candidate : resolution
    }

    /// The indices of the points kept of `count` when one in `resolution` is:
    /// from the last point down, the `resolution - 1` points at and below each
    /// kept place are dropped, never leaving fewer than three. A resolution
    /// of 1 or less keeps them all.
    public static func keptIndices(count: Int, resolution: Int) -> [Int] {
        var kept = Array(0 ..< max(count, 0))
        guard resolution > 1, count > 0 else { return kept }
        var index = count - 1
        while index >= 0 {
            for offset in 0 ..< resolution - 1 where kept.count > 3 && index - offset >= 0 {
                kept.remove(at: index - offset)
            }
            index -= resolution
        }
        return kept
    }

    /// Clears the first and last row and column of the `width` x `height`
    /// bytes at `mask`, so that a region touching the image's edge still has
    /// a closed outline.
    public static func clearBorder(_ mask: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        for x in 0 ..< width {
            mask[x] = 0
            mask[width * (height - 1) + x] = 0
        }
        for y in 0 ..< height {
            mask[y * width] = 0
            mask[y * width + width - 1] = 0
        }
    }
}
