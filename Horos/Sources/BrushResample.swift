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

import Foundation
import simd

/// Brush masks carried from one stack of slices to another of the same volume,
/// in patient coordinates.
///
/// A brush ROI is a texture of one slice: pixels in or out, at an offset in
/// the slice's pixel grid. The 2D viewer's reslice replaces the slices by
/// others, cut along another axis and then flipped or rotated; each pixel of
/// the new slices takes the mask value of the voxel of the old stack that
/// holds its centre (nearest neighbour, so a mask stays a mask and two masks
/// never blend). Positions follow DCMPix with integer pixel indices:
/// origin + x · spacingX · row + y · spacingY · column.
///
/// Nothing here infers geometry from dimensions: two stacks with the same
/// sizes but another orientation, order or origin give other pixels.
enum BrushResample {

    /// One slice's grid.
    struct Slice: Equatable, Sendable {
        var origin: SIMD3<Double>
        /// Unit vectors of increasing x and increasing y.
        var row: SIMD3<Double>
        var column: SIMD3<Double>
        var spacingX: Double
        var spacingY: Double
        var width: Int
        var height: Int

        func position(x: Double, y: Double) -> SIMD3<Double> {
            origin + (x * spacingX) * row + (y * spacingY) * column
        }

        var normal: SIMD3<Double> { simd_normalize(simd_cross(row, column)) }

        /// Fractional pixel coordinates of a position in this slice's plane,
        /// and its signed distance to the plane.
        func pixel(of p: SIMD3<Double>) -> (x: Double, y: Double, distance: Double) {
            let d = p - origin
            return (simd_dot(d, row) / spacingX, simd_dot(d, column) / spacingY, simd_dot(d, normal))
        }
    }

    /// A mask on one slice: a rectangle of bytes at (x, y), nonzero inside.
    struct Plane: Equatable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var bytes: [UInt8]

        func contains(_ px: Int, _ py: Int) -> Bool {
            let u = px - x, v = py - y
            guard u >= 0, v >= 0, u < width, v < height else { return false }
            return bytes[v * width + u] != 0
        }

        var isEmpty: Bool { !bytes.contains { $0 != 0 } }

        /// The same pixels in the smallest rectangle; nil when none is in.
        func trimmed() -> Plane? {
            var minU = width, maxU = -1, minV = height, maxV = -1
            for v in 0..<height {
                for u in 0..<width where bytes[v * width + u] != 0 {
                    minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
                }
            }
            guard maxU >= 0 else { return nil }
            let w = maxU - minU + 1, h = maxV - minV + 1
            var out = [UInt8](repeating: 0, count: w * h)
            for v in 0..<h {
                for u in 0..<w { out[v * w + u] = bytes[(v + minV) * width + u + minU] != 0 ? 255 : 0 }
            }
            return Plane(x: x + minU, y: y + minV, width: w, height: h, bytes: out)
        }
    }

    /// The stack a mask comes from: its slices, located along their normal
    /// whatever order the list has them in.
    struct Stack: Sendable {
        let slices: [Slice]
        let normal: SIMD3<Double>
        /// Slice indices by increasing depth along `normal`, and their depths.
        let order: [Int]
        let depths: [Double]
        /// Half the smallest gap between neighbouring slices: a position
        /// farther than this from every slice is outside the stack.
        let halfGap: Double
        /// The distance between slices when they are evenly spaced.
        let step: Double?
        /// When every slice has the first one's row, column and spacing, as
        /// in a reslice's stack: where each slice's grid sits in the first
        /// one's, so a row of target pixels maps with additions only.
        let offsets: [SIMD2<Double>]?

        init?(_ slices: [Slice]) {
            guard let first = slices.first else { return nil }
            let normal = first.normal
            guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { return nil }
            // The slices of a stack are parallel; a reslice needs a volume.
            for s in slices where abs(simd_dot(s.normal, normal)) < 0.999 { return nil }
            let depth = slices.map { simd_dot($0.origin - first.origin, normal) }
            let order = depth.indices.sorted { depth[$0] < depth[$1] }
            let sorted = order.map { depth[$0] }
            var gap = Double.infinity
            for k in sorted.indices.dropFirst() where sorted[k] - sorted[k - 1] > 1e-6 { gap = min(gap, sorted[k] - sorted[k - 1]) }
            if !gap.isFinite { gap = min(first.spacingX, first.spacingY) }
            self.slices = slices
            self.normal = normal
            self.order = order
            self.depths = sorted
            self.halfGap = gap / 2
            let span = (sorted.last ?? 0) - (sorted.first ?? 0)
            let even = sorted.count > 1 && sorted.indices.dropFirst().allSatisfy {
                abs(sorted[$0] - sorted[$0 - 1] - span / Double(sorted.count - 1)) <= 1e-4 * gap
            }
            self.step = even ? span / Double(sorted.count - 1) : nil
            let uniform = slices.allSatisfy {
                simd_distance($0.row, first.row) < 1e-9 && simd_distance($0.column, first.column) < 1e-9 &&
                    $0.spacingX == first.spacingX && $0.spacingY == first.spacingY
            }
            self.offsets = uniform ? slices.map {
                SIMD2(simd_dot($0.origin - first.origin, first.row) / first.spacingX,
                      simd_dot($0.origin - first.origin, first.column) / first.spacingY)
            } : nil
        }

        /// The slice at a depth along `normal`, or nil between or beyond them.
        func slice(atDepth depth: Double) -> Int? {
            var k: Int
            if let step {
                k = min(max(Int(((depth - depths[0]) / step).rounded()), 0), depths.count - 1)
            } else {
                var low = 0, high = depths.count - 1
                while low < high {
                    let mid = (low + high) / 2
                    if depths[mid] < depth { low = mid + 1 } else { high = mid }
                }
                k = low
                if k > 0 && abs(depths[k - 1] - depth) <= abs(depths[k] - depth) { k -= 1 }
            }
            guard abs(depths[k] - depth) <= halfGap + 1e-6 else { return nil }
            return order[k]
        }

        /// The voxel holding a position: its slice and pixel, or nil outside.
        func voxel(at p: SIMD3<Double>) -> (slice: Int, x: Int, y: Int)? {
            guard let index = slice(atDepth: simd_dot(p - slices[0].origin, normal)) else { return nil }
            let slice = slices[index]
            let pixel = slice.pixel(of: p)
            let x = Int(pixel.x.rounded()), y = Int(pixel.y.rounded())
            guard x >= 0, y >= 0, x < slice.width, y < slice.height else { return nil }
            return (index, x, y)
        }
    }

    /// `planes[i]` is the mask on slice i of the source stack, nil where it
    /// has none. Returns the mask on each target slice, nil where it has none.
    static func resample(_ planes: [Plane?], from source: Stack, to target: [Slice]) -> [Plane?] {
        var result = [Plane?](repeating: nil, count: target.count)
        // The mask's box in the source: its slices and pixel range.
        var kRange: ClosedRange<Int>? = nil
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for (k, index) in source.order.enumerated() {
            guard index < planes.count, let plane = planes[index], !plane.isEmpty else { continue }
            kRange = kRange.map { min($0.lowerBound, k)...max($0.upperBound, k) } ?? k...k
            minX = min(minX, plane.x); maxX = max(maxX, plane.x + plane.width - 1)
            minY = min(minY, plane.y); maxY = max(maxY, plane.y + plane.height - 1)
        }
        guard let kRange else { return result }
        let lookup = Lookup(planes)

        // Its corners in patient space, a half voxel out on every side.
        var corners: [SIMD3<Double>] = []
        for (k, side) in [(kRange.lowerBound, -1.0), (kRange.upperBound, 1.0)] {
            let slice = source.slices[source.order[k]]
            let out = (side * source.halfGap) * source.normal
            for x in [Double(minX) - 0.5, Double(maxX) + 0.5] {
                for y in [Double(minY) - 0.5, Double(maxY) + 0.5] { corners.append(slice.position(x: x, y: y) + out) }
            }
        }

        for (t, slice) in target.enumerated() {
            let projected = corners.map { slice.pixel(of: $0) }
            if projected.allSatisfy({ $0.distance > 1e-6 }) || projected.allSatisfy({ $0.distance < -1e-6 }) { continue }
            let x0 = max(0, Int(projected.map(\.x).min()!.rounded(.down)))
            let x1 = min(slice.width - 1, Int(projected.map(\.x).max()!.rounded(.up)))
            let y0 = max(0, Int(projected.map(\.y).min()!.rounded(.down)))
            let y1 = min(slice.height - 1, Int(projected.map(\.y).max()!.rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            var bytes = [UInt8](repeating: 0, count: w * h)
            var any = false
            if let offsets = source.offsets {
                // Along a row of the target, depth and source pixel move by
                // the same amounts at every step.
                let first = source.slices[0]
                let stride = slice.row * slice.spacingX
                let dDepth = simd_dot(stride, source.normal)
                let dX = simd_dot(stride, first.row) / first.spacingX, dY = simd_dot(stride, first.column) / first.spacingY
                for v in 0..<h {
                    let p = slice.position(x: Double(x0), y: Double(y0 + v)) - first.origin
                    let depth = simd_dot(p, source.normal)
                    let sx = simd_dot(p, first.row) / first.spacingX, sy = simd_dot(p, first.column) / first.spacingY
                    for u in 0..<w {
                        let step = Double(u)
                        guard let index = source.slice(atDepth: depth + step * dDepth), index < lookup.count,
                              lookup[index].width > 0 else { continue }
                        let x = Int((sx + step * dX - offsets[index].x).rounded())
                        let y = Int((sy + step * dY - offsets[index].y).rounded())
                        if lookup.contains(index, x, y) { bytes[v * w + u] = 255; any = true }
                    }
                }
            } else {
                for v in 0..<h {
                    for u in 0..<w {
                        let p = slice.position(x: Double(x0 + u), y: Double(y0 + v))
                        guard let voxel = source.voxel(at: p), lookup.contains(voxel.slice, voxel.x, voxel.y) else { continue }
                        bytes[v * w + u] = 255
                        any = true
                    }
                }
            }
            if any { result[t] = Plane(x: x0, y: y0, width: w, height: h, bytes: bytes).trimmed() }
        }
        return result
    }

    /// The planes of a mask in flat arrays, read once per target pixel.
    private struct Lookup {
        var x: [Int] = [], y: [Int] = [], width: [Int] = [], height: [Int] = [], start: [Int] = []
        var bytes: [UInt8] = []

        init(_ planes: [Plane?]) {
            for plane in planes {
                x.append(plane?.x ?? 0); y.append(plane?.y ?? 0)
                width.append(plane?.width ?? 0); height.append(plane?.height ?? 0)
                start.append(bytes.count)
                if let plane { bytes.append(contentsOf: plane.bytes) }
            }
        }

        var count: Int { width.count }
        subscript(index: Int) -> (width: Int, height: Int) { (width[index], height[index]) }

        func contains(_ index: Int, _ px: Int, _ py: Int) -> Bool {
            guard index < width.count else { return false }
            let u = px - x[index], v = py - y[index]
            guard u >= 0, v >= 0, u < width[index], v < height[index] else { return false }
            return bytes[start[index] + v * width[index] + u] != 0
        }
    }
}
