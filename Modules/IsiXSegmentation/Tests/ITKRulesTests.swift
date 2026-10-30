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
@testable import IsiXSegmentation

// The rules around ITK's region growing, resampling and VTK's outline, with
// values worked out by hand. The comparison with the Objective-C++ the module
// replaced, through ITK and VTK, runs outside the package, in tests/.
@Suite struct ITKRulesTests {

    @Test func aVolumeImportsWholeOrOneSlice() {
        let whole = VolumeImportGeometry.of(width: 4, height: 3, sliceCount: 5, originX: 0.1, originY: -2, originZ: 7,
                                            pixelSpacingX: 0.7, pixelSpacingY: 0.8, sliceInterval: 1.25, slice: -1, halve: false)
        #expect(whole.width == 4 && whole.height == 3 && whole.depth == 5 && whole.voxelOffset == 0 && !whole.halved)
        // Through single precision.
        #expect(whole.origin == [Double(Float(0.1)), -2, 7])
        #expect(whole.spacing == [Double(Float(0.7)), Double(Float(0.8)), 1.25])

        let one = VolumeImportGeometry.of(width: 4, height: 3, sliceCount: 5, originX: 0, originY: 0, originZ: 0,
                                          pixelSpacingX: 1, pixelSpacingY: 1, sliceInterval: 0, slice: 2, halve: true)
        #expect(one.depth == 1 && one.voxelOffset == 24 && !one.halved)
        #expect(one.spacing[2] == Double(Float(0.1)))

        let tilted = VolumeImportGeometry.of(width: 4, height: 3, sliceCount: 2, originX: 0, originY: 0, originZ: 0,
                                             pixelSpacingX: 1, pixelSpacingY: 1, sliceInterval: 2, slice: -2, halve: false)
        #expect(tilted.depth == 2 && tilted.spacing[2] == 1000)

        let halved = VolumeImportGeometry.of(width: 5, height: 4, sliceCount: 4, originX: 0, originY: 0, originZ: 0,
                                             pixelSpacingX: 1, pixelSpacingY: 0.5, sliceInterval: 2, slice: -1, halve: true)
        #expect(halved.halved && halved.width == 2 && halved.height == 2 && halved.depth == 2 && halved.spacing == [2, 1, 4])
        let voxels = (0 ..< 80).map(Float.init)
        let picked = voxels.withUnsafeBufferPointer { VolumeImportGeometry.halvedVoxels($0.baseAddress!, width: 5, height: 4, depth: 4) }
        // Odd x (1, 3), odd y (1, 3), odd z (1, 3).
        #expect(picked == [26, 28, 36, 38, 66, 68, 76, 78])
    }

    @Test func algorithmsChooseTheirFilter() {
        let values: [Float] = [100, 300, 2.9]
        let float: (Int) -> Float = { values[$0] }
        let integer: (Int) -> Int32 = { Int32(values[$0]) }
        #expect(RegionGrowingFilter.of(algorithm: 0, float: float, integer: integer, seedValue: { 250 })
                == .connectedThreshold(lower: 200, upper: 300))
        #expect(RegionGrowingFilter.of(algorithm: 1, float: float, integer: integer, seedValue: { 0 })
                == .connectedThreshold(lower: 100, upper: 300))
        #expect(RegionGrowingFilter.of(algorithm: 2, float: float, integer: integer, seedValue: { 0 })
                == .neighborhoodConnected(lower: 100, upper: 300, radius: 2))
        #expect(RegionGrowingFilter.of(algorithm: 3, float: float, integer: integer, seedValue: { 0 })
                == .confidenceConnected(multiplier: 100, iterations: 300, radius: 2))
        #expect(RegionGrowingFilter.of(algorithm: 4, float: float, integer: integer, seedValue: { 0 }) == nil)
        #expect(RegionGrowingFilter.seed(x: 12.9, y: -0.5, slice: -1, currentImage: 7) == (12, 0, 7))
        #expect(RegionGrowingFilter.seed(x: .nan, y: 3, slice: 4, currentImage: 7) == (0, 3, 0))
    }

    @Test func resultsCoverTheirSlices() {
        #expect(RegionGrowingResult.slices(slice: -1, sliceCount: 3) == 0 ..< 3)
        #expect(RegionGrowingResult.slices(slice: 5, sliceCount: 9) == 5 ..< 6)
        #expect(RegionGrowingResult.maskPlane(slice: -1, resultSlice: 4) == 4)
        #expect(RegionGrowingResult.maskPlane(slice: 3, resultSlice: 3) == 0)
        #expect(RegionGrowingResult.previewColour == (43908, 58981, 38010))
        #expect(!RegionGrowingResult.mergesVolume(name: "Preview", previewName: "Preview", merge: true))
        #expect(RegionGrowingResult.mergesSlice(name: "Liver", previewName: "Preview", merge: true))
    }

    @Test func outlinesAreOrderedAndThinned() {
        #expect(ContourTracing.pointOrder(lineCount: 5) == [0, 2, 4, 3, 1])
        #expect(ContourTracing.pointOrder(lineCount: 6) == [0, 2, 4, 5, 3, 1])
        #expect(ContourTracing.pointOrder(lineCount: 0) == [])
        #expect(!ContourTracing.makesPolygon(lineCount: 3) && ContourTracing.makesPolygon(lineCount: 4))
        #expect(ContourTracing.resolution(pointCount: 250, numPoints: 100) == 3)
        #expect(ContourTracing.resolution(pointCount: 80, numPoints: 100) == 1)
        #expect(ContourTracing.resolution(pointCount: 250, numPoints: 0) == 1)
        #expect(ContourTracing.resolution(pointCount: 401, numPoints: 200, resolution: 5) == 5)
        // From the end: 9 and 8 go, then 6 and 5, 3 and 2, and 0 while more than three are left.
        #expect(ContourTracing.keptIndices(count: 10, resolution: 3) == [1, 4, 7])
        #expect(ContourTracing.keptIndices(count: 5, resolution: 4) == [0, 1, 2])
        #expect(ContourTracing.keptIndices(count: 5, resolution: 1) == [0, 1, 2, 3, 4])
        var mask = [UInt8](repeating: 255, count: 12)
        mask.withUnsafeMutableBufferPointer { ContourTracing.clearBorder($0.baseAddress!, width: 4, height: 3) }
        #expect(mask == [0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0, 0])
    }

    @Test func resamplingGridFollowsTheReference() {
        let axial = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
        let coronal = [1.0, 0, 0, 0, 0, -1, 0, 1, 0]
        #expect(AffineResampleGrid.rotated([1, 2, 3], by: coronal) == [1, -3, 2])
        let rescaled = AffineResampleGrid.grid(rescale: true, imageCount: 4, referenceOrigin: [1, 2, 3], referenceOrientation: axial,
                                               referenceWidth: 64, referenceHeight: 32, referenceSpacingX: 0.5, referenceSpacingY: 0.6,
                                               referenceInterval: 2, originalWidth: 16, originalHeight: 8,
                                               originalSpacingX: 1, originalSpacingY: 1.5)
        #expect(rescaled.origin == [1, 2, 3] && rescaled.spacing == [0.5, 0.6, 2] && rescaled.size == [64, 32, 4])
        #expect(rescaled.byteCount == 4 * 32 * 64 * 4)
        let kept = AffineResampleGrid.grid(rescale: false, imageCount: 1, referenceOrigin: [0, 0, 0], referenceOrientation: axial,
                                           referenceWidth: 64, referenceHeight: 32, referenceSpacingX: 0.5, referenceSpacingY: 0.6,
                                           referenceInterval: 2, originalWidth: 16, originalHeight: 8,
                                           originalSpacingX: 1, originalSpacingY: 1.5)
        #expect(kept.spacing == [1, 1.5, 1] && kept.size == [16, 8, 1])
    }

    @Test func structuringElementsAreDiscs() {
        #expect(MorphologyKernel.side(radius: 1) == 3 && MorphologyKernel.side(radius: 4) == 9)
        #expect(MorphologyKernel.erosion(side: 3) == [0, 255, 0, 255, 255, 255, 0, 255, 0])
        #expect(MorphologyKernel.dilation(side: 3) == [255, 0, 255, 0, 0, 0, 255, 0, 255])
        // Radius 2: the 3 x 3 square inside the 5 x 5 window.
        let five = MorphologyKernel.erosion(side: 5)
        #expect(five.filter { $0 == 255 }.count == 9 && five[0] == 0 && five[12] == 255 && five[6] == 255)
        #expect(MorphologyKernel.erosion(side: 1) == [0])
    }
}
