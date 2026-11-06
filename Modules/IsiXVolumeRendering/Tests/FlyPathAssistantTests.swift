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
/// Objective-C++ it came from, bit for bit, is tests/test-fly-path-equivalence.py.
struct FlyPathAssistantTests {

    // MARK: - Volumes

    /// An assistant over `volume` (`size` voxels spaced by `spacing`),
    /// resampled at 1; the caller keeps the volume.
    private func assistant(_ volume: [Float], _ size: SIMD3<Int>, spacing: SIMD3<Float>) -> FlyPathAssistant {
        volume.withUnsafeBufferPointer {
            FlyPathAssistant(volume: $0.baseAddress!, width: size.x, height: size.y, depth: size.z,
                             spacing: spacing, resampleVoxelSize: 1)!
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
