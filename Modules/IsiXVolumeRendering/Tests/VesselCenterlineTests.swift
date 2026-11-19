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
import Synchronization
import Testing
@testable import IsiXVolumeRendering

/// The Curved MPR's vessel tracer on synthetic CT angiographies whose vessel
/// axis is known: a coronary beside a cavity, a winding thin vessel, a
/// coronary leaving the aorta, a carotid; and the former fly-through search
/// on the same volumes, which the tracer replaces for the Curved MPR.
struct VesselCenterlineTests {
    static let coronary = SyntheticVessel.coronaryBesideCavity(radius: 1.5)
    static let thinCoronary = SyntheticVessel.coronaryBesideCavity(radius: 1.0)
    static let stenosed = SyntheticVessel.coronaryBesideCavity(radius: 1.5, stenosis: 0.3)
    static let helix = SyntheticVessel.helix(radius: 1.2)
    static let ostium = SyntheticVessel.ostium()
    static let carotid = SyntheticVessel.carotid()

    private func volume(_ v: SyntheticVessel) -> VesselVolume {
        VesselVolume(copying: v.voxels, width: v.size.x, height: v.size.y, depth: v.size.z, spacing: v.spacing)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The former search as the Curved MPR ran it (resampled at `voxel`,
    /// thinned by the radius), and its time.
    private func former(_ v: SyntheticVessel, voxel: Float) -> (code: Int32, line: [SIMD3<Float>], seconds: Double) {
        v.voxels.withUnsafeBufferPointer { buffer in
            let fly = FlyPathAssistant(volume: buffer.baseAddress!, width: v.size.x, height: v.size.y, depth: v.size.z,
                                       spacing: v.spacing, resampleVoxelSize: voxel)!
            let clock = ContinuousClock.now
            let (code, points) = fly.centerline(from: v.start, to: v.end)
            let elapsed = seconds(ContinuousClock.now - clock)
            guard code == 0, points.count > 2 else { return (code, points, elapsed) }
            return (code, fly.thinnedCenterlineIndices(points).map { points[$0] }, elapsed)
        }
    }

    /// The distance in millimetres from a point to a polyline, both in voxel coordinates.
    private func distance(_ p: SIMD3<Float>, toLine line: [SIMD3<Float>], spacing s: SIMD3<Float>) -> Double {
        func mm(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x * s.x), Double(v.y * s.y), Double(v.z * s.z)) }
        let q = mm(p)
        var best = Double.infinity
        for i in 0..<max(line.count - 1, 1) {
            let a = mm(line[i]), b = mm(line[min(i + 1, line.count - 1)])
            let ab = b - a, aq = q - a
            let length = (ab * ab).sum()
            let t = length > 0 ? min(max((aq * ab).sum() / length, 0), 1) : 0
            let d = q - (a + ab * t)
            best = min(best, (d * d).sum().squareRoot())
        }
        return best
    }

    // MARK: - Coronary beside a cavity

    @Test(arguments: [1.5, 1.0])
    func aCoronaryBesideACavityKeepsItsCenterlineInTheTube(radius: Double) throws {
        let v = radius == 1.5 ? Self.coronary : Self.thinCoronary
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        let nodes = line.curveNodes()
        // Every point of the path, and every node of the curve built on it,
        // lies in the tube: nearer to its axis than its radius.
        #expect(v.worstDistance(line.points) < radius, "the path strays \(v.worstDistance(line.points)) mm from the axis")
        #expect(v.worstDistance(nodes) < radius / 2, "the curve strays \(v.worstDistance(nodes)) mm from the axis")
        #expect(line.pointsOutsideLumen == 0 && !line.isLumenFaint)
        #expect(nodes.first == v.start && nodes.last == v.end)
        #expect(line.gridStep == SIMD3(1, 1, 1))
        // The lumen's interval holds the coronary (400 HU) but neither the wall
        // (100 HU) nor the fat (-80 HU).
        #expect(line.lumenRange.contains(400) && !line.lumenRange.contains(100) && !line.lumenRange.contains(-80))
    }

    @Test func theFormerSearchCutsThroughTheCavityOnTheSameVolume() {
        // The Curved MPR resampled a 512 matrix over 200 mm at 0.78 mm.
        let voxel = curvedMPRResampleVoxel(matrix: 512, fieldOfView: 200, spacing: 0.4)
        let v = Self.coronary
        let (code, line, _) = former(v, voxel: voxel)
        #expect(code == 0)
        #expect(v.worstDistance(line) > 10, "the former path keeps within \(v.worstDistance(line)) mm of the axis")
    }

    @Test func aStenosisOnTheWayIsCrossedNotAvoided() throws {
        // A third of the radius left over 4 mm: on the voxels of the search the
        // narrowest part reads below the lumen's interval, a short occlusion.
        let v = Self.stenosed
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        #expect(v.worstDistance(line.points) < v.radius, "the path strays \(v.worstDistance(line.points)) mm from the axis")
        #expect(line.pointsOutsideLumen < 10)
    }

    // MARK: - Other vessels

    @Test func aWindingThinVesselIsFollowed() throws {
        let v = Self.helix
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        #expect(v.worstDistance(line.points) < v.radius / 2, "the path strays \(v.worstDistance(line.points)) mm from the axis")
        #expect(v.worstDistance(line.curveNodes()) < v.radius / 2)
    }

    @Test func aCoronaryIsFollowedFromAPointInTheAorta() throws {
        let v = Self.ostium
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        // Out of the aorta (10 mm round x = y = 12 mm) every point lies in the coronary.
        let outOfAorta = line.points.filter { p in
            let x = Double(p.x * v.spacing.x) - 12, y = Double(p.y * v.spacing.y) - 12
            return (x * x + y * y).squareRoot() > 10.5
        }
        #expect(outOfAorta.count > 40)
        #expect(v.worstDistance(outOfAorta) < v.radius, "the path strays \(v.worstDistance(outOfAorta)) mm from the coronary's axis")
        #expect(line.pointsOutsideLumen == 0)
    }

    /// The carotid's path is the former one, within its own error: the
    /// former search's path runs within a millimetre of the axis, the
    /// tracer's curve within 0.2 mm of it, and within a millimetre of the
    /// former path all along. The tracer's nodes within 2 mm of an end are
    /// left out of that comparison: the former thinning could stop the path
    /// short of its end.
    @Test func theCarotidPathStaysTheFormerOne() throws {
        let v = Self.carotid
        let formerResult = former(v, voxel: curvedMPRResampleVoxel(matrix: 64, fieldOfView: 32, spacing: v.spacing.x))
        #expect(formerResult.code == 0)
        let formerLine = formerResult.line
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        let nodes = line.curveNodes()
        #expect(line.gridStep == SIMD3(1, 1, 1))
        #expect(v.worstDistance(formerLine) < 1 && v.worstDistance(nodes) < 0.2,
                "the former path keeps within \(v.worstDistance(formerLine)) mm of the axis, the tracer's \(v.worstDistance(nodes)) mm")
        let toNew = formerLine.map { distance($0, toLine: nodes, spacing: v.spacing) }.max() ?? .infinity
        let ends = [v.millimetres(v.start), v.millimetres(v.end)]
        let inner = nodes.filter { node in
            ends.allSatisfy { end in
                let d = v.millimetres(node) - end
                return (d * d).sum().squareRoot() > 2
            }
        }
        let toFormer = inner.map { distance($0, toLine: formerLine, spacing: v.spacing) }.max() ?? .infinity
        #expect(toNew < 1 && toFormer < 1, "the paths are \(toNew) and \(toFormer) mm apart")
    }

    // MARK: - Time, progress and cancellation

    @Test func aSegmentTakesAFractionOfTheFormerSearchsTime() throws {
        // The same volume and the same points; both unoptimized here.
        let v = Self.coronary
        let formerSeconds = former(v, voxel: 0.4).seconds
        let clock = ContinuousClock.now
        _ = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        let tracerSeconds = seconds(ContinuousClock.now - clock)
        #expect(tracerSeconds * 5 < formerSeconds, "the tracer took \(tracerSeconds) s, the former search \(formerSeconds) s")
    }

    @Test func progressRisesToTheEndAndACancelStopsTheTrace() throws {
        let v = Self.helix
        var heard: [Double] = []
        _ = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v), progress: { heard.append($0) })
        #expect(heard.last == 1)
        #expect(zip(heard, heard.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(throws: VesselTraceError.cancelled) {
            try VesselTracer.trace(from: v.start, to: v.end, in: volume(v), isCancelled: { true })
        }
    }

    /// Called from the main actor, as the Curved MPR will call it: the
    /// segments are traced, and their progress told, on another thread.
    @MainActor
    @Test func segmentsAreTracedOffTheCallersActor() async throws {
        let v = Self.helix
        let middle = v.axis[v.axis.count / 2]
        let node = SIMD3(Float(middle.x) / v.spacing.x, Float(middle.y) / v.spacing.y, Float(middle.z) / v.spacing.z)
        let heard = Mutex<[(share: Double, onMainThread: Bool)]>([])
        let segments = try await VesselTracer.traceSegments(through: [v.start, node, v.end], in: volume(v)) { share in
            let onMainThread = Thread.isMainThread
            heard.withLock { $0.append((share, onMainThread)) }
        }
        #expect(segments.count == 2)
        for segment in segments {
            let line = try segment.get()
            #expect(v.worstDistance(line.points) < v.radius)
        }
        #expect(heard.withLock { $0.last?.share } == 1)
        #expect(heard.withLock { $0.count > 2 && $0.allSatisfy { !$0.onMainThread } })

        let traced = Task { try await VesselTracer.traceSegments(through: [v.start, node, v.end], in: volume(v)) }
        traced.cancel()
        await #expect(throws: VesselTraceError.cancelled) { try await traced.value }
    }

    // MARK: - Refusals

    @Test func theSamePointTwiceIsRefused() {
        let v = Self.helix
        #expect(throws: VesselTraceError.samePoint) { try VesselTracer.trace(from: v.start, to: v.start, in: volume(v)) }
    }

    @Test func anAirFilledLumenIsLeftToTheFormerAssistant() {
        // An airway: air (-1000 HU) in a wall of soft tissue (40 HU).
        var voxels = [Float](repeating: 40, count: 30 * 30 * 40)
        for z in 0..<40 { for y in 10..<20 { for x in 10..<20 { voxels[(z * 30 + y) * 30 + x] = -1000 } } }
        let airway = VesselVolume(copying: voxels, width: 30, height: 30, depth: 40, spacing: SIMD3(repeating: 0.6))
        #expect(throws: VesselTraceError.darkLumen) {
            try VesselTracer.trace(from: SIMD3(15, 15, 5), to: SIMD3(15, 15, 35), in: airway)
        }
    }
}
