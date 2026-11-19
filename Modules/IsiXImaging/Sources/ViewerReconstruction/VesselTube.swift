//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import simd

/// The voxels of a volume within a tube around paths.
///
/// A maximum intensity projection of a coronary CT shows the chambers, full
/// of contrast, in front of the arteries. Keeping only what lies within a
/// few millimetres of the paths marked along the arteries leaves the tree
/// alone, as an angiogram shows it, without segmenting anything: the tube
/// knows where the paths run, not what the voxels hold.
public enum VesselTube {
    /// A volume's grid: its size in voxels, the place of the centre of its
    /// first voxel and the step to the next voxel along each of its axes,
    /// in patient space, in mm.
    public struct Grid: Equatable, Sendable {
        public var width: Int, height: Int, depth: Int
        public var origin: SIMD3<Double>
        public var column: SIMD3<Double>, row: SIMD3<Double>, slice: SIMD3<Double>

        public init(width: Int, height: Int, depth: Int, origin: SIMD3<Double>, column: SIMD3<Double>, row: SIMD3<Double>, slice: SIMD3<Double>) {
            (self.width, self.height, self.depth) = (width, height, depth)
            (self.origin, self.column, self.row, self.slice) = (origin, column, row, slice)
        }

        var count: Int { width * height * depth }
    }

    /// The radius of the tube a window starts with, in mm: the widest
    /// coronary artery is 5 mm across, and a path marked by hand strays a
    /// millimetre or two from the middle of its vessel.
    public static let defaultRadius = 4.0
    public static let radii: ClosedRange<Double> = 2...10

    /// One byte for each voxel of `grid`, slice after slice, row after row:
    /// 1 within `radius` mm of a path, 0 elsewhere. A path is the points it
    /// runs through, in patient space, joined by straight lines; one of a
    /// single point is a ball. Nil when the grid's axes do not span space.
    public static func mask(of grid: Grid, around paths: [[SIMD3<Double>]], radius: Double) -> [UInt8]? {
        let toPatient = simd_double3x3(columns: (grid.column, grid.row, grid.slice))
        guard grid.count > 0, radius > 0, abs(toPatient.determinant) > 1e-12 else { return nil }
        let toVoxel = toPatient.inverse
        // How far, in voxels along each axis, a ball of `radius` reaches.
        let reach = SIMD3(simd_length(toVoxel.transpose.columns.0), simd_length(toVoxel.transpose.columns.1), simd_length(toVoxel.transpose.columns.2)) * radius
        var mask = [UInt8](repeating: 0, count: grid.count)
        let limit = SIMD3(Double(grid.width - 1), Double(grid.height - 1), Double(grid.depth - 1))
        for path in paths where !path.isEmpty {
            let segments = path.count == 1 ? [(path[0], path[0])] : Array(zip(path, path.dropFirst()))
            for (a, b) in segments {
                let (va, vb) = (toVoxel * (a - grid.origin), toVoxel * (b - grid.origin))
                let low = simd_clamp(simd.floor(simd_min(va, vb) - reach), .zero, limit)
                let high = simd_clamp(simd.ceil(simd_max(va, vb) + reach), .zero, limit)
                guard low.x <= high.x, low.y <= high.y, low.z <= high.z else { continue }
                let along = b - a
                let lengthSquared = simd_length_squared(along)
                for z in Int(low.z)...Int(high.z) {
                    for y in Int(low.y)...Int(high.y) {
                        let start = grid.origin + Double(y) * grid.row + Double(z) * grid.slice
                        let base = (z * grid.height + y) * grid.width
                        for x in Int(low.x)...Int(high.x) where mask[base + x] == 0 {
                            let p = start + Double(x) * grid.column
                            let t = lengthSquared > 0 ? min(max(simd_dot(p - a, along) / lengthSquared, 0), 1) : 0
                            if simd_length_squared(p - (a + t * along)) <= radius * radius { mask[base + x] = 1 }
                        }
                    }
                }
            }
        }
        return mask
    }

    /// Gives `value` to the voxels of `volume` outside `mask`.
    public static func keep(_ mask: [UInt8], of volume: UnsafeMutableBufferPointer<Float>, elsewhere value: Float) {
        for index in 0..<min(mask.count, volume.count) where mask[index] == 0 { volume[index] = value }
    }
}
