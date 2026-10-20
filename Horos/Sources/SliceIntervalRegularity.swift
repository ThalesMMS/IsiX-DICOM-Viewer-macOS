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

/// Whether a stack of slices is spaced regularly enough for 3D and measurements.
///
/// The warning compared the straight distance between neighbouring origins and
/// flagged the stack when any two consecutive distances differed by 0.01 mm:
/// an absolute threshold, by integer truncation, unrelated to the size of a
/// voxel. A step-and-shoot CT with a tilted gantry moves the table the same
/// distance at each acquisition, which along the slice normal is a little
/// shorter: 1.25 mm slices met 0.037 mm closer at each of 7 boundaries, a
/// warning for a stack whose largest error is a tenth of a pixel. Positions
/// written with two decimals warned on regular stacks too.
///
/// Positions are measured along the slice normal. The stack is irregular when
/// an interval differs from the mean interval by more than 10% (a missing
/// slice, a mix of thicknesses), or when a slice lies more than half the
/// smallest pixel spacing away from a uniform grid at the mean interval.
@objc(HorosSliceIntervalRegularity)
public final class SliceIntervalRegularity: NSObject {
    /// The intervals along the normal, as the warning reports them.
    @objc public let minimumInterval: Double
    @objc public let maximumInterval: Double
    @objc public let meanInterval: Double
    /// The largest distance of a slice from the uniform grid, in mm.
    @objc public let largestGridDeviation: Double
    @objc public let isIrregular: Bool

    static let relativeTolerance = 0.10

    init(minimum: Double, maximum: Double, mean: Double, deviation: Double, irregular: Bool) {
        minimumInterval = minimum
        maximumInterval = maximum
        meanInterval = mean
        largestGridDeviation = deviation
        isIrregular = irregular
    }

    /// `origins` holds x, y, z of each slice in stack order; `normal` the slice
    /// normal (rows x columns); `pixelSpacing` the smallest in-plane spacing.
    @objc(regularityOfOrigins:normal:pixelSpacing:)
    public static func regularity(origins: [NSNumber], normal: [NSNumber], pixelSpacing: Double) -> SliceIntervalRegularity {
        regularity(origins: origins.map(\.doubleValue), normal: normal.map(\.doubleValue), pixelSpacing: pixelSpacing)
    }

    static func regularity(origins: [Double], normal: [Double], pixelSpacing: Double) -> SliceIntervalRegularity {
        let count = origins.count / 3
        guard count >= 2 else { return SliceIntervalRegularity(minimum: 0, maximum: 0, mean: 0, deviation: 0, irregular: false) }
        func origin(_ i: Int) -> (Double, Double, Double) { (origins[3 * i], origins[3 * i + 1], origins[3 * i + 2]) }

        // Without an orientation, the direction from the first slice to the last.
        var n = normal.count == 3 ? (normal[0], normal[1], normal[2]) : (0, 0, 0)
        var length = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
        if length < 0.5 {
            let a = origin(0), b = origin(count - 1)
            n = (b.0 - a.0, b.1 - a.1, b.2 - a.2)
            length = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
        }
        guard length > 0 else { return SliceIntervalRegularity(minimum: 0, maximum: 0, mean: 0, deviation: 0, irregular: false) }
        n = (n.0 / length, n.1 / length, n.2 / length)
        let positions = (0..<count).map { i -> Double in let o = origin(i); return o.0 * n.0 + o.1 * n.1 + o.2 * n.2 }

        let intervals = (1..<count).map { abs(positions[$0] - positions[$0 - 1]) }
        let minimum = intervals.min() ?? 0, maximum = intervals.max() ?? 0
        let span = positions[count - 1] - positions[0]
        let mean = abs(span) / Double(count - 1)
        guard mean > 1e-6 else {
            return SliceIntervalRegularity(minimum: minimum, maximum: maximum, mean: mean, deviation: 0, irregular: maximum > 1e-3)
        }
        let step = span / Double(count - 1)
        let deviation = (0..<count).map { abs(positions[$0] - (positions[0] + step * Double($0))) }.max() ?? 0
        let uneven = intervals.contains { abs($0 - mean) > relativeTolerance * mean }
        let offGrid = pixelSpacing > 0 && deviation > pixelSpacing / 2
        return SliceIntervalRegularity(minimum: minimum, maximum: maximum, mean: mean, deviation: deviation, irregular: uneven || offGrid)
    }
}
