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

/// The plane geometry of a ROI's points, in image pixels: lengths, angles,
/// areas, perimeters and centroids.
///
/// The arithmetic is the one the ROI drawing and export have always shown, to
/// the bit: `Float` where it was `float`, `Double` where it was `double`, and a
/// fused multiply-add wherever the Objective-C compiler fused `a * b + c` on
/// Apple silicon (`-ffp-contract=on`). Changing any of these changes the last
/// digit of a measurement a user may already have written down.
@objc(IsiXROIPlanarGeometry)
public final class ROIPlanarGeometry: NSObject {
    /// `M_PI / 180.0f`, kept in a `float` as the ROI code always kept it.
    static let degreesToRadians = Float(Double.pi / 180.0)

    // MARK: Points

    /// The point at `ratio` of the way from `a` to `b`.
    @objc(pointBetweenPoint:and:ratio:)
    public static func point(between a: CGPoint, and b: CGPoint, ratio: Float) -> CGPoint {
        let r = Double(ratio)
        return CGPoint(x: (b.x * r).addingProduct(a.x, 1.0 - r),
                       y: (b.y * r).addingProduct(a.y, 1.0 - r))
    }

    /// The distance between two points, in pixels.
    @objc(lengthBetween:and:)
    public static func length(between a: CGPoint, and b: CGPoint) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y
        return Float((dy * dy).addingProduct(dx, dx)).squareRoot()
    }

    /// The projection of `p` on the line through `a` and `b`, not clamped to the segment.
    @objc(segmentDistToPoint:::)
    public static func projection(onSegment a: CGPoint, _ b: CGPoint, of p: CGPoint) -> CGPoint {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let f = Float((d.y * d.y).addingProduct(d.x, d.x))
        let u = Float(((p.y - a.y) * d.y).addingProduct(p.x - a.x, d.x) / Double(f))
        let x = Float(a.x.addingProduct(Double(u), d.x))
        let y = Float(a.y.addingProduct(Double(u), d.y))
        return CGPoint(x: Double(x), y: Double(y))
    }

    /// The point `distance` pixels along the closed outline through `points`.
    public static func position(atDistance distance: Float, along points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        if distance == 0 { return points[0] }
        var i = 0
        var position: Float = 0
        while position < distance && i < points.count - 1 {
            position += length(between: points[i], and: points[i + 1])
            i += 1
        }
        if position < distance {
            position += length(between: points[i], and: points[0])
            i += 1
        }
        let next = i == points.count ? points[0] : points[i]
        let ratio = (position - distance) / length(between: points[i - 1], and: next)
        return point(between: points[i - 1], and: next, ratio: Float(1.0 - Double(ratio)))
    }

    /// `count` points evenly spaced along the closed outline through `points`,
    /// starting at the leftmost one and turning the way the outline turns
    /// there. Empty when there is nothing to resample.
    public static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard !points.isEmpty, count > 0 else { return [] }
        var total: Float = 0
        var i = 0
        while i < points.count - 1 {
            total += length(between: points[i], and: points[i + 1])
            i += 1
        }
        total += length(between: points[i], and: points[0])

        var resampled: [CGPoint] = []
        resampled.reserveCapacity(count)
        for n in 0..<count {
            let s = Float(Int32(truncatingIfNeeded: n)) * total / Float(Int32(truncatingIfNeeded: count))
            resampled.append(position(atDistance: s, along: points))
        }

        var minX = Float(resampled[0].x), minY = Float(resampled[0].y)
        var minXIndex = 0, minYIndex = 0
        for (index, p) in resampled.enumerated() {
            if minX > Float(p.x) { minX = Float(p.x); minXIndex = index }
            if minY > Float(p.y) { minY = Float(p.y); minYIndex = index }
        }
        let distance = minXIndex - minYIndex
        let reverse = abs(distance) > resampled.count / 2 ? distance >= 0 : distance < 0

        var ordered: [CGPoint] = []
        ordered.reserveCapacity(resampled.count)
        var index = minXIndex
        for _ in 0..<resampled.count {
            ordered.append(resampled[index])
            if reverse {
                index -= 1
                if index < 0 { index = resampled.count - 1 }
            } else {
                index += 1
                if index == resampled.count { index = 0 }
            }
        }
        return ordered
    }

    /// The outline of an oval ROI, whose frame keeps its centre and half
    /// sides: `resolution` points around it, starting on the right.
    public static func outline(ofOval frame: CGRect, resolution: Int) -> [CGPoint] {
        (0..<max(resolution, 0)).map { i in
            let angle = Double(Float(Double(i * 2) * Double.pi / Double(resolution)))
            return CGPoint(x: frame.origin.x.addingProduct(frame.size.width, cos(angle)),
                           y: frame.origin.y.addingProduct(frame.size.height, sin(angle)))
        }
    }

    /// The corners of a rectangle ROI, counterclockwise from its origin.
    public static func outline(ofRectangle frame: CGRect) -> [CGPoint] {
        [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY),
         CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.minY)]
    }

    /// `position(atDistance:along:)` for a C array of points.
    @objc(positionAtDistance:alongPoints:count:)
    public static func position(atDistance distance: Float, alongPoints points: UnsafePointer<CGPoint>?, count: Int) -> CGPoint {
        guard let points, count > 0 else { return .zero }
        return position(atDistance: distance, along: Array(UnsafeBufferPointer(start: points, count: count)))
    }

    /// `resample(_:count:)` for C arrays: writes `number` points to `resampled`,
    /// which holds as many; returns how many it wrote (0 or `number`).
    @objc(resamplePoints:count:number:into:)
    public static func resample(_ points: UnsafePointer<CGPoint>?, count: Int, number: Int,
                                into resampled: UnsafeMutablePointer<CGPoint>) -> Int {
        guard let points, count > 0 else { return 0 }
        let result = resample(Array(UnsafeBufferPointer(start: points, count: count)), count: number)
        for (i, p) in result.enumerated() { resampled[i] = p }
        return result.count
    }

    /// `outline(ofOval:resolution:)` into `outline`, which holds `resolution` points.
    @objc(outlineOfOval:resolution:into:)
    public static func outline(ofOval frame: CGRect, resolution: Int, into outline: UnsafeMutablePointer<CGPoint>) {
        for (i, p) in self.outline(ofOval: frame, resolution: resolution).enumerated() { outline[i] = p }
    }

    /// `outline(ofRectangle:)` into `outline`, which holds four points.
    @objc(outlineOfRectangle:into:)
    public static func outline(ofRectangle frame: CGRect, into outline: UnsafeMutablePointer<CGPoint>) {
        for (i, p) in self.outline(ofRectangle: frame).enumerated() { outline[i] = p }
    }

    // MARK: Lengths

    /// The length of a segment: in centimetres when both spacings are known
    /// (and `inPixels` is false), in pixels otherwise.
    @objc(lengthFrom:to:spacingX:spacingY:inPixels:)
    public static func length(from a: CGPoint, to b: CGPoint, spacingX: Double, spacingY: Double, inPixels: Bool) -> Float {
        let calibrated = spacingX != 0 && spacingY != 0 && !inPixels
        var sideA = abs(a.x - b.x)
        var sideB = abs(a.y - b.y)
        if calibrated {
            sideA *= spacingX
            sideB *= spacingY
        }
        var length: Float
        if sideA == 0 { length = Float(sideB) }
        else if sideB == 0 { length = Float(sideA) }
        else { length = Float(sideB / sin(atan(sideB / sideA))) }
        if calibrated { length = Float(Double(length) / 10.0) }
        return length
    }

    /// The length of a line ROI in centimetres (pixels when uncalibrated) and,
    /// in `pixels`, the same length counted in pixels of the horizontal spacing.
    @objc(measureLengthFrom:to:spacingX:spacingY:pixels:)
    public static func measureLength(from a: CGPoint, to b: CGPoint, spacingX: Double, spacingY: Double,
                                     pixels: UnsafeMutablePointer<Float>?) -> Float {
        let value = length(from: a, to: b, spacingX: spacingX, spacingY: spacingY, inPixels: false)
        if let pixels {
            if spacingX != 0 {
                var inPixels = Float(Double(value) * 10.0)
                inPixels = Float(Double(inPixels) / spacingX)
                pixels.pointee = inPixels
            } else {
                pixels.pointee = value
            }
        }
        return value
    }

    /// The length of the outline through `points`, closed back to the first
    /// point when `closed`, in centimetres or pixels as `length(from:to:)`.
    @objc(perimeterOfPoints:count:closed:spacingX:spacingY:)
    public static func perimeter(of points: UnsafePointer<CGPoint>?, count: Int, closed: Bool,
                                 spacingX: Double, spacingY: Double) -> Float {
        guard let points, count > 0 else { return 0 }
        var total: Float = 0
        var i = 0
        while i < count - 1 {
            total += length(from: points[i], to: points[i + 1], spacingX: spacingX, spacingY: spacingY, inPixels: false)
            i += 1
        }
        if closed {
            total += length(from: points[i], to: points[0], spacingX: spacingX, spacingY: spacingY, inPixels: false)
        }
        return total
    }

    /// The length of a path whose points lie on several slices, in millimetres:
    /// `slices` holds each point's slice index, `sliceInterval` their distance.
    @objc(pathLengthOfPoints:slices:count:spacingX:spacingY:sliceInterval:)
    public static func pathLength(of points: UnsafePointer<CGPoint>?, slices: UnsafePointer<Int32>?, count: Int,
                                  spacingX: Double, spacingY: Double, sliceInterval: Double) -> Double {
        guard let points, let slices, count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<count {
            let dx = points[i].x * spacingX - points[i - 1].x * spacingX
            let dy = points[i].y * spacingY - points[i - 1].y * spacingY
            let dz = Double(slices[i]) * sliceInterval - Double(slices[i - 1]) * sliceInterval
            total += ((dy * dy).addingProduct(dx, dx)).addingProduct(dz, dz).squareRoot()
        }
        return total
    }

    // MARK: Angles

    /// The angle at `vertex` between the rays to `a` and `b`, in degrees,
    /// with the pixel spacing applied when both are known.
    @objc(angleAt:from:to:spacingX:spacingY:)
    public static func angle(at vertex: CGPoint, from a: CGPoint, to b: CGPoint, spacingX: Double, spacingY: Double) -> Float {
        var px: Float = 1, py: Float = 1
        if spacingX != 0 && spacingY != 0 {
            px = Float(spacingX)
            py = Float(spacingY)
        }
        let sx = Double(px), sy = Double(py)
        let ax = Float((-(vertex.x * sx)).addingProduct(a.x, sx))
        let ay = Float((-(vertex.y * sy)).addingProduct(a.y, sy))
        let bx = Float((-(vertex.x * sx)).addingProduct(b.x, sx))
        let by = Float((-(vertex.y * sy)).addingProduct(b.y, sy))
        if ax == 0 && ay == 0 { return 0 }
        let dot = (ay * by).addingProduct(ax, bx)
        let lengths = Double((ay * ay).addingProduct(ax, ax)).squareRoot() * Double((by * by).addingProduct(bx, bx)).squareRoot()
        let cosine = Float(Double(dot) / lengths)
        return Float(acos(Double(cosine)) / Double(degreesToRadians))
    }

    /// The signed angle between the line `a1`-`a2` and the line `b1`-`b2`, in degrees.
    @objc(angleBetweenLine::andLine::)
    public static func angle(betweenLine a1: CGPoint, _ a2: CGPoint, andLine b1: CGPoint, _ b2: CGPoint) -> Double {
        let angle1 = atan2(a1.y - a2.y, a1.x - a2.x)
        let angle2 = atan2(b1.y - b2.y, b1.x - b2.x)
        return (angle1 - angle2) * (180.0 / Double.pi)
    }

    /// The acute angle between two lines, in degrees, that the dynamic angle
    /// shows; the pixel spacing is applied when both are known.
    @objc(acuteAngleBetweenLine::andLine::spacingX:spacingY:)
    public static func acuteAngle(betweenLine a1: CGPoint, _ a2: CGPoint, andLine b1: CGPoint, _ b2: CGPoint,
                                  spacingX: Double, spacingY: Double) -> Float {
        var a1 = a1, a2 = a2, b1 = b1, b2 = b2
        if spacingX != 0 && spacingY != 0 {
            a1 = CGPoint(x: a1.x * spacingX, y: a1.y * spacingY)
            a2 = CGPoint(x: a2.x * spacingX, y: a2.y * spacingY)
            b1 = CGPoint(x: b1.x * spacingX, y: b1.y * spacingY)
            b2 = CGPoint(x: b2.x * spacingX, y: b2.y * spacingY)
        }
        var angle = Float(angle(betweenLine: a1, a2, andLine: b1, b2))
        if angle < -180 { angle = -180 - angle }
        else if angle < -90 { angle += 180 }
        else if angle < 0 { angle *= -1 }

        if angle > 270 { angle = 360 - angle }
        else if angle > 180 { angle -= 180 }
        else if angle > 90 { angle = 180 - angle }
        return angle
    }

    // MARK: Distances to a line

    /// The distance between two points, as a `float`.
    @objc(magnitudeFrom:to:)
    public static func magnitude(from a: CGPoint, to b: CGPoint) -> Float {
        let vx = b.x - a.x, vy = b.y - a.y
        return Float((vy * vy).addingProduct(vx, vx).squareRoot())
    }

    /// The projection of `point` on the line through `start` and `end`.
    @objc(projectionOfPoint:onLineFrom:to:)
    public static func projection(of point: CGPoint, onLineFrom start: CGPoint, to end: CGPoint) -> CGPoint {
        let u = parameter(of: point, onLineFrom: start, to: end)
        return CGPoint(x: start.x.addingProduct(Double(u), end.x - start.x),
                       y: start.y.addingProduct(Double(u), end.y - start.y))
    }

    /// The distance from `point` to the segment `start`-`end`, or nil when its
    /// projection falls outside the segment (with a 1 % margin).
    public static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> Float? {
        let u = parameter(of: point, onLineFrom: start, to: end)
        if u < -0.01 || u > 1.01 { return nil }
        let intersection = CGPoint(x: start.x.addingProduct(Double(u), end.x - start.x),
                                   y: start.y.addingProduct(Double(u), end.y - start.y))
        return magnitude(from: point, to: intersection)
    }

    /// `-DistancePointLine::::`: 1 and the distance when `point` projects on
    /// the segment, else 0 and a distance of 100.
    @objc(distanceFromPoint:toSegmentFrom:to:distance:)
    public static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint,
                                distance: UnsafeMutablePointer<Float>) -> Int32 {
        guard let value = self.distance(from: point, toSegmentFrom: start, to: end) else {
            distance.pointee = 100
            return 0
        }
        distance.pointee = value
        return 1
    }

    private static func parameter(of point: CGPoint, onLineFrom start: CGPoint, to end: CGPoint) -> Float {
        let lineMagnitude = magnitude(from: end, to: start)
        var u = Float(((point.y - start.y) * (end.y - start.y)).addingProduct(point.x - start.x, end.x - start.x))
        u /= lineMagnitude * lineMagnitude
        return u
    }

    // MARK: Areas and centroids

    /// The area of the polygon through `points`, in square pixels.
    @objc(areaOfPolygon:count:)
    public static func area(ofPolygon points: UnsafePointer<CGPoint>?, count: Int) -> Float {
        guard let points, count > 0 else { return 0 }
        var area: Float = 0
        for i in 0..<count {
            let j = (i + 1) % count
            let xi = Float(points[i].x), yi = Float(points[i].y)
            let xj = Float(points[j].x), yj = Float(points[j].y)
            area = area.addingProduct(xi, yj)
            area = area.addingProduct(-yi, xj)
        }
        area *= 0.5
        return abs(area)
    }

    /// The area of the ellipse inscribed in a rectangle whose half sides are
    /// `size`, as an oval ROI keeps its frame, in square pixels.
    @objc(areaOfEllipseWithHalfSize:)
    public static func area(ofEllipseWithHalfSize size: CGSize) -> Float {
        Float(abs(Double.pi * size.width * 2.0 * size.height * 2.0) / 4.0)
    }

    /// The number of painted pixels of a brush mask, in square pixels.
    @objc(areaOfMask:count:)
    public static func area(ofMask mask: UnsafePointer<UInt8>?, count: Int) -> Float {
        Float(paintedPixels(of: mask, count: count))
    }

    /// The painted pixels of a brush mask.
    public static func paintedPixels(of mask: UnsafePointer<UInt8>?, count: Int) -> Int {
        guard let mask, count > 0 else { return 0 }
        var painted = 0
        var i = 0
        while i < count {
            if mask[i] != 0 { painted += 1 }
            i += 1
        }
        return painted
    }

    /// The mean of the points, accumulated as the ROI always did it: each
    /// coordinate divided in `float`, summed in `double`.
    @objc(centroidOfPoints:count:)
    public static func centroid(of points: UnsafePointer<CGPoint>?, count: Int) -> CGPoint {
        guard let points, count > 0 else { return .zero }
        let n = Float(count)
        var centroid = CGPoint.zero
        for i in 0..<count {
            centroid.x += Double(Float(points[i].x) / n)
            centroid.y += Double(Float(points[i].y) / n)
        }
        return centroid
    }
}
