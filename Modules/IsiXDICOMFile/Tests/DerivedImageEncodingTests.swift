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
@testable import IsiXDICOMFile

@Suite struct DerivedImageEncodingTests {

    @Test func wholeValuesAreExact() {
        let values: [Float] = [-1024, 0, 40, 3071, -32768, 32767]
        let encoded = DerivedImageEncoding.signed16(values)
        #expect(encoded.slope == 1)
        #expect(encoded.samples.map(Float.init) == values)
    }

    @Test func otherValuesAreScaledToTheRange() {
        let values: [Float] = [0.25, -1.5, 100000, 3.75]
        let encoded = DerivedImageEncoding.signed16(values)
        #expect(abs(encoded.slope - 100000.0 / 32767) < 1e-9)
        #expect(encoded.samples[2] == 32767)
        for (sample, value) in zip(encoded.samples, values) {
            #expect(abs(Double(sample) * encoded.slope - Double(value)) <= encoded.slope / 2 + 1e-9)
        }
        let fractions = DerivedImageEncoding.signed16([0.5, -0.25])
        #expect(fractions.samples == [32767, -16384] && abs(fractions.slope - 0.5 / 32767) < 1e-12)
    }

    @Test func aSlopeOfSixDecimalsIsTheOneTheSamplesUse() {
        let values: [Float] = (0..<24).map { Float($0 * 3 - 20) * 0.5 }
        let encoded = DerivedImageEncoding.signed16(values, slopeDecimals: 6)
        #expect(encoded.slope == 0.000748)
        #expect(String(format: "%f", encoded.slope) == "0.000748")
        for (sample, value) in zip(encoded.samples, values) {
            #expect(abs(Double(sample) * encoded.slope - Double(value)) <= encoded.slope / 2 + 1e-12)
        }
        #expect(DerivedImageEncoding.signed16([1e-9, -2e-9], slopeDecimals: 6).slope == 0.000001)
    }

    @Test func emptyAndNotFiniteValues() {
        #expect(DerivedImageEncoding.signed16([]).samples.isEmpty)
        let encoded = DerivedImageEncoding.signed16([.nan, 2, .infinity])
        #expect(encoded.slope == 1 && encoded.samples == [0, 2, 0])
    }
}
