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

    /// Marks are evenly spaced thickness values, the same on both scales,
    /// projected onto the knob's curve. On an exponential scale they stand far
    /// apart at the thin end and close together at the thick end, which shows
    /// the curve. Marks closer than `minimumSpacing` are omitted rather than
    /// drawn on top of each other; both endpoints remain visible.
    func tickPositions(count: Int, minimumSpacing: Double, integral: Bool) -> [Double] {
        guard (2...50).contains(count), maximum > minimum else { return [] }
        var values = [minimum]
        for index in 1..<(count - 1) {
            let value = minimum + Double(index) / Double(count - 1) * (maximum - minimum)
            values.append(integral ? value.rounded() : value)
        }
        // A linear scale keeps its marks evenly spaced; an exponential one may
        // crowd them up to the legible spacing.
        let legible = minimumSpacing.isFinite ? max(minimumSpacing, 0) : 0
        let gap = exponential ? legible : max(legible, 1 / Double(count - 1))
        var positions = [0.0]
        for value in values.dropFirst() {
            let next = position(for: value)
            if next < 1, next - positions.last! >= gap { positions.append(next) }
        }
        if positions.count > 1, 1 - positions.last! < gap { positions.removeLast() }
        positions.append(1)
        return positions
    }
}
