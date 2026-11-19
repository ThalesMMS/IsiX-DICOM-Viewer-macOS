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

/// A ruler as the ROI measures it: its length in centimetres by the spacing,
/// in mm, and that length told as pixels along X (the ROI's -MesureLength:).
/// Without spacing both are its length in pixels.
private func measure(dx: Double, dy: Double, spacingX: Double, spacingY: Double) -> (centimetres: Double, pixels: Double) {
    guard spacingX != 0, spacingY != 0 else {
        let pixels = (dx * dx + dy * dy).squareRoot()
        return (pixels, pixels)
    }
    let millimetres = ((dx * spacingX) * (dx * spacingX) + (dy * spacingY) * (dy * spacingY)).squareRoot()
    return (millimetres / 10, millimetres / spacingX)
}

@Suite struct RulerCalibrationTests {

    // Pixels of 0.5 mm across and 2 mm down. Whatever the direction of the
    // ruler, the image calibrated with it reads the length entered along it,
    // and its pixels keep their proportion.
    @Test func aRulerInAnyDirectionReadsTheLengthEnteredOnPixelsThatAreNotSquare() {
        let rulers: [(String, Double, Double)] = [("horizontal", 10, 0), ("vertical", 0, 10), ("oblique", 6, 8), ("steep", 1, 30)]
        for (name, dx, dy) in rulers {
            for requested in [1.0, 0.25, 12.5] {
                let before = measure(dx: dx, dy: dy, spacingX: 0.5, spacingY: 2)
                let x = RulerCalibration.resolution(requestedCentimetres: requested, pixels: before.pixels)
                let y = RulerCalibration.verticalSpacing(previousX: 0.5, previousY: 2, resolution: x)
                let after = measure(dx: dx, dy: dy, spacingX: x, spacingY: y)
                #expect(abs(after.centimetres - requested) < 1e-9, "\(name), \(requested) cm: reads \(after.centimetres)")
                #expect(abs(y / x - 4) < 1e-12, "\(name): the pixels are \(y / x) to 1")
            }
        }
        // The case as it was reported: a vertical ruler of 10 pixels, 2 cm by
        // the image, entered as 1 cm. The spacing halves, both ways.
        let vertical = measure(dx: 0, dy: 10, spacingX: 0.5, spacingY: 2)
        #expect(vertical.centimetres == 2 && vertical.pixels == 40)
        let x = RulerCalibration.resolution(requestedCentimetres: 1, pixels: vertical.pixels)
        #expect(x == 0.25 && RulerCalibration.verticalSpacing(previousX: 0.5, previousY: 2, resolution: x) == 1)
    }

    @Test func anImageWithNoSpacingGetsSquarePixels() {
        let before = measure(dx: 30, dy: 40, spacingX: 0, spacingY: 0)
        #expect(before.pixels == 50)
        let x = RulerCalibration.resolution(requestedCentimetres: 2.5, pixels: before.pixels)
        let y = RulerCalibration.verticalSpacing(previousX: 0, previousY: 0, resolution: x)
        #expect(x == 0.5 && y == 0.5)
        #expect(measure(dx: 30, dy: 40, spacingX: x, spacingY: y).centimetres == 2.5)
    }

    @Test func theFactorIsTheLengthEnteredOverTheLengthRead() {
        #expect(RulerCalibration.factor(requestedCentimetres: 1, measuredCentimetres: 2) == 0.5)
        #expect(RulerCalibration.factor(requestedCentimetres: 3, measuredCentimetres: 1.5) == 2)
        #expect(RulerCalibration.factor(requestedCentimetres: 1, measuredCentimetres: 0) == nil)
        #expect(RulerCalibration.factor(requestedCentimetres: 0, measuredCentimetres: 1) == nil)
        #expect(RulerCalibration.factor(requestedCentimetres: -1, measuredCentimetres: 1) == nil)
        #expect(RulerCalibration.factor(requestedCentimetres: .infinity, measuredCentimetres: 1) == nil)
    }
}
