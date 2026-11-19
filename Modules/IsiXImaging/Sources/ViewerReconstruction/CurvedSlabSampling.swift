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

/// The planes the curved MPR samples a slab with.
///
/// A slab `width` millimetres thick is sampled by planes on both sides of the
/// curve, the first and the last `width` apart. Left to itself the distance
/// between two planes is the finest spacing of the volume or less, whatever
/// divides the width evenly: planes exactly that spacing apart covered only
/// the whole steps that fit, 2.8 mm of a slab of 3 mm at 0.7 mm. A request
/// that fixes the distance (an export in its own interval) keeps it, and has
/// the planes that fit in the width.
public enum CurvedSlabSampling {
    /// The planes of a slab sampled no coarser than `maximumStep`: as many
    /// equal steps as cover the whole width, and one plane more. A slab that
    /// cannot be sampled (no width, no step) is the one plane of the curve.
    public static func planes(width: Double, maximumStep: Double) -> (count: Int, step: Double) {
        guard width.isFinite, maximumStep.isFinite, width > 0, maximumStep > 0 else {
            return (1, maximumStep.isFinite ? maximumStep : 0)
        }
        let steps = max(1, (width / maximumStep - 1e-9).rounded(.up))
        guard steps < Double(Int32.max) else { return (1, maximumStep) }
        return (Int(steps) + 1, width / steps)
    }

    /// The planes of a slab sampled every `step`: those that fit in the
    /// width, the first one included. A width that is a whole number of steps
    /// has its last plane whatever the division's last bit says.
    public static func planes(width: Double, step: Double) -> Int {
        let steps = width / step
        guard steps.isFinite, steps > 0 else { return 1 }
        return Int(min((steps + 1e-9).rounded(.down), Double(Int32.max - 1))) + 1
    }

    /// The planes of a generator request and the distance between them: the
    /// request's own distance when it fixes one, else the volume's finest
    /// `spacing` as the most.
    public static func planes(width: Double, spacing: Double, fixedDistance: Double) -> (count: Int, distance: Double) {
        if fixedDistance != 0 {
            return (planes(width: width, step: fixedDistance), fixedDistance)
        }
        let sampled = planes(width: width, maximumStep: spacing)
        return (sampled.count, sampled.step)
    }
}
