//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXImaging

@Suite struct FusionComparisonTests {

    @Test func blendFollowsTheSlider() {
        #expect(FusionComparison.blend(value: 0, minimum: -256, maximum: 256) == 0.5)
        #expect(FusionComparison.blend(value: 256, minimum: -256, maximum: 256) == 1)
        #expect(FusionComparison.blend(value: 7, minimum: 3, maximum: 3) == 0.5)
        #expect(FusionComparison.sliderValue(stop: 0, minimum: -256, maximum: 256) == -256)
        #expect(FusionComparison.sliderValue(stop: 1, minimum: -256, maximum: 256) == 256)
        for stop in [0.0, 0.25, 0.5, 1] {
            let value = FusionComparison.sliderValue(stop: stop, minimum: -256, maximum: 256)
            #expect(FusionComparison.blend(value: value, minimum: -256, maximum: 256) == stop)
        }
    }

    @Test func offsetCountsWhatIsNotANumberAsZero() {
        #expect(FusionComparison.offset([1.5, .nan, -.infinity]) == [1.5, 0, 0])
    }

    @Test func boundsEncloseThePoints() {
        let box = FusionComparison.bounds(of: [SIMD3(1, -2, 3), SIMD3(-4, 5, 0.5)])
        #expect(box.minimum == [-4, -2, 0.5] && box.maximum == [1, 5, 3])
        let empty = FusionComparison.bounds(of: [])
        #expect(empty.minimum.allSatisfy { $0 == .infinity } && empty.maximum.allSatisfy { $0 == -.infinity })
    }
}
