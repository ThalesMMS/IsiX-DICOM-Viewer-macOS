//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import simd

/// Where one image of a series lies in the patient, in DICOM terms.
///
/// The centre of the pixel at column `c`, row `r` is
/// `origin + rowDirection * (c * columnSpacing) + columnDirection * (r * rowSpacing)`:
/// `origin` is Image Position (Patient), the two directions are the six
/// cosines of Image Orientation (Patient), and the centre of the first pixel
/// is (0, 0). The application's ROIs keep pixel centres at half coordinates;
/// the caller adds or removes the half pixel.
public struct ROISlicePlane: Sendable, Equatable {
    public var origin: SIMD3<Double>
    public var rowDirection: SIMD3<Double>
    public var columnDirection: SIMD3<Double>
    /// Millimetres between the centres of adjacent columns (the x pixel spacing).
    public var columnSpacing: Double
    /// Millimetres between the centres of adjacent rows (the y pixel spacing).
    public var rowSpacing: Double

    /// A plane without an orientation lies in the axial plane, as the viewer
    /// draws such an image; a spacing that is zero or not finite is 1 mm, as
    /// the measures between slices take it.
    public init(origin: SIMD3<Double>, rowDirection: SIMD3<Double>, columnDirection: SIMD3<Double>,
                columnSpacing: Double, rowSpacing: Double) {
        self.origin = origin
        let axial = simd_length(rowDirection) == 0 || simd_length(columnDirection) == 0
        self.rowDirection = axial ? SIMD3(1, 0, 0) : rowDirection
        self.columnDirection = axial ? SIMD3(0, 1, 0) : columnDirection
        self.columnSpacing = columnSpacing.isFinite && columnSpacing != 0 ? columnSpacing : 1
        self.rowSpacing = rowSpacing.isFinite && rowSpacing != 0 ? rowSpacing : 1
    }

    /// The unit normal, row direction × column direction; the axial normal
    /// when the two directions are parallel.
    public var normal: SIMD3<Double> {
        let crossed = simd_cross(rowDirection, columnDirection)
        let length = simd_length(crossed)
        return length > 0 && length.isFinite ? crossed / length : SIMD3(0, 0, 1)
    }

    /// The point of the patient at pixel (`column`, `row`) of the plane.
    public func patientPoint(column: Double, row: Double) -> SIMD3<Double> {
        origin + rowDirection * (column * columnSpacing) + columnDirection * (row * rowSpacing)
    }

    /// The pixel position of the projection of `point` on the plane.
    public func pixel(of point: SIMD3<Double>) -> (column: Double, row: Double) {
        let offset = point - origin
        return (simd_dot(offset, rowDirection) / columnSpacing, simd_dot(offset, columnDirection) / rowSpacing)
    }

    /// The signed distance of `point` from the plane, along `normal`, in millimetres.
    public func distance(to point: SIMD3<Double>) -> Double {
        simd_dot(point - origin, normal)
    }
}

/// The points of the straight line between two points of a series, one every
/// millimetre, each put on the image whose plane is nearest to it. The planes
/// need not be parallel nor evenly spaced: every point is measured against
/// every plane, so oblique and irregular stacks place their points as a
/// regular axial one does.
public enum ROIPointsBetween {
    /// Millimetres between consecutive points of the line.
    public static let step = 1.0

    /// How close to the end a point may come and still be a point of its own,
    /// rather than the end point again.
    static let endTolerance = 1e-6

    /// One point of the line and the image it goes on.
    public struct Placement: Sendable, Equatable {
        /// The point on the line, in patient coordinates.
        public var position: SIMD3<Double>
        /// The index of the image, in the order of the planes given.
        public var slice: Int
        /// The projection of `position` on that image, in pixels with the
        /// centre of the first pixel at (0, 0).
        public var column: Double
        public var row: Double
        /// Signed distance from `position` to the image's plane, in millimetres.
        public var distanceFromPlane: Double
    }

    /// The points 1, 2, 3 … mm from `start` towards `end`, without the two
    /// ends themselves: a line shorter than a millimetre and one between
    /// points that are not finite give none.
    public static func positions(from start: SIMD3<Double>, to end: SIMD3<Double>) -> [SIMD3<Double>] {
        let span = end - start
        let length = simd_length(span)
        guard length.isFinite, length > 0 else { return [] }
        let direction = span / length
        var positions: [SIMD3<Double>] = []
        var distance = step
        while distance < length - endTolerance {
            positions.append(start + direction * distance)
            distance += step
        }
        return positions
    }

    /// The plane nearest to `point`, by the absolute distance from it, and
    /// that distance, signed; on a tie the first plane wins. Nil without planes.
    public static func nearestPlane(to point: SIMD3<Double>, among planes: [ROISlicePlane]) -> (index: Int, distance: Double)? {
        var best: (index: Int, distance: Double)?
        for (index, plane) in planes.enumerated() {
            let distance = plane.distance(to: point)
            guard distance.isFinite else { continue }
            if let current = best, abs(current.distance) <= abs(distance) { continue }
            best = (index, distance)
        }
        return best
    }

    /// The points between `start` and `end`, each on the plane nearest to it
    /// among `planes` (one per image of the series, in order), at its
    /// projection on that plane.
    public static func placements(from start: SIMD3<Double>, to end: SIMD3<Double>,
                                  planes: [ROISlicePlane]) -> [Placement] {
        positions(from: start, to: end).compactMap { position in
            guard let nearest = nearestPlane(to: position, among: planes) else { return nil }
            let pixel = planes[nearest.index].pixel(of: position)
            guard pixel.column.isFinite, pixel.row.isFinite else { return nil }
            return Placement(position: position, slice: nearest.index, column: pixel.column, row: pixel.row,
                             distanceFromPlane: nearest.distance)
        }
    }
}
