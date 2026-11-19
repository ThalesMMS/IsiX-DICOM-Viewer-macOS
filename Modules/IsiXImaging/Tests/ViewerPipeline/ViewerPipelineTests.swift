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
import IsiXPreferences

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

    @Test func reorderingMovesEachSliceToItsPlace() {
        let slice = 5
        for order in [[0, 1, 2, 3], [3, 2, 1, 0], [1, 2, 3, 0], [2, 0, 1, 4, 3], [0, 4, 2, 3, 1, 5]] {
            let volume = UnsafeMutablePointer<Float>.allocate(capacity: order.count * slice)
            defer { volume.deallocate() }
            for i in 0..<(order.count * slice) { volume[i] = Float(i) }
            SliceStack.reorderSlices(volume, order: order, sliceFloatCount: slice)
            #expect((0..<(order.count * slice)).allSatisfy { volume[$0] == Float(order[$0 / slice] * slice + $0 % slice) }, "\(order)")
            #expect(SliceStackOrder.inverse(of: order).enumerated().allSatisfy { order[$0.element] == $0.offset })
        }
    }
}

/// The order of a whole stack, which the viewer reverses or sorts before a 3D
/// reconstruction, applied as the viewer applies it: reversed when it
/// descends, then sorted when still out of order, and applied again.
@Suite struct SliceStackOrderTests {

    let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    func order(_ z: [Double], orientation: [Double]? = nil) -> SliceStackOrder {
        SliceStackOrder(origins: z.map { [10, -20, $0] }, orientations: z.map { _ in orientation ?? axial })
    }

    /// The viewer's arrangement: reversed when it descends, then sorted.
    func arranged(_ z: [Double]) -> [Double] {
        var z = z
        if order(z).isDescending(stepInterval: z[2] - z[1]) { z.reverse() }
        if case .unordered(let sorting) = order(z).arrangement { z = sorting.map { z[$0] } }
        return z
    }

    @Test func aRegularStackKeepsItsDirectionAndItsStep() {
        let descending = (0..<20).map { -926.096 - Double($0) }
        #expect(order(descending).arrangement == .descending)
        #expect(order(descending).isDescending(stepInterval: 1))
        #expect(abs(order(descending).meanInterval3D - 1) < 1e-9)
        #expect(order(Array(descending.reversed())).arrangement == .ascending)
        #expect(arranged(descending) == descending.reversed())
        #expect(arranged(arranged(descending)) == arranged(descending))
    }

    /// The CT of the report sorted by date: instances 1 to 5 share an
    /// acquisition time and come first in ascending location, the other
    /// slices descend. The step from slice 1 to 2 rises; the stack descends.
    @Test func slicesSortedByDateWithATieAreSortedAlongTheNormal() throws {
        let instances = [5, 4, 3, 2, 1] + Array(6...40)
        let z = instances.map { -926.096 - Double($0 - 1) }
        let stack = order(z)
        guard case .unordered = stack.arrangement else {
            Issue.record("a stack that rises then falls is out of order, not \(stack.arrangement)")
            return
        }
        #expect(z[2] - z[1] > 0 && stack.isDescending(stepInterval: z[2] - z[1]))
        #expect(abs(stack.meanInterval3D - 1) < 1e-9)
        let once = arranged(z)
        #expect(once == z.sorted())
        #expect(order(once).arrangement == .ascending)
        #expect(arranged(once) == once)
    }

    /// Another slice than the first out of place: sorted wherever it is.
    @Test func aSliceOutOfPlaceIsSorted() {
        var z = (0..<30).map { Double($0) * 1.25 }
        z.swapAt(12, 17)
        #expect(!order(z).isDescending(stepInterval: z[2] - z[1]))
        #expect(arranged(z) == z.sorted())
        #expect(arranged(arranged(z)) == z.sorted())
    }

    /// Instance numbers given twice (two acquisitions numbered from 1, each
    /// slice 0.5 mm from its twin) and the twins taken in descending location:
    /// the stack zigzags; it is sorted, and stays sorted.
    @Test func repeatedInstanceNumbersInEitherOrderAreSorted() {
        let twinsDescending = (0..<20).flatMap { [Double($0) + 0.5, Double($0)] }
        #expect(arranged(twinsDescending) == twinsDescending.sorted())
        #expect(arranged(arranged(twinsDescending)) == twinsDescending.sorted())
        let twinsAscendingDownwards = (0..<20).flatMap { [-Double($0) - 0.5, -Double($0)] }
        #expect(arranged(twinsAscendingDownwards) == twinsAscendingDownwards.sorted())
    }

    /// Slices missing, in order: not reordered; the mean interval spans the
    /// stack, where slices 1 and 2 gave the step of one gap.
    @Test func aStackWithGapsKeepsItsOrderAndGetsItsMeanInterval() {
        let z = [0.0, 3, 6, 7, 8, 9, 13, 14, 15, 16].map { -$0 }
        let stack = order(z)
        #expect(stack.arrangement == .descending && stack.isMonotonic)
        #expect(abs(stack.meanInterval3D - 16.0 / 9) < 1e-9)
        #expect(arranged(z) == z.reversed())
    }

    /// Two time points of one series, or a repeated slice: no single order.
    /// The viewer keeps the former rule, from slices 1 and 2.
    @Test func repeatedPositionsLeaveTheFormerRule() {
        let phases = (0..<10).map { Double($0) } + (0..<10).map { Double($0) }
        #expect(order(phases).arrangement == .undetermined)
        #expect(order(phases).isDescending(stepInterval: -1))
        #expect(!order(phases).isDescending(stepInterval: 1))
        #expect(order([0, 1, 1, 2]).arrangement == .undetermined)
        #expect(order([0, 1, 1.0005, 2]).arrangement == .undetermined)
    }

    /// A scout of another orientation, slices without one, or one slice.
    @Test func otherOrientationsHaveNoOrder() {
        let coronal: [Double] = [1, 0, 0, 0, 0, -1, 0, 1, 0]
        let mixed = SliceStackOrder(origins: [[0, 0, 0], [0, 0, 1], [0, 0, 2]], orientations: [coronal, axial, axial])
        #expect(mixed.arrangement == .undetermined && mixed.meanInterval3D == 0)
        #expect(order([0, 1, 2], orientation: [Double](repeating: 0, count: 9)).arrangement == .undetermined)
        #expect(order([4]).arrangement == .undetermined)
    }

    /// The direction is the slice normal's: a sagittal stack whose normal
    /// points to -x ascends as x falls, and a tilted stack keeps the distance
    /// between its origins.
    @Test func positionsAreMeasuredAlongTheNormal() {
        let sagittal: [Double] = [0, 1, 0, 0, 0, -1, -1, 0, 0]
        let stack = SliceStackOrder(origins: [[5, 0, 0], [4, 0, 0], [3, 0, 0]], orientations: Array(repeating: sagittal, count: 3))
        #expect(stack.arrangement == .ascending)
        let tilted = SliceStackOrder(origins: (0..<5).map { [0, Double($0) * 0.3, Double($0)] }, orientations: Array(repeating: axial, count: 5))
        #expect(tilted.arrangement == .ascending && abs(tilted.meanInterval3D - (1.09 as Double).squareRoot()) < 1e-9)
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

    @Test func presetNameFromTitlesOfOneTwoAndThreeDigits() {
        #expect(WindowLevel.presetName(fromMenuTitle: "9 - CT - Bone") == "CT - Bone")
        #expect(WindowLevel.presetName(fromMenuTitle: "10 - Lung") == "Lung")
        #expect(WindowLevel.presetName(fromMenuTitle: "12 - CT - Bone") == "CT - Bone")
        #expect(WindowLevel.presetName(fromMenuTitle: "103 - Écho") == "Écho")
        #expect(WindowLevel.presetName(fromMenuTitle: "10 - ") == "")
        // Without a number and " - " ahead, the first four characters go, as before.
        #expect(WindowLevel.presetName(fromMenuTitle: "Brain") == "n")
    }

    /// The window level menus of the MPR, the CPR, the orthogonal MPRs, the PET-CT and the volume
    /// rendering list the stored presets as `ReconstructionPreferences.windowLevelMenuTitles`, those of the
    /// 2D viewer as `ViewerPresetMenus.wlwwPresetTitle`; the windows find the preset again from the title
    /// of the chosen item. With twelve presets, every item, the tenth and later included, gives its own.
    @Test func everyOfTwelveWindowLevelItemsFindsItsPreset() throws {
        let store = MemoryPreferences()
        var levels: [String: IsiXPreferences.WindowLevelPreset] = [:]
        for index in 0 ..< 12 {
            levels[String(format: "Preset %02d - part", index)] = IsiXPreferences.WindowLevelPreset(level: Float(index * 10), width: Float(100 + index))
        }
        store.set(levels, for: ImagePresetPreferences.windowLevelPresets)

        let titles = ReconstructionPreferences.windowLevelMenuTitles(in: store)
        #expect(titles.count == 12)
        #expect(titles[9] == "10 - Preset 09 - part" && titles[11] == "12 - Preset 11 - part")
        for (index, title) in titles.enumerated() {
            let name = try #require(WindowLevel.presetName(fromMenuTitle: title))
            let preset = ReconstructionPreferences.preset(name, of: ImagePresetPreferences.windowLevelPresets, in: store)
            #expect(preset?.level == Double(index * 10) && preset?.width == Double(100 + index), "\(title)")
            #expect(ViewerPresetMenus.checksWLWWItem(title: title, current: name))
        }

        let names = ViewerPresetMenus.sortedNames(Array(levels.keys))
        for (index, name) in names.enumerated() {
            let title = ViewerPresetMenus.wlwwPresetTitle(index: index, name: name)
            #expect(WindowLevel.presetName(fromMenuTitle: title) == name, "\(title)")
        }
    }

    @Test func stackFusion() {
        #expect(StackFusion.mode(3, imageSizes: [(4, 4), (4, 4)]) == 3)
        #expect(StackFusion.mode(3, imageSizes: [(4, 4), (5, 4)]) == 0)
        #expect(StackFusion.mode(3, imageSizes: []) == 3)
        #expect(StackFusion.isVolumeRendering(5) && StackFusion.flipsVolumeRendering(4) && !StackFusion.flipsVolumeRendering(5))
        // The slider's thin end is one slice, which is no slab.
        #expect(StackFusion.sliderMove(to: 1, active: true, tracking: true) == .switchOff)
        #expect(StackFusion.sliderMove(to: 0, active: true, tracking: false) == .switchOff)
        #expect(StackFusion.sliderMove(to: 1, active: false, tracking: true) == .none)
        // The drag that switched the fusion off brings it back; nothing else starts one.
        #expect(StackFusion.sliderMove(to: 7, active: false, tracking: true) == .start(7))
        #expect(StackFusion.sliderMove(to: 7, active: false, tracking: false) == .set(7))
        #expect(StackFusion.sliderMove(to: 2, active: true, tracking: true) == .set(2))
        #expect(StackFusion.thickness(afterSteps: 3, active: false, current: 7, maximum: 10) == 2)
        #expect(StackFusion.thickness(afterSteps: -1, active: false, current: 7, maximum: 10) == nil)
        #expect(StackFusion.thickness(afterSteps: 500, active: true, current: 2, maximum: 300) == 130)
        #expect(StackFusion.thickness(afterSteps: -9, active: true, current: 5, maximum: 10) == 1)
        #expect(StackFusion.thickness(afterSteps: 1, active: true, current: 10, maximum: 10) == nil)
        #expect(StackFusion.thickness(afterSteps: 1, active: true, current: 1, maximum: 1) == nil)
        #expect(StackFusion.thickness(afterSteps: 0, active: true, current: 3, maximum: 10) == nil)
    }

    @Test func theSlabSliderReachesTheWholeSeries() {
        #expect(StackFusion.sliderMaximum(sliceCounts: [347]) == 347)
        // Every time of a 4D series has the slab: the shortest one rules.
        #expect(StackFusion.sliderMaximum(sliceCounts: [120, 118, 120]) == 118)
        // A slab needs two slices, and the images count them in 16 bits.
        #expect(StackFusion.sliderMaximum(sliceCounts: [1]) == 2)
        #expect(StackFusion.sliderMaximum(sliceCounts: []) == 2)
        #expect(StackFusion.sliderMaximum(sliceCounts: [100_000]) == 32_767)
    }
}
