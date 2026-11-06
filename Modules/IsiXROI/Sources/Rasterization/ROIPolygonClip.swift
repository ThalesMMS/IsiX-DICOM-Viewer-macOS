/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

/// A polygon cut to a rectangle of the image, one side after the other (left,
/// right, top, bottom), as DCMPix clipped a ROI that leaves the image before
/// filling it. The new vertices on a vertical side are found with the slope in
/// `float` and a fused multiply-add, those on a horizontal side by dividing by
/// it, and both truncated to `long`: the C did so, and the vertices decide
/// which pixels the scanline fill reaches.
public enum ROIPolygonClip {
    /// `polygon` clipped to the pixels from `min` to `max` (exclusive).
    public static func clip(_ polygon: [ROIPixelPoint], min: CGPoint, max: CGPoint) -> [ROIPixelPoint] {
        let upLeft = ROIPixelPoint(x: ROIRasterConversion.long(Double(min.x)), y: ROIRasterConversion.long(Double(min.y)))
        let downRight = ROIPixelPoint(x: ROIRasterConversion.long(Double(max.x) - 1), y: ROIRasterConversion.long(Double(max.y) - 1))

        var left: [ROIPixelPoint] = []
        left.reserveCapacity(polygon.count * 2)
        for v in polygon.indices {
            clipLeft(&left, polygon[v], polygon[v + 1 == polygon.count ? 0 : v + 1], upLeft)
        }
        var right: [ROIPixelPoint] = []
        right.reserveCapacity(left.count * 2)
        for v in left.indices {
            clipRight(&right, left[v], left[v + 1 == left.count ? 0 : v + 1], downRight)
        }
        var top: [ROIPixelPoint] = []
        top.reserveCapacity(right.count * 2)
        for v in right.indices {
            clipTop(&top, right[v], right[v + 1 == right.count ? 0 : v + 1], upLeft)
        }
        var bottom: [ROIPixelPoint] = []
        bottom.reserveCapacity(top.count * 2)
        for v in top.indices {
            clipBottom(&bottom, top[v], top[v + 1 == top.count ? 0 : v + 1], downRight)
        }
        return bottom
    }

    /// The slope of an edge, `dy / dx` in `float` (1 for a vertical edge).
    @inline(__always)
    private static func slope(_ v1: ROIPixelPoint, _ v2: ROIPixelPoint) -> (dx: Float, m: Float) {
        let dx = Float(v2.x &- v1.x), dy = Float(v2.y &- v1.y)
        return (dx, dx != 0 ? dy / dx : 1)
    }

    /// The `y` where the edge from `v1` meets the vertical line at `x`.
    @inline(__always)
    private static func yAt(_ x: Int, _ v1: ROIPixelPoint, _ m: Float) -> Int {
        ROIRasterConversion.long(Float(v1.y).addingProduct(m, Float(x &- v1.x)))
    }

    /// The `x` where the edge from `v1` meets the horizontal line at `y`.
    @inline(__always)
    private static func xAt(_ y: Int, _ v1: ROIPixelPoint, _ dx: Float, _ m: Float) -> Int {
        dx != 0 ? ROIRasterConversion.long(Float(v1.x) + Float(y &- v1.y) / m) : v1.x
    }

    private static func clipLeft(_ out: inout [ROIPixelPoint], _ v1: ROIPixelPoint, _ v2: ROIPixelPoint, _ upLeft: ROIPixelPoint) {
        let (_, m) = slope(v1, v2)
        if v1.x >= upLeft.x && v2.x >= upLeft.x { out.append(v2) }
        if v1.x >= upLeft.x && v2.x < upLeft.x { out.append(ROIPixelPoint(x: upLeft.x, y: yAt(upLeft.x, v1, m))) }
        if v1.x < upLeft.x && v2.x >= upLeft.x {
            out.append(ROIPixelPoint(x: upLeft.x, y: yAt(upLeft.x, v1, m)))
            out.append(v2)
        }
    }

    private static func clipRight(_ out: inout [ROIPixelPoint], _ v1: ROIPixelPoint, _ v2: ROIPixelPoint, _ downRight: ROIPixelPoint) {
        let (_, m) = slope(v1, v2)
        if v1.x <= downRight.x && v2.x <= downRight.x { out.append(v2) }
        if v1.x <= downRight.x && v2.x > downRight.x { out.append(ROIPixelPoint(x: downRight.x, y: yAt(downRight.x, v1, m))) }
        if v1.x > downRight.x && v2.x <= downRight.x {
            out.append(ROIPixelPoint(x: downRight.x, y: yAt(downRight.x, v1, m)))
            out.append(v2)
        }
    }

    private static func clipTop(_ out: inout [ROIPixelPoint], _ v1: ROIPixelPoint, _ v2: ROIPixelPoint, _ upLeft: ROIPixelPoint) {
        let (dx, m) = slope(v1, v2)
        if v1.y >= upLeft.y && v2.y >= upLeft.y { out.append(v2) }
        if v1.y >= upLeft.y && v2.y < upLeft.y { out.append(ROIPixelPoint(x: xAt(upLeft.y, v1, dx, m), y: upLeft.y)) }
        if v1.y < upLeft.y && v2.y >= upLeft.y {
            out.append(ROIPixelPoint(x: xAt(upLeft.y, v1, dx, m), y: upLeft.y))
            out.append(v2)
        }
    }

    private static func clipBottom(_ out: inout [ROIPixelPoint], _ v1: ROIPixelPoint, _ v2: ROIPixelPoint, _ downRight: ROIPixelPoint) {
        let (dx, m) = slope(v1, v2)
        if v1.y <= downRight.y && v2.y <= downRight.y { out.append(v2) }
        if v1.y <= downRight.y && v2.y > downRight.y { out.append(ROIPixelPoint(x: xAt(downRight.y, v1, dx, m), y: downRight.y)) }
        if v1.y > downRight.y && v2.y <= downRight.y {
            out.append(ROIPixelPoint(x: xAt(downRight.y, v1, dx, m), y: downRight.y))
            out.append(v2)
        }
    }
}
