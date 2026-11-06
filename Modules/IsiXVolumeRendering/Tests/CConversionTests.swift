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
@testable import IsiXVolumeRendering

/// The C casts of the 3D view's former Objective-C as arm64 computed them:
/// toward zero, saturated, NaN to 0, where Swift's initialisers stop.
struct CConversionTests {

    @Test func truncatesTowardZero() {
        #expect(CConversion.long(2.9) == 2)
        #expect(CConversion.long(-2.9) == -2)
        #expect(CConversion.int(Float(106.5)) == 106)
        #expect(CConversion.long(Double(Float(105.99999))) == 105)
    }

    @Test func saturatesAndTakesNaNToZero() {
        #expect(CConversion.long(Double.nan) == 0)
        #expect(CConversion.long(1e300) == Int.max)
        #expect(CConversion.long(-1e300) == Int.min)
        #expect(CConversion.int(Double.infinity) == Int32.max)
        #expect(CConversion.int(-Double.infinity) == Int32.min)
        #expect(CConversion.int(Double.nan) == 0)
    }

    @Test func shortKeepsTheLowBitsOfTheInt() {
        #expect(CConversion.short(70000) == Int16(truncatingIfNeeded: 70000))
        #expect(CConversion.short(-3.7) == -3)
    }
}
