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
import Testing
@testable import IsiXImaging

@Suite struct ThickSlabSliderScaleTests {

    /// The thicknesses of the marks, as the knob standing on each gives them.
    private func values(_ scale: ThickSlabSliderScale, spacing: Double) -> [Double] {
        scale.tickPositions(minimumSpacing: spacing).map { (scale.thickness(at: $0) * 1000).rounded() / 1000 }
    }

    @Test func aLinearRulerCountsEqualStepsOfWholeUnitsFromItsThinEnd() {
        // A series of 128 slices on a long track: steps of 13 slices, and what
        // the series leaves before its last slice.
        let slices = ThickSlabSliderScale(minimum: 1, maximum: 128, exponential: false)
        #expect(values(slices, spacing: 8.0 / 172) == [1, 14, 27, 40, 53, 66, 79, 92, 105, 118, 128])
        // A mark that would leave less than half a step gives way to the end.
        #expect(values(ThickSlabSliderScale(minimum: 1, maximum: 122, exponential: false), spacing: 8.0 / 172)
                == [1, 14, 27, 40, 53, 66, 79, 92, 105, 122])
        // A short track keeps five steps.
        #expect(values(slices, spacing: 0.15) == [1, 27, 53, 79, 105, 128])
        // And the shortest, two.
        #expect(values(slices, spacing: 0.3) == [1, 65, 128])
        #expect(values(slices, spacing: 0.6) == [1, 128])
    }

    @Test func aShortSeriesMarksEverySlice() {
        let slices = ThickSlabSliderScale(minimum: 1, maximum: 7, exponential: false)
        #expect(values(slices, spacing: 0.05) == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func theMarksOfAVolumeAreEvenlySpacedFromTheSliceInterval() {
        // The thin end is the volume's finest spacing, 1 mm here; the volume
        // is 347.3 mm across.
        let scale = ThickSlabSliderScale(minimum: 1, maximum: 347.3, exponential: false)
        let marks = scale.tickPositions(minimumSpacing: 0.05)
        #expect(values(scale, spacing: 0.05) == [1, 36, 71, 106, 141, 176, 211, 246, 281, 316, 347.3])
        // A thin end below a millimetre keeps its own mark, and the whole millimetres theirs.
        let fine = ThickSlabSliderScale(minimum: 0.7, maximum: 180, exponential: false)
        #expect(values(fine, spacing: 0.05) == [0.7, 19, 37, 55, 73, 91, 109, 127, 145, 163, 180])
        let gaps = zip(marks, marks.dropFirst()).map { $1 - $0 }.dropLast()
        #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 1e-4 })
    }

    @Test func theThinEndIsTheFinestSpacingOfTheVolume() {
        func thin(_ interval: Double, _ thickness: Double, _ pixel: Double) -> Double {
            ThickSlabSliderScale.thinEnd(sliceInterval: interval, sliceThickness: thickness, pixelSpacingX: pixel, pixelSpacingY: pixel)
        }
        // Slices 2 mm thick every 1 mm and every 2 mm, 0.625 mm ones, and a series that does not say its thickness.
        #expect(thin(1, 2, 1) == 1)
        #expect(thin(2, 2, 1) == 1)
        #expect(thin(1, 2, 0.7) == 0.7)
        #expect(thin(0.625, 0.625, 0.7) == 0.625)
        #expect(thin(1.25, 0, 0.8) == 0.8)
        // A reversed stack counts as its interval's magnitude.
        #expect(thin(-1, 2, 1) == 1)
        #expect(thin(-0.5, 2, 1) == 0.5)
        // No interval: the slices' thickness.
        #expect(thin(0, 0.5, 1) == 0.5)
        #expect(thin(.nan, 2, 0.7) == 0.7)
        #expect(thin(.nan, 0.4, 0.7) == 0.4)
        // Pixels that say nothing.
        #expect(thin(1.5, 2, 0) == 1.5)
        #expect(thin(1.5, 2, .nan) == 1.5)
        #expect(thin(1.5, 2, -0.7) == 1.5)
        #expect(ThickSlabSliderScale.thinEnd(sliceInterval: 3, sliceThickness: 3, pixelSpacingX: 0, pixelSpacingY: 0.9) == 0.9)
        // Nothing known.
        #expect(thin(0, 0, 0) == 1)
        #expect(thin(.nan, .nan, .nan) == 1)
        #expect(thin(.infinity, .infinity, .infinity) == 1)
        for interval in [0, 1, -1, 0.3, .nan, .infinity] {
            for thickness in [0, 2, .nan, -1] {
                for pixel in [0, 0.7, .nan, -3, .infinity] {
                    let end = thin(interval, thickness, pixel)
                    #expect(end.isFinite && end > 0)
                    // Where the reslice has a sample step and the pixels a size, it is the thin end.
                    if pixel > 0, pixel.isFinite, let step = MPRPlaneRules.sampleStep(sliceInterval: interval, sliceThickness: thickness, pixelSpacingX: pixel, pixelSpacingY: pixel) {
                        #expect(step == end)
                    }
                }
            }
        }
    }

    @Test func theExportIntervalKeepsItsSlackUnderTheThinEnd() {
        #expect(abs(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: 1) - 0.999) < 1e-12)
        #expect(abs(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: 0.7) - 0.699) < 1e-12)
        #expect(abs(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: 0.625) - 0.619) < 1e-12)
        #expect(abs(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: 0.4) - 0.399) < 1e-12)
        // A spacing that came through a Float.
        #expect(abs(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: Double(Float(0.7))) - 0.699) < 1e-12)
        #expect(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: 0.004) == 0.01)
        #expect(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: .nan) == 0.01)
        // The field's two decimals of the thin end are never below the bound kept as a Float.
        for thin in [0.4, 0.625, 0.7, 1, 1.25, 2] {
            let bound = Double(Float(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: thin)))
            #expect((thin * 100).rounded(.down) / 100 >= bound)
        }
    }

    @Test func theEndsOfAScaleAreItsOwn() {
        for exponential in [false, true] {
            let scale = ThickSlabSliderScale(minimum: 0.625, maximum: 359, exponential: exponential)
            #expect(scale.thickness(at: 0) == 0.625)
            #expect(scale.wholeThickness(at: 0) == 0.625)
            #expect(scale.wholeThickness(at: 1) == 359)
            #expect(scale.position(for: 0.625) == 0)
        }
        // A volume no thicker than its thin end: one thickness.
        let flat = ThickSlabSliderScale(minimum: 2, maximum: 1, exponential: true)
        #expect(flat.thickness(at: 0.5) == 2)
        #expect(flat.tickPositions(minimumSpacing: 0.05).isEmpty)
    }

    @Test func everyMarkOfALinearRulerIsWhereTheKnobStops() {
        for (minimum, maximum) in [(1.0, 128.0), (1.0, 347.3), (0.6, 100.0), (0.625, 100.0), (0.7, 180.0), (2.5, 51.0), (1.0, 3.0)] {
            let scale = ThickSlabSliderScale(minimum: minimum, maximum: maximum, exponential: false)
            for spacing in [0.02, 0.05, 0.12, 0.3] {
                for mark in scale.tickPositions(minimumSpacing: spacing) {
                    #expect(abs(scale.wholeThickness(at: mark) - scale.thickness(at: mark)) < 1e-6)
                }
            }
        }
    }

    @Test func anExponentialRulerGathersItsMarksTowardsItsThickEnd() {
        let track = 8.0 / 172
        for (minimum, maximum) in [(1.0, 350.0), (2.0, 687.0), (0.625, 400.0), (1.0, 128.0), (2.0, 20.0), (2.5, 51.0)] {
            let scale = ThickSlabSliderScale(minimum: minimum, maximum: maximum, exponential: true)
            let marks = scale.tickPositions(minimumSpacing: track)
            #expect(marks.first == 0 && marks.last == 1 && marks.count == 17)
            let gaps = zip(marks, marks.dropFirst()).map { $1 - $0 }
            // Each step is shorter than the one before it, whatever the range.
            #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $1 < $0 }, "\(minimum) to \(maximum): gaps \(gaps)")
            #expect((gaps.last ?? 0) >= track / 3 - 1e-12)
            // The thicknesses marked grow by steps that grow by the same amount.
            let marked = marks.map { scale.thickness(at: $0) }
            let steps = zip(marked, marked.dropFirst()).map { $1 - $0 }
            let growth = zip(steps, steps.dropFirst()).map { $1 - $0 }
            #expect(growth.allSatisfy { abs($0 - growth[0]) < 1e-6 * maximum }, "steps \(steps)")
        }
        // 2 to 687 mm, the track of a long series: the first mark at a quarter of the track, where equal steps of
        // thickness had it past the middle, and the last two as close as 3.6 points.
        let long = ThickSlabSliderScale(minimum: 2, maximum: 687, exponential: true).tickPositions(minimumSpacing: track)
        #expect(long[1] > 0.2 && long[1] < 0.3 && long.filter { $0 > 0 && $0 < 0.61 }.count >= 4)
        #expect(1 - long[long.count - 2] < 0.025)
        // A short track has fewer marks, and a scale of few stops no more intervals than stops.
        let scale = ThickSlabSliderScale(minimum: 1, maximum: 350, exponential: true)
        #expect(scale.tickPositions(minimumSpacing: 0.2).count == 6)
        #expect(scale.tickPositions(minimumSpacing: track, most: 5).count == 6)
        #expect(scale.tickPositions(minimumSpacing: track, most: 1) == [0, 1])
        #expect(scale.tickPositions(minimumSpacing: 2) == [0, 1])
        // The linear ruler of the same range stays evenly spaced.
        let even = ThickSlabSliderScale(minimum: 1, maximum: 350, exponential: false).tickPositions(minimumSpacing: track)
        let evenGaps = zip(even, even.dropFirst()).map { $1 - $0 }.dropLast()
        #expect((evenGaps.max() ?? 1) - (evenGaps.min() ?? 0) < 1e-12)
    }

    @Test func marksKeepTheirDistanceAndBothEnds() {
        let scales = [ThickSlabSliderScale(minimum: 1, maximum: 128, exponential: false),
                      ThickSlabSliderScale(minimum: 1, maximum: 128, exponential: true),
                      ThickSlabSliderScale(minimum: 0.6, maximum: 100, exponential: true),
                      ThickSlabSliderScale(minimum: 0.6, maximum: 100, exponential: false),
                      ThickSlabSliderScale(minimum: 1, maximum: 2, exponential: true)]
        for scale in scales {
            for spacing in [0, 0.01, 0.03, 0.2, 2, Double.nan] {
                let marks = scale.tickPositions(minimumSpacing: spacing)
                #expect(marks.first == 0 && marks.last == 1 && marks.count <= (scale.exponential ? 17 : 12))
                // The last marks of an exponential ruler stand three times closer.
                let least = (spacing.isNaN ? 0 : min(spacing, 1)) / (scale.exponential ? ThickSlabSliderScale.exponentialCrowding : 1) - 1e-12
                #expect(zip(marks, marks.dropFirst()).allSatisfy { $1 - $0 >= least && $1 > $0 })
            }
        }
    }

    @Test func theThickEndIsTheWholeVolume() {
        // 512 x 512 pixels of 0.7 mm and 695 slices every 0.5 mm.
        #expect(ThickSlabSliderScale.volumeMaximum(sides: [358.4, 358.4, 347.5], fallback: 100) == 359)
        // A long scan is longest along its slices.
        #expect(ThickSlabSliderScale.volumeMaximum(sides: [350, 350, 1820.25], fallback: 100) == 1821)
        // A small volume has a short ruler; one of unknown size keeps the ruler it had.
        #expect(ThickSlabSliderScale.volumeMaximum(sides: [60.2, 60.2, 12], fallback: 100) == 61)
        #expect(ThickSlabSliderScale.volumeMaximum(sides: [.nan, 0, -3, .infinity], fallback: 100) == 100)
        #expect(ThickSlabSliderScale.volumeMaximum(sides: [], fallback: 100) == 100)
    }

    @Test func aScaleWithoutARangeHasNoRuler() {
        for (minimum, maximum) in [(0.0, 0.0), (3.0, 2.0), (Double.nan, Double.infinity)] {
            let scale = ThickSlabSliderScale(minimum: minimum, maximum: maximum, exponential: true)
            #expect(scale.thickness(at: 0.5).isFinite && scale.position(for: 1) == 0)
            #expect(scale.tickPositions(minimumSpacing: 0.02).isEmpty)
        }
    }

    @Test func theKnobStopsAtWholeUnitsBetweenItsEnds() {
        for exponential in [false, true] {
            let scale = ThickSlabSliderScale(minimum: 0.6, maximum: 347.3, exponential: exponential)
            #expect(scale.wholeThickness(at: 0) == 0.6 && scale.wholeThickness(at: 1) == 347.3)
            var last = 0.6
            for step in 1..<1000 {
                let position = Double(step) / 1000
                let stop = scale.wholeThickness(at: position)
                #expect(stop == 0.6 || stop == 347.3 || stop == stop.rounded())
                #expect(stop >= last && abs(stop - scale.thickness(at: position)) <= 0.5 + 1e-9)
                last = stop
            }
        }
        #expect(ThickSlabSliderScale(minimum: 0.3, maximum: 100, exponential: true).wholeThickness(at: 0.01) == 0.3)
    }
}
