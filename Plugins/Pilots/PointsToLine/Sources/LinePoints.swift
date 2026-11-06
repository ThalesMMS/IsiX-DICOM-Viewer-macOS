//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import IsiXPluginKit

/// The points of a straight line between two points of a volume, one per
/// millimetre, each put on the slice whose plane is nearest to it.
enum LinePoints {
    struct Placement: Sendable, Equatable {
        /// The point on the line, in patient coordinates.
        var target: IsiXVector3
        var slice: Int
        /// Where the point falls on that slice: the projection of `target` on its plane.
        var pixel: IsiXPixelPoint
        /// Signed distance from `target` to the slice's plane, in millimetres.
        var distanceFromPlane: Double
    }

    /// The points 1, 2, ... ⌊|end - start|⌋ mm from `start` towards `end`,
    /// placed on the slices of `geometries` (one per slice, in order): the
    /// slice whose plane is nearest, at the projection of the point on it.
    /// Works for any orientation, also for slices that are not parallel.
    static func placements(from start: IsiXVector3, to end: IsiXVector3,
                           geometries: [IsiXImageGeometry]) -> [Placement] {
        let span = end - start
        let length = span.length
        guard length >= 1, !geometries.isEmpty else { return [] }
        let step = span * (1 / length)
        var result: [Placement] = []
        for millimetre in 1...Int(length.rounded(.down)) {
            let target = start + step * Double(millimetre)
            var best = 0
            var bestDistance = Double.infinity
            for (slice, geometry) in geometries.enumerated() {
                let distance = geometry.distanceFromPlane(target)
                if abs(distance) < abs(bestDistance) {
                    best = slice
                    bestDistance = distance
                }
            }
            result.append(Placement(target: target, slice: best, pixel: geometries[best].pixelPoint(of: target),
                                    distanceFromPlane: bestDistance))
        }
        return result
    }
}
