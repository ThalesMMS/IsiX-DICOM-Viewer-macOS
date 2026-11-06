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

// The numbers of a 2D viewer's comparison with the series fused over it: the
// blend the Fusion panel's slider stands for, the slider value of a blend, the
// manual offset typed before a guided ROI copy, and the patient-space box of
// a volume. The viewer (ViewerController+RegistrationHost.swift and
// ViewerController+RegisteredGIF.swift, in the app) reads its controls and
// slices and asks these.
public enum FusionComparison {

    /// The fusion blend, 0 to 1, of the slider's `value` between its
    /// `minimum` and `maximum` (the Fusion panel's spans -256 to 256, shown
    /// as 0 to 100 %); one half when the slider has no range.
    public static func blend(value: Double, minimum: Double, maximum: Double) -> Double {
        return maximum > minimum ? (value - minimum) / (maximum - minimum) : 0.5
    }

    /// The slider value of a blend `stop` (0 to 1) between `minimum` and
    /// `maximum`.
    public static func sliderValue(stop: Double, minimum: Double, maximum: Double) -> Double {
        return minimum.addingProduct(stop, maximum - minimum)
    }

    /// The manual offset in millimetres from the values typed in its fields:
    /// what is not a finite number counts as 0.
    public static func offset(_ values: [Double]) -> [Double] {
        return values.map { $0.isFinite ? $0 : 0 }
    }

    /// The axis-aligned box, in patient millimetres, around these points
    /// (the corners of a volume's first and last slices): its minimum and
    /// maximum on each axis, infinite when there is no point.
    public static func bounds(of points: [SIMD3<Float>]) -> (minimum: [Double], maximum: [Double]) {
        var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
        for point in points {
            for axis in 0..<3 {
                let value = Double(point[axis])
                // MIN and MAX as Foundation's macros compare, NaN included.
                lo[axis] = lo[axis] < value ? lo[axis] : value
                hi[axis] = hi[axis] < value ? value : hi[axis]
            }
        }
        return (lo, hi)
    }
}
