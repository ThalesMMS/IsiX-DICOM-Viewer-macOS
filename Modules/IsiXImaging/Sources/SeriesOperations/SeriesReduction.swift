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

/// A reduced copy of a series: the slices from a first one to a last one,
/// every `step` of them, for a new viewer. The first and last slices are image
/// numbers as the viewer shows them, from 1, so that a flipped series is cut
/// where the user reads it. The kept slices stay in the order of the series'
/// storage, which is the order of their positions: a regular stack of
/// interval d gives a regular stack of interval step × d, and nothing here
/// moves a slice. The viewer copies the slices and their pixels; nothing here
/// knows DCMPix or the viewer.
public struct SeriesReduction: Sendable, Equatable {

    /// The first slice kept, from 1, as the viewer numbers it.
    public let first: Int
    /// The last slice of the range, from 1; it is kept only when the step
    /// lands on it.
    public let last: Int
    /// One slice is kept every `step`.
    public let step: Int
    /// The number of slices of the series.
    public let sliceCount: Int

    /// Why the values of the dialog do not make a reduction.
    public enum Problem: Error, Sendable, Equatable {
        /// The series has no slice.
        case emptySeries
        /// The first slice is not between 1 and the number of slices.
        case firstOutOfRange
        /// The last slice is not between 1 and the number of slices.
        case lastOutOfRange
        /// The last slice comes before the first.
        case lastBeforeFirst
        /// The step is less than 1.
        case stepTooSmall
    }

    /// What the dialog proposes: the whole series, every second slice.
    public static func defaults(sliceCount: Int) -> (first: Int, last: Int, step: Int) {
        (1, max(sliceCount, 1), 2)
    }

    /// The reduction the values of the dialog ask for, or why there is none.
    public static func make(first: Int, last: Int, step: Int, sliceCount: Int) -> Result<SeriesReduction, Problem> {
        guard sliceCount > 0 else { return .failure(.emptySeries) }
        guard (1...sliceCount).contains(first) else { return .failure(.firstOutOfRange) }
        guard (1...sliceCount).contains(last) else { return .failure(.lastOutOfRange) }
        guard last >= first else { return .failure(.lastBeforeFirst) }
        guard step >= 1 else { return .failure(.stepTooSmall) }
        return .success(SeriesReduction(first: first, last: last, step: step, sliceCount: sliceCount))
    }

    private init(first: Int, last: Int, step: Int, sliceCount: Int) {
        self.first = first
        self.last = last
        self.step = step
        self.sliceCount = sliceCount
    }

    /// The image numbers kept, from 1, as the viewer shows them.
    public var keptImageNumbers: [Int] {
        Array(stride(from: first, through: last, by: step))
    }

    /// The number of slices of the reduced series.
    public var keptCount: Int {
        (last - first) / step + 1
    }

    /// The indexes, in the series' storage, of the slices kept, ascending. When
    /// the viewer shows the series flipped, image number n is the slice at
    /// sliceCount - n.
    public func keptIndices(flipped: Bool) -> [Int] {
        let indices = keptImageNumbers.map { flipped ? sliceCount - $0 : $0 - 1 }
        return flipped ? indices.reversed() : indices
    }

    /// The interval between the kept slices: `step` times the series' interval,
    /// with its sign.
    public func sliceInterval(original: Double) -> Double {
        original * Double(step)
    }

    /// The slice of the reduced series to show first: the kept slice nearest
    /// to `storageIndex`, the slice the viewer shows, as an index into the
    /// kept slices (`keptIndices(flipped:)`); the earlier one on a tie.
    public func nearestKeptPosition(to storageIndex: Int, flipped: Bool) -> Int {
        let kept = keptIndices(flipped: flipped)
        var best = 0
        for (position, index) in kept.enumerated() where abs(index - storageIndex) < abs(kept[best] - storageIndex) {
            best = position
        }
        return best
    }
}
