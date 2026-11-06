//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics

// The geometry of the volume ROIs the MPR and the CPR draw (the app's OSIROI
// family): how a planar outline becomes runs of voxels, how far an extrusion
// reaches, the box a group of ROIs is resampled in, and which points stand for
// a ROI's extent. The app walks its Bezier paths and volumes; the decisions
// are here, with the arithmetic the Objective-C classes had: indexes are
// rounded half away from zero, MIN and MAX keep their C macro order, and a
// value out of the integer range saturates as a conversion on arm64 does.

/// The integer an Objective-C cast of a double gave on arm64: truncated toward
/// zero, NaN as 0, out of range saturated.
public func volumeROIIndex(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9_223_372_036_854_775_807.0 { return Int.max }
    if value <= -9_223_372_036_854_775_808.0 { return Int.min }
    return Int(value)
}

/// MIN(a, b) of Foundation: `a < b ? a : b`, so that a NaN second argument wins.
@inline(__always) public func volumeROIMin(_ a: Double, _ b: Double) -> Double { a < b ? a : b }

/// MAX(a, b) of Foundation: `a < b ? b : a`, so that a NaN first argument wins.
@inline(__always) public func volumeROIMax(_ a: Double, _ b: Double) -> Double { a < b ? b : a }

/// How a planar outline is cut into runs of voxels, one row of the volume at a
/// time, as the planar path and extrusion ROIs build their masks.
public enum VolumeROIScan {
    /// The rows of a volume `height` high that an outline spanning `minY`
    /// to `maxY` (volume indexes) crosses: floor(minY) to ceil(maxY), without
    /// the rows outside the volume.
    public static func rows(minY: Double, maxY: Double, height: Int) -> [Int] {
        let low = minY.rounded(.down), high = maxY.rounded(.up)
        guard !low.isNaN, !high.isNaN, low <= high, height > 0 else { return [] }
        let first = Swift.max(low, 0), last = Swift.min(high, Double(height - 1))
        guard first <= last else { return [] }
        return Array(volumeROIIndex(first)...volumeROIIndex(last))
    }

    /// The runs of one row of a volume `width` wide, from the x where the
    /// outline crosses the row: sorted, taken in pairs, each end rounded; a
    /// pair that rounds to one pixel or lies outside the row gives nothing,
    /// the others are clipped to the row, the last pixel left out.
    public static func spans(crossings: [Double], width: Int) -> [(start: Int, length: Int)] {
        let sorted = crossings.sorted()
        var spans: [(start: Int, length: Int)] = []
        var j = 0
        while j + 1 < sorted.count {
            var start = volumeROIIndex(sorted[j].rounded())
            var end = volumeROIIndex(sorted[j + 1].rounded())
            j += 2
            if start == end || start >= width || end < 0 {
                continue
            }
            start = Swift.max(start, 0)
            // pixelsWide - 1 was unsigned: a volume with no width clips nothing.
            if width > 0 {
                end = Swift.min(end, width - 1)
            }
            if end > start {
                spans.append((start, end - start))
            }
        }
        return spans
    }

    /// The slice of a volume `depth` deep an outline at rounded index `z`
    /// lies on, or nil when it is outside the volume. A NaN index was slice 0.
    public static func slice(z: Double, depth: Int) -> Int? {
        if z < 0 || z >= Double(depth) {
            return nil
        }
        return volumeROIIndex(z)
    }

    /// The slices an extrusion of `thickness` (in slices) centred on `center`
    /// covers in a volume `depth` deep: round(center - thickness / 2) to
    /// round(center + thickness / 2), within the volume.
    public static func extrusionSlices(center: Double, thickness: Double, depth: Int) -> [Int] {
        let first = volumeROIMax((center - thickness / 2.0).rounded(), 0)
        let last = volumeROIMin((center + thickness / 2.0).rounded(), Double(depth) - 1)
        guard first <= last else { return [] }
        return Array(volumeROIIndex(first)...volumeROIIndex(last))
    }
}

/// The box, in voxels, that holds a set of points with a voxel to spare on
/// every side: the volume a group of ROIs is merged in, and the picture a slab
/// of it is resampled to.
public enum VolumeROIBox {
    /// floor(min) - 1 to ceil(max) + 1 on each axis of `points` (x, y, z).
    public static func padded(_ points: [(x: Double, y: Double, z: Double)])
        -> (minX: Double, minY: Double, minZ: Double, width: Int, height: Int, depth: Int) {
        var minX = Double.greatestFiniteMagnitude, minY = minX, minZ = minX
        var maxX = -Double.greatestFiniteMagnitude, maxY = maxX, maxZ = maxX
        for point in points {
            minX = volumeROIMin(minX, point.x); minY = volumeROIMin(minY, point.y); minZ = volumeROIMin(minZ, point.z)
            maxX = volumeROIMax(maxX, point.x); maxY = volumeROIMax(maxY, point.y); maxZ = volumeROIMax(maxZ, point.z)
        }
        minX = minX.rounded(.down) - 1; minY = minY.rounded(.down) - 1; minZ = minZ.rounded(.down) - 1
        maxX = maxX.rounded(.up) + 1; maxY = maxY.rounded(.up) + 1; maxZ = maxZ.rounded(.up) + 1
        return (minX, minY, minZ, volumeROIIndex(maxX - minX), volumeROIIndex(maxY - minY), volumeROIIndex(maxZ - minZ))
    }

    /// floor(min) - 1 to ceil(max) + 1 of `points` in the plane (x, y).
    public static func padded(_ points: [(x: Double, y: Double)]) -> (minX: Double, minY: Double, width: Int, height: Int) {
        let box = padded(points.map { (x: $0.x, y: $0.y, z: 0.0) })
        return (box.minX, box.minY, box.width, box.height)
    }

    /// The corners of a volume whose extent a slab picture must hold, in the
    /// order and with the values the coalesced ROI has always used: the last
    /// two take the depth for y, as they did.
    public static func sliceCorners(width: Int, height: Int, depth: Int) -> [(x: Double, y: Double, z: Double)] {
        let w = Double(width), h = Double(height), d = Double(depth)
        return [(0, 0, 0), (w, 0, 0), (0, h, 0), (w, h, 0), (0, 0, d), (w, 0, d), (0, d, d), (w, d, d)]
    }
}

/// The voxels of a mask, written into a float volume.
public enum VolumeROIMaskVolume {
    /// A brush ROI's texture as intensities from 0 to 1: byte / 255, rounded
    /// to a float from the double quotient. A missing texture leaves zeros.
    public static func brushIntensities(_ texture: UnsafePointer<UInt8>?, width: Int, height: Int,
                                        into intensities: UnsafeMutablePointer<Float>) {
        guard let texture, width > 0, height > 0 else { return }
        for j in 0..<height {
            for i in 0..<width {
                intensities[j * width + i] = Float(Double(Float(texture[j * width + i])) / 255.0)
            }
        }
    }

    /// Each voxel of each run keeps the larger of its value and the run's
    /// intensity, in a volume `width` by `height` by `count / (width * height)`;
    /// a voxel outside the volume is left out.
    public static func mergeMaximum(_ runs: [(location: Int, length: Int, row: Int, slice: Int, intensity: Float)],
                                    into volume: UnsafeMutablePointer<Float>, width: Int, height: Int, count: Int) {
        for run in runs where run.length > 0 {
            let rowStart = run.slice * width * height + run.row * width
            for i in run.location..<(run.location + run.length) {
                let index = rowStart + i
                guard index >= 0, index < count else { continue }
                let value = volume[index]
                volume[index] = value < run.intensity ? run.intensity : value
            }
        }
    }
}

/// A mask of one volume taken to another volume on the same grid: the same
/// axes and spacing, whole voxels apart, as the box a group of ROIs is merged
/// in is to their home volume.
public enum VolumeROIMaskGrid {
    /// The offset, in voxels, that takes an index of one volume to the same
    /// place in the other, from the affine map between their indexes, which
    /// acts on row vectors: `linear` is its 3 × 3 part row by row and
    /// `translation` its last row. Nil when the map is anything but a
    /// translation by whole voxels; the volumes are then on different grids.
    public static func wholeVoxelOffset(linear: [Double], translation: (x: Double, y: Double, z: Double))
        -> (x: Int, y: Int, z: Int)? {
        // The maps come from inverting and composing transforms in double
        // precision: an aligned grid is off by far less than these.
        let linearTolerance = 1e-6, voxelTolerance = 1e-4
        guard linear.count == 9 else { return nil }
        for row in 0..<3 {
            for column in 0..<3 where !(abs(linear[row * 3 + column] - (row == column ? 1 : 0)) <= linearTolerance) {
                return nil
            }
        }
        var offset: [Int] = []
        for value in [translation.x, translation.y, translation.z] {
            let whole = value.rounded()
            guard abs(value - whole) <= voxelTolerance, abs(whole) < Double(Int32.max) else { return nil }
            offset.append(Int(whole))
        }
        return (offset[0], offset[1], offset[2])
    }

    /// `runs` moved by `offset` into a volume `width` by `height` by `depth`:
    /// the voxels that fall outside it are left out, the rest keep their order.
    public static func moved(_ runs: [(location: Int, length: Int, row: Int, slice: Int, intensity: Float)],
                             by offset: (x: Int, y: Int, z: Int), width: Int, height: Int, depth: Int)
        -> [(location: Int, length: Int, row: Int, slice: Int, intensity: Float)] {
        var moved: [(location: Int, length: Int, row: Int, slice: Int, intensity: Float)] = []
        for run in runs where run.length > 0 {
            let row = run.row + offset.y, slice = run.slice + offset.z
            guard row >= 0, row < height, slice >= 0, slice < depth else { continue }
            let start = Swift.max(run.location + offset.x, 0)
            let end = Swift.min(run.location + run.length + offset.x, width)
            if end > start {
                moved.append((start, end - start, row, slice, run.intensity))
            }
        }
        return moved
    }
}

/// The kind of an element of a Bezier path.
public enum VolumeROIPathElement: Sendable {
    case moveTo, lineTo, curveTo, closePath
}

/// Which points stand for a ROI's extent.
public enum VolumeROIHull {
    /// The end of each move and line, and both controls and the end of each
    /// curve, in order; a close adds nothing. The ROI lies inside their hull.
    public static func points<Point>(of elements: [(kind: VolumeROIPathElement, control1: Point, control2: Point, end: Point)]) -> [Point] {
        var points: [Point] = []
        for element in elements {
            switch element.kind {
            case .moveTo, .lineTo:
                points.append(element.end)
            case .curveTo:
                points.append(element.control1)
                points.append(element.control2)
                points.append(element.end)
            case .closePath:
                break
            }
        }
        return points
    }
}

/// What a planar path ROI is outlined with, from the 2D ROI it stands for.
public enum VolumeROIOutline: Equatable, Sendable {
    /// A measure: a segment from the first point to the second.
    case segment(CGPoint, CGPoint)
    /// A polygon through the nodes, whose ends meet; it is then closed.
    case nodes([CGPoint])
    /// A polyline through the points, then closed.
    case polyline([CGPoint])

    /// The 2D ROI tools a planar path ROI is made from.
    public enum Kind: Sendable {
        case measure, openPolygon, closedPolygon, oval, pencil, traced, other
    }

    /// The outline of a 2D ROI of `kind` through `points`, or nil when it has
    /// none: a measure needs two points, a traced ROI one. An oval whose first
    /// two points coincide (`firstTwoCoincide`, as the points compare) is a
    /// one-pixel square; a closed polygon, an oval and a pencil end on their
    /// first point again.
    public static func make(kind: Kind, points: [CGPoint], firstTwoCoincide: Bool) -> VolumeROIOutline? {
        switch kind {
        case .measure:
            return points.count > 1 ? .segment(points[0], points[1]) : nil
        case .openPolygon:
            return .nodes(points)
        case .closedPolygon, .oval, .pencil:
            var points = points
            if kind == .oval && points.count >= 2 && firstTwoCoincide {
                var point = points[0]
                var square = [point]
                point.x += 1
                square.append(point)
                point.y += 1
                square.append(point)
                point.x -= 1
                square.append(point)
                points = square
            }
            if points.count > 1 {
                points.append(points[0])
            }
            return .nodes(points)
        case .traced:
            return points.isEmpty ? nil : .polyline(points)
        case .other:
            return nil
        }
    }
}
