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

/// The segment and polygon tests the ROI selector asks. The view's own
/// geometry answers them, so that a ROI is touched exactly where the view
/// draws it; this module does not depend on it.
public protocol ROISelectorGeometry {
    /// Whether the segment from `start` to `end` touches `rect`.
    func segment(from start: CGPoint, to end: CGPoint, intersects rect: CGRect) -> Bool
    /// Whether `point` is inside the closed `polygon`.
    func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool
    /// Whether the segments `a1`–`a2` and `b1`–`b2` cross.
    func segment(_ a1: CGPoint, _ a2: CGPoint, crosses b1: CGPoint, _ b2: CGPoint) -> Bool
}

/// The region the ROI selector drags over the image, in the image's pixels,
/// and which ROIs it touches. Over an image that is not rotated it is a
/// rectangle; over a rotated one, the four corners of the dragged rectangle
/// taken into the image, a quadrilateral.
public struct ROISelectorRegion: Sendable, Equatable {

    /// The rectangle, or the quadrilateral's four corners in order.
    public enum Area: Sendable, Equatable {
        case rect(CGRect)
        case quad([CGPoint])
    }

    public let area: Area

    public init(area: Area) {
        self.area = area
    }

    /// The rectangle between the two corners of the drag, in the image's
    /// pixels, at least one pixel wide and high. Its corner went through the
    /// single-precision min() of the former DCMView.m.
    public static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        func floatMin(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let a = Float(a), b = Float(b)
            return CGFloat(a < b ? a : b)
        }
        var rect = CGRect(x: floatMin(start.x, end.x), y: floatMin(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y))
        if rect.size.width < 1 { rect.size.width = 1 }
        if rect.size.height < 1 { rect.size.height = 1 }
        return rect
    }

    /// The four corners of the dragged rectangle, in the view's backing
    /// points from its upper left corner, in the order the quadrilateral
    /// takes them, before the view takes each into the image.
    public static func corners(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        [start, CGPoint(x: start.x, y: start.y - (start.y - end.y)),
         end, CGPoint(x: start.x - (start.x - end.x), y: start.y)]
    }

    /// A ROI, as the selector tests it.
    public enum Shape: Sendable, Equatable {
        /// A text: its rectangle as the ROI keeps it, centred on its origin
        /// and sized in view points, at the view's scale.
        case text(CGRect, scale: Float)
        /// A rectangle ROI over an image that is not rotated.
        case rectangle(CGRect)
        /// A 2D point.
        case point(CGPoint)
        /// Any other ROI, by the points of its spline; `closed` when the
        /// last point joins the first.
        case contour([CGPoint], closed: Bool)
    }

    /// The kind of shape a ROI of `type` (ToolMode's value) is tested as:
    /// a rectangle ROI is a contour over a rotated image.
    public enum ShapeKind: Sendable, Equatable {
        case text, rectangle, point, contour
    }

    // ToolMode's values the selector tells apart.
    static let length: Int16 = 5, rectangleROI: Int16 = 6, openPolygon: Int16 = 10, angle: Int16 = 12
    static let textROI: Int16 = 13, arrow: Int16 = 14, point2D: Int16 = 19

    public func shapeKind(type: Int16) -> ShapeKind {
        switch type {
        case Self.textROI: return .text
        case Self.point2D: return .point
        case Self.rectangleROI:
            if case .rect = area { return .rectangle }
            return .contour
        default: return .contour
        }
    }

    /// Whether the last point of a ROI of `type` joins its first: not for a
    /// length, an angle, a 2D point, an open polygon or an arrow.
    public static func isClosed(type: Int16) -> Bool {
        type != length && type != angle && type != point2D && type != openPolygon && type != arrow
    }

    /// The rectangle of a text: `rect` sized at the scale, centred on its origin.
    static func textRect(_ rect: CGRect, scale: Float) -> CGRect {
        let w = Float(rect.size.width / CGFloat(scale))
        let h = Float(rect.size.height / CGFloat(scale))
        let o = rect.origin
        return CGRect(x: o.x - CGFloat(w) / 2.0, y: o.y - CGFloat(h) / 2.0, width: CGFloat(w), height: CGFloat(h))
    }

    /// Whether the region touches the ROI.
    public func touches<G: ROISelectorGeometry>(_ shape: Shape, geometry: G) -> Bool {
        switch area {
        case .rect(let rect): return touches(shape, rect: rect, geometry: geometry)
        case .quad(let quad): return touches(shape, quad: quad, geometry: geometry)
        }
    }

    private func touches<G: ROISelectorGeometry>(_ shape: Shape, rect: CGRect, geometry: G) -> Bool {
        switch shape {
        case .text(let textRect, let scale):
            return NSIntersectsRect(rect, Self.textRect(textRect, scale: scale))
        case .rectangle(let roiRect):
            return NSIntersectsRect(rect, roiRect)
        case .point(let point):
            return NSPointInRect(point, rect)
        case .contour(let points, let closed):
            if points.isEmpty { return false }
            var j = 0
            while j < points.count - 1 {
                if geometry.segment(from: points[j], to: points[j + 1], intersects: rect) { return true }
                j += 1
            }
            // The last segment: between the last point and the first one.
            return closed && geometry.segment(from: points[points.count - 1], to: points[0], intersects: rect)
        }
    }

    private func touches<G: ROISelectorGeometry>(_ shape: Shape, quad: [CGPoint], geometry: G) -> Bool {
        switch shape {
        case .text(let textRect, let scale):
            let r = Self.textRect(textRect, scale: scale)
            return [CGPoint(x: NSMinX(r), y: NSMinY(r)), CGPoint(x: NSMinX(r), y: NSMaxY(r)),
                    CGPoint(x: NSMaxX(r), y: NSMaxY(r)), CGPoint(x: NSMaxX(r), y: NSMinY(r))]
                .contains { geometry.polygon(quad, contains: $0) }
        case .rectangle(let r):
            // Over a rotated image a rectangle ROI is the contour of its corners.
            let corners = [CGPoint(x: NSMinX(r), y: NSMinY(r)), CGPoint(x: NSMinX(r), y: NSMaxY(r)),
                           CGPoint(x: NSMaxX(r), y: NSMaxY(r)), CGPoint(x: NSMaxX(r), y: NSMinY(r))]
            return touches(.contour(corners, closed: true), quad: quad, geometry: geometry)
        case .point(let point):
            return geometry.polygon(quad, contains: point)
        case .contour(let points, let closed):
            if points.contains(where: { geometry.polygon(quad, contains: $0) }) { return true }
            if quad.contains(where: { geometry.polygon(points, contains: $0) }) { return true }
            if points.isEmpty { return false }
            func crossesQuad(_ p1: CGPoint, _ p2: CGPoint) -> Bool {
                geometry.segment(p1, p2, crosses: quad[0], quad[1]) || geometry.segment(p1, p2, crosses: quad[1], quad[2]) ||
                    geometry.segment(p1, p2, crosses: quad[2], quad[3]) || geometry.segment(p1, p2, crosses: quad[3], quad[0])
            }
            var j = 0
            while j < points.count - 1 {
                if crossesQuad(points[j], points[j + 1]) { return true }
                j += 1
            }
            // The last segment: between the last point and the first one.
            return closed && crossesQuad(points[points.count - 1], points[0])
        }
    }
}
