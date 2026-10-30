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

// The 2D viewer's image pipeline as the module answers it, without the viewer.
// The equivalence with the former Objective-C of the viewer, image by image,
// is checked by tests/test-viewer-image-pipeline-equivalence.py.
@Suite struct VolumeResamplingTests {

    @Test func sizes() throws {
        let plan = try #require(VolumeResamplingPlan(width: 7, height: 5, count: 9, sliceInterval: 1.5, xFactor: 2, yFactor: 2, zFactor: 2))
        #expect((plan.width, plan.height, plan.count) == (4, 3, 5))
        #expect(plan.bufferFloatCount == 9 * 12)
        #expect((0..<5).map(plan.sourceIndex(ofSlice:)) == [0, 1, 3, 5, 7])

        // Without a slice interval the series keeps its slices.
        let flat = try #require(VolumeResamplingPlan(width: 8, height: 8, count: 6, sliceInterval: 0, xFactor: 0.5, yFactor: 0.5, zFactor: 0.5))
        #expect((flat.width, flat.height, flat.count, flat.zFactor, flat.resamplesAlongZ) == (16, 16, 6, 1, false))

        #expect(try #require(VolumeResamplingPlan(width: 4, height: 4, count: 1, sliceInterval: 2, xFactor: 1, yFactor: 1, zFactor: 0.25)).count == 1)
        #expect(VolumeResamplingPlan(width: 4, height: 4, count: 4, sliceInterval: 2, xFactor: 0, yFactor: 1, zFactor: 1) == nil)
        #expect(VolumeResamplingPlan(width: 4, height: 4, count: 4, sliceInterval: 2, xFactor: -1, yFactor: 1, zFactor: 1) == nil)
    }

    @Test func stackOrigin() {
        let axial: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let first = SliceGeometry(origin: [10, 20, 30], orientation: axial, pixelSpacingX: 0.5, pixelSpacingY: 0.5, sliceThickness: 2, pixelRatio: 1)
        var second = first
        second.origin = [10, 20, 32]
        let stack = ResampledStackOrigin(first: first, second: second, zFactor: 2)
        #expect(stack.axis == 2 && stack.interval == 4)
        #expect(stack.corner == [9.75, 19.75, 29])
        let resampled = first.resampled(by: VolumeResamplingPlan(width: 4, height: 4, count: 4, sliceInterval: 2, xFactor: 2, yFactor: 2, zFactor: 2)!)
        #expect(resampled.pixelSpacingX == 1 && resampled.sliceThickness == 4 && resampled.pixelRatio == 1)
        #expect(stack.origin(ofSlice: 1, pixelSpacingX: 1, pixelSpacingY: 1, sliceThickness: 4) == [10.25, 20.25, 35])

        // Other orientations: no axis, no step.
        second.orientation = [0, 1, 0, 0, 0, 1, 1, 0, 0]
        let mixed = ResampledStackOrigin(first: first, second: second, zFactor: 2)
        #expect(mixed.axis == nil && mixed.interval == 0)
    }

    @Test func passes() throws {
        let plan = try #require(VolumeResamplingPlan(width: 4, height: 4, count: 4, sliceInterval: 1, xFactor: 1, yFactor: 1, zFactor: 2))
        let source = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { source.deallocate() }
        for i in 0..<64 { source[i] = Float(i / 16) * 10 }
        let buffer = try #require(plan.allocateBuffer())
        defer { free(buffer) }
        VolumeResampler.scaleSlices(plan, slices: (0..<4).map { source + 16 * $0 }, isRGB: [false, false, false, false], into: buffer)
        #expect((0..<64).allSatisfy { buffer[$0] == source[$0] })
        VolumeResampler.scaleAlongZ(plan, buffer: buffer, isRGB: false)
        // Two slices of a uniform ramp: each one is uniform.
        #expect((0..<16).allSatisfy { buffer[$0] == buffer[0] } && (16..<32).allSatisfy { buffer[$0] == buffer[16] })
        #expect(buffer[0] < buffer[16])
    }
}

@Suite struct SliceStackTests {

    @Test func intervals() {
        let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(SliceStack.interval(fromOrigin: [0, 0, 5], orientation: axial, toOrigin: [0, 0, 7], orientation: axial) == 2)
        #expect(SliceStack.interval(fromOrigin: [0, 0, 7], orientation: axial, toOrigin: [0, 0, 5], orientation: axial) == -2)
        let none = [Double](repeating: 0, count: 9)
        #expect(SliceStack.interval(fromOrigin: [0, 0, 5], orientation: none, toOrigin: [0, 0, 7], orientation: none) == 0)

        let spacing = SliceStackSpacing(orientation1: axial, orientation2: axial, origin1: [0, 0, 7], origin2: [0, 0, 4])
        #expect(spacing?.orientation == .axialPositive && spacing?.interval == -3 && spacing?.interval3D == 3)
        #expect(SliceStackSpacing.sliceInterval(interval: -3, interval3D: 3) == -3)
        #expect(SliceStackSpacing.reversedSliceInterval(interval: -3, interval3D: 3) == 3)
        #expect(SliceStackSpacing(orientation1: axial, orientation2: none, origin1: [0, 0, 0], origin2: [0, 0, 1]) == nil)
        #expect(SliceStackOrientation.coronalNegative.orthogonalTag == 1)
    }

    @Test func normalAndAxes() {
        #expect(SliceStack.normal([1, 0, 0, 0, 1, 0, 0, 0, 0]) == [0, 0, 1])
        #expect(SliceStack.dominantAxis(0.1, -0.9, 0.2) == 1)
        #expect(SliceStack.dominantAxis(0.5, 0.5, 0.1) == nil)
    }

    @Test(arguments: [3, 50, 51, 120])
    func reversal(count: Int) {
        let slice = 6
        let volume = UnsafeMutablePointer<Float>.allocate(capacity: count * slice)
        defer { volume.deallocate() }
        for i in 0..<(count * slice) { volume[i] = Float(i) }
        SliceStack.reverseSlices(volume, sliceCount: count, sliceFloatCount: slice)
        #expect((0..<(count * slice)).allSatisfy { volume[$0] == Float((count - 1 - $0 / slice) * slice + $0 % slice) })
    }
}

@Suite struct MaskSubtractionTests {

    @Test func range() {
        #expect(MaskSubtraction.range(of: []) == CGPoint(x: 1024, y: 0))
        #expect(MaskSubtraction.range(of: [CGPoint(x: -12.7, y: 300.9), CGPoint(x: 4, y: 1200)]) == CGPoint(x: -12, y: 1200))
    }

    @Test func shiftAndIndicator() {
        var offset = CGPoint.zero
        for tag in [9, 9, 6] { offset = MaskSubtraction.shift(offset, afterTag: tag) }
        #expect(offset == CGPoint(x: 3, y: 2))
        #expect(MaskSubtraction.shift(offset, afterTag: 5) == .zero)
        #expect(MaskSubtraction.shift(offset, afterTag: 0) == offset)
        #expect(MaskSubtraction.isApplicable(CGPoint(x: 29, y: -29)) && !MaskSubtraction.isApplicable(CGPoint(x: 30, y: 0)))
        #expect([-3, -2, -1, 0, 1, 2, 3].map(MaskSubtraction.indicatorIndex) == [0, 0, 1, 4, 2, 3, 3])
        #expect(MaskSubtraction.indicatorCode(CGPoint(x: 1, y: -1)) == 7)
        // No shift: nothing lit; every code of the 5 × 5 grid has nine states.
        #expect(MaskSubtraction.indicatorStates(code: 24) == [Bool](repeating: false, count: 9))
        #expect((0..<25).allSatisfy { MaskSubtraction.indicatorStates(code: $0)?.count == 9 })
        #expect(MaskSubtraction.indicatorStates(code: 25) == nil)
        // Shifted right and up: the left column and the bottom row stay lit.
        #expect(MaskSubtraction.indicatorStates(code: 12) == [false, false, true, false, false, true, true, true, true])
    }

    @Test func sliders() {
        #expect(MaskSubtraction.window(afterSliderTag: 37, level: 100, width: 50)! == (95, 50))
        #expect(MaskSubtraction.window(afterSliderTag: 35, level: 100, width: 50)! == (100, 256))
        #expect(MaskSubtraction.window(afterSliderTag: 1, level: 100, width: 50) == nil)
        #expect(MaskSubtraction.sum(afterTag: 33, current: 4) == 5 && MaskSubtraction.sum(afterTag: 32, current: 4) == 1)
    }
}

@Suite struct ColorAndWindowTests {

    @Test func colorLookupTable() throws {
        let ramp = (0..<256).map { NSNumber(value: $0) }
        let reversed = Array(ramp.reversed())
        let preset: NSDictionary = ["Red": ramp, "Green": reversed, "Blue": (0..<256).map { NSNumber(value: $0 + 256) }]
        let table = try #require(ColorLookupTable(preset: preset))
        #expect(table.red[10] == 10 && table.green[10] == 245 && table.blue[3] == 3)
        #expect(table.darkestIndex == 0)
        #expect(ColorLookupTable(preset: ["Red": ramp, "Green": ramp]) == nil)
        #expect(ColorLookupTable(preset: ["Red": ramp, "Green": ramp, "Blue": Array(ramp.prefix(10))]) == nil)

        let stored = table.preset(points: ["p"], colors: ["c"])
        #expect(stored.allKeys.count == 5 && (stored["Red"] as? [NSNumber])?[200] == 200 && (stored["Points"] as? [String]) == ["p"])
        #expect(ColorLookupTable(preset: stored) == table)
        #expect(OpacityTablePreset.points(of: OpacityTablePreset.preset(points: ["a"])) == ["a"])
    }

    @Test func windowLevel() {
        #expect(WindowLevel.range(level: 40, width: 400) == (-160, 240))
        #expect(WindowLevel.window(from: -160, to: 240) == (40, 400))
        #expect(WindowLevel.presetName(fromMenuTitle: "1 - Abdomen") == "Abdomen")
        #expect(WindowLevel.presetName(fromMenuTitle: "abc") == nil)
    }

    @Test func stackFusion() {
        #expect(StackFusion.mode(3, imageSizes: [(4, 4), (4, 4)]) == 3)
        #expect(StackFusion.mode(3, imageSizes: [(4, 4), (5, 4)]) == 0)
        #expect(StackFusion.mode(3, imageSizes: []) == 3)
        #expect(StackFusion.isVolumeRendering(5) && StackFusion.flipsVolumeRendering(4) && !StackFusion.flipsVolumeRendering(5))
        #expect(StackFusion.thickness(afterSteps: 3, active: false, current: 7, maximum: 10) == 2)
        #expect(StackFusion.thickness(afterSteps: -1, active: false, current: 7, maximum: 10) == nil)
        #expect(StackFusion.thickness(afterSteps: 500, active: true, current: 2, maximum: 300) == 130)
        #expect(StackFusion.thickness(afterSteps: -9, active: true, current: 5, maximum: 10) == 1)
        #expect(StackFusion.thickness(afterSteps: 1, active: true, current: 10, maximum: 10) == nil)
        #expect(StackFusion.thickness(afterSteps: 1, active: true, current: 1, maximum: 1) == nil)
        #expect(StackFusion.thickness(afterSteps: 0, active: true, current: 3, maximum: 10) == nil)
    }
}
