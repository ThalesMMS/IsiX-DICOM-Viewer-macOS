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

import simd

/// Patient-space geometry of the Sync item of the 3D MPR.
///
/// The position the MPR shares is the point where its three planes meet, the
/// centre of its cross. Each plane is the one of a view's resliced image: its
/// origin and the normal of its orientation, in DICOM patient coordinates.
enum MPRPositionSync {
    struct Plane {
        var origin: SIMD3<Double>
        var normal: SIMD3<Double>
    }

    /// The point common to three planes; nil when two of them are parallel.
    static func intersection(_ planes: [Plane]) -> SIMD3<Double>? {
        guard planes.count == 3 else { return nil }
        let n = planes.map { simd_normalize($0.normal) }
        guard n.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        let d = zip(planes, n).map { simd_dot($0.origin, $1) }
        let n12 = simd_cross(n[1], n[2]), n20 = simd_cross(n[2], n[0]), n01 = simd_cross(n[0], n[1])
        let determinant = simd_dot(n[0], n12)
        guard abs(determinant) > 1e-6 else { return nil }
        return (d[0] * n12 + d[1] * n20 + d[2] * n01) / determinant
    }

    /// The point of a plane closest to `point`.
    static func projection(of point: SIMD3<Double>, onto plane: Plane) -> SIMD3<Double> {
        let normal = simd_normalize(plane.normal)
        return point - simd_dot(point - plane.origin, normal) * normal
    }

    /// A 2D slice moved the MPR only when its centre left the slab of that
    /// slice: the slice nearest to the MPR centre is within half a slice of it,
    /// so the MPR does not creep after its own position comes back.
    static func shouldFollow(from center: SIMD3<Double>, to target: SIMD3<Double>, halfSlice: Double) -> Bool {
        simd_distance(center, target) > max(halfSlice, 0.01)
    }
}
