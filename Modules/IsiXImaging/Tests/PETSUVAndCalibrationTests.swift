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

@Suite struct PETSUVConversionTests {

    @Test func convertibleValues() {
        #expect(PETSUVConversion.canConvert(isRGB: false, units: "BQML", philipsFactor: 0, radionuclideTotalDoseCorrected: 3e8, patientsWeight: 70, hasSUV: true))
        #expect(!PETSUVConversion.canConvert(isRGB: true, units: "BQML", philipsFactor: 0, radionuclideTotalDoseCorrected: 3e8, patientsWeight: 70, hasSUV: true))
        #expect(!PETSUVConversion.canConvert(isRGB: false, units: "BQML", philipsFactor: 0, radionuclideTotalDoseCorrected: 0, patientsWeight: 70, hasSUV: true))
        #expect(!PETSUVConversion.canConvert(isRGB: false, units: nil, philipsFactor: 0, radionuclideTotalDoseCorrected: 3e8, patientsWeight: -1, hasSUV: true))
        #expect(!PETSUVConversion.canConvert(isRGB: false, units: "BQML", philipsFactor: 0, radionuclideTotalDoseCorrected: 3e8, patientsWeight: 70, hasSUV: false))
        // Philips counts with their factor need neither dose nor weight.
        #expect(PETSUVConversion.canConvert(isRGB: false, units: "CNTS", philipsFactor: 0.5, radionuclideTotalDoseCorrected: 0, patientsWeight: 0, hasSUV: true))
        #expect(!PETSUVConversion.canConvert(isRGB: false, units: "CNTS", philipsFactor: 0, radionuclideTotalDoseCorrected: 0, patientsWeight: 70, hasSUV: true))
    }

    @Test func theFactorMultipliesTheDoseAndDecayInFloat() {
        let dose: Float = 3.1e8, decay: Float = 1.0625
        #expect(PETSUVConversion.factor(units: "BQML", philipsFactor: 9, patientsWeight: 70.5, radionuclideTotalDoseCorrected: dose, decayFactor: decay)
                == 70.5 * 1000.0 / Double(dose * decay))
        #expect(PETSUVConversion.factor(units: "CNTS", philipsFactor: 0.00125, patientsWeight: 70.5, radionuclideTotalDoseCorrected: dose, decayFactor: decay)
                == Double(Float(0.00125)))
    }

    @Test func scalesEveryPixel() {
        var pixels: [Float] = [1, -2.5, 3]
        pixels.withUnsafeMutableBufferPointer { PETSUVConversion.scale($0.baseAddress!, count: 2, by: 1.5) }
        #expect(pixels == [1.5, -3.75, 3])
        pixels.withUnsafeMutableBufferPointer { PETSUVConversion.scale($0.baseAddress!, count: -1, by: 2) }
        #expect(pixels == [1.5, -3.75, 3])
    }
}

@Suite struct CalibrationNumberTests {

    private let french = Locale(identifier: "fr_FR"), american = Locale(identifier: "en_US")

    @Test func theLocaleThenPOSIX() {
        #expect(CalibrationNumber.parse("1,5", locale: french) == 1.5)
        #expect(CalibrationNumber.parse("1.5", locale: french) == 1.5)
        #expect(CalibrationNumber.parse(" 2.25\n", locale: american) == 2.25)
        #expect(CalibrationNumber.parse("-0", locale: american) == 0)
    }

    @Test func refusals() {
        for entry in ["", "  ", "abc", "1.5x", "1e39", "inf", "nan", "1e-50"] {
            #expect(CalibrationNumber.parse(entry, locale: american) == nil, "\(entry)")
        }
        // The smallest float is still a number.
        #expect(CalibrationNumber.parse("1e-45", locale: american) == Float.leastNonzeroMagnitude)
    }
}
