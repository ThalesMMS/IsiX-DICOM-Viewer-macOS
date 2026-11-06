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

/// The empty slices that make a stack with missing positions regular.
///
/// A series where slices are missing (a dropped image, a reconstruction that
/// skipped a range) has intervals that are whole multiples of its slice
/// interval: 1.25 mm everywhere and 2.5 mm where one slice is gone. Inserting
/// an empty slice at each missing position gives a stack at one interval,
/// which the 3D viewers and the measurements need. The inserted slices hold no
/// invented values: the viewer fills them with one defined value and marks
/// them as empty.
///
/// The regular step is the most common interval along the slice normal: the
/// intervals are grouped within the tolerance, the largest group wins (the
/// smaller interval on a tie), and its mean is the step. The smallest interval
/// would be a poor choice: two slices written at almost the same position
/// would make it tiny and fill the whole stack with empty slices. Each
/// interval must then be a whole multiple k of the step, within the tolerance;
/// k − 1 empty slices go in it, spread evenly between its two slices, so the
/// gap's own length is kept and nothing is moved. An interval that is not a
/// multiple (1.5 steps, or shorter than the step) cannot be made regular by
/// inserting slices, and the stack is refused rather than distorted.
public struct SliceGapFill: Sendable, Equatable {

    /// The relative tolerance of an interval against the step, as the
    /// irregular-interval warning measures it: 10% of the step.
    public static let relativeTolerance = 0.10

    /// One slice of the filled stack.
    public enum Slice: Sendable, Equatable {
        /// The original slice at this index of the stack.
        case original(Int)
        /// An empty slice between original slices `after` and `after + 1`,
        /// at `fraction` (0 < fraction < 1) of the way from one to the other,
        /// at `position` along the normal.
        case empty(after: Int, fraction: Double, position: Double)

        /// Whether this slice was inserted.
        public var isEmpty: Bool {
            if case .empty = self { return true }
            return false
        }
    }

    /// Why a stack cannot be filled.
    public enum Refusal: Sendable, Equatable {
        /// Fewer than three slices: there is no interval to compare.
        case tooFewSlices
        /// Two neighbouring slices share a position (several frames or
        /// echoes at one place): no slice is missing between them.
        case coincidentSlices
        /// The positions do not run one way along the normal.
        case notMonotonic
        /// An interval is not a whole multiple of the step.
        case notMultiple(interval: Double, step: Double)
    }

    /// What the gap computation finds in a stack.
    public enum Outcome: Sendable, Equatable {
        /// Empty slices make the stack regular.
        case fill(SliceGapFill)
        /// Every interval is the step already: no position is missing.
        case noGaps(step: Double)
        case refused(Refusal)
    }

    /// The regular interval of the filled stack, in mm, positive.
    public let step: Double
    /// The slices of the filled stack, original and empty, in stack order.
    public let slices: [Slice]

    /// The number of empty slices inserted.
    public var emptyCount: Int { slices.reduce(0) { $1.isEmpty ? $0 + 1 : $0 } }

    /// The gaps of a stack whose slices are at `positions` along their normal,
    /// in stack order (ascending or descending). `relativeTolerance` is the
    /// fraction of the step an interval may differ from a whole multiple of it.
    public static func plan(positions: [Double], relativeTolerance: Double = SliceGapFill.relativeTolerance) -> Outcome {
        guard positions.count >= 3, positions.allSatisfy(\.isFinite) else { return .refused(.tooFewSlices) }

        let signed = (1..<positions.count).map { positions[$0] - positions[$0 - 1] }
        let intervals = signed.map(abs)
        guard let largest = intervals.max(), largest > 0 else { return .refused(.coincidentSlices) }
        // A slice at the same place as its neighbour, against the largest interval.
        if intervals.contains(where: { $0 <= largest * 1e-6 }) { return .refused(.coincidentSlices) }
        let direction: Double = signed[0] > 0 ? 1 : -1
        if signed.contains(where: { ($0 > 0 ? 1 : -1) != direction }) { return .refused(.notMonotonic) }

        let step = mostCommonInterval(intervals, relativeTolerance: relativeTolerance)
        let tolerance = relativeTolerance * step

        var slices: [Slice] = [.original(0)]
        for (index, interval) in intervals.enumerated() {
            let multiple = (interval / step).rounded()
            guard multiple >= 1, abs(interval - multiple * step) <= tolerance else {
                return .refused(.notMultiple(interval: interval, step: step))
            }
            let missing = Int(multiple) - 1
            if missing > 0 {
                for j in 1...missing {
                    let fraction = Double(j) / multiple
                    slices.append(.empty(after: index, fraction: fraction, position: positions[index] + fraction * signed[index]))
                }
            }
            slices.append(.original(index + 1))
        }

        let filled = SliceGapFill(step: step, slices: slices)
        return filled.emptyCount == 0 ? .noGaps(step: step) : .fill(filled)
    }

    /// The positions of slices along `normal` (x, y, z) from their `origins`.
    /// Without a normal, the direction from the first origin to the last.
    public static func positions(origins: [SIMD3<Double>], normal: SIMD3<Double>) -> [Double] {
        var n = normal
        var length = (n * n).sum().squareRoot()
        if length < 0.5, let first = origins.first, let last = origins.last {
            n = last - first
            length = (n * n).sum().squareRoot()
        }
        guard length > 0 else { return origins.map { _ in 0 } }
        n /= length
        return origins.map { ($0 * n).sum() }
    }

    /// The interval most slices are apart: the intervals sorted and grouped
    /// within the tolerance of each group's smallest, the largest group (the
    /// smaller on a tie), its mean.
    static func mostCommonInterval(_ intervals: [Double], relativeTolerance: Double) -> Double {
        let sorted = intervals.sorted()
        var best: (count: Int, sum: Double) = (0, 0)
        var start = 0
        while start < sorted.count {
            var end = start
            while end + 1 < sorted.count, sorted[end + 1] <= sorted[start] * (1 + relativeTolerance) { end += 1 }
            let count = end - start + 1
            if count > best.count { best = (count, sorted[start...end].reduce(0, +)) }
            start = end + 1
        }
        return best.sum / Double(best.count)
    }

    /// Copies the original slices of `source` (each `sliceFloatCount` floats,
    /// one after the other) into `destination` in the order of `slices`, and
    /// writes `fillValue` into every empty one. `destination` holds
    /// `slices.count` slices.
    public func fillVolume(source: UnsafePointer<Float>, sliceFloatCount: Int,
                           into destination: UnsafeMutablePointer<Float>, fillValue: Float) {
        for (index, slice) in slices.enumerated() {
            let target = destination + index * sliceFloatCount
            switch slice {
            case .original(let original):
                target.update(from: source + original * sliceFloatCount, count: sliceFloatCount)
            case .empty:
                target.update(repeating: fillValue, count: sliceFloatCount)
            }
        }
    }

    /// The origin of a filled slice from the origins of the original ones:
    /// an empty slice lies on the straight line between its two neighbours.
    public static func origin(of slice: Slice, origins: [SIMD3<Double>]) -> SIMD3<Double> {
        switch slice {
        case .original(let index):
            return origins[index]
        case let .empty(after, fraction, _):
            return origins[after] + fraction * (origins[after + 1] - origins[after])
        }
    }
}
