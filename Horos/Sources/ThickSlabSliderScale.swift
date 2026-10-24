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
/// and numeric field. Logarithms require a positive minimum; incomplete bounds
/// during nib loading fall back to a finite linear or constant range.
struct ThickSlabSliderScale {
    static let defaultsKey = "LogarithmicThickSlabSlider"

    let minimum: Double
    let maximum: Double
    let logarithmic: Bool

    init(minimum: Double, maximum: Double, logarithmic: Bool) {
        self.minimum = minimum.isFinite ? minimum : 0
        self.maximum = maximum.isFinite ? max(self.minimum, maximum) : self.minimum
        self.logarithmic = logarithmic && self.minimum > 0 && self.maximum > self.minimum
    }

    func thickness(at position: Double) -> Double {
        guard maximum > minimum, !position.isNaN, position > 0 else { return minimum }
        guard position < 1 else { return maximum }
        if logarithmic {
            return min(maximum, max(minimum, exp(log(minimum) + position * (log(maximum) - log(minimum)))))
        }
        return minimum + position * (maximum - minimum)
    }

    func position(for thickness: Double) -> Double {
        guard maximum > minimum, !thickness.isNaN, thickness > minimum else { return 0 }
        guard thickness < maximum else { return 1 }
        if logarithmic {
            return (log(thickness) - log(minimum)) / (log(maximum) - log(minimum))
        }
        return (thickness - minimum) / (maximum - minimum)
    }
}
