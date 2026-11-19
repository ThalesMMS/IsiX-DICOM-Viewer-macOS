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

/// The vessel tracer where a coronary CT angiography makes it hard: a faint
/// lumen on enhancing myocardium, points marked off the vessel, an occlusion
/// beside a cavity or where the vessel bends, a wall thinner than a voxel, a
/// thin distal vessel, a vessel that turns back on itself, two vessels that
/// touch, a lumen too faint to tell from the myocardium, the aorta on coarse
/// blocks; the inputs it refuses, voxels that are not a number, the limit of
/// its work, and a cancel during the search.
struct VesselTracerRobustnessTests {
    private func volume(_ v: SyntheticVessel, spacing: SIMD3<Float>? = nil) -> VesselVolume {
        VesselVolume(copying: v.voxels, width: v.size.x, height: v.size.y, depth: v.size.z, spacing: spacing ?? v.spacing)
    }

    private func trace(_ v: SyntheticVessel, options: VesselTraceOptions = VesselTraceOptions()) throws -> VesselCenterline {
        try VesselTracer.trace(from: v.start, to: v.end, in: volume(v), options: options)
    }

    // MARK: - The lumen's interval

    struct Contrast: Sendable, CustomTestStringConvertible {
        let lumen: Double, wall: Double, cavity: Double, radius: Double
        var testDescription: String { "lumen \(lumen), myocardium \(wall), cavity \(cavity) HU, radius \(radius) mm" }
    }

    /// Myocardium brighter than half way from fat to a faint lumen, and
    /// cavities as bright as the lumen or brighter.
    @Test(arguments: [Contrast(lumen: 250, wall: 140, cavity: 300, radius: 1.5),
                      Contrast(lumen: 300, wall: 120, cavity: 450, radius: 1.0),
                      Contrast(lumen: 350, wall: 150, cavity: 500, radius: 1.5)])
    func aFaintCoronaryOnTheMyocardiumKeepsToItsLumen(_ contrast: Contrast) throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: contrast.radius, lumen: contrast.lumen,
                                                           cavity: contrast.cavity, wall: contrast.wall))
        let line = try trace(v)
        #expect(v.worstDistance(line.points) < contrast.radius, "the path strays \(v.worstDistance(line.points)) mm")
        #expect(v.worstDistance(line.curveNodes()) < contrast.radius / 2, "the curve strays \(v.worstDistance(line.curveNodes())) mm")
        #expect(line.lumenRange.contains(Float(contrast.lumen)) && !line.lumenRange.contains(Float(contrast.wall)))
        #expect(!line.isLumenFaint, "the lumen's floor lies \(line.lumenMargin) noise widths above the myocardium")
    }

    /// A distal vessel of 0.75 mm at 250 HU on myocardium of 120 HU, blurred
    /// by 0.45 mm, with noise of 30 HU: its blurred peak, about 155 HU, hardly
    /// stands out from the myocardium, whose noise reads as lumen in spots
    /// that join up, and no interval tells them apart; the path may run
    /// through the myocardium. It is traced all the same, and flagged. With
    /// the second noise no ray finds an edge toward the myocardium at either
    /// point, and the tissue round them reads as fat past the lumen's edge:
    /// the myocardium is found across the vessel's course all the same.
    @Test(arguments: [SyntheticVessel.CoronaryScene().seed, 14])
    func aThinVesselTooFaintToTellFromTheMyocardiumIsFlagged(seed: UInt64) throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: 0.75, lumen: 250, wall: 120, blur: 0.45, noise: 30, seed: seed))
        let line = try trace(v)
        #expect(line.isLumenFaint, "the lumen's floor lies \(line.lumenMargin) noise widths above the myocardium")
    }

    @Test func myocardiumBehindFatStaysOutOfTheInterval() throws {
        // The coronary in 2 mm of fat on the myocardium: the rays past its
        // edge meet fat, and the interval's floor is the half maximum to it.
        let v = SyntheticVessel.coronaryBesideCavity(.init(wall: 150, fatGap: 2))
        let line = try trace(v)
        #expect(line.lumenRange.lowerBound > 150 && line.lumenRange.contains(400))
        #expect(v.worstDistance(line.points) < v.radius)
    }

    // MARK: - Points marked off the vessel

    struct Offset: Sendable, CustomTestStringConvertible {
        let radius: Double, end: SIMD3<Double>
        var testDescription: String { "radius \(radius) mm, end moved \(end) mm" }
    }

    /// The second point 0.5 mm out into the fat of a 1 mm vessel, on the
    /// edge of its lumen toward the cavity, and 0.5 mm out of a 1.5 mm vessel
    /// across the arc's plane.
    @Test(arguments: [Offset(radius: 1.0, end: SIMD3(-1.5, 0, 0)), Offset(radius: 1.0, end: SIMD3(1.0, 0, 0)),
                      Offset(radius: 1.5, end: SIMD3(0, 2.0, 0))])
    func aPointMarkedBesideTheVesselIsMovedOntoIt(_ offset: Offset) throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: offset.radius, endOffset: offset.end))
        let line = try trace(v)
        #expect(v.worstDistance(line.points) < offset.radius, "the path strays \(v.worstDistance(line.points)) mm")
        #expect(line.pointsOutsideLumen == 0)
        #expect(line.curveNodes().last == v.end)
        #expect(line.lumenRange.lowerBound > 100, "the wall entered the interval \(line.lumenRange)")
    }

    // MARK: - Occlusions and walls

    @Test func anOcclusionBesideACavityIsCrossedThroughThePlaque() throws {
        // 10 mm of plaque at 40 HU on a 3 mm wall: crossing the wall twice
        // to the cavity is shorter out of the lumen than the plaque, but the
        // cavity is no lumen of the coronary.
        let v = SyntheticVessel.coronaryBesideCavity(.init(occlusion: 10))
        let line = try trace(v)
        #expect(v.worstDistance(line.points) < v.radius, "the path strays \(v.worstDistance(line.points)) mm")
        #expect(line.longestGap > 7 && line.longestGap < 14, "the gap is \(line.longestGap) mm")
        #expect(line.pointsOutsideLumen > 0)
    }

    struct BlurredCavity: Sendable, CustomTestStringConvertible {
        let cavity: Double, blur: Double, seed: UInt64
        var testDescription: String { "a cavity of \(cavity) HU blurred by \(blur) mm, seed \(seed)" }
    }

    /// The same occlusion beside a brighter cavity under the scanner's blur:
    /// the cavity's edge runs down through the lumen's interval over a
    /// millimetre and more of the wall, and the path through the plaque ran
    /// along it instead, 4.5 to 7 mm off the axis, in pieces of 2 to 3 mm
    /// that raised no notice. The path keeps to the vessel, or says how far
    /// it went without a lumen.
    @Test(arguments: [450.0, 600.0].flatMap { cavity in [0.3, 0.45].flatMap { blur in (1...3).map { BlurredCavity(cavity: cavity, blur: blur, seed: UInt64($0)) } } })
    func anOcclusionBesideABlurredBrightCavityKeepsToTheVesselOrSaysSo(_ scene: BlurredCavity) throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: 1.0, cavity: scene.cavity, occlusion: 10, blur: scene.blur, seed: scene.seed))
        let line = try trace(v)
        let strays = v.worstDistance(line.points)
        #expect(strays < 1.5 || line.longestGap >= 10, "the path strays \(strays) mm with a longest gap of \(line.longestGap) mm")
    }

    // MARK: - Stents

    struct Stent: Sendable, CustomTestStringConvertible {
        let blur: Double, offset: Double
        var testDescription: String { "blurred by \(blur) mm, the points \(offset) mm off the axis" }
    }

    /// A stent's mesh is brighter than the lumen all round it. A point marked
    /// in the lumen was moved onto the mesh, the brightest thing near it, the
    /// lumen's interval became the mesh's, and the path ran along the mesh,
    /// 1.4 to 1.6 mm from the axis of a lumen of 1.85 mm. The path keeps to
    /// the middle of the lumen, from points on its axis and from points
    /// marked off it (past 2 mm from them, where it has left the points).
    @Test(arguments: [Stent(blur: 0, offset: 0), Stent(blur: 0.3, offset: 0), Stent(blur: 0, offset: 0.8), Stent(blur: 0.3, offset: 0.8)])
    func aStentedVesselIsTracedDownItsLumenNotAlongTheMesh(_ stent: Stent) throws {
        let v = SyntheticVessel.stented(offset: stent.offset, blur: stent.blur)
        let line = try trace(v)
        let ends = [v.start, v.end]
        let between = line.points.filter { p in ends.allSatisfy { e in ((p - e) * (p - e) * v.spacing * v.spacing).sum().squareRoot() > 2 } }
        let strays = v.worstDistance(between)
        #expect(between.count > 10 && strays < v.radius / 2, "the path strays \(strays) mm in a lumen of \(v.radius) mm")
        #expect(line.longestGap == 0 && !line.isLumenFaint, "a gap of \(line.longestGap) mm, the lumen \(line.lumenRange)")
        // The lumen's interval, not the mesh's.
        #expect(line.lumenRange.contains(400) && line.lumenRange.upperBound < 800, "the interval is \(line.lumenRange)")
    }

    /// In-stent restenosis under the scanner's blur, the second point marked
    /// on its tissue: that point was moved onto the mesh, the brightest thing
    /// near it, and the first, whose rays met the mesh's rise all round, was
    /// left out of the lumen's interval, which the mesh then set alone; the
    /// path ran along the mesh from end to end. The lumen's level comes from
    /// the point within the mesh: the path keeps to the axis where the lumen
    /// is whole, and to what is left of the lumen beside the tissue.
    @Test(arguments: [0.3, 0.45])
    func inAStentWithRestenosisThePathKeepsToTheLumenLeft(blur: Double) throws {
        let v = SyntheticVessel.stented(restenosis: true, blur: blur)
        let line = try trace(v)
        #expect(line.lumenRange.contains(400) && line.lumenRange.upperBound < 800, "the interval is \(line.lumenRange)")
        func millimetres(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), Double(p.z)) * 0.4 }
        let whole = line.points.map(millimetres).filter { $0.z > 14 && $0.z < 24 }
        var offAxis = 0.0
        for p in whole {
            let dx: Double = p.x - 12.8, dy: Double = p.y - 12.8
            offAxis = max(offAxis, (dx * dx + dy * dy).squareRoot())
        }
        #expect(whole.count > 10 && offAxis < v.radius / 2, "where the lumen is whole the path strays \(offAxis) mm from its axis")
        // Beside the tissue, the lumen left spans x from 0.4 to 1.85 mm of the axis: within it, a voxel's blur of margin.
        let narrowed = line.points.map(millimetres).filter { $0.z > 28 && $0.z < 33 }
        let x: [Double] = narrowed.map { $0.x - 12.8 }
        let nearest: Double = x.min() ?? -9, furthest: Double = x.max() ?? 9
        #expect(narrowed.count > 5 && nearest > 0.2 && furthest < 1.65,
                "beside the tissue the path runs from x = \(nearest) to \(furthest) mm of the axis")
    }

    struct Bend: Sendable, CustomTestStringConvertible {
        let occlusion: Double, helix: Bool
        var testDescription: String { "\(occlusion) mm of plaque on \(helix ? "a helix" : "a coronary round the heart")" }
    }

    /// Plaque over 10 and 20 mm of a coronary that curves round the heart
    /// (22.5 mm of radius), where a straight line across it would lie up to
    /// 0.6 and 2.2 mm inside the curve, and over 8 mm of a helix that bends a
    /// tenth of a radian per millimetre (0.8 mm), more where the line hugs the
    /// inner wall. Out of the lumen, the path carries on the curve of the
    /// lumen on both sides.
    @Test(arguments: [Bend(occlusion: 10, helix: false), Bend(occlusion: 20, helix: false), Bend(occlusion: 8, helix: true)])
    func anOcclusionWhereTheVesselBendsFollowsTheBend(_ bend: Bend) throws {
        let v = bend.helix ? SyntheticVessel.helix(radius: 1.2, occlusion: bend.occlusion)
            : SyntheticVessel.coronaryBesideCavity(.init(occlusion: bend.occlusion))
        let line = try trace(v)
        let outside = zip(line.points, line.radii).filter { $0.1 == 0 }.map(\.0)
        #expect(outside.count > 5 && line.longestGap > Float(bend.occlusion) - 2, "the gap is \(line.longestGap) mm")
        #expect(v.worstDistance(outside) < 0.5, "out of the lumen the path strays \(v.worstDistance(outside)) mm")
        #expect(v.worstDistance(line.points) < v.radius, "the path strays \(v.worstDistance(line.points)) mm")
    }

    @Test(arguments: [0.5, 1.0])
    func aWallThinnerThanAVoxelKeepsThePathOutOfTheCavity(wallThickness: Double) throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: 1.0, wallThickness: wallThickness))
        let line = try trace(v)
        #expect(v.worstDistance(line.points) < v.radius, "the path strays \(v.worstDistance(line.points)) mm")
    }

    @Test func aThinDistalVesselBesideACavityIsTracedNotLeftToTheAirwaySearch() throws {
        let v = SyntheticVessel.coronaryBesideCavity(.init(radius: 0.75, lumen: 300))
        let line = try trace(v)
        #expect(v.worstDistance(line.points) < v.radius, "the path strays \(v.worstDistance(line.points)) mm")
    }

    // MARK: - Shapes

    @Test func aVesselThatTurnsBackIsFollowedRoundTheTurn() throws {
        // Points 4 mm apart, 20 mm from the turn: the region round them cuts
        // the turn off, and the way through the 2 mm of fat is no answer.
        let v = SyntheticVessel.hairpin(gap: 2, limb: 20)
        let line = try trace(v)
        #expect(line.pointsOutsideLumen == 0)
        let farthest = line.points.map { Double($0.x * v.spacing.x) }.max() ?? 0
        #expect(farthest > 24, "the path turns at \(farthest) mm, before the vessel does")
        #expect(v.worstDistance(line.points) < 1.5 * v.radius, "the path strays \(v.worstDistance(line.points)) mm")
    }

    /// The two limbs of a vessel that turns back on itself with 0.4 mm of fat
    /// between them: the scanner's blur lifts that fat to the lumen's half
    /// maximum, and the search's mean over a millimetre into the interval, so
    /// the limbs touch. The path still goes round the turn, 13 mm on from the
    /// points along the limbs, rather than across the fat. Turned by half a
    /// radian, the fat lies across the voxels' axes.
    @Test(arguments: [0.0, 0.5])
    func twoVesselsThatTouchStayTwo(turn: Double) throws {
        let v = SyntheticVessel.hairpin(gap: 0.4, limb: 14, blur: 0.3, noise: 25, turn: turn)
        let line = try trace(v)
        let from = v.millimetres(v.start)
        let farthest = line.points.map { p in
            let q = v.millimetres(p)
            return (q.x - from.x) * cos(turn) + (q.y - from.y) * sin(turn)
        }.max() ?? 0
        #expect(farthest > 13, "the path turns \(farthest) mm on from the points, before the vessel does")
        #expect(v.worstDistance(line.points) < v.radius / 2, "the path strays \(v.worstDistance(line.points)) mm")
        #expect(line.pointsOutsideLumen == 0)
    }

    @Test func theAorticArchIsTracedOnBlocksCloseToItsAxis() throws {
        let v = SyntheticVessel.aorticArch()
        let line = try trace(v)
        // Blocks of 1.56 mm in plane; the slices of 1 mm stay single.
        #expect(line.gridStep.x > 1 && line.gridStep.y > 1, "the search ran on blocks of \(line.gridStep) voxels")
        #expect(v.worstDistance(line.curveNodes()) < 1, "the curve strays \(v.worstDistance(line.curveNodes())) mm")
        #expect(v.worstDistance(line.points) < v.radius / 4, "the path strays \(v.worstDistance(line.points)) mm")
    }

    // MARK: - Inputs

    @Test func aNegativeSpacingIsTakenByItsSize() throws {
        let v = SyntheticVessel.helix(radius: 1.2)
        let downward = SIMD3(v.spacing.x, v.spacing.y, -v.spacing.z)
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: volume(v, spacing: downward))
        let upward = try trace(v)
        #expect(line.points == upward.points && line.spacing == v.spacing)
    }

    /// Voxels that are not a number, one in a hundred or one in twenty
    /// within 4 mm of the first point: the noise is read from the boxes
    /// without them, the trace ends, and with the fewer ones the vessel is
    /// followed and not flagged faint.
    @Test(arguments: [0.01, 0.05])
    func voxelsThatAreNotANumberNearAPointAreLeftOut(share: Double) throws {
        let v = SyntheticVessel.coronaryBesideCavity(radius: 1.5)
        var voxels = v.voxels
        var draw = SyntheticNoise(seed: 99)
        let start = v.millimetres(v.start)
        for k in 0..<v.size.z { for j in 0..<v.size.y { for i in 0..<v.size.x {
            let dx = Double(i) * Double(v.spacing.x) - start.x, dy = Double(j) * Double(v.spacing.y) - start.y
            let dz = Double(k) * Double(v.spacing.z) - start.z
            if dx * dx + dy * dy + dz * dz < 16 && draw.uniform() < share { voxels[(k * v.size.y + j) * v.size.x + i] = .nan }
        } } }
        let damaged = VesselVolume(copying: voxels, width: v.size.x, height: v.size.y, depth: v.size.z, spacing: v.spacing)
        let line = try VesselTracer.trace(from: v.start, to: v.end, in: damaged)
        #expect(line.lumenMargin.isFinite && line.points.count > 10)
        if share <= 0.01 {
            #expect(v.worstDistance(line.points) < v.radius, "the path strays \(v.worstDistance(line.points)) mm")
            #expect(!line.isLumenFaint, "the lumen's floor lies \(line.lumenMargin) noise widths above the myocardium")
        }
    }

    @Test func aZeroSpacingOrAPointThatIsNotANumberIsRefused() {
        let v = SyntheticVessel.helix(radius: 1.2)
        let flat = volume(v, spacing: SIMD3(v.spacing.x, v.spacing.y, 0))
        #expect(throws: VesselTraceError.invalidSpacing) { try VesselTracer.trace(from: v.start, to: v.end, in: flat) }
        let nowhere = SIMD3<Float>(.nan, v.start.y, v.start.z)
        #expect(throws: VesselTraceError.invalidPoint) { try VesselTracer.trace(from: nowhere, to: v.end, in: volume(v)) }
    }

    // MARK: - Work and cancellation

    @Test func aSearchStopsAtItsVoxelLimitAndJoinsTheEnds() throws {
        var options = VesselTraceOptions()
        options.searchedVoxelLimit = 3000
        let v = SyntheticVessel.coronaryBesideCavity(.init(occlusion: 10))
        let line = try trace(v, options: options)
        #expect(line.searchedVoxels <= 2 * options.searchedVoxelLimit)
        #expect(line.points.count > 10 && line.longestGap > 0)
    }

    @Test func aCancelDuringTheSearchStopsIt() {
        // The first question comes after the lumen's interval, the next ones
        // every thousand voxels of the search: cancel at the second.
        let v = SyntheticVessel.coronaryBesideCavity(.init(occlusion: 10))
        var asked = 0
        var heard: [Double] = []
        #expect(throws: VesselTraceError.cancelled) {
            try VesselTracer.trace(from: v.start, to: v.end, in: volume(v), progress: { heard.append($0) },
                                   isCancelled: {
                                       asked += 1
                                       return asked > 2
                                   })
        }
        #expect(asked == 3)
        #expect(!heard.isEmpty && heard.allSatisfy { $0 > 0 && $0 < 1 })
    }

    @Test func aTaskCancelledWhileTracingStopsBeforeItsSegmentsEnd() async {
        // The task cancels itself on the first share of progress it hears,
        // in the middle of the first segment, which crosses the occlusion.
        let v = SyntheticVessel.coronaryBesideCavity(.init(occlusion: 10))
        let middle = v.axis[3 * v.axis.count / 4]
        let node = SIMD3(Float(middle.x) / v.spacing.x, Float(middle.y) / v.spacing.y, Float(middle.z) / v.spacing.z)
        let handle = Mutex<Task<[Result<VesselCenterline, VesselTraceError>], any Error>?>(nil)
        let heard = Mutex<[Double]>([])
        let traced = Task {
            try await VesselTracer.traceSegments(through: [v.start, node, v.end], in: volume(v)) { share in
                heard.withLock { $0.append(share) }
                // The task may not be stored yet when the first share comes.
                let deadline = ContinuousClock.now + .seconds(10)
                while handle.withLock({ $0 == nil }) && ContinuousClock.now < deadline { usleep(1000) }
                handle.withLock { $0?.cancel() }
            }
        }
        handle.withLock { $0 = traced }
        await #expect(throws: VesselTraceError.cancelled) { try await traced.value }
        #expect(heard.withLock { !$0.isEmpty && $0.allSatisfy { $0 < 0.5 } })
    }
}
