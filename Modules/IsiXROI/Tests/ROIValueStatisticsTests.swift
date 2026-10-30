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

@Suite struct ROIValueStatisticsTests {

    static func statistics(_ values: [Float]) -> ROIValueStatistics? {
        values.withUnsafeBufferPointer { ROIValueStatistics.of($0) }
    }

    @Test func noValues() {
        #expect(Self.statistics([]) == nil)
    }

    @Test func values() throws {
        let s = try #require(Self.statistics([4, -2, 10, 0.5]))
        #expect(s.min == -2 && s.max == 10)
        #expect(s.total == 12.5 && s.mean == 3.125)
        // Each squared distance is a Float: 0.765625, 26.265625, 47.265625, 6.890625.
        #expect(s.deviation == (81.1875 / 3).squareRoot())
    }

    @Test func squaredDistancesAreRoundedToFloat() throws {
        let s = try #require(Self.statistics([0.1, 0.2, 0.7]))
        var expected = 0.0
        for v: Float in [0.1, 0.2, 0.7] {
            var d = Float(s.mean - Double(v))
            d *= d
            expected += Double(d)
        }
        #expect(s.deviation == (expected / 2).squareRoot())
    }

    @Test func oneValueHasNoDeviation() throws {
        let s = try #require(Self.statistics([7]))
        #expect(s.mean == 7 && s.deviation.isNaN)
    }
}

@Suite struct ROIVolumePointsTests {

    @Test func keptUnlessMoreThanTwiceTheLimit() {
        #expect(ROIVolumePoints.keptIndices(count: 14_000) == nil)
        #expect(Array(ROIVolumePoints.keptIndices(count: 14_001) ?? stride(from: 0, to: 0, by: 1)).count == 7001)
        let kept = Array(ROIVolumePoints.keptIndices(count: 21_005) ?? stride(from: 0, to: 0, by: 1))
        #expect(kept.first == 0 && kept[1] == 3 && kept.last == 21_003)
    }
}
