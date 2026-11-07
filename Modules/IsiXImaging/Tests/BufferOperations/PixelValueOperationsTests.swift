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

// Invert Pixel Values and Normalize Series by ROI Mean on synthetic buffers.
// The inversion is checked against the rules of the version 1 Invert Data
// pilot (v → -v; colour c → 255 - c with alpha kept; level → -level, or
// 255 - level for colour), the normalization against values computed here in
// Double from a synthetic series and a rectangular ROI.

/// A synthetic CT-like slice: a ramp plus a per-slice offset, negative values
/// included, `width` × `height` floats.
private func syntheticSlice(width: Int, height: Int, slice: Int) -> [Float] {
    (0..<(width * height)).map { index in
        Float(index % width) * 3.5 - Float(index / width) * 2 + Float(slice) * 40 - 120
    }
}

@Suite struct PixelValueInversionTests {

    @Test func grayscaleBecomesItsNegativeEverySample() {
        // 7 × 3: a pixel count that is not a multiple of a vector width.
        let original = syntheticSlice(width: 7, height: 3, slice: 1)
        var pixels = original
        pixels.withUnsafeMutableBufferPointer { PixelInversion.invertGrayscale($0.baseAddress!, count: $0.count) }
        #expect(pixels == original.map { -$0 })

        // Twice gives the original back, bit for bit.
        pixels.withUnsafeMutableBufferPointer { PixelInversion.invertGrayscale($0.baseAddress!, count: $0.count) }
        #expect(pixels == original)
    }

    @Test func emptyImageIsLeftAlone() {
        var pixels: [Float] = [5]
        pixels.withUnsafeMutableBufferPointer { PixelInversion.invertGrayscale($0.baseAddress!, count: 0) }
        #expect(pixels == [5])
    }

    @Test func colourInvertsRedGreenBlueAndKeepsAlpha() {
        // ARGB, alpha first, as the viewer holds colour images.
        let original: [UInt8] = [255, 0, 128, 255,
                                 17, 10, 20, 30,
                                 0, 200, 1, 254]
        var bytes = original
        bytes.withUnsafeMutableBufferPointer { PixelInversion.invertARGB($0.baseAddress!, pixelCount: 3) }
        #expect(bytes == [255, 255, 127, 0,
                          17, 245, 235, 225,
                          0, 55, 254, 1])
        bytes.withUnsafeMutableBufferPointer { PixelInversion.invertARGB($0.baseAddress!, pixelCount: 3) }
        #expect(bytes == original)
    }

    @Test func colourStopsAtThePixelCount() {
        var bytes: [UInt8] = [1, 2, 3, 4, 9, 9, 9, 9]
        bytes.withUnsafeMutableBufferPointer { PixelInversion.invertARGB($0.baseAddress!, pixelCount: 1) }
        #expect(bytes == [1, 253, 252, 251, 9, 9, 9, 9])
    }

    @Test func windowMovesAcrossZeroOrTheMiddleOfTheColourRange() {
        #expect(PixelInversion.window(PixelWindow(level: 40, width: 400), colour: false) == PixelWindow(level: -40, width: 400))
        #expect(PixelInversion.window(PixelWindow(level: 100, width: 200), colour: true) == PixelWindow(level: 155, width: 200))
    }

    /// The inverted image through the inverted window is the original image
    /// through the original window, in negative: a value at the bottom of the
    /// window comes to the top.
    @Test func invertedWindowShowsTheNegative() {
        let window = PixelWindow(level: 40, width: 400)
        let inverted = PixelInversion.window(window, colour: false)
        func shown(_ value: Double, _ window: PixelWindow) -> Double {
            min(max((value - (window.level - window.width / 2)) / window.width, 0), 1)
        }
        for value in stride(from: -300.0, through: 300, by: 25) {
            #expect(abs(shown(-value, inverted) - (1 - shown(value, window))) < 1e-12)
        }
    }
}

@Suite struct PixelValueNormalizationTests {

    /// A series of three slices of 16 × 12 and a rectangle on slice 1: every
    /// pixel of every slice is divided by the rectangle's mean on slice 1 and
    /// multiplied by 100, so that mean becomes 100.
    @Test func seriesIsDividedByTheROIMeanAndMultiplied() throws {
        let width = 16, height = 12
        let original = (0..<3).map { syntheticSlice(width: width, height: height, slice: $0) }
        let rectangle = (x: 4..<10, y: 3..<8)

        // The mean of the rectangle, in Double, as the expectation.
        var sum = 0.0, count = 0
        for y in rectangle.y { for x in rectangle.x { sum += Double(original[1][y * width + x]); count += 1 } }
        let mean = sum / Double(count)
        #expect(mean != 0)

        let multiplier = 100.0
        let factor = try ROIMeanNormalization.factor(mean: mean, multiplier: multiplier).get()
        var series = original
        for index in series.indices {
            series[index].withUnsafeMutableBufferPointer { ROIMeanNormalization.scale($0.baseAddress!, count: $0.count, by: factor) }
        }

        for (slice, pixels) in series.enumerated() {
            for (index, value) in pixels.enumerated() {
                let expected = Double(original[slice][index]) / mean * multiplier
                #expect(abs(Double(value) - expected) <= 1e-4 * max(1, abs(expected)), "slice \(slice) pixel \(index)")
            }
        }

        var normalizedSum = 0.0
        for y in rectangle.y { for x in rectangle.x { normalizedSum += Double(series[1][y * width + x]) } }
        #expect(abs(normalizedSum / Double(count) - multiplier) < 1e-3)
    }

    @Test func negativeMeanFlipsTheSignOfThePixels() throws {
        let factor = try ROIMeanNormalization.factor(mean: -50, multiplier: 2).get()
        #expect(abs(factor + 0.04) < 1e-7)
        var pixels: [Float] = [-50, 0, 25]
        pixels.withUnsafeMutableBufferPointer { ROIMeanNormalization.scale($0.baseAddress!, count: $0.count, by: factor) }
        for (value, expected) in zip(pixels, [Float(2), 0, -1]) { #expect(abs(value - expected) < 1e-6) }
    }

    @Test func refusals() {
        #expect(ROIMeanNormalization.factor(mean: 0, multiplier: 1) == .failure(.zeroMean))
        #expect(ROIMeanNormalization.factor(mean: .nan, multiplier: 1) == .failure(.undefinedMean))
        #expect(ROIMeanNormalization.factor(mean: .infinity, multiplier: 1) == .failure(.undefinedMean))
        #expect(ROIMeanNormalization.factor(mean: 10, multiplier: 0) == .failure(.invalidMultiplier))
        #expect(ROIMeanNormalization.factor(mean: 10, multiplier: .nan) == .failure(.invalidMultiplier))
        #expect(ROIMeanNormalization.factor(mean: 1e-300, multiplier: 1e10) == .failure(.outOfRange))
    }

    /// The scaled window over the scaled pixels shows what the original
    /// window showed over the original ones.
    @Test func windowFollowsThePixels() {
        let window = PixelWindow(level: 40, width: 400)
        #expect(ROIMeanNormalization.window(window, factor: 0.5) == PixelWindow(level: 20, width: 200))
        #expect(ROIMeanNormalization.window(window, factor: -2) == PixelWindow(level: -80, width: 800))
    }
}
