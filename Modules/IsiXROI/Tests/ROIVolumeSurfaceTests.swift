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

/// The mask, the slice offsets and the thickness of an ROI volume's Iso Contour surface.
struct ROIVolumeSurfaceTests {

    @Test func theMaskIsOneAboveZero() {
        let pixels: [Float] = [0, 1000, -3, 0.5, .nan]
        let mask = pixels.withUnsafeBufferPointer { ROIVolumeSurface.binaryMask($0) }
        #expect([UInt8](mask) == [0, 1, 0, 1, 0])
    }

    @Test func theOffsetIsAlongTheNormalTimesTheFactor() {
        let offset = ROIVolumeSurface.frameOffset(origin: SIMD3(1, 2, 13), firstOrigin: SIMD3(1, 2, 3), normal: (0, 0, 1), factor: 0.5)
        #expect(offset == 5)
        #expect(ROIVolumeSurface.frameOffset(origin: SIMD3(4, 0, 0), firstOrigin: SIMD3(0, 0, 0), normal: (0, 0, 1), factor: 1) == 0)
    }

    @Test func aSingleSliceIsAsThickAsItsLargerSpacing() {
        #expect(ROIVolumeSurface.singleFrameThickness(factor: 2, thickness: -1.5, interval: 1.25) == 3)
        #expect(ROIVolumeSurface.singleFrameThickness(factor: 1, thickness: .nan, interval: 2) == 2)
        #expect(ROIVolumeSurface.perUnitFactor(8, factor: 2) == 1)
    }
}
