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

/// The Curved MPR's path assistant: the vessel tracer through the nodes of a
/// path, off the caller's actor and cancellable; the former fly-through
/// assistant for an air-filled lumen only; what the user is told to check;
/// and when Vessel Analysis traces on its own.
struct VesselPathAssistantTests {
    private func volume(_ v: SyntheticVessel) -> VesselVolume {
        VesselVolume(copying: v.voxels, width: v.size.x, height: v.size.y, depth: v.size.z, spacing: v.spacing)
    }

    /// An airway: air (-1000 HU) in a wall of soft tissue (40 HU), along z.
    private func airway() -> VesselVolume {
        var voxels = [Float](repeating: 40, count: 30 * 30 * 40)
        for z in 0..<40 { for y in 10..<20 { for x in 10..<20 { voxels[(z * 30 + y) * 30 + x] = -1000 } } }
        return VesselVolume(copying: voxels, width: 30, height: 30, depth: 40, spacing: SIMD3(repeating: 0.6))
    }

    @Test func aVesselTakesTheNodesOfTheTracersCurve() async throws {
        let v = SyntheticVessel.coronaryBesideCavity(radius: 1.5)
        let path = try await VesselPathAssistant.trace(through: [v.start, v.end], in: volume(v))
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v))
        #expect(path.segments == [.traced(nodes: line.curveNodes(), longestGap: line.longestGap, isLumenFaint: line.isLumenFaint)])
        #expect(path.segmentNodes == [line.curveNodes()])
        #expect(path.failures.isEmpty && !path.needsChecking)
    }

    @Test func anAirFilledLumenIsTracedByTheFormerAssistant() async throws {
        let airway = airway()
        let a = SIMD3<Float>(15, 15, 5), b = SIMD3<Float>(15, 15, 35)
        let path = try await VesselPathAssistant.trace(through: [a, b], in: airway)
        // As the window's FlyAssistant traced it: resampled at the input's
        // own voxel below a 256 matrix, thinned by the radius.
        let former = try #require(VesselPathAssistant.formerAssistant(over: airway))
        let (code, points) = withExtendedLifetime(airway) { former.centerline(from: a, to: b) }
        #expect(code == 0)
        let expected = former.thinnedCenterlineIndices(points).map { points[$0] }
        #expect(path.segments == [.formerAssistant(nodes: expected)])
        let nodes = try #require(path.segmentNodes.first ?? nil)
        #expect(nodes.first == a && nodes.last == b && nodes.count > 2)
        #expect(!path.needsChecking)
    }

    @Test func theFormerAssistantIsResampledAsTheCurvedMPRResampledIt() {
        // No voxels are read: the sizes alone.
        func size(_ width: Int, _ height: Int, _ spacing: SIMD3<Float>) -> Float {
            VesselPathAssistant.formerResampleVoxelSize(of: VesselVolume(copying: [], width: width, height: height, depth: 0, spacing: spacing))
        }
        #expect(size(256, 256, SIMD3(0.7, 0.6, 1)) == 0.7, "a 256 matrix keeps the input's voxel")
        #expect(size(512, 300, SIMD3(0.390625, 0.5, 1)) == Float(200.0 / 256), "a field of view of 200 mm across")
        #expect(size(300, 512, SIMD3(0.5, 0.5, 1)) == 1, "a field of view of 256 mm down")
    }

    @Test func aRefusedSegmentKeepsItsReasonAndTheOthersTheirNodes() async throws {
        let v = SyntheticVessel.helix(radius: 1.2)
        let path = try await VesselPathAssistant.trace(through: [v.start, v.start, v.end], in: volume(v))
        #expect(path.segments.count == 2)
        #expect(path.segments[0] == .failed(.refused(.samePoint)))
        #expect(path.segmentNodes[0] == nil && path.segmentNodes[1] != nil)
        #expect(path.failures == [.refused(.samePoint)])
    }

    @Test func anOcclusionAsksForTheUserToCheckThePath() async throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(occlusion: 10))
        let path = try await VesselPathAssistant.trace(through: [v.start, v.end], in: volume(v))
        #expect(path.longestGap > VesselPathAssistant.noticeGapMillimetres, "the gap is \(path.longestGap) mm")
        #expect(path.needsChecking && !path.isLumenFaint)
    }

    @Test func aFaintVesselAsksForTheUserToCheckThePath() async throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: 0.75, lumen: 250, wall: 120, blur: 0.45, noise: 30))
        let path = try await VesselPathAssistant.trace(through: [v.start, v.end], in: volume(v))
        #expect(path.isLumenFaint && path.needsChecking)
    }

    /// Called from the main actor, as the Curved MPR calls it: the vessel's
    /// segments and the airway's, which the former assistant traces, run on
    /// another thread, and so does the progress.
    @MainActor
    @Test func theTraceRunsOffTheMainActor() async throws {
        let heard = Mutex<[Bool]>([])
        let path = try await VesselPathAssistant.trace(through: [SIMD3(15, 15, 5), SIMD3(15, 15, 20), SIMD3(15, 15, 35)],
                                                       in: airway()) { _ in
            let onMainThread = Thread.isMainThread
            heard.withLock { $0.append(onMainThread) }
        }
        #expect(path.segments.allSatisfy { if case .formerAssistant = $0 { true } else { false } })
        #expect(heard.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } })

        let v = SyntheticVessel.helix(radius: 1.2)
        let vessel = try await VesselPathAssistant.trace(through: [v.start, v.end], in: volume(v)) { _ in
            let onMainThread = Thread.isMainThread
            heard.withLock { $0.append(onMainThread) }
        }
        #expect(vessel.segmentNodes.allSatisfy { $0 != nil })
        #expect(heard.withLock { $0.allSatisfy { !$0 } })
    }

    @Test func cancellingTheTaskEndsTheTrace() async {
        let v = SyntheticVessel.helix(radius: 1.2)
        let before = Task { try await VesselPathAssistant.trace(through: [v.start, v.end], in: volume(v)) }
        before.cancel()
        await #expect(throws: VesselTraceError.cancelled) { try await before.value }

        // Cancelled once the trace is under way: from its own progress, after
        // the first segments of a path of many.
        let nodes = (0...12).map { index -> SIMD3<Float> in
            let p = v.axis[(v.axis.count - 1) * index / 12]
            return SIMD3(Float(p.x) / v.spacing.x, Float(p.y) / v.spacing.y, Float(p.z) / v.spacing.z)
        }
        let running = Mutex<Task<VesselAssistedPath, any Error>?>(nil)
        let heard = Mutex(0)
        let task = Task {
            try await VesselPathAssistant.trace(through: nodes, in: volume(v)) { share in
                if share >= 2.0 / 12 { running.withLock { $0?.cancel() } }
                heard.withLock { $0 += 1 }
            }
        }
        running.withLock { $0 = task }
        await #expect(throws: VesselTraceError.cancelled) { try await task.value }
        #expect(heard.withLock { $0 } > 0)
    }

    @Test func vesselAnalysisTracesTheTwoPointsMarkedOnce() {
        let a = SIMD3<Double>(1, 2, 3), b = SIMD3<Double>(4, 5, 6), c = SIMD3<Double>(7, 8, 9)
        var trigger = VesselAnalysisTrigger()
        func traces(_ nodes: [SIMD3<Double>]) -> Bool { trigger.shouldTrace(nodes: nodes) }
        #expect(!traces([]))
        #expect(!traces([a]))
        #expect(traces([a, b]), "the second point traces")
        #expect(!traces([a, b]), "the sections moved on the same two points trace nothing")
        #expect(!traces([a, c, b]), "a node added to a path traces nothing")
        #expect(!traces([a, b, c, a]))
        #expect(!traces([c]), "a path deleted and begun again")
        #expect(traces([c, b]), "two new points trace")
        #expect(traces([c, a]), "a point of an untraced pair moved traces again")
        // The traced path thinned back to its ends, which came back through Float voxels.
        let origin = SIMD3<Double>(-120.7, 33.1, -401.3), spacing = SIMD3<Double>(0.39, 0.39, 0.625)
        let float = { (p: SIMD3<Double>) in SIMD3<Double>(SIMD3<Float>((p - origin) / spacing)) * spacing + origin }
        let d = SIMD3<Double>(12.345678, -45.678901, 101.234567), e = SIMD3<Double>(-3.14159, 27.18281, 64.0123)
        #expect(traces([d, e]))
        #expect(float(d) != d && float(e) != e)
        #expect(!traces([float(d), float(e)]), "the traced path's own ends trace again")
        #expect(traces([d, e + SIMD3(0.05, 0, 0)]), "a point moved by 0.05 mm does not trace")
    }
}
