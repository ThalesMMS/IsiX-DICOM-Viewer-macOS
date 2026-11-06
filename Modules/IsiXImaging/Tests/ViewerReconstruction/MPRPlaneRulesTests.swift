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

@Suite struct MPRPlaneRulesTests {

    @Test func reslicesTheProjectionsOnly() {
        #expect(!MPRPlaneRules.reslices(projectionMode: 0))
        #expect(MPRPlaneRules.reslices(projectionMode: 1) && MPRPlaneRules.reslices(projectionMode: 3))
        #expect(!MPRPlaneRules.reslices(projectionMode: 4))
    }

    @Test func takesTheSmallestUsableSpacing() {
        #expect(MPRPlaneRules.sampleStep(sliceInterval: -2, sliceThickness: 5, pixelSpacingX: 0.7, pixelSpacingY: 0.8) == 0.7)
        #expect(MPRPlaneRules.sampleStep(sliceInterval: 0, sliceThickness: 0.5, pixelSpacingX: 0.7, pixelSpacingY: 0.8) == 0.5)
        // An unknown pixel spacing counts as 1 mm.
        #expect(MPRPlaneRules.sampleStep(sliceInterval: 3, sliceThickness: 0, pixelSpacingX: 0, pixelSpacingY: .nan) == 1)
        #expect(MPRPlaneRules.sampleStep(sliceInterval: 0, sliceThickness: 0, pixelSpacingX: 1, pixelSpacingY: 1) == nil)
        #expect(MPRPlaneRules.sampleStep(sliceInterval: .infinity, sliceThickness: 1, pixelSpacingX: 1, pixelSpacingY: 1) == nil)
        #expect(MPRPlaneRules.sampleStep(sliceInterval: 1, sliceThickness: 1, pixelSpacingX: .infinity, pixelSpacingY: 1) == nil)
    }

    @Test func samplesThePixelCentre() {
        // An axial plane: rows along x, columns along y, 0.5 mm pixels.
        let centre = MPRPlaneRules.pixelCentre(corner: [10, 20, 30], cosines: [1, 0, 0, 0, 1, 0, 0, 0, 1], spacing: 0.5)
        #expect(centre == [10.25, 20.25, 30])
    }

    @Test func makesTheCubicPlaneOnAThinSlabOnly() {
        #expect(MPRPlaneRules.drawsCubicDisplayPlane(preference: true, fused: false, thickness: 1.0))
        #expect(MPRPlaneRules.drawsCubicDisplayPlane(preference: true, fused: false, thickness: 1.0005))
        #expect(!MPRPlaneRules.drawsCubicDisplayPlane(preference: true, fused: false, thickness: 1.01))
        #expect(!MPRPlaneRules.drawsCubicDisplayPlane(preference: true, fused: true, thickness: 0.5))
        #expect(!MPRPlaneRules.drawsCubicDisplayPlane(preference: false, fused: false, thickness: 0.5))
    }
}
