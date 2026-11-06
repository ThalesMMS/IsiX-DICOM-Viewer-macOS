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

// The 2D segment arithmetic of the viewers (ROI selection, measurements). As
// in PlaneGeometry, the fused multiply-adds clang made of the Objective-C
// expressions are written out, so that the results are the same bits.
public enum LineGeometry {

    /// The length of the segment `p1`–`p2`, in single precision.
    public static func magnitude(_ p1: CGPoint, _ p2: CGPoint) -> Float {
        let vx = p2.x - p1.x, vy = p2.y - p1.y
        return Float((vy * vy).addingProduct(vx, vx).squareRoot())
    }

    /// Where the segments `a1`–`a2` and `b1`–`b2` cross, or nil when they do
    /// not (parallel, or crossing outside one of them). The computation is in
    /// single precision.
    public static func intersection(a1: CGPoint, a2: CGPoint, b1: CGPoint, b2: CGPoint) -> CGPoint? {
        let x1 = Float(a1.x), y1 = Float(a1.y)
        let x2 = Float(a2.x), y2 = Float(a2.y)
        let x3 = Float(b1.x), y3 = Float(b1.y)
        let x4 = Float(b2.x), y4 = Float(b2.y)

        let d = (-((y1 - y2) * (x3 - x4))).addingProduct(x1 - x2, y3 - y4)
        if d == 0 { return nil }

        // x1*y2 - y1*x2 and x3*y4 - y3*x4, computed again for yi as they were.
        let crossA = (-(y1 * x2)).addingProduct(x1, y2)
        let crossB = (-(y3 * x4)).addingProduct(x3, y4)
        let xi = (-((x1 - x2) * crossB)).addingProduct(x3 - x4, crossA) / d
        let crossA2 = (-(y1 * x2)).addingProduct(x1, y2)
        let crossB2 = (-(y3 * x4)).addingProduct(x3, y4)
        let yi = (-((y1 - y2) * crossB2)).addingProduct(y3 - y4, crossA2) / d

        let mag1 = magnitude(a1, a2)
        var u1 = ((yi - y1) * (y2 - y1)).addingProduct(xi - x1, x2 - x1)
        u1 /= mag1 * mag1

        let mag2 = magnitude(b1, b2)
        var u2 = ((yi - y3) * (y4 - y3)).addingProduct(xi - x3, x4 - x3)
        u2 /= mag2 * mag2

        if u1 >= 0 && u1 <= 1 && u2 >= 0 && u2 <= 1 {
            return CGPoint(x: CGFloat(xi), y: CGFloat(yi))
        }
        return nil
    }

    /// The distance from `point` to the line through `start` and `end` (not
    /// the segment: the foot of the perpendicular may lie outside it).
    public static func distance(from point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> Float {
        let lineMag = magnitude(end, start)
        var u = Float(((point.y - start.y) * (end.y - start.y)).addingProduct(point.x - start.x, end.x - start.x))
        u /= lineMag * lineMag
        let foot = CGPoint(x: start.x.addingProduct(CGFloat(u), end.x - start.x),
                           y: start.y.addingProduct(CGFloat(u), end.y - start.y))
        return magnitude(point, foot)
    }

    /// Whether the segment from `start` to `end` touches `rect`: by halving
    /// it until a half lies in the rectangle or misses its bounding box.
    public static func segment(from start: CGPoint, to end: CGPoint, intersects rect: CGRect) -> Bool {
        if NSPointInRect(start, rect) || NSPointInRect(end, rect) { return true }
        if rect.size.width == 0 || rect.size.height == 0 { return false }

        let width = abs(start.x - end.x)
        let height = abs(start.y - end.y)
        // The corner went through a single precision min().
        let box = CGRect(x: CGFloat(min(Float(start.x), Float(end.x))), y: CGFloat(min(Float(start.y), Float(end.y))),
                         width: width, height: height)

        if NSIsEmptyRect(box) {
            if distance(start, end) <= 1 { return false }
            // Vertical or horizontal.
            let mid = CGPoint(x: (start.x + end.x) / 2.0, y: (start.y + end.y) / 2.0)
            return segment(from: start, to: mid, intersects: rect) || segment(from: mid, to: end, intersects: rect)
        } else if NSIntersectsRect(box, rect) {
            let mid = CGPoint(x: box.origin.x.addingProduct(box.size.width, 0.5),
                              y: box.origin.y.addingProduct(box.size.height, 0.5))
            return segment(from: start, to: mid, intersects: rect) || segment(from: mid, to: end, intersects: rect)
        }
        return false
    }

    /// The distance between two points, in single precision.
    static func distance(_ p1: CGPoint, _ p2: CGPoint) -> Float {
        let dx = Float(p1.x - p2.x), dy = Float(p1.y - p2.y)
        return Float(Double((dy * dy).addingProduct(dx, dx)).squareRoot())
    }
}
