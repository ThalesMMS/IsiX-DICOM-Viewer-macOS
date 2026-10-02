//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// Where the square magnifier of a 2D view goes and what its pixels look like.
/// The view decides when it shows and renders the picture under the pointer;
/// nothing here touches a view, so it can be checked on its own.
@objc(HorosMagnifierPresentation)
public final class MagnifierPresentation: NSObject {

    /// The default that moves the magnifier from the pointer to the view's
    /// lower right corner.
    @objc public static let cornerDefaultsKey = "magnifyingLensInCorner"

    /// The magnifier's side in view points, before the view's own size factor.
    @objc public static let side: CGFloat = 240

    private static let margin: CGFloat = 12
    private static let smallestSide: CGFloat = 60

    /// The magnifier's square in the coordinates of `bounds`, or a zero
    /// rectangle when the view is too small to spare the room.
    ///
    /// Centred, it follows the pointer. In the corner it sits at the lower
    /// right and steps to the lower left while the pointer is close enough to
    /// be covered, so the point being placed is never under its own magnifier.
    @objc(frameInBounds:cursor:side:inCorner:flipped:)
    public static func frame(inBounds bounds: NSRect, cursor: NSPoint, side wanted: CGFloat,
                             inCorner: Bool, flipped: Bool) -> NSRect {
        let side = floor(min(wanted, min(bounds.width, bounds.height) * 0.5))
        guard side >= smallestSide else { return .zero }
        if !inCorner {
            return NSRect(x: cursor.x - side / 2, y: cursor.y - side / 2, width: side, height: side)
        }
        let y = flipped ? bounds.maxY - margin - side : bounds.minY + margin
        let right = NSRect(x: bounds.maxX - margin - side, y: y, width: side, height: side)
        if right.insetBy(dx: -side / 4, dy: -side / 4).contains(cursor) {
            let left = NSRect(x: bounds.minX + margin, y: y, width: side, height: side)
            if !left.contains(cursor) { return left }
            return right.contains(cursor) ? .zero : right
        }
        return right
    }

    /// The magnifier's picture: `bgra`, `side` x `side` pixels, as opaque ARGB
    /// with a frame around it and a sight at its centre. The sight leaves the
    /// centre itself open, so the pixel being pointed at stays visible.
    ///
    /// `segments` are the ROI lines that cross the magnified area, each as
    /// x0, y0, x1, y1, red, green, blue, width in the picture's own pixels.
    /// They go over the sight: the line being measured is what is being aimed.
    @objc(squareARGBFromBGRA:side:scale:segments:)
    public static func squareARGB(fromBGRA bgra: Data, side: Int, scale: Int, segments: [[NSNumber]]) -> NSMutableData? {
        guard side > 0, scale > 0, bgra.count >= side * side * 4,
              let argb = NSMutableData(length: side * side * 4) else { return nil }
        let pixels = argb.mutableBytes.assumingMemoryBound(to: UInt8.self)
        bgra.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for i in 0..<(side * side) {
                pixels[4 * i] = 255
                pixels[4 * i + 1] = source[4 * i + 2]
                pixels[4 * i + 2] = source[4 * i + 1]
                pixels[4 * i + 3] = source[4 * i]
            }
        }

        func paint(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8,
                   inset: Int = 0) {
            let top = max(inset, y), bottom = min(side - inset, y + height)
            let left = max(inset, x), right = min(side - inset, x + width)
            guard top < bottom, left < right else { return }
            for row in top..<bottom {
                for column in left..<right {
                    let p = 4 * (row * side + column)
                    pixels[p + 1] = red; pixels[p + 2] = green; pixels[p + 3] = blue
                }
            }
        }
        func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ grey: UInt8, _ blue: UInt8) {
            paint(x, y, width, height, grey, grey, blue)
        }
        func ring(_ inset: Int, _ width: Int, _ grey: UInt8) {
            let length = side - 2 * inset
            fill(inset, inset, length, width, grey, grey)
            fill(inset, side - inset - width, length, width, grey, grey)
            fill(inset, inset, width, length, grey, grey)
            fill(side - inset - width, inset, width, length, grey, grey)
        }
        // Dark outside, light inside: one of the two shows on any picture.
        ring(0, scale, 0)
        ring(scale, scale, 230)

        // Four arms, yellow on a dark edge, stopping short of the centre.
        let centre = side / 2, gap = 5 * scale, arm = 14 * scale
        if side > 2 * (gap + arm + 2 * scale) {
            for (grow, grey, blue) in [(1, UInt8(0), UInt8(0)), (0, UInt8(255), UInt8(0))] {
                let thick = scale + 2 * grow, near = centre - scale / 2 - grow
                fill(centre - gap - arm - grow, near, arm + 2 * grow, thick, grey, blue)
                fill(centre + gap - grow, near, arm + 2 * grow, thick, grey, blue)
                fill(near, centre - gap - arm - grow, thick, arm + 2 * grow, grey, blue)
                fill(near, centre + gap - grow, thick, arm + 2 * grow, grey, blue)
            }
        }

        // The ROI lines, inside the frame. A vertex can be far outside at this
        // magnification, so each segment is cut to the picture before it is walked.
        let inset = 2 * scale
        for segment in segments where segment.count == 8 {
            let v = segment.map { $0.doubleValue }
            guard v.allSatisfy({ $0.isFinite }) else { continue }
            let width = max(1, Int(v[7].rounded()))
            guard let (a, b) = clip(CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]),
                                    to: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: -CGFloat(width), dy: -CGFloat(width)))
            else { continue }
            let red = UInt8(max(0, min(255, v[4]))), green = UInt8(max(0, min(255, v[5]))), blue = UInt8(max(0, min(255, v[6])))
            let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) * 2).rounded(.up)))
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let x = Int((a.x + (b.x - a.x) * t - CGFloat(width) / 2).rounded())
                let y = Int((a.y + (b.y - a.y) * t - CGFloat(width) / 2).rounded())
                paint(x, y, width, width, red, green, blue, inset: inset)
            }
        }
        return argb
    }

    /// The part of the segment from `a` to `b` inside `rect`, if any.
    static func clip(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else if p < 0 {
                t0 = max(t0, q / p)
            } else {
                t1 = min(t1, q / p)
            }
            if t0 > t1 { return nil }
        }
        return (CGPoint(x: a.x + dx * t0, y: a.y + dy * t0), CGPoint(x: a.x + dx * t1, y: a.y + dy * t1))
    }

    /// One step of the magnifier's zoom factor, as the lens counts it: 4 shows
    /// the picture at twice the view's scale and 2.2, the closest, at twenty times.
    @objc(zoomFactor:steppedIn:)
    public static func zoomFactor(_ factor: Float, steppedIn closer: Bool) -> Float {
        let current = min(4, max(2.2, factor))
        return closer ? max(2.2, current - 0.2) : min(4, current + 0.2)
    }

    /// One step of the size factor, kept where the magnifier still fits a view.
    @objc(sizeFactor:steppedUp:)
    public static func sizeFactor(_ factor: Float, steppedUp larger: Bool) -> Float {
        min(3, max(0.5, larger ? factor * 1.25 : factor / 1.25))
    }
}
