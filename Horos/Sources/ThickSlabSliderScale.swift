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

/// The knob's unit interval is separate from the thickness used by the renderer
/// and numeric field. The exponential curve requires a positive minimum; incomplete bounds
/// during nib loading fall back to a finite linear or constant range.
struct ThickSlabSliderScale {
    // Keep the original persisted key so existing choices survive the UI rename.
    static let defaultsKey = "LogarithmicThickSlabSlider"

    let minimum: Double
    let maximum: Double
    let exponential: Bool

    init(minimum: Double, maximum: Double, exponential: Bool) {
        self.minimum = minimum.isFinite ? minimum : 0
        self.maximum = maximum.isFinite ? max(self.minimum, maximum) : self.minimum
        self.exponential = exponential && self.minimum > 0 && self.maximum > self.minimum
    }

    func thickness(at position: Double) -> Double {
        guard maximum > minimum, !position.isNaN, position > 0 else { return minimum }
        guard position < 1 else { return maximum }
        if exponential {
            return min(maximum, max(minimum, exp(log(minimum) + position * (log(maximum) - log(minimum)))))
        }
        return minimum + position * (maximum - minimum)
    }

    func position(for thickness: Double) -> Double {
        guard maximum > minimum, !thickness.isNaN, thickness > minimum else { return 0 }
        guard thickness < maximum else { return 1 }
        if exponential {
            return (log(thickness) - log(minimum)) / (log(maximum) - log(minimum))
        }
        return (thickness - minimum) / (maximum - minimum)
    }

    /// The thickness the MPR's knob gives at `position`: whole millimeters,
    /// with the scale's own ends kept as they are, so the thin end is still
    /// the slice interval. The curve alone gave 1.03, 1.57 or 2.61 mm.
    func wholeThickness(at position: Double) -> Double {
        let raw = thickness(at: position)
        guard raw > minimum, raw < maximum else { return raw }
        return min(maximum, max(minimum, raw.rounded()))
    }

    /// Where the marks stand, both ends included: at round values of the
    /// scale's own unit, never closer than `minimumSpacing` of the track.
    /// A linear scale marks the multiples of one step (1, 2, 5, 10, 20…), the
    /// smallest that fits, so its marks are evenly spaced. An exponential
    /// scale is a logarithmic ruler: 1, 2, 3 … 9 of each power of ten, or 1, 2
    /// and 5, or the powers alone, whichever is the densest that fits; its
    /// marks close up toward each power, and the same ratio is the same
    /// distance anywhere on the track.
    func tickPositions(minimumSpacing: Double) -> [Double] {
        guard maximum > minimum else { return [] }
        let spacing = minimumSpacing.isFinite ? max(minimumSpacing, 0) : 0
        let rulers = exponential ? Self.digits.map { logarithmicMarks($0) } : linearSteps.map { linearMarks(every: $0) }
        for case let values? in rulers {
            let inner = values.map { position(for: $0) }
            guard zip(inner, inner.dropFirst()).allSatisfy({ $1 - $0 >= spacing }) else { continue }
            // A mark that would touch an end gives way to the end's own.
            return [0] + inner.filter { $0 >= spacing && 1 - $0 >= spacing } + [1]
        }
        return [0, 1]
    }

    /// The digits marked in each power of ten, from the densest ruler to the sparsest.
    private static let digits: [[Double]] = [[1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 5], [1]]
    /// More marks than this are no ruler.
    private static let mostMarks = 48

    /// The values strictly inside the scale that a logarithmic ruler of `digits` marks.
    private func logarithmicMarks(_ digits: [Double]) -> [Double]? {
        var values: [Double] = []
        var power = pow(10, floor(log10(minimum)))
        while power < maximum {
            values += digits.map { $0 * power }.filter { $0 > minimum && $0 < maximum }
            if values.count > Self.mostMarks { return nil }
            power *= 10
        }
        return values
    }

    /// Round steps, from about a fiftieth of the range up.
    private var linearSteps: [Double] {
        let finest = pow(10, floor(log10((maximum - minimum) / 50)))
        return (0..<4).flatMap { decade in [1.0, 2, 5].map { $0 * finest * pow(10, Double(decade)) } }
    }

    /// The multiples of `step` strictly inside the scale.
    private func linearMarks(every step: Double) -> [Double]? {
        let first = Int((minimum / step).rounded(.down)) + 1
        let last = Int((maximum / step).rounded(.up)) - 1
        guard last >= first else { return [] }
        guard last - first < Self.mostMarks else { return nil }
        return (first...last).map { Double($0) * step }
    }
}
