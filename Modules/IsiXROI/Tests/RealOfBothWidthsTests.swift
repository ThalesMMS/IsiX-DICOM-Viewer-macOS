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
@testable import IsiXROI

@Suite struct RealOfBothWidthsTests {

    /// What a caller that reads a float finds in the register of `answered`.
    private func asFloat(_ answered: Double) -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: answered.bitPattern))
    }

    /// What a caller that passes a float leaves in the register on arm64.
    private func passed(_ value: Float) -> Double {
        Double(bitPattern: UInt64(value.bitPattern))
    }

    @Test func bothReadingsFindTheValue() {
        for value in [25.0, 0.1, -1234.5678, 3.0e9, 1.0e-12, 65535.0, -0.25, Double.pi * 1.0e6] {
            let answered = RealOfBothWidths.answered(value)
            #expect(asFloat(answered) == Float(value))
            #expect(abs(answered - value) <= abs(value) * 1.0e-6)
        }
    }

    @Test func zeroInfinityAndNoNumber() {
        #expect(RealOfBothWidths.answered(0).bitPattern == 0)
        #expect(asFloat(RealOfBothWidths.answered(0)) == 0)
        #expect(RealOfBothWidths.answered(.infinity) == .infinity)
        #expect(RealOfBothWidths.answered(-.infinity) == -.infinity)
        let none = RealOfBothWidths.answered(.nan)
        #expect(none.isNaN && asFloat(none).isNaN)
        // Past what a float holds, the float reading is infinite and the double one keeps its value.
        let large = RealOfBothWidths.answered(1.0e300)
        #expect(asFloat(large) == .infinity && abs(large - 1.0e300) <= 1.0e294)
    }

    @Test func aDoubleGivenIsTakenAsItIs() {
        for value in [25.0, 0.0, -0.5, 1.0e-200, Double.infinity] {
            #expect(RealOfBothWidths.taken(value) == value)
        }
        #expect(RealOfBothWidths.taken(.nan).isNaN)
        // What was answered comes back within the same part in a million.
        #expect(abs(RealOfBothWidths.taken(RealOfBothWidths.answered(33.25)) - 33.25) <= 33.25e-6)
    }

    #if arch(arm64)
    @Test func aFloatGivenIsTakenAsTheFloat() {
        for value: Float in [12.5, -3.75, 1.0e-30, 0.1, -0.0] {
            #expect(RealOfBothWidths.taken(passed(value)) == Double(value))
        }
        #expect(RealOfBothWidths.taken(passed(.nan)).isNaN)
        #expect(RealOfBothWidths.taken(passed(.infinity)) == .infinity)
        #expect(RealOfBothWidths.taken(passed(0)) == 0)
    }
    #endif
}
