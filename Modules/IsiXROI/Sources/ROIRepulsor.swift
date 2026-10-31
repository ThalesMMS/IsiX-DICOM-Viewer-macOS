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

/// The repulsor: a circle dragged over the image that pushes the points of
/// the ROIs it covers to its edge, and keeps their contours even, removing a
/// neighbour that comes too close and adding one halfway where two are too
/// far apart. The view keeps the ROIs and their points; this says how each
/// ROI's points change under the circle, as the edits the view applies, in
/// order, to the ROI's own points.
public struct ROIRepulsor: Sendable, Equatable {
    /// The centre of the circle, in the image's pixels.
    public var center: CGPoint
    /// Its radius, in pixels.
    public var radius: Int32
    /// The ratio the rows are scaled by (ViewInput's repulsor ratio).
    public var pixelRatio: Float
    /// The view's scale: the spacing kept between the points follows it.
    public var scale: Float

    public init(center: CGPoint, radius: Int32, pixelRatio: Float, scale: Float) {
        self.center = center
        self.radius = radius
        self.pixelRatio = pixelRatio
        self.scale = scale
    }

    /// A change to a ROI's points, applied in order.
    public enum Edit: Sendable, Equatable {
        /// The point at the index moves by (dx, dy).
        case move(Int, dx: Float, dy: Float)
        /// A 2D point moves its rectangle instead.
        case moveRect(dx: Float, dy: Float)
        /// The point at the index goes.
        case remove(Int)
        /// A new point is inserted at the index.
        case insert(CGPoint, at: Int)
        /// A point was pushed, with its neighbours: the ROI is recomputed and
        /// the change announced, once per point pushed.
        case pushed
    }

    // ToolMode's values the repulsor tells apart.
    static let closedPolygon: Int16 = 11, pencil: Int16 = 15, point2D: Int16 = 19
    static let unpushed: Set<Int16> = [26, 12, 14, 27, 29, 20] // axis, angle, arrow, dynamic angle, TAGT, plain

    /// Whether the repulsor pushes a ROI of `type` (ToolMode's value): not an
    /// axis, an angle, an arrow, a dynamic angle, a perpendicular distance or
    /// a brush, and not a locked ROI.
    public static func pushes(type: Int16, locked: Bool) -> Bool {
        !locked && !unpushed.contains(type)
    }

    /// The edits the circle makes to the points of a ROI of `type`.
    public func edits(points original: [CGPoint], type: Int16) -> [Edit] {
        let minD = Float(10.0 / Double(scale))
        let maxD = Float(50.0 / Double(scale))
        let maxN = Float(10.0 * Double(scale))
        let radius = Float(self.radius)
        let area = NSMakeRect(center.x - CGFloat(self.radius), center.y - CGFloat(self.radius),
                              CGFloat(Double(self.radius) * 2.0), CGFloat(Double(self.radius) * 2.0))
        let ratio = CGFloat(pixelRatio)
        let wraps = type == Self.closedPolygon || type == Self.pencil

        var points = original
        var edits: [Edit] = []
        var n: Int32 = 0
        var j: Int32 = 0
        while Int(j) < points.count {
            var pt = points[Int(j)]
            if NSPointInRect(pt, area) {
                let dx = Float(pt.x - center.x)
                let dy = Float((pt.y - center.y) * ratio)
                let d = Float(sqrt(Double(dx * dx + dy * dy)))

                if d < radius {
                    let moveX = dx / d * radius - dx
                    let moveY = dy / d * radius - dy
                    if type == Self.point2D {
                        edits.append(.moveRect(dx: moveX, dy: moveY))
                    } else {
                        edits.append(.move(Int(j), dx: moveX, dy: moveY))
                        points[Int(j)].x += CGFloat(moveX)
                        points[Int(j)].y += CGFloat(moveY)
                    }

                    pt.x += CGFloat(dx / d * radius - dx)
                    pt.y += CGFloat(dy / d * radius - dy)

                    for delta: Int32 in -1...1 {
                        var k = j + delta
                        if wraps {
                            if k == -1 {
                                k = Int32(truncatingIfNeeded: points.count - 1)
                            } else if Int(k) == points.count {
                                k = 0
                            }
                        }

                        if k != j && k >= 0 && Int(k) < points.count {
                            let pt2 = points[Int(k)]
                            let dx = Float(pt2.x - pt.x)
                            let dy = Float((pt2.y - pt.y) * ratio)
                            let d = Float(sqrt(Double(dx * dx + dy * dy)))

                            if d <= minD && d < radius {
                                points.remove(at: Int(k))
                                edits.append(.remove(Int(k)))
                                if delta == -1 { j -= 1 }
                            } else if (d >= maxD || d >= radius) && Float(n) < maxN {
                                let middle = NSPoint(x: (pt2.x + pt.x) / 2.0, y: (pt2.y + pt.y) / 2.0)
                                let index = (delta == -1) ? j : j + 1
                                if delta == -1 { j += 1 }
                                points.insert(middle, at: Int(index))
                                edits.append(.insert(middle, at: Int(index)))
                                n += 1
                            }
                        }
                    }
                    edits.append(.pushed)
                }
            }
            j += 1
        }
        return edits
    }
}
