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

/// The ruler of a slab thickness slider: where the knob stands for a
/// thickness, the thicknesses it stops at, and the marks along the track.
///
/// The knob's unit interval is separate from the thickness used by the renderer
/// and numeric field. The exponential curve requires a positive minimum; incomplete bounds
/// during nib loading fall back to a finite linear or constant range.
public struct ThickSlabSliderScale: Sendable, Equatable {
    // Keep the original persisted key so existing choices survive the UI rename.
    public static let defaultsKey = "LogarithmicThickSlabSlider"

    public let minimum: Double
    public let maximum: Double
    public let exponential: Bool

    public init(minimum: Double, maximum: Double, exponential: Bool) {
        self.minimum = minimum.isFinite ? minimum : 0
        self.maximum = maximum.isFinite ? max(self.minimum, maximum) : self.minimum
        self.exponential = exponential && self.minimum > 0 && self.maximum > self.minimum
    }

    /// The thick end of a reconstruction's slab, in millimeters: the whole
    /// volume. The three planes share one thickness and each looks along
    /// another side of the volume, so it is the longest side, in whole
    /// millimeters, that lets any of them hold the volume in one slab. A
    /// volume whose sides are not known keeps `fallback`.
    public static func volumeMaximum(sides: [Double], fallback: Double) -> Double {
        let longest = sides.filter { $0.isFinite && $0 > 0 }.max() ?? 0
        return longest > 0 ? longest.rounded(.up) : fallback
    }

    /// The thin end of a reconstruction's slab, in millimeters: the finest
    /// spacing of the volume, of its pixels in a slice and of its slices,
    /// which is the step the reslice samples the volume by. A slab that thin
    /// holds one sample, as one image does in the 2D viewer. The three planes
    /// share one thickness and each looks along another side of the volume,
    /// so the slice's own thickness would thicken the planes across the
    /// slices of a series reconstructed with overlap.
    ///
    /// The slices count by their interval, whichever its sign (a reversed
    /// stack), or by their thickness when the series gives no interval. A
    /// spacing that is not a positive number does not count, and a volume
    /// with none has 1 mm: the answer is always a positive number, which the
    /// exponential curve needs.
    public static func thinEnd(sliceInterval: Double, sliceThickness: Double, pixelSpacingX: Double, pixelSpacingY: Double) -> Double {
        func usable(_ value: Double) -> Double? {
            let size = abs(value)
            return size.isFinite && size > 0 ? size : nil
        }
        let spacings = [usable(sliceInterval) ?? usable(sliceThickness),
                        pixelSpacingX > 0 ? usable(pixelSpacingX) : nil, pixelSpacingY > 0 ? usable(pixelSpacingY) : nil]
        return spacings.compactMap { $0 }.min() ?? 1
    }

    /// The least interval a reconstruction window's export fields take, for
    /// its thin end: the thin end in hundredths, less a thousandth, and a
    /// hundredth at least (1 → 0.999, 0.7 → 0.699, 0.625 → 0.619). Those
    /// fields write two decimals and compare what was typed, a Double, with
    /// this bound kept as a Float: without the slack a field refused its own
    /// text, «0.62» against Float(0.62) or against 0.625. The slab itself has
    /// no use for it: its thin end is the exact one.
    public static func intervalFieldMinimum(thinEnd: Double) -> Double {
        guard thinEnd.isFinite else { return 0.01 }
        // The hundredths of a spacing read from a Float (0.69999999) are those of its number.
        return max(0.01, (thinEnd * 100 + 1e-4).rounded(.towardZero) / 100 - 0.001)
    }

    public func thickness(at position: Double) -> Double {
        guard maximum > minimum, !position.isNaN, position > 0 else { return minimum }
        guard position < 1 else { return maximum }
        if exponential {
            return min(maximum, max(minimum, exp(log(minimum) + position * (log(maximum) - log(minimum)))))
        }
        return minimum + position * (maximum - minimum)
    }

    public func position(for thickness: Double) -> Double {
        guard maximum > minimum, !thickness.isNaN, thickness > minimum else { return 0 }
        guard thickness < maximum else { return 1 }
        if exponential {
            return (log(thickness) - log(minimum)) / (log(maximum) - log(minimum))
        }
        return (thickness - minimum) / (maximum - minimum)
    }

    /// The thickness the knob stops at for `position`: a whole unit (a
    /// millimeter in the MPR, a slice in the 2D viewer), with the scale's own
    /// ends kept as they are, so the thin end is still the volume's finest
    /// spacing and the thick end the whole volume. The curve alone gave 1.03, 1.57 or
    /// 2.61 mm.
    public func wholeThickness(at position: Double) -> Double {
        let raw = thickness(at: position)
        guard raw > minimum, raw < maximum else { return raw }
        return min(maximum, max(minimum, raw.rounded()))
    }

    /// The most intervals the marks divide the track in, from the ruler of a
    /// long track to that of a short one: the main marks only.
    private static let divisions = [10, 5, 2]

    /// Where the marks stand, both ends included, never closer than
    /// `minimumSpacing` of the track. Every mark stands where the knob stops,
    /// by the same curve: the knob reaches each of them, and stands on it.
    ///
    /// A linear scale counts whole units from its thin end in equal steps, so
    /// its marks are evenly spaced; the last step, to the thick end, is what
    /// the range leaves. An exponential scale marks the stops nearest to
    /// equal shares of the track, each the same ratio of thickness.
    public func tickPositions(minimumSpacing: Double) -> [Double] {
        guard maximum > minimum else { return [] }
        let spacing = minimumSpacing.isFinite ? max(minimumSpacing, 0) : 0
        guard let intervals = Self.divisions.first(where: { 1 / Double($0) >= spacing }) else { return [0, 1] }
        let (stops, step) = exponential ? curveStops(intervals) : evenStops(intervals)
        // A mark that would touch an end gives way to the end's own, and so
        // does one that leaves less than half a step before the thick end.
        let edge = max(spacing, 1e-9)
        var marks: [Double] = [0]
        for mark in stops.map({ position(for: $0) }) where mark - marks[marks.count - 1] >= edge && 1 - mark >= max(edge, step / 2) {
            marks.append(mark)
        }
        return marks + [1]
    }

    /// Whole units from the first one of the scale, in equal steps of as many
    /// units as `intervals` of them take to cover it; and a step's share of
    /// the track.
    private func evenStops(_ intervals: Int) -> (stops: [Double], step: Double) {
        // A thin end that is a whole unit is the first one itself, also when
        // its Float is a hair above the number (1.0000001).
        let first = (minimum - 0.002).rounded(.up)
        guard maximum > first else { return ([], 0) }
        let units = max(1, ((maximum - first) / Double(intervals)).rounded(.up))
        var stops: [Double] = []
        var value = first
        while value < maximum {
            stops.append(value)
            value += units
        }
        return (stops, units / (maximum - minimum))
    }

    /// The stops nearest to `intervals` equal shares of the track.
    private func curveStops(_ intervals: Int) -> (stops: [Double], step: Double) {
        ((1..<intervals).map { wholeThickness(at: Double($0) / Double(intervals)) }, 0)
    }
}
