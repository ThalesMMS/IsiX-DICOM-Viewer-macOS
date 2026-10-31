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

@Suite struct ViewerSyncMessageTests {

    /// The user info as the view posts it: the values, then the view and the two images.
    static func userInfo(_ message: ViewerSyncMessage, view: NSObject, image: NSObject?, farEnd: NSObject?) -> NSDictionary {
        let info = NSMutableDictionary()
        info.setObject(view, forKey: ViewerSyncMessage.Key.view as NSString)
        message.forEachEntry { info.setObject($1, forKey: $0 as NSString) }
        if let image { info.setObject(image, forKey: ViewerSyncMessage.Key.image as NSString) }
        if let farEnd { info.setObject(farEnd, forKey: ViewerSyncMessage.Key.farEndImage as NSString) }
        return info
    }

    @Test func thirteenKeysGoAndComeBack() {
        let message = ViewerSyncMessage(position: 7, direction: -2, location: -41.5, offset: 3.25, frameOfReferenceUID: "1.2.3",
                                        studyInstanceUID: "1.2.840", patientPoint: .init(x: 1, y: -2, z: 3.5),
                                        sharesPatientCrosshair: true)
        let view = NSObject(), image = NSObject(), farEnd = NSObject()
        let info = Self.userInfo(message, view: view, image: image, farEnd: farEnd)
        #expect(info.count == 13)
        #expect(Set(info.allKeys.compactMap { $0 as? String }) == Set(ViewerSyncMessage.Key.all))
        // The objects the former sender put there, compared as the plugins read them.
        #expect(info.object(forKey: "Pos") as? NSNumber == 7)
        #expect(info.object(forKey: "Direction") as? NSNumber == -2)
        #expect(info.object(forKey: "Location") as? NSNumber == NSNumber(value: Float(-41.5)))
        #expect(info.object(forKey: "offsetsync") as? NSNumber == NSNumber(value: Float(3.25)))
        #expect(info.object(forKey: "frameofReferenceUID") as? String == "1.2.3")
        #expect(info.object(forKey: "studyID") as? String == "1.2.840")
        #expect(info.object(forKey: "point3DZ") as? NSNumber == NSNumber(value: Float(3.5)))
        #expect((info.object(forKey: "HorosPatientCrosshair") as? NSNumber)?.boolValue == true)
        #expect(info.object(forKey: "view") as AnyObject === view)
        #expect(info.object(forKey: "DCMPix2") as AnyObject === farEnd)
        #expect(ViewerSyncMessage(entry: { info.object(forKey: $0) }) == message)
    }

    @Test func theScrollMessageHasNoPointAndNoFlag() {
        let message = ViewerSyncMessage(position: 0, direction: 1, location: 0, offset: 0, frameOfReferenceUID: nil, studyInstanceUID: nil)
        let info = Self.userInfo(message, view: NSObject(), image: nil, farEnd: nil)
        #expect(Set(info.allKeys.compactMap { $0 as? String }) == ["view", "Pos", "Direction", "Location", "offsetsync"])
        #expect(ViewerSyncMessage(entry: { info.object(forKey: $0) }) == message)
    }

    @Test func aMessageIsReadAsTheReceiverReadIt() {
        // Numbers read as -intValue and -floatValue; anything else as 0; an
        // offset of another class is still an offset; no point without its x.
        let read = ViewerSyncMessage(entry: { key in
            ["Pos": NSNumber(value: 3.9), "Location": "12", "offsetsync": NSNull(), "point3DY": NSNumber(value: 4)][key]
        })
        #expect(read.position == 3)
        #expect(read.location == 0)
        #expect(read.offset == 0)
        #expect(read.direction == nil)
        #expect(read.patientPoint == nil)
        #expect(!read.sharesPatientCrosshair)
        #expect(ViewerSyncMessage(entry: { _ in nil }).offset == nil)
    }

    @Test func positionCountsFromTheEndOfAReversedSeries() {
        #expect(ViewerSyncMessage.position(current: 3, count: 10, flippedData: false) == 3)
        #expect(ViewerSyncMessage.position(current: 3, count: 10, flippedData: true) == 6)
    }
}

/// A unit vector along `v`.
private func normalized(_ v: SIMD3<Float>) -> SIMD3<Float> {
    v / (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
}

@Suite struct SliceSynchronizerTests {

    static let synchronizer = SliceSynchronizer(parallelPlaneTolerance: 0.01, syncPlaneTolerance: 0.1)
    static let axial = SIMD3<Float>(0, 0, 1)

    static func plane(_ z: Float, normal: SIMD3<Float> = axial, matches: Bool = false) -> SliceSynchronizer.Plane {
        .init(normal: normal, origin: SIMD3(0, 0, z), matchesType: matches)
    }

    /// The plane search as DCMView+WindowLevel+Coordinates.swift wrote it,
    /// over the same planes, for the equivalence below.
    static func previousSearch(_ point: SIMD3<Float>, _ planes: [SliceSynchronizer.Plane], parallelTo: SIMD3<Float>?,
                               tolerance: Float, current: Int?, currentNormal: SIMD3<Float>) -> (Int32, Float) {
        var ii: Int32 = -1, distance: Float = 999999, vParallel = false, selectedIndex = -1
        var expectedIndex = Double.nan
        if let current {
            func along(_ p: SIMD3<Float>) -> Float { p.x * currentNormal.x + p.y * currentNormal.y + p.z * currentNormal.z }
            expectedIndex = SliceSynchronizer.expectedIndex(current: current, count: planes.count, target: along(point)) { along(planes[$0].origin) }
        }
        for (index, plane) in planes.enumerated() {
            let currParallel = parallelTo != nil && SliceSynchronizer.angle(parallelTo!, plane.normal) < tolerance
            var projection = SIMD3<Float>()
            let tempDistance = SliceSynchronizer.planeBase(point, plane.origin, plane.normal, &projection)
            let selectedMatchingType = selectedIndex >= 0 && planes[selectedIndex].matchesType
            if (!vParallel && currParallel) || (currParallel == vParallel &&
                SliceSynchronizer.candidateWins(distance: tempDistance, selectedDistance: distance, matchingType: plane.matchesType,
                                                selectedMatchingType: selectedMatchingType, index: index, selectedIndex: selectedIndex,
                                                expectedIndex: expectedIndex)) {
                vParallel = currParallel
                distance = tempDistance
                selectedIndex = index
                ii = Int32(index)
            }
        }
        return (ii, distance)
    }

    @Test func thePlaneSearchAnswersAsBefore() {
        var generator = SystemRandomNumberGenerator()
        let oblique = normalized(SIMD3<Float>(0.2, 0.1, 1))
        for _ in 0..<200 {
            let count = Int.random(in: 0...24, using: &generator)
            let planes = (0..<count).map { i in
                Self.plane(Float(i % 6) + Float.random(in: -0.004...0.004, using: &generator),
                           normal: Bool.random(using: &generator) ? Self.axial : oblique,
                           matches: Bool.random(using: &generator))
            }
            let point = SIMD3<Float>(Float.random(in: -5...5), Float.random(in: -5...5), Float.random(in: -1...7))
            let current = count > 0 && Bool.random(using: &generator) ? Int.random(in: 0..<count) : nil
            let direction: SIMD3<Float>? = Bool.random(using: &generator) ? Self.axial : nil
            let found = Self.synchronizer.nearestPlane(to: point, among: planes, parallelTo: direction, current: current, currentNormal: Self.axial)
            let before = Self.previousSearch(point, planes, parallelTo: direction, tolerance: 0.01, current: current, currentNormal: Self.axial)
            #expect(Int32(found.index ?? -1) == before.0)
            #expect(found.distance == before.1)
        }
    }

    @Test func aParallelPlaneComesFirstThenTheNearerOne() {
        let tilted = normalized(SIMD3<Float>(1, 0, 1))
        let planes = [Self.plane(2, normal: tilted), Self.plane(5), Self.plane(3)]
        let found = Self.synchronizer.nearestPlane(to: SIMD3(0, 0, 2), among: planes, parallelTo: Self.axial, current: nil, currentNormal: nil)
        #expect(found.index == 2)
        #expect(found.distance == 1)
        #expect(found.location == SIMD3(0, 0, 3))
        let none = Self.synchronizer.nearestPlane(to: .zero, among: [], parallelTo: nil, current: nil, currentNormal: nil)
        #expect(none.index == nil && none.distance == SliceSynchronizer.noDistance)
    }

    @Test func stackedPhasesKeepTheReceiverInItsPhase() {
        // Three phases of three positions: each current image stays in its phase.
        let planes = (0..<9).map { Self.plane(Float($0 % 3) + Float($0 / 3) * 0.001) }
        for current in 0..<9 {
            let found = Self.synchronizer.nearestPlane(to: SIMD3(0, 0, 2), among: planes, parallelTo: Self.axial,
                                                       current: current, currentNormal: Self.axial)
            #expect(found.index == current / 3 * 3 + 2)
        }
        // The preferred type before the phase.
        let typed = [Self.plane(1), Self.plane(1, matches: true)]
        #expect(Self.synchronizer.nearestPlane(to: SIMD3(0, 0, 1), among: typed, parallelTo: nil, current: 0, currentNormal: Self.axial).index == 1)
    }

    @Test func expectedIndexStaysInTheSubStack() {
        let locations: [Float] = [0, 1, 2, 0, 1, 2, 0, 1, 2]
        for current in 0..<9 {
            let expected = SliceSynchronizer.expectedIndex(current: current, count: 9, target: 2) { locations[$0] }
            #expect(Int(expected.rounded()) == current / 3 * 3 + 2)
        }
        #expect(SliceSynchronizer.expectedIndex(current: 9, count: 9, target: 2) { locations[$0] }.isNaN)
        #expect(SliceSynchronizer.expectedIndex(current: 0, count: 1, target: 2) { _ in 5 } == 0)
        #expect(SliceSynchronizer.candidateWins(distance: 0, selectedDistance: 0.005, matchingType: false, selectedMatchingType: false,
                                                index: 5, selectedIndex: 2, expectedIndex: 5))
        #expect(!SliceSynchronizer.candidateWins(distance: 0.5, selectedDistance: 0, matchingType: true, selectedMatchingType: false,
                                                 index: 5, selectedIndex: 2, expectedIndex: 5))
        #expect(!SliceSynchronizer.candidateWins(distance: 0, selectedDistance: 0, matchingType: false, selectedMatchingType: false,
                                                 index: 5, selectedIndex: 2, expectedIndex: .nan))
    }

    @Test func toleranceDecidesWhoFollowsByLocation() {
        let slightly = normalized(SIMD3<Float>(0.05, 0, 1)), half = normalized(SIMD3<Float>(0.7, 0, 1))
        #expect(Self.synchronizer.followsByLocation(receiverNormal: Self.axial, sourceNormal: slightly, manual: false))
        #expect(!Self.synchronizer.followsByLocation(receiverNormal: Self.axial, sourceNormal: half, manual: false))
        // By hand, up to about 45 degrees.
        #expect(Self.synchronizer.followsByLocation(receiverNormal: Self.axial, sourceNormal: half, manual: true))
        #expect(!Self.synchronizer.followsByLocation(receiverNormal: Self.axial, sourceNormal: SIMD3(1, 0, 0), manual: true))
        #expect(SliceSynchronizer.accepts(distance: 100, sliceThickness: 0))
        #expect(SliceSynchronizer.accepts(distance: 2, sliceThickness: 1))
        #expect(!SliceSynchronizer.accepts(distance: 2.5, sliceThickness: 1))
    }

    @Test func theLocationSearchFollowsTheSameRules() {
        let locations: [Float] = [0, 1, 2, 0, 1, 2]
        let found = SliceSynchronizer.nearestLocation(count: 6, current: 4, target: 1.002, correction: nil,
                                                      location: { locations[$0] }, matchesType: { _ in false })
        #expect(found.index == 4)
        #expect(abs(found.distance - 0.002) < 1e-6)
        // Both synchronised by hand: the difference of the offsets is taken off.
        let corrected = SliceSynchronizer.nearestLocation(count: 6, current: 0, target: 0, correction: 2,
                                                          location: { locations[$0] }, matchesType: { _ in false })
        #expect(corrected.index == 2 && corrected.distance == 0)
        #expect(SliceSynchronizer.nearestLocation(count: 0, current: 0, target: 0, correction: nil,
                                                  location: { _ in 0 }, matchesType: { _ in false }) == .init(index: -1, distance: -1))
        #expect(SliceSynchronizer.locationIsImpossible(distance: -2.5, sliceInterval: 1))
        #expect(!SliceSynchronizer.locationIsImpossible(distance: 2, sliceInterval: 1))
        #expect(SliceSynchronizer.clampedIndex(12, count: 10) == 9)
        #expect(SliceSynchronizer.clampedIndex(-1, count: 10) == 9)
        #expect(SliceSynchronizer.clampedIndex(-1, count: 0) == 0)
        #expect(SliceSynchronizer.clampedIndex(4, count: 10) == 4)
    }

    @Test func theCrosshairIsOnTheSliceItCuts() {
        func on(_ point: SIMD3<Float>) -> Bool {
            SliceSynchronizer.crosshairIsOnSlice(point, sliceInterval: -2, sliceThickness: 1, width: 64, height: 32,
                                                 pixelSpacingX: 0.5, pixelSpacingY: 0.5)
        }
        #expect(on(SIMD3(10, 10, 1)))
        #expect(!on(SIMD3(10, 10, 1.1)))
        #expect(!on(SIMD3(32, 10, 0)))
        #expect(!on(SIMD3(10, 16, 0)))
        #expect(!on(SIMD3(-0.1, 10, 0)))
        #expect(!on(SIMD3(.nan, 10, 0)))
    }

    @Test func referenceLinesGoAndComeBackAndCompare() {
        var values: [Float] = [1, 2, 3, 4, 5, 6]
        let line = values.withUnsafeBufferPointer { ReferenceLines.Line($0.baseAddress!) }
        #expect(line.isDrawn && line.z1 == 6)
        var lines = ReferenceLines(cut: line, seriesStart: line, seriesEnd: line, farEnd: line, thickness: 2, direction: SIMD3(0, 1, 0))
        #expect(lines.hasLine)
        let before = lines
        lines.invalidate()
        #expect(!lines.hasLine && !lines.cut.isDrawn && !lines.farEnd.isDrawn && lines.cut.y0 == 2)
        #expect(lines != before)
        values = [Float](repeating: 0, count: 6)
        values.withUnsafeMutableBufferPointer { lines.cut.write(to: $0.baseAddress!) }
        #expect(values[0] == .infinity && values[5] == 6)
        // An undefined value is a change, as the comparison of the floats said.
        var undefined = before
        undefined.thickness = .nan
        #expect(undefined != undefined)
    }

    @MainActor @Test func theSharedModeStartsByLocation() {
        #expect(SliceSyncSettings.mode == SliceSynchronizer.Mode.location)
        #expect(SliceSyncSettings.listensToMessages)
    }
}
