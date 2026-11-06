//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import Foundation
import Testing
@testable import IsiXImaging

@Suite struct SeriesReslicePlanTests {

    @Test func smallStackIsSquaredToTheInterval() {
        // 12 slices 2.5 apart, rows 0.8: 37.5 rows, 36 once even.
        let plan = SeriesReslicePlan(direction: 0, sliceCount: 12, width: 24, height: 20, spacingX: 0.8, spacingY: 0.6, sliceInterval: 2.5)
        #expect(plan.square && !plan.squareAbandoned)
        #expect(plan.sliceCount == 20 && plan.width == 24 && plan.height == 36)
        #expect(plan.spacingX == 0.8 && plan.spacingY == 0.8)
    }

    @Test func squareAbandonedWhenItAddsNoRows() {
        let plan = SeriesReslicePlan(direction: 1, sliceCount: 12, width: 24, height: 20, spacingX: 0.8, spacingY: 0.6, sliceInterval: -0.5)
        #expect(!plan.square && plan.squareAbandoned)
        #expect(plan.sliceCount == 24 && plan.width == 20 && plan.height == 12)
        #expect(plan.spacingX == 0.6 && plan.spacingY == 0.5)
    }

    @Test func largeStacksAreNotSquared() {
        #expect(!SeriesReslicePlan(direction: 0, sliceCount: 100, width: 10, height: 10, spacingX: 1, spacingY: 1, sliceInterval: 1).square)
        #expect(!SeriesReslicePlan(direction: 0, sliceCount: 10, width: 257, height: 10, spacingX: 1, spacingY: 1, sliceInterval: 5).square)
        let plan = SeriesReslicePlan(direction: 0, sliceCount: 13, width: 25, height: 21, spacingX: 1, spacingY: 1, sliceInterval: 0.25)
        #expect(plan.width == 24 && plan.height == 12 && plan.squareAbandoned)
    }

    @Test func referenceSliceIsTheLastOfAnEvenCount() {
        #expect(SeriesReslicePlan.referenceSliceIndex(sliceCount: 13) == 11)
        #expect(SeriesReslicePlan.referenceSliceIndex(sliceCount: 12) == 11)
    }

    @Test func noSpacingDoesNotTrap() {
        let plan = SeriesReslicePlan(direction: 0, sliceCount: 10, width: 10, height: 10, spacingX: 0, spacingY: 0, sliceInterval: 1)
        #expect(plan.square && plan.height == Int.max / 2 * 2)
    }
}

@Suite struct SeriesResliceTests {

    @Test func orientationTakesTheNormalAsColumns() {
        let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(SeriesReslice.orientation(direction: 0, reference: axial, sign: 1) == [1, 0, 0, 0, 0, -1, 0, 0, 1])
        #expect(SeriesReslice.orientation(direction: 1, reference: axial, sign: 1) == [0, 1, 0, 0, 0, -1, 0, 0, 1])
    }

    @Test func rowsAreGatheredLastSliceFirst() {
        let slices: [[Float]] = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]]	// 2×2 each
        var out = [Float](repeating: 0, count: 6)
        let pointers = slices.map { s -> UnsafePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: 4); p.initialize(from: s, count: 4); return UnsafePointer(p)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        SeriesReslice.gatherRows(pointers, row: 1, sourceWidth: 2, width: 2, into: &out, sign: 1)
        #expect(out == [11, 12, 7, 8, 3, 4])
        SeriesReslice.gatherRows(pointers, row: 0, sourceWidth: 2, width: 2, into: &out, sign: -1)
        #expect(out == [1, 2, 5, 6, 9, 10])
    }

    @Test func columnsAreGatheredFromTheLastSliceBackwards() {
        // Two slices of 2×3 (width 2, height 3), stored one after the other.
        let volume: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        var out = [Float](repeating: 0, count: 6)
        volume.withUnsafeBufferPointer { v in
            SeriesReslice.gatherColumns(v.baseAddress! + 6, column: 1, count: 2, sliceFloatCount: 6, rowFloats: 2, width: 3, into: &out, sign: 1)
        }
        // Row x of the new slice is slice count-1-x's column 1.
        #expect(out == [8, 10, 12, 2, 4, 6])
        volume.withUnsafeBufferPointer { v in
            SeriesReslice.gatherColumns(v.baseAddress!, column: 0, count: 2, sliceFloatCount: 6, rowFloats: 2, width: 3, into: &out, sign: -1)
        }
        #expect(out == [1, 3, 5, 7, 9, 11])
    }
}

@Suite struct SeriesTransformsTests {

    @Test func rotationConstants() {
        #expect(SeriesRotation(vImageConstant: Int(kRotate90DegreesClockwise)) == .clockwise90)
        #expect(SeriesRotation(vImageConstant: Int(kRotate180DegreesClockwise)) == .clockwise180)
        #expect(SeriesRotation(vImageConstant: Int(kRotate270DegreesClockwise)) == .clockwise270)
        #expect(SeriesRotation(vImageConstant: Int(kRotate0DegreesClockwise)) == nil)
        #expect(!SeriesRotation.clockwise180.swapsAxes && SeriesRotation.clockwise90.swapsAxes)
    }

    @Test func originPixelOfEachTurn() {
        #expect(SeriesRotation.clockwise90.originPixel(width: 10, height: 6) == (-9, 0))
        #expect(SeriesRotation.clockwise180.originPixel(width: 10, height: 6) == (-9, 5))
        #expect(SeriesRotation.clockwise270.originPixel(width: 10, height: 6) == (9, 0))
    }

    @Test func flipsReverseRowsOrColumns() {
        let o: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(SeriesTransforms.verticallyFlipped(o) == [1, 0, 0, -0.0, -1, -0.0, 0, 0, 1])
        #expect(SeriesTransforms.horizontallyFlipped(o) == [-1, -0.0, -0.0, 0, 1, 0, 0, 0, 1])
    }

    @Test func quarterTurnOfAnAxialSlice() {
        let o = SeriesTransforms.rotated([1, 0, 0, 0, 1, 0, 0, 0, 0], degrees: 90)
        #expect(Array(o[6...8]) == [0, 0, 1])
        #expect(abs(o[0]) < 1e-7 && abs(o[1] + 1) < 1e-7)
        #expect(abs(o[3] - 1) < 1e-7 && abs(o[4]) < 1e-7)
    }

    @Test func spacingsSwapThroughFloats() {
        let swapped = SeriesTransforms.swappedSpacing(x: 0.1, y: 0.3)
        #expect(swapped.x == Double(Float(0.3)) && swapped.y == Double(Float(0.1)))
        #expect(swapped.ratio == Double(Float(0.1) / Float(0.3)))
        #expect(SeriesTransforms.swappedSize(width: 7, height: 3) == (3, 7))
    }

    @Test func originOfAPixel() {
        let d = SeriesTransforms.origin([1, 2, 3], orientation: [1, 0, 0, 0, 1, 0, 0, 0, 1], spacingX: 0.5, spacingY: 2, pixel: (-9, 5))
        #expect(d == [-3.5, 12, 3])
    }

    @Test func pixelsFlipAndTurn() {
        var pixels: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]	// two slices of 3×2
        pixels.withUnsafeMutableBufferPointer { SeriesTransforms.flipSlicesVertically($0.baseAddress!, width: 3, height: 2, count: 2) }
        #expect(pixels == [4, 5, 6, 1, 2, 3, 10, 11, 12, 7, 8, 9])
        pixels.withUnsafeMutableBufferPointer { SeriesTransforms.flipRowsHorizontally($0.baseAddress!, width: 3, rows: 4) }
        #expect(pixels == [6, 5, 4, 3, 2, 1, 12, 11, 10, 9, 8, 7])
        var turned: [Float] = [1, 2, 3, 4, 5, 6]	// one slice of 3×2
        turned.withUnsafeMutableBufferPointer {
            SeriesTransforms.rotateSlices($0.baseAddress!, width: 3, height: 2, count: 1, vImageConstant: UInt8(kRotate90DegreesClockwise))
        }
        #expect(turned == [4, 1, 5, 2, 6, 3])
    }
}

@Suite struct SeriesConsistencyTests {

    @Test func matrixMismatchesAndTheSliceThatCanGo() {
        let one = SeriesConsistency.matrixMismatches(widths: [9, 8, 8, 8, 8], heights: [6, 6, 6, 6, 6], width: 8, height: 6)
        #expect(one.count == 1 && one.first == 0)
        #expect(SeriesConsistency.dropsOneSlice(mismatches: one, sliceCount: 5) == 0)
        let middle = SeriesConsistency.matrixMismatches(widths: [8, 8, 9, 8, 8], heights: [6, 6, 6, 6, 6], width: 8, height: 6)
        #expect(SeriesConsistency.dropsOneSlice(mismatches: middle, sliceCount: 5) == nil)
        let last = SeriesConsistency.matrixMismatches(widths: [8, 8, 8, 8, 8], heights: [6, 6, 6, 6, 7], width: 8, height: 6)
        #expect(SeriesConsistency.dropsOneSlice(mismatches: last, sliceCount: 5) == 4)
    }

    @Test func orientationTolerance() {
        let a: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(!SeriesConsistency.orientationDiffers([1.0005, 0, 0, 0, 1, 0, 0, 0, 1], from: a))
        #expect(SeriesConsistency.orientationDiffers([1, 0, 0, 0, 0.998, 0, 0, 0, 1], from: a))
    }

    @Test func endSlicesContinueTheStack() {
        #expect(SeriesConsistency.extrapolatedFirstOrigin(second: [0, 0, 2], third: [0, 0, 4]) == [0, 0, 0])
        #expect(SeriesConsistency.extrapolatedLastOrigin(penultimate: [1, 0, 6], antepenultimate: [1, 0, 4]) == [1, 0, 8])
    }
}

@Suite struct GantryTiltCorrectionTests {

    @Test func sameOrientationOnly() {
        let model: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(GantryTiltCorrection.hasModelOrientation([1, 0, 0, 0, 1, 0, 0.3, 0, 0.9], model: model))
        #expect(!GantryTiltCorrection.hasModelOrientation([1, 0, 0, 0, 0.9999, 0.01, 0, 0, 1], model: model))
    }

    @Test func parametersOfASlideAlongTheGantry() {
        let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let p = GantryTiltCorrection.parameters(sensor: axial, model: axial, offset: [0, 1.5, -4])
        #expect(p == [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.5, -4])
        // Only the part of the offset along the normal is kept.
        #expect(GantryTiltCorrection.projectedOrigin(modelOrigin: [10, 20, 30], model: axial, offset: [0, 1.5, -4]) == [10, 20, 26])
    }
}
