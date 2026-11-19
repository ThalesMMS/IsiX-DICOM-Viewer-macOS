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

/// A region of an ultrasound image: its rectangle, its spatial format and the
/// units and deltas of its axes.
private func region(_ minX: Int32, _ minY: Int32, _ maxX: Int32, _ maxY: Int32, format: Int32 = 1, units: (Int32, Int32) = (3, 3),
                    deltas: (Double, Double) = (0.1, 0.1)) -> USRegion {
    let region = USRegion()
    region.regionLocationMinX0 = minX
    region.regionLocationMinY0 = minY
    region.regionLocationMaxX1 = maxX
    region.regionLocationMaxY1 = maxY
    region.regionSpatialFormat = format
    region.physicalUnitsXDirection = units.0
    region.physicalUnitsYDirection = units.1
    region.physicalDeltaX = deltas.0
    region.physicalDeltaY = deltas.1
    return region
}

@Suite struct USRegionTests {

    // Two 2D regions side by side, of 0.1 and 0.2 cm a pixel: a line of ten
    // pixels is 10 mm in one and 20 mm in the other, whichever comes first in
    // the sequence. The image's own spacing is that of one of them only.
    @Test func aLineIsMeasuredWithTheScaleOfTheRegionThatHoldsIt() throws {
        let fine = region(0, 0, 99, 99, deltas: (0.1, 0.1)), coarse = region(100, 0, 199, 99, deltas: (0.2, -0.2))
        for regions in [[fine, coarse], [coarse, fine]] {
            let inFine = try #require(USRegion.region(holding: (10, 50), (20, 50), in: regions))
            #expect(inFine === fine)
            let fineSpacing = try #require(inFine.pixelSpacing)
            #expect(fineSpacing.x == 1 && fineSpacing.y == 1)
            let inCoarse = try #require(USRegion.region(holding: (110, 50), (120, 50), in: regions))
            #expect(inCoarse === coarse)
            let coarseSpacing = try #require(inCoarse.pixelSpacing)
            // The sign of a delta is its direction.
            #expect(coarseSpacing.x == 2 && coarseSpacing.y == 2)
            // 10 pixels along x, in mm.
            #expect(10 * fineSpacing.x == 10 && 10 * coarseSpacing.x == 20)
            // A square of 10 pixels: 1 cm2 in one region, 4 cm2 in the other.
            #expect(100 * fineSpacing.x * fineSpacing.y / 100 == 1 && 100 * coarseSpacing.x * coarseSpacing.y / 100 == 4)
        }
    }

    @Test func aLineFromOneRegionToAnotherIsInNone() {
        let regions = [region(0, 0, 99, 99), region(100, 0, 199, 99)]
        #expect(USRegion.region(holding: (90, 50), (110, 50), in: regions) == nil)
        #expect(USRegion.region(holding: (250, 50), (260, 50), in: regions) == nil)
        // The edges belong to the region.
        #expect(USRegion.region(holding: (0, 0), (99, 99), in: regions) === regions[0])
        #expect(USRegion.region(holding: (100, 0), (199, 99), in: regions) === regions[1])
    }

    @Test func aRegionWithNoFormatAndNoUnitsIsPassedOver() {
        let blank = region(0, 0, 199, 99, format: 0, units: (0, 0)), real = region(0, 0, 99, 99)
        #expect(USRegion.region(holding: (10, 10), (20, 20), in: [blank, real]) === real)
        #expect(USRegion.region(holding: (10, 10), (20, 20), in: [blank]) == nil)
        #expect(!blank.measures && real.measures)
    }

    @Test func onlyA2DRegionInCentimetresGivesAPixelSpacing() {
        // A spectral region: seconds along x, centimetres a second along y.
        let doppler = region(0, 100, 199, 199, format: 3, units: (4, 7), deltas: (0.01, 0.5))
        #expect(doppler.measures && !doppler.isTwoDimensionalInCentimetres && doppler.pixelSpacing == nil)
        // M-mode, and a 2D region in other units or with no delta.
        #expect(region(0, 0, 9, 9, format: 2, units: (4, 3)).pixelSpacing == nil)
        #expect(region(0, 0, 9, 9, units: (3, 4)).pixelSpacing == nil)
        #expect(region(0, 0, 9, 9, deltas: (0, 0.1)).pixelSpacing == nil)
        #expect(region(0, 0, 9, 9, deltas: (0.05, 0.025)).pixelSpacing.map { [$0.x, $0.y] } == [0.5, 0.25])
    }
}
