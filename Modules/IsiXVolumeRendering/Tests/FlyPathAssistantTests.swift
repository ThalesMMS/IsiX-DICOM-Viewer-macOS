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
@testable import IsiXVolumeRendering

/// The endoscopy's path assistant: what earlier fixes made of the centerline
/// search and the view scan, which must hold. Its arithmetic against the
/// Objective-C++ it came from, with the corrections it documents, is
/// tests/test-fly-path-equivalence.py.
struct FlyPathAssistantTests {

    // MARK: - Volumes

    /// An assistant over `volume` (`size` voxels spaced by `spacing`),
    /// resampled at `resampleVoxelSize`; the caller keeps the volume.
    private func assistant(_ volume: [Float], _ size: SIMD3<Int>, spacing: SIMD3<Float>,
                           resampleVoxelSize: Float = 1) -> FlyPathAssistant {
        volume.withUnsafeBufferPointer {
            FlyPathAssistant(volume: $0.baseAddress!, width: size.x, height: size.y, depth: size.z,
                             spacing: spacing, resampleVoxelSize: resampleVoxelSize)!
        }
    }

    /// 20 × 20 × `depth` voxels of 0.5 mm, all wall (0) but for a tube along z (1000).
    private func tubeVolume(depth: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 20 * 20 * depth)
        for z in 4..<(depth - 4) { for y in 6..<14 { for x in 6..<14 { v[(z * 20 + y) * 20 + x] = 1000 } } }
        return v
    }

    private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }

    /// The centerline from A to B as the app's FlyAssistant keeps it: thinned by the lumen's radius.
    private func centerline(_ fly: FlyPathAssistant, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (Int32, [SIMD3<Float>]) {
        let (code, points) = fly.centerline(from: a, to: b)
        guard code == 0, points.count > 2 else { return (code, points) }
        return (code, fly.thinnedCenterlineIndices(points).map { points[$0] })
    }

    private func endsNear(_ line: [SIMD3<Float>], _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        guard let head = line.first, let tail = line.last else { return false }
        return min(distance(head, a) + distance(tail, b), distance(head, b) + distance(tail, a)) < 6
    }

    // MARK: - Centerline

    @Test func twoSearchesFromTheSamePointsFindTheSameCenterline() {
        let volume = tubeVolume(depth: 128)
        let fly = assistant(volume, SIMD3(20, 20, 128), spacing: SIMD3(repeating: 0.5))
        let a = SIMD3<Float>(10, 10, 12), b = SIMD3<Float>(10, 10, 115)
        let (first, line) = centerline(fly, a, b)
        let (second, again) = centerline(fly, a, b)
        #expect(first == 0 && second == 0)
        #expect(line.count > 1 && line == again)
        #expect(endsNear(line, a, b))
        // The thresholds come from the voxels around A and B, the tube's.
        #expect(fly.thresholdA <= 1000 && 1000 <= fly.thresholdB)
    }

    @Test func theDistanceTransformCoversEverySlice() {
        // 20, 44 and 64 resampled slices: fewer than a block of 32, a block and 12, two blocks.
        for depth in [40, 88, 128] {
            let volume = tubeVolume(depth: depth)
            let fly = assistant(volume, SIMD3(20, 20, depth), spacing: SIMD3(repeating: 0.5))
            fly.computeIntervalThresholds(from: 1000)
            fly.distanceTransform()
            let (w, h, d) = (fly.distmapWidth, fly.distmapHeight, fly.distmapDepth)
            var untouched = 0
            for z in 1..<(d - 1) { for y in 1..<(h - 1) { for x in 1..<(w - 1) where fly.distmap![x + w * y + w * h * z] > 1e30 {
                untouched += 1
            } } }
            #expect(untouched == 0, "\(d) resampled slices: \(untouched) voxels kept 3.4e38")
            let middle = fly.distmap![w / 2 + w * (h / 2) + w * h * (d / 2)]
            let end = fly.distmap![w / 2 + w * (h / 2) + w * h * (d - 7)]
            #expect(middle > 0 && middle < 1e30 && middle == end, "\(d) resampled slices: the tube's center is \(middle) and \(end)")
        }
    }

    @Test func aVolumeOfFewerThan32ResampledSlicesHasACenterline() {
        let volume = tubeVolume(depth: 40)
        let fly = assistant(volume, SIMD3(20, 20, 40), spacing: SIMD3(repeating: 0.5))
        let a = SIMD3<Float>(10, 10, 10), b = SIMD3<Float>(10, 10, 30)
        let (code, line) = centerline(fly, a, b)
        #expect(code == 0 && line.count > 1 && endsNear(line, a, b))
    }

    // MARK: - Voxel centres and ends

    /// 20 × 20 × 64 voxels of 1 mm, resampled at 1 mm: the tube's voxels 6
    /// to 13 put its axis at x = y = 9.5.
    private func tubeAtTheInputsGrid() -> (volume: [Float], fly: FlyPathAssistant) {
        let volume = tubeVolume(depth: 64)
        let fly = assistant(volume, SIMD3(20, 20, 64), spacing: SIMD3(repeating: 1))
        return (volume, fly)
    }

    @Test func theCenterlineRunsOnTheAxisThroughVoxelCentresFromClickToClick() {
        let (volume, fly) = tubeAtTheInputsGrid()
        let a = SIMD3<Float>(9.2, 9.8, 8.3), b = SIMD3<Float>(9.7, 9.4, 55.6)
        let (code, raw) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
        #expect(code == 0 && raw.count > 40)
        #expect(raw.first == a && raw.last == b, "the path runs from \(raw.first.map { "\($0)" } ?? "-") to \(raw.last.map { "\($0)" } ?? "-")")
        // Between the ends, the centres of the resampled voxels, on the tube's axis.
        let offAxis = raw.dropFirst().dropLast().filter { $0.x != 9.5 || $0.y != 9.5 || $0.z - $0.z.rounded(.down) != 0.5 }
        #expect(offAxis.isEmpty, "\(offAxis.count) points are off the axis or the voxels' centres, as \(offAxis.first.map { "\($0)" } ?? "-")")
        let thinned = fly.thinnedCenterlineIndices(raw).map { raw[$0] }
        #expect(thinned.first == a && thinned.last == b)
    }

    @Test func theThinnedCenterlineEndsAtTheSecondClickWhereverItFalls() {
        let (volume, fly) = tubeAtTheInputsGrid()
        let a = SIMD3<Float>(9.5, 9.5, 8.5)
        for z in 50...54 {
            let b = SIMD3<Float>(9.5, 9.5, Float(z) + 0.5)
            let (code, raw) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
            let kept = fly.thinnedCenterlineIndices(raw)
            #expect(code == 0 && kept.first == 0 && kept.last == raw.count - 1, "ending at z = \(z) the line stops at index \(kept.last ?? -1) of \(raw.count)")
            // The points kept stay apart: the last one takes the place of the
            // one before it rather than crowding it.
            let gaps = zip(kept, kept.dropFirst()).map { distance(raw[$0], raw[$1]) }
            #expect(gaps.allSatisfy { $0 >= 2 }, "ending at z = \(z) the points kept are \(gaps) apart")
        }
    }

    @Test func aResampledVoxelTakesTheValueAtItsCentre() {
        // A bright slab, x up to 9, on a dark ground, resampled at the input's
        // grid: the resampled voxel 9 lies between the input's voxels 9 (in
        // the slab) and 10, and reads 500 at its centre.
        var volume = [Float](repeating: 0, count: 20 * 8 * 8)
        for z in 0..<8 { for y in 0..<8 { for x in 0...9 { volume[(z * 8 + y) * 20 + x] = 1000 } } }
        let fly = assistant(volume, SIMD3(20, 8, 8), spacing: SIMD3(repeating: 1))
        func lumen(_ low: Float, _ high: Float) -> [Int] {
            fly.thresholdA = low
            fly.thresholdB = high
            withExtendedLifetime(volume) { fly.thresholdImage() }
            // The row y = 3 of the slice z = 4: the closing that follows reads the
            // map in runs of 8 values (the depth), and none starts or ends at its
            // voxels 8 to 10, where a run's clipped edge would join the lumen.
            let row = 4 * fly.distmapImageSize + 3 * fly.distmapWidth
            return (0..<fly.distmapWidth).filter { fly.distmap![row + $0] > 0 }
        }
        // The voxel across the edge belongs to the side its centre's value falls
        // in, bright or dark: the brightest of its voxels put it in the bright side.
        #expect(lumen(600, 1400) == Array(0...8))
        #expect(lumen(300, 1400) == Array(0...9))
        #expect(lumen(-100, 400) == Array(10..<20))
        #expect(lumen(-100, 700) == Array(9..<20))
    }

    @Test func coarserVoxelsAndThickSlicesAreSampledAtTheirCentres() {
        // Voxels of 0.5 mm across x resampled at 1 mm: the resampled voxel i
        // has its centre on the input's voxel 2i + 1. A bright slab up to x = 8
        // leaves the resampled voxel 4 (centre 9) dark; the brightest of the
        // voxels 8 and 9 put it in the slab.
        var across = [Float](repeating: 0, count: 32 * 8 * 8)
        for z in 0..<8 { for y in 0..<8 { for x in 0...8 { across[(z * 8 + y) * 32 + x] = 1000 } } }
        let coarse = assistant(across, SIMD3(32, 8, 8), spacing: SIMD3(0.5, 1, 1))
        #expect(coarse.resampleScale == SIMD3(0.5, 1, 1) && coarse.distmapWidth == 16)
        coarse.thresholdA = 600
        coarse.thresholdB = 1400
        withExtendedLifetime(across) { coarse.thresholdImage() }
        // The row y = 3 of the slice z = 4; the closing's runs of 8 values (the
        // depth) are the row's halves, which start and end away from the slab's edge.
        let row = 4 * coarse.distmapImageSize + 3 * coarse.distmapWidth
        #expect((0..<coarse.distmapWidth).filter { coarse.distmap![row + $0] > 0 } == Array(0...3))

        // Slices of 2 mm resampled at 1 mm: the resampled slice k has its centre
        // at (k + 0.5) / 2, a quarter or three quarters of the way between two
        // slices. A bright slab up to the slice 4 reads 1000, 750, 250 and 0 on
        // the resampled slices 7 to 10. Every slice is uniform and the closing's
        // runs (16 values, the depth) lie each in one slice, so it changes nothing.
        var along = [Float](repeating: 0, count: 8 * 8 * 8)
        for z in 0...4 { for i in 0..<64 { along[z * 64 + i] = 1000 } }
        let thick = assistant(along, SIMD3(8, 8, 8), spacing: SIMD3(1, 1, 2))
        #expect(thick.resampleScale == SIMD3(1, 1, 2) && thick.distmapDepth == 16)
        func slices(_ low: Float, _ high: Float) -> [Int] {
            thick.thresholdA = low
            thick.thresholdB = high
            withExtendedLifetime(along) { thick.thresholdImage() }
            return (0..<thick.distmapDepth).filter { thick.distmap![$0 * thick.distmapImageSize + 3 * thick.distmapWidth + 4] > 0 }
        }
        #expect(slices(800, 1400) == Array(0...7))
        #expect(slices(600, 1400) == Array(0...8))
        #expect(slices(200, 1400) == Array(0...9))
        #expect(slices(-100, 200) == Array(10..<16))
        #expect(slices(-100, 700) == Array(9..<16))
    }

    /// Three tissues across x: 0 up to x = 7, 1000 at 8 and 9, 500 from 10 on.
    /// Two thirds of the voxels around x = 8 are at 1000 and two thirds of
    /// those around x = 7 at 0: their medians, which the histogram puts in
    /// other intervals.
    private func threeTissues() -> [Float] {
        var volume = [Float](repeating: 0, count: 24 * 8 * 8)
        for z in 0..<8 { for y in 0..<8 { for x in 8..<24 { volume[(z * 8 + y) * 24 + x] = x < 10 ? 1000 : 500 } } }
        return volume
    }

    @Test func theThresholdsComeFromTheVoxelsAroundTheOneNearestToEachPoint() {
        let volume = threeTissues()
        func thresholds(from median: Float) -> (Float, Float) {
            let fly = assistant(volume, SIMD3(24, 8, 8), spacing: SIMD3(repeating: 1))
            fly.computeIntervalThresholds(from: median)
            return (fly.thresholdA, fly.thresholdB)
        }
        // 2 × 27 voxels, two thirds of them at 1000 around x = 8, a third around x = 7.
        let nearest = thresholds(from: 1000), aside = thresholds(from: 0)
        #expect(nearest != aside)
        // The Curved MPR counts the voxel 8 at 8, the endoscopy's views from its
        // corner (8 to 9): x = 7.6 and x = 8.2 are both nearest to it, though
        // the voxel from the corner of 7.6 (or of 8.2 - 0.5) is 7.
        for (frame, x) in [(SIMD3<Float>(repeating: 0), Float(7.6)), (SIMD3<Float>(0.5, 0.5, 0), Float(8.2))] {
            let fly = assistant(volume, SIMD3(24, 8, 8), spacing: SIMD3(repeating: 1))
            fly.firstVoxelCentre = frame
            _ = withExtendedLifetime(volume) { fly.centerline(from: SIMD3(x, 3.6, 2.2), to: SIMD3(x, 4.3, 5.4)) }
            #expect((fly.thresholdA, fly.thresholdB) == nearest, "from x = \(x) in the frame \(frame)")

            let navigator = assistant(volume, SIMD3(24, 8, 8), spacing: SIMD3(repeating: 1))
            navigator.firstVoxelCentre = frame
            var pt = SIMD3<Float>(x, 3.6, 2.2), dir = SIMD3<Float>(0, 0, 1)
            _ = withExtendedLifetime(volume) { navigator.nextPosition(from: &pt, towards: &dir) }
            // One point, 27 voxels: the same median.
            #expect((navigator.thresholdA, navigator.thresholdB) == nearest, "a step from x = \(x) in the frame \(frame)")
        }
    }

    @Test func theEndoscopysPixelCornersPutThePathOnTheAxisItsViewsDraw() {
        // The endoscopy's views count the pixel i from i to i + 1: the tube's
        // pixels 6 to 13 put its axis at x = y = 10 there, and the slice k at z = k.
        let (volume, fly) = tubeAtTheInputsGrid()
        let frame = SIMD3<Float>(0.5, 0.5, 0)
        fly.firstVoxelCentre = frame
        let a = SIMD3<Float>(10.3, 9.6, 8), b = SIMD3<Float>(9.8, 10.4, 55)
        let (code, raw) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
        #expect(code == 0 && raw.count > 40)
        #expect(raw.first == a && raw.last == b)
        let offAxis = raw.dropFirst().dropLast().filter { $0.x != 10 || $0.y != 10 || $0.z - $0.z.rounded(.down) != 0.5 }
        #expect(offAxis.isEmpty, "\(offAxis.count) points are off the axis or the voxels' centres, as \(offAxis.first.map { "\($0)" } ?? "-")")
        let thinned = fly.thinnedCenterlineIndices(raw).map { raw[$0] }
        #expect(thinned.first == a && thinned.last == b && thinned.count > 2)

        // The radius, the view and a step of the navigator are those of the
        // Curved MPR's frame at the point moved back by the frame.
        let (_, plain) = tubeAtTheInputsGrid()
        _ = withExtendedLifetime(volume) { plain.centerline(from: a - frame, to: b - frame) }
        let middle = raw[raw.count / 2]
        #expect(fly.radius(at: middle) == plain.radius(at: middle - frame) && fly.radius(at: middle) > 0)
        #expect(fly.averageRadius(at: 5, on: raw, range: 3) == plain.averageRadius(at: 5, on: raw.map { $0 - frame }, range: 3))
        let view = withExtendedLifetime(volume) { fly.maximizingViewDirection(from: middle, lookingAt: middle + SIMD3(0, 0, 6)) }
        let plainView = withExtendedLifetime(volume) { plain.maximizingViewDirection(from: middle - frame, lookingAt: middle - frame + SIMD3(0, 0, 6)) }
        #expect(distance(view - frame, plainView) < 1e-4, "the view \(view) for \(plainView) + \(frame)")
        var pt = SIMD3<Float>(10.2, 9.7, 20), dir = SIMD3<Float>(0, 0, 1)
        var plainPt = pt - frame, plainDir = dir
        let step = withExtendedLifetime(volume) { fly.nextPosition(from: &pt, towards: &dir) }
        let plainStep = withExtendedLifetime(volume) { plain.nextPosition(from: &plainPt, towards: &plainDir) }
        #expect(step == 0 && plainStep == 0 && pt == plainPt + frame && dir == plainDir)
        #expect(fly.resampleCoordinates(ofInputPoint: SIMD3(10, 10, 20)) == SIMD3(9.5, 9.5, 20))
        #expect(fly.inputCoordinates(ofResamplePoint: SIMD3(9.5, 9.5, 20)) == SIMD3(10, 10, 20))
    }

    @Test func aStepThatFindsNoPathLeavesThePointAndDirection() {
        let volume = tubeVolume(depth: 128)
        let fly = assistant(volume, SIMD3(20, 20, 128), spacing: SIMD3(repeating: 0.5))
        fly.computeIntervalThresholds(from: 1000)
        fly.distanceTransform()
        // In the wall beside the tube, looking across x: the cross-section there is all wall.
        var pt = SIMD3<Float>(1, 10, 60), dir = SIMD3<Float>(1, 0, 0)
        #expect(fly.nextPosition(from: &pt, towards: &dir) == FlyPathAssistant.cannotFindPath)
        #expect(pt == SIMD3(1, 10, 60) && dir == SIMD3(1, 0, 0))
    }

    @Test func aStepBeforeTheTransformTakesItsThresholdsAroundItsPoint() {
        let volume = tubeVolume(depth: 128)
        let fly = assistant(volume, SIMD3(20, 20, 128), spacing: SIMD3(repeating: 0.5))
        var pt = SIMD3<Float>(10, 10, 60), dir = SIMD3<Float>(0, 0, 1)
        _ = fly.nextPosition(from: &pt, towards: &dir)
        #expect(fly.thresholdA <= 1000 && 1000 <= fly.thresholdB)
    }

    // MARK: - Thresholds of a noisy lumen

    /// Gaussian noise of 1, the same for a seed (SplitMix64, Box–Muller).
    private struct Noise {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func gaussian() -> Double {
            let u = max(Double(next() >> 11) / Double(1 << 53), 1e-12), v = Double(next() >> 11) / Double(1 << 53)
            return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
        }
    }

    /// 24 × 24 × 40 voxels of 0.6 mm: a contrast-filled vessel (350 HU,
    /// radius 4 voxels, its axis at x = y = 11.5) in soft tissue (40 HU), with
    /// 10 HU of noise in whole units, as a CT gives them, and a column of air
    /// in a corner, which stretches the histogram as the rest of a CT does.
    private func contrastVessel(seed: UInt64) -> [Float] {
        var noise = Noise(state: seed)
        var volume = [Float](repeating: 0, count: 24 * 24 * 40)
        for z in 0..<40 { for y in 0..<24 { for x in 0..<24 {
            let dx = Double(x) - 11.5, dy = Double(y) - 11.5
            let mean: Double = x < 2 && y < 2 ? -900 : dx * dx + dy * dy <= 16 ? 350 : 40
            volume[(z * 24 + y) * 24 + x] = Float((mean + 10 * noise.gaussian()).rounded())
        } } }
        return volume
    }

    @Test func aBrightLumenKeepsItsPathOnTheAxis() {
        // The lumen's values at the resampled voxels' centres lie within a few
        // HU of 350. From the mean of the voxels around the clicks the
        // histogram's interval can start at that mean ([350, 370] for the seed
        // 8), or reach only 10 HU below it: half of the lumen, or its edges,
        // then fell out, and the path zig-zagged up to 3 voxels off the axis.
        let a = SIMD3<Float>(11.5, 11.5, 3), b = SIMD3<Float>(11.8, 11.2, 36)
        for seed in UInt64(1)...8 {
            let volume = contrastVessel(seed: seed)
            let fly = assistant(volume, SIMD3(24, 24, 40), spacing: SIMD3(repeating: 0.6), resampleVoxelSize: 0.6)
            let (code, raw) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
            let offAxis = raw.dropFirst().dropLast().filter { $0.x != 11.5 || $0.y != 11.5 }
            #expect(code == 0 && raw.count > 30 && offAxis.isEmpty,
                    "seed \(seed): \(offAxis.count) points off the axis, as \(offAxis.first.map { "\($0)" } ?? "-"), within [\(fly.thresholdA), \(fly.thresholdB)]")
            let values = withExtendedLifetime(volume) { [a, b].flatMap { fly.inputNeighborhood(fly.nearestInputVoxel($0)) } }
            let mean = values.reduce(0, +) / Float(values.count)
            #expect(fly.thresholdA <= mean - 10 && mean + 10 <= fly.thresholdB, "seed \(seed): [\(fly.thresholdA), \(fly.thresholdB)] from \(mean)")
            if seed == 8 {
                // The case seen in the app: the histogram's own interval starts at the mean.
                fly.computeIntervalThresholds(from: mean)
                #expect(fly.thresholdA > mean - 1, "the histogram's interval from \(mean) is [\(fly.thresholdA), \(fly.thresholdB)]")
            }
        }
    }

    /// 24 × 24 × 40 voxels of 0.6 mm: a contrast-filled vessel of 2 mm
    /// (300 HU, its axis at x = y = 11.5) in fat (-100 HU) out to 6 mm and
    /// soft tissue (40 HU) beyond, each wall blurred as a Gaussian of 0.6 mm
    /// blurs it (a CT's kernel and its voxels), with 15 HU of noise in whole
    /// units and the column of air.
    private func blurredVesselInFat(seed: UInt64) -> [Float] {
        var noise = Noise(state: seed)
        var volume = [Float](repeating: 0, count: 24 * 24 * 40)
        /// The share, `r` mm from the axis, of what lies within `edge` mm of
        /// it, blurred: 1 well within, 0 well beyond.
        func within(_ r: Double, _ edge: Double) -> Double { erfc((r - edge) / (0.6 * 2.0.squareRoot())) / 2 }
        for z in 0..<40 { for y in 0..<24 { for x in 0..<24 {
            let dx = Double(x) - 11.5, dy = Double(y) - 11.5
            let r = (dx * dx + dy * dy).squareRoot() * 0.6
            let mean = x < 2 && y < 2 ? -900 : 40 - 140 * within(r, 6) + 400 * within(r, 2)
            volume[(z * 24 + y) * 24 + x] = Float((mean + 15 * noise.gaussian()).rounded())
        } } }
        return volume
    }

    @Test func pointsBesideABlurredWallLeaveTheTissueAroundOutOfTheLumen() {
        // From points 1.4 mm off the axis the voxels around them run down the
        // wall's ramp from the lumen to the fat. Their deviation measures the
        // ramp, not the noise: an interval widened by all of it took in the fat
        // and the tissue, ten times the vessel's voxels ([-48, 402] for the
        // seed 2, from the histogram's [177, 197]), for a centerline and a step.
        let vesselVoxels = Float.pi * (2 / 0.6) * (2 / 0.6) * 40
        let off: Float = 1.4 / 0.6
        let a = SIMD3<Float>(11.5 + off, 11.5, 3), b = SIMD3<Float>(11.5, 11.5 - off, 36)
        func lumenVoxels(_ fly: FlyPathAssistant) -> Int { (0..<fly.distmapVolumeSize).filter { fly.distmap![$0] > 0 }.count }
        for seed in UInt64(1)...6 {
            let volume = blurredVesselInFat(seed: seed)
            let fly = assistant(volume, SIMD3(24, 24, 40), spacing: SIMD3(repeating: 0.6), resampleVoxelSize: 0.6)
            let (code, _) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
            // Above the tissue's values, give or take three times its noise.
            #expect(code == 0 && fly.thresholdA > 85 && Float(lumenVoxels(fly)) < vesselVoxels,
                    "seed \(seed): a centerline within [\(fly.thresholdA), \(fly.thresholdB)], \(lumenVoxels(fly)) voxels of lumen")
            let navigator = assistant(volume, SIMD3(24, 24, 40), spacing: SIMD3(repeating: 0.6), resampleVoxelSize: 0.6)
            var pt = a, dir = SIMD3<Float>(0, 0, 1)
            _ = withExtendedLifetime(volume) { navigator.nextPosition(from: &pt, towards: &dir) }
            #expect(navigator.thresholdA > 85 && Float(lumenVoxels(navigator)) < vesselVoxels,
                    "seed \(seed): a step within [\(navigator.thresholdA), \(navigator.thresholdB)], \(lumenVoxels(navigator)) voxels of lumen")
        }
    }

    @Test func pointsOnAFaceOfTheVolumePlantNoSeedAcrossIt() {
        // Two lumens that do not touch: one at the left face of the volume, the
        // other at the right face, one row up. The voxel before the first
        // column of a row is, in the volume's memory, the last column of the
        // row before: the seeds planted around a point of the left face landed
        // in the other lumen, and the path jumped across the volume there.
        let size = SIMD3(16, 12, 12)
        var volume = [Float](repeating: 0, count: size.x * size.y * size.z)
        for z in 4...6 {
            for y in 5...7 { for x in 0...4 { volume[(z * size.y + y) * size.x + x] = 1000 } }
            for y in 2...3 { for x in 11...15 { volume[(z * size.y + y) * size.x + x] = 1000 } }
        }
        let fly = assistant(volume, size, spacing: SIMD3(repeating: 1))
        let a = SIMD3<Float>(0, 6, 5), b = SIMD3<Float>(13, 3, 5)
        let (code, points) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
        #expect(code == 0 && points.count > 2)
        // Each voxel of the path touches the next: the wall between the lumens is crossed, not skipped.
        let longest = zip(points, points.dropFirst()).map { distance($0, $1) }.max() ?? 0
        #expect(longest < 1.8, "the path steps \(longest) voxels at once")
        // The same at the last column, row and slice.
        let (back, reversed) = withExtendedLifetime(volume) { fly.centerline(from: SIMD3(15, 3, 5), to: SIMD3(2, 6, 5)) }
        #expect(back == 0 && (zip(reversed, reversed.dropFirst()).map { distance($0, $1) }.max() ?? 9) < 1.8)
    }

    @Test func theLumenIsClosedAlongTheSlicesNotAlongRunsOfTheMemory() {
        // A lumen that is the half of the volume at x >= 5, in 10 x 10 x 7
        // voxels: its closing "along the depth" read the memory in runs of 7
        // values along x, across the rows, and added a voxel of lumen where a
        // run started beside the lumen or ended at the start of a row. (A
        // resampled voxel takes the value at its centre, between two voxels:
        // 500 at x = 4, under the threshold.)
        let size = SIMD3(10, 10, 7)
        var volume = [Float](repeating: 0, count: size.x * size.y * size.z)
        for z in 0..<size.z { for y in 0..<size.y { for x in 5..<size.x { volume[(z * size.y + y) * size.x + x] = 1000 } } }
        let fly = assistant(volume, size, spacing: SIMD3(repeating: 1))
        fly.thresholdA = 600
        fly.thresholdB = 1500
        withExtendedLifetime(volume) { fly.thresholdImage() }
        var stray: [SIMD3<Int>] = []
        for z in 0..<size.z { for y in 0..<size.y { for x in 0..<size.x {
            if (fly.distmap![(z * size.y + y) * size.x + x] > 0) != (x >= 5) { stray.append(SIMD3(x, y, z)) }
        } } }
        #expect(stray.isEmpty, "\(stray.count) voxels are not the half volume's, the first at \(stray.first ?? SIMD3(0, 0, 0))")

        // A gap of one resampled slice in a lumen along z is closed, as a gap of one voxel in a slice
        // is: slices 3 and 4 without the lumen leave 500, 0 and 500 at the resampled slices 2, 3 and 4.
        var gapped = [Float](repeating: 0, count: size.x * size.y * size.z)
        for z in 0..<size.z where z != 3 && z != 4 { for y in 2...7 { for x in 2...7 { gapped[(z * size.y + y) * size.x + x] = 1000 } } }
        let closing = assistant(gapped, size, spacing: SIMD3(repeating: 1))
        closing.thresholdA = 400
        closing.thresholdB = 1500
        withExtendedLifetime(gapped) { closing.thresholdImage() }
        #expect(closing.distmap![(3 * size.y + 4) * size.x + 4] > 0 && closing.distmap![(3 * size.y + 0) * size.x + 0] == 0)
    }

    @Test func pointsInTheRingOfAWallsPartialVolumeTakeTheLumensValue() {
        // 0.3 mm inside the edge of a wall blurred over 0.6 mm, the voxels
        // around a point are the lumen's for more than half and the wall's ramp
        // for the rest. Their mean lies on the ramp, the thresholds came from
        // there, and the lumen leaked into the tissue (twelve times the vessel
        // for two seeds of six) and every step failed; their median is nearer
        // the lumen's. A step has one point's voxels: where the point's own
        // value is far down the ramp it may still find no path, and says so.
        let vesselVoxels = Float.pi * (2 / 0.6) * (2 / 0.6) * 40
        let off: Float = 1.7 / 0.6
        let a = SIMD3<Float>(11.5 + off, 11.5, 3), b = SIMD3<Float>(11.5, 11.5 - off, 36)
        func lumenVoxels(_ fly: FlyPathAssistant) -> Int { (0..<fly.distmapVolumeSize).filter { fly.distmap![$0] > 0 }.count }
        var stepsWithoutAPath = 0
        for seed in UInt64(1)...6 {
            let volume = blurredVesselInFat(seed: seed)
            let fly = assistant(volume, SIMD3(24, 24, 40), spacing: SIMD3(repeating: 0.6), resampleVoxelSize: 0.6)
            let (code, _) = withExtendedLifetime(volume) { fly.centerline(from: a, to: b) }
            #expect(code == 0 && Float(lumenVoxels(fly)) < 1.5 * vesselVoxels,
                    "seed \(seed): a centerline (\(code)) within [\(fly.thresholdA), \(fly.thresholdB)], \(lumenVoxels(fly)) voxels of lumen")
            let navigator = assistant(volume, SIMD3(24, 24, 40), spacing: SIMD3(repeating: 0.6), resampleVoxelSize: 0.6)
            var pt = a, dir = SIMD3<Float>(0, 0, 1)
            let step = withExtendedLifetime(volume) { navigator.nextPosition(from: &pt, towards: &dir) }
            #expect(Float(lumenVoxels(navigator)) < 1.5 * vesselVoxels,
                    "seed \(seed): a step (\(step)) within [\(navigator.thresholdA), \(navigator.thresholdB)], \(lumenVoxels(navigator)) voxels of lumen")
            if step != 0 { stepsWithoutAPath += 1 }
        }
        #expect(stepsWithoutAPath <= 1, "\(stepsWithoutAPath) steps of 6 found no path")
    }

    @Test func theIntervalHoldsTheMeanGiveOrTakeTheNoiseUnlessItCameFromAnotherPeak() {
        let volume = threeTissues()
        let fly = assistant(volume, SIMD3(24, 8, 8), spacing: SIMD3(repeating: 1))
        func lumen(from mean: Float, among values: [Float]) -> (Float, Float) {
            fly.computeLumenThresholds(from: mean, among: values)
            return (fly.thresholdA, fly.thresholdB)
        }
        // Median 0 (lower middle), deviations 0 5 5 10 10 20 20: 10; three of them, 30. Not a number is left out.
        let noise: [Float] = [-20, -10, -5, 0, 5, 10, 20, .nan]
        // The histogram's intervals: [990, 1010] from 1000, [490, 530] from 520, [996, 1016] from 666.67.
        // The margin is at most the interval's width: 20 from 1000, 30 from 520.
        #expect(lumen(from: 1000, among: noise.map { 1000 + $0 }) == (980, 1020))
        #expect(lumen(from: 520, among: noise.map { 520 + $0 }) == (490, 550))
        // Values spread far wider than the interval, down a blurred wall: widened by its width, not by theirs.
        #expect(lumen(from: 1000, among: [0, 250, 500, 750, 1000, 1000, 1000]) == (980, 1020))
        // The mean of voxels on either side of a wall, far from the interval the histogram took: as it is.
        #expect(lumen(from: 666.67, among: noise.map { 666.67 + $0 }) == (996, 1016))
        // Without voxels, or without noise, the histogram's interval.
        #expect(lumen(from: 1000, among: []) == (990, 1010))
        #expect(lumen(from: 1000, among: [Float](repeating: 1000, count: 27)) == (990, 1010))
    }

    // MARK: - Resampled grid

    @Test func anAxisAHairShortOfAWholeNumberOfVoxelsHasThatNumber() {
        // 110 slices 0.59999996 mm apart, as a slice interval measured between
        // two positions of 0.6 mm slices comes out in float, resampled at
        // 0.6 mm: 110 resampled slices, where the truncated quotient made 109.
        let volume = [Float](repeating: 0, count: 4 * 4 * 110)
        let sliced = assistant(volume, SIMD3(4, 4, 110), spacing: SIMD3(0.6, 0.6, 0.59999996), resampleVoxelSize: 0.6)
        #expect(sliced.distmapDepth == 110 && sliced.resampleScale.z == 1)
        // A quotient that is not a whole number keeps the whole voxels it holds: 48 × 0.7 mm at 1 mm, 33.
        let wide = [Float](repeating: 0, count: 48 * 4 * 4)
        let coarse = assistant(wide, SIMD3(48, 4, 4), spacing: SIMD3(0.7, 1, 1))
        #expect(coarse.distmapWidth == 33)
    }

    // MARK: - View scan

    private func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { v / ((v * v).sum().squareRoot()) }
    private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
    private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    private func degrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(max(-1, min(1, dot(unit(a), unit(b))))) * 180 / .pi
    }
    private func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
    private func float(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

    /// `v` turned `deg` degrees about `axis` (Rodrigues).
    private func rotated(_ v: SIMD3<Double>, _ axis: SIMD3<Double>, _ deg: Double) -> SIMD3<Double> {
        let r = deg * .pi / 180, k = unit(axis)
        return v * cos(r) + cross(k, v) * sin(r) + k * dot(k, v) * (1 - cos(r))
    }

    /// The signed angle of `v` from `forward` about `axis`, in the plane normal to it.
    private func about(_ v: SIMD3<Double>, _ forward: SIMD3<Double>, _ axis: SIMD3<Double>) -> Double {
        let k = unit(axis)
        let f = unit(forward - k * dot(forward, k)), p = unit(v - k * dot(v, k))
        return atan2(dot(k, cross(f, p)), dot(f, p)) * 180 / .pi
    }

    private let C = SIMD3<Float>(10, 20, 30)

    /// The scan from C toward C + forward, the volume replaced by a target:
    /// the farther a ray, the nearer it is to the target. The rays traced, and
    /// the view returned (from C).
    private func scan(_ forward: SIMD3<Double>, toward target: SIMD3<Double>) -> (traced: [SIMD3<Double>], view: SIMD3<Double>) {
        let volume = [Float](repeating: 0, count: 8 * 8 * 8)
        let fly = assistant(volume, SIMD3(8, 8, 8), spacing: SIMD3(repeating: 1))
        nonisolated(unsafe) var traced: [SIMD3<Double>] = []
        let goal = unit(target)
        fly.traceProbe = { _, direction in
            let d = SIMD3(Double(direction.x), Double(direction.y), Double(direction.z))
            traced.append(d)
            return UInt32((1e6 * (2.0 + (d / ((d * d).sum().squareRoot()) * goal).sum())).rounded())
        }
        let best = fly.maximizingViewDirection(from: C, lookingAt: C + float(forward))
        return (traced, double(best - C))
    }

    private func extent(_ traced: [SIMD3<Double>], _ forward: SIMD3<Double>, _ axis: SIMD3<Double>) -> (Double, Double) {
        let angles = traced.map { about($0, forward, axis) }
        return (angles.min() ?? 0, angles.max() ?? 0)
    }

    @Test func lookingAlongXTheScanCoversTheSquareGrid() {
        let forward = SIMD3<Double>(7, 0, 0)
        let traced = scan(forward, toward: forward).traced
        #expect(traced.count == 31 * 31)
        for axis in [SIMD3<Double>(0, 0, 1), SIMD3(0, 1, 0)] {
            let (lo, hi) = extent(traced, forward, axis)
            #expect(lo <= -44 && hi >= 44, "about \(axis) the scan covers \(lo) to \(hi) degrees")
        }
        #expect(traced.map { degrees($0, forward) }.min()! < 1)
        var missing = 0
        for el in stride(from: -45, through: 45, by: 3) {
            for az in stride(from: -45, through: 45, by: 3) {
                let hit = traced.contains { v in
                    let u = unit(v)
                    return abs(atan2(u.y, u.x) * 180 / .pi - Double(az)) < 0.1 && abs(asin(u.z) * 180 / .pi - Double(el)) < 0.1
                }
                if !hit { missing += 1 }
            }
        }
        #expect(missing == 0, "\(missing) grid nodes have no ray")
    }

    @Test func lookingObliquelyTheScanCoversBothAxes() {
        let forward = SIMD3<Double>(1, 2, 3), a = SIMD3<Double>(-2, 1, 0)
        let traced = scan(forward, toward: forward).traced
        #expect(traced.count == 31 * 31)
        for axis in [a, cross(forward, a)] {
            let (lo, hi) = extent(traced, forward, axis)
            #expect(lo <= -44 && hi >= 44, "about \(axis) the scan covers \(lo) to \(hi) degrees")
        }
        #expect(traced.map { degrees($0, forward) }.min()! < 1)
    }

    @Test func theGridIsSquareWhicheverWayThePathRuns() {
        let x = SIMD3<Double>(7, 0, 0)
        let reference = scan(x, toward: x).traced.map { degrees($0, x) }.sorted()
        for forward in [SIMD3<Double>(1, 2, 3), SIMD3(0, 0, 1), SIMD3(0, -5, 0.01)] {
            let angles = scan(forward, toward: forward).traced.map { degrees($0, forward) }.sorted()
            #expect(angles.count == reference.count)
            let worst = zip(angles, reference).map { abs($0 - $1) }.max() ?? 1e9
            #expect(worst < 0.1, "looking along \(forward) the rays are up to \(worst) degrees off the square grid")
        }
    }

    @Test func theViewTurnsToTheOpenLumen() {
        let forward = SIMD3<Double>(7, 0, 0), y = SIMD3<Double>(0, 1, 0), z = SIMD3<Double>(0, 0, 1)
        let targets = [forward, rotated(forward, z, 40), rotated(forward, z, -40), rotated(forward, y, -40),
                       rotated(forward, y, 40), rotated(rotated(forward, y, -30), z, 30)]
        for target in targets {
            let view = scan(forward, toward: target).view
            #expect(degrees(view, target) < 2.5, "the view is \(degrees(view, target)) degrees from \(target)")
        }
    }

    // A distance map of 64 × 64 × 128 resampled voxels, all wall, for input
    // voxels twice as fine in x and y and twice as coarse in z.
    private let scale = SIMD3<Float>(0.5, 0.5, 2)
    private let origin = SIMD3<Float>(32.5, 32.5, 8.5)

    private func walledAssistant(_ volume: [Float]) -> FlyPathAssistant {
        let fly = assistant(volume, SIMD3(128, 128, 64), spacing: scale)
        #expect(fly.distmapWidth == 64 && fly.distmapHeight == 64 && fly.distmapDepth == 128 && fly.resampleScale == scale)
        fly.distmap!.update(repeating: 0, count: fly.distmapVolumeSize)
        return fly
    }

    private func carve(_ fly: FlyPathAssistant, _ x: Int, _ y: Int, _ z: Int) {
        if x >= 0 && x < 64 && y >= 0 && y < 64 && z >= 0 && z < 128 { fly.distmap![x + 64 * y + 64 * 64 * z] = 1 }
    }

    private func room(_ fly: FlyPathAssistant) {
        for z in 4..<14 { for y in 28..<38 { for x in 28..<38 { carve(fly, x, y, z) } } }
    }

    /// Opens every voxel whose centre is within `radius` of the half-line from `o` along `d`.
    private func tube(_ fly: FlyPathAssistant, _ o: SIMD3<Double>, _ d: SIMD3<Double>, _ radius: Double) {
        let d = unit(d)
        for z in 0..<128 { for y in 0..<64 { for x in 0..<64 {
            let p = SIMD3(Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5) - o
            let t = dot(p, d)
            if t < -radius { continue }
            let off = p - d * max(t, 0)
            if (off * off).sum().squareRoot() <= radius { carve(fly, x, y, z) }
        } } }
    }

    private var inputVolume: [Float] { [Float](repeating: 0, count: 128 * 128 * 64) }

    @Test func everyRayStartsAtTheCenterlinePoint() {
        let volume = inputVolume
        let fly = walledAssistant(volume)
        room(fly)
        tube(fly, double(origin), SIMD3(0, 0, 1), 1)
        nonisolated(unsafe) var starts: [SIMD3<Float>] = []
        fly.traceProbe = { center, _ in starts.append(center); return nil }
        let c = origin / scale
        _ = fly.maximizingViewDirection(from: c, lookingAt: c + SIMD3<Float>(3, 0, 3) / scale)
        #expect(starts.count == 31 * 31)
        #expect(starts.allSatisfy { distance($0, origin) < 1e-3 })
    }

    @Test func onAnAnisotropicVolumeTheViewLiesAlongTheLumen() {
        let volume = inputVolume
        let fly = walledAssistant(volume)
        // The path runs 45 degrees up in resample coordinates, the only lumen 75 degrees up.
        let forward = SIMD3<Double>(5, 0, 5)
        let lumen = SIMD3<Double>(cos(75 * .pi / 180), 0, sin(75 * .pi / 180))
        tube(fly, double(origin), lumen, 1)
        let c = origin / scale
        let best = fly.maximizingViewDirection(from: c, lookingAt: c + float(forward) / scale)
        let view = double((best - c) * scale)
        #expect(degrees(view, lumen) < 2.5)
        let length = (view * view).sum().squareRoot(), expected = (forward * forward).sum().squareRoot()
        #expect(abs(length - expected) < 0.05 * expected)
    }

    @Test func theTraceStepsOneResampledVoxelAtATime() {
        let volume = inputVolume
        let fly = walledAssistant(volume)
        // Open along +x from x = 11 to 40, but for a wall at x = 22.
        for x in 11...40 where x != 22 { carve(fly, x, 32, 8) }
        for length: Float in [7, 0.5, 1] {
            #expect(fly.traceLine(from: SIMD3(10.5, 32.5, 8.5), along: SIMD3(length, 0, 0)) == 12)
        }
    }

    @Test func aZeroDirectionTracesNothingAndARepeatedPointIsItsOwnView() {
        let volume = inputVolume
        let fly = walledAssistant(volume)
        room(fly)
        #expect(fly.traceLine(from: origin, along: .zero) == 0)
        let c = origin / scale
        #expect(fly.maximizingViewDirection(from: c, lookingAt: c) == c)
    }
}
