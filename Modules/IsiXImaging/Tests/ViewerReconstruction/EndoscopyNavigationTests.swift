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

@Suite struct EndoscopyNavigationTests {

    @Test func aPathPointBetweenTwoSlicesIsBlended() {
        let between = EndoscopyNavigation.slices(around: 12.5, count: 40)
        #expect(between.lower == 12 && between.upper == 13 && between.fraction == 0.5)
        let on = EndoscopyNavigation.slices(around: 7, count: 40)
        #expect(on.lower == 7 && on.fraction == 0)
        // Half a slice past the last one, as the centre of the last resampled voxel is; before the first; no stack.
        let past = EndoscopyNavigation.slices(around: 39.5, count: 40)
        #expect(past.lower == 39 && past.upper == 39 && past.fraction == 0)
        let before = EndoscopyNavigation.slices(around: -0.5, count: 40)
        #expect(before.lower == 0 && before.fraction == 0)
        #expect(EndoscopyNavigation.slices(around: 3, count: 0) == (0, 0, 0))
        #expect(EndoscopyNavigation.slices(around: .nan, count: 40) == (0, 0, 0))
        #expect(EndoscopyNavigation.blend([0, 10, -4], [2, 20, -5], at: 0.5) == [1, 15, -4.5])
        #expect(EndoscopyNavigation.blend([0, 10, -4], [2, 20, -5], at: 0) == [0, 10, -4])
    }

    @Test func theCrossRowGivesTheSliceInBothOrders() {
        // Slice 3 of 10: its row is 6 with a positive sign (cross at 6.5), 3 otherwise (cross at 3.5).
        #expect(EndoscopyNavigation.slice(atCrossRow: 6.5, sliceCount: 10, sign: 1) == 3)
        #expect(EndoscopyNavigation.slice(atCrossRow: 3.5, sliceCount: 10, sign: -1) == 3)
        #expect(EndoscopyNavigation.slice(atCrossRow: 3.5, sliceCount: 10, sign: 0) == 3)
        // A shift down the rows goes to lower slices with a positive sign, to higher ones otherwise.
        #expect(EndoscopyNavigation.sliceDirection(ofRowShift: 4, sign: 1) == -4)
        #expect(EndoscopyNavigation.sliceDirection(ofRowShift: 4, sign: -1) == 4)
    }

    @Test func theFocalHandleStandsWhereTheCameraLooksAtAnyZoom() {
        // A shift of (12, -5) pixels: the handle at that place while it is shorter than 50 points on screen.
        for scale in [Float(1), 2, 0.5] where (Float(13) * scale) <= 50 {
            let handle = EndoscopyNavigation.focalHandle(shift: (12, -5), scale: scale, pixelAspect: 1, maximumLength: 50)
            #expect(abs(handle.x - 12) < 1e-4 && abs(handle.y + 5) < 1e-4)
        }
        // Longer than 50 points on screen: along the same direction, 50 points long.
        let capped = EndoscopyNavigation.focalHandle(shift: (120, -50), scale: 2, pixelAspect: 1, maximumLength: 50)
        #expect(abs((capped.x * capped.x + capped.y * capped.y).squareRoot() * 2 - 50) < 1e-3)
        #expect(abs(capped.y / capped.x - (-50.0 / 120.0)) < 1e-5)
        // Pixels taller than wide count for their height on screen.
        let tall = EndoscopyNavigation.focalHandle(shift: (0, 40), scale: 1, pixelAspect: 2, maximumLength: 50)
        #expect(abs(tall.y - 25) < 1e-4)
        #expect(EndoscopyNavigation.focalHandle(shift: (0, 0), scale: 2, pixelAspect: 1, maximumLength: 50) == (0, 0))
        #expect(EndoscopyNavigation.focalHandle(shift: (3, 4), scale: 0, pixelAspect: 1, maximumLength: 50) == (0, 0))
    }
}
