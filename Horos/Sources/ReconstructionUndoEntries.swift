//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The «mprCamera» entries of a reconstruction window's undo queue: the three
/// planes' cameras and their lines' angles.
@MainActor
enum ReconstructionUndoEntries {

    /// Whether two entries show the planes the same: a press in a plane that
    /// leaves them so has nothing to undo. A camera read back from the
    /// rendering differs from itself by rounding, so each value is compared
    /// within a ten-thousandth of the plane's scale (of the value, for the
    /// scale and the window) and each angle within a hundredth of a degree.
    static func sameCameras(_ one: Any?, _ other: Any?) -> Bool {
        let entries = [one, other].map { $0 as? [String: Any] }
        let cameras = entries.map { $0?["cameras"] as? [Camera] ?? [] }
        let angles = entries.map { ($0?["angleMPRs"] as? [NSNumber] ?? []).map(\.floatValue) }
        guard entries[0] != nil, entries[1] != nil, cameras[0].count == cameras[1].count, angles[0].count == angles[1].count else { return false }
        func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }
        func near(_ a: Point3D?, _ b: Point3D?, _ tolerance: Float) -> Bool {
            near(a?.x ?? 0, b?.x ?? 0, tolerance) && near(a?.y ?? 0, b?.y ?? 0, tolerance) && near(a?.z ?? 0, b?.z ?? 0, tolerance)
        }
        return zip(angles[0], angles[1]).allSatisfy { abs(($0 - $1).remainder(dividingBy: 360)) <= 0.01 }
            && zip(cameras[0], cameras[1]).allSatisfy { c, d in
                let unit = max(abs(d.parallelScale), 1) * 1e-4
                return near(c.position, d.position, unit) && near(c.focalPoint, d.focalPoint, unit) && near(c.viewUp, d.viewUp, 1e-4)
                    && near(c.clippingRangeNear, d.clippingRangeNear, unit) && near(c.clippingRangeFar, d.clippingRangeFar, unit)
                    && near(c.parallelScale, d.parallelScale, abs(d.parallelScale) * 1e-4) && near(c.viewAngle, d.viewAngle, 1e-3)
                    && near(c.wl, d.wl, max(abs(d.ww), 1) * 1e-4) && near(c.ww, d.ww, max(abs(d.ww), 1) * 1e-4)
                    && near(c.fusionPercentage, d.fusionPercentage, 1e-3) && c.movieIndexIn4D == d.movieIndexIn4D
            }
    }
}
