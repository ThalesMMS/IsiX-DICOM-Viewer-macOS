//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

/// The operations on a loaded image on their own. The comparison with the
/// Objective-C operations they replaced is tests/test-dcmpix-buffer-operations.py.
struct BufferOperationsTests {
    @Test func aRequestOfZeroWidthOrNotANumberIsTheFullWindow() {
        #expect(ImageWindow.requested(level: 40, width: 0, fullWidth: 1000, slope: 1) == nil)
        #expect(ImageWindow.requested(level: .nan, width: 400, fullWidth: 1000, slope: 1) == nil)
        #expect(ImageWindow.requested(level: 40, width: .infinity, fullWidth: 1000, slope: 1) == nil)
    }

    @Test func aWideImageIsWindowedInWholeValues() {
        let rounded = ImageWindow.requested(level: 100.6, width: 300.3, fullWidth: 1000, slope: 1)
        #expect(rounded?.level == 100 && rounded?.width == 300)
        let fromZero = ImageWindow.requested(level: 150, width: 300, fullWidth: 1000, slope: 1)
        #expect(fromZero?.level == 150 && fromZero?.width == 300)
        let narrow = ImageWindow.requested(level: 3.3, width: 1.7, fullWidth: 100, slope: 1)
        #expect(narrow?.level == 3.3 && narrow?.width == 1.7)
        #expect(ImageWindow.requested(level: 5, width: 0.0001, fullWidth: 100, slope: 3)?.width == Float(0.001 * 3.0))
    }

    @Test func theFullWindowSpansTheValuesAndAFlatImageGetsTwenty() {
        let values: [Float] = [-10, 30, 5]
        let full = values.withUnsafeBufferPointer { ImageWindow.full($0.baseAddress!, count: 3, isRGB: false) }
        #expect(full.level == 10 && full.width == 40)
        let flat = [Float](repeating: 42, count: 4).withUnsafeBufferPointer { ImageWindow.full($0.baseAddress!, count: 4, isRGB: false) }
        #expect(flat.level == 52 && flat.width == 20)
        let colour = values.withUnsafeBufferPointer { ImageWindow.full($0.baseAddress!, count: 3, isRGB: true) }
        #expect(colour.level == 127.5 && colour.width == 255)
    }

    @Test func aShiftedDifferenceIsZeroWhereTheOtherImageHasNoPixel() {
        let a: [Float] = [1, 2, 3, 4, 5, 6], b: [Float] = [10, 20, 30, 40, 50, 60]
        let result = a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                ImageArithmetic.difference(a.baseAddress!, b.baseAddress!, width: 3, height: 2, offset: CGPoint(x: 1, y: 0), absolute: true)
            }
        }
        defer { free(result) }
        #expect(Array(UnsafeBufferPointer(start: result, count: 6)) == [0, 8, 17, 0, 35, 44])
    }

    @Test func theSubtractionWindowIsHeldAndStandsForAGammaAndAZero() {
        let window = SubtractionSliders.window(level: 600, width: 1)
        #expect(window.level == 512 && window.width == 2)
        #expect(window.gamma == Float(2.0 * (2.0 / 256.0)))
        #expect(window.zero == Float(1.6 - 0.8 * 4.0))
        #expect(SubtractionSliders(percent: 1, gamma: 1, zero: 0.9).zero == Float(0.9))
    }

    @Test func aSubtractionIsNormalizedByTheRangeOfTheSeries() {
        let frame: [Float] = [4, 8], mask: [Float] = [2, 2]
        let range = frame.withUnsafeBufferPointer { f in mask.withUnsafeBufferPointer { MaskSubtractionImage.range(frame: f.baseAddress!, mask: $0.baseAddress!, count: 2) } }
        #expect(range == CGPoint(x: 2, y: 6))
        var sliders = SubtractionSliders(percent: 1, gamma: 1, zero: 0.8)
        sliders.zero = 0.5
        let result = frame.withUnsafeBufferPointer { f in
            mask.withUnsafeBufferPointer {
                MaskSubtractionImage.subtract(frame: f.baseAddress!, mask: $0.baseAddress!, width: 2, height: 1, offset: .zero,
                                              sliders: sliders, range: range)
            }
        }
        defer { free(result) }
        let expected: [Float] = [1, 2]
        #expect(Array(UnsafeBufferPointer(start: result, count: 2)) == expected)
    }

    @Test func aColourWindowOfZeroWidthLeavesTheFrameAsItIsAboveTheLevel() {
        let table = WindowRendering.colourTable(level: 128, window: 0, table: nil)
        #expect(table[127] == 0 && table[128] == 0 && table[129] == 255)
        let identity = WindowRendering.colourTable(level: 127.5, window: 255, table: nil)
        #expect(identity == (0..<256).map { UInt8($0) })
    }

    @Test func theTransferFunctionGivesTheShadeOfEachValue() {
        let pixels: [Float] = [-1, 0, 50, 100, 200]
        var picture = [UInt8](repeating: 7, count: 5)
        let table = (0..<4096).map { Float($0) / 4095 }
        pixels.withUnsafeBufferPointer { p in
            picture.withUnsafeMutableBufferPointer { out in
                table.withUnsafeBufferPointer {
                    WindowRendering.throughTable(p.baseAddress!, into: out.baseAddress!, width: 5, height: 1, level: 50, window: 100,
                                                 table: $0.baseAddress!, threads: 3)
                }
            }
        }
        #expect(picture == [0, 0, 127, 255, 255])
    }

    @Test func invertingTurnsBlackToWhite() {
        var picture: [UInt8] = [0, 1, 254, 255]
        picture.withUnsafeMutableBufferPointer { WindowRendering.invert($0.baseAddress!, count: 4) }
        #expect(picture == [255, 254, 1, 0])
    }

    @Test func theConvolutionKeepsAFlatImageAndRepeatsTheFirstPixelOnTheFirstRow() {
        var weights = [Float](repeating: 0, count: 25)
        weights[0..<9] = [0, -1, 0, -1, 5, -1, 0, -1, 0]
        let flat = [Float](repeating: 3, count: 20)
        let result = weights.withUnsafeBufferPointer { w in
            flat.withUnsafeBufferPointer { ImageConvolution(weights: w.baseAddress!, size: 3, normalization: 1).filtered($0.baseAddress!, width: 5, height: 4) }
        }
        defer { free(result) }
        #expect(Array(UnsafeBufferPointer(start: result, count: 20)) == flat)
    }

    @Test func theDoseDecaysFromInjectionToAcquisition() {
        let injection = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let corrected = SUVComputation.correctedDose(decayCorrection: "START", dose: 1000, halflife: 100, injection: injection,
                                                     acquisition: injection.addingTimeInterval(100))
        #expect(abs(corrected.dose - 500) < 0.001 && corrected.decayFactor == nil)
        let admin = SUVComputation.correctedDose(decayCorrection: "ADMIN", dose: 1000, halflife: 0, injection: nil, acquisition: nil)
        #expect(admin.dose == 1000 && admin.decayFactor == 1)
        #expect(SUVComputation.correctedDose(decayCorrection: "START", dose: 1000, halflife: 100, injection: injection,
                                             acquisition: injection.addingTimeInterval(-5)).dose == 0)
    }

    @Test func anImageHasSUVOnlyWithWhatSUVNeeds() {
        func check(_ units: String?, _ decay: String?, philips: Float = 0, factor: Float = 1, halflife: Float = 6586,
                   times: Bool = true, dose: Float = 1, rgb: Bool = false) -> SUVComputation.Availability {
            SUVComputation.availability(units: units, decayCorrection: decay, philipsFactor: philips, decayFactor: factor, halflife: halflife,
                                        hasInjectionAndAcquisition: times, dose: dose, isRGB: rgb)
        }
        #expect(check("BQML", "START") == .init(hasSUV: true, correctsDose: false))
        #expect(check("BQML", "ADMIN", factor: 0, halflife: 0, times: false) == .init(hasSUV: true, correctsDose: true))
        #expect(check("CNTS", "START").hasSUV == false)
        #expect(check("CNTS", "START", philips: 0.5).hasSUV)
        #expect(check("BQML", "NONE", rgb: true) == .init(hasSUV: false, correctsDose: true))
        #expect(check("GML", "START").hasSUV == false)
        #expect(check("BQML", "START", times: false).hasSUV == false)
        #expect(check("BQML", "START", dose: 0).hasSUV == false)
    }
}
