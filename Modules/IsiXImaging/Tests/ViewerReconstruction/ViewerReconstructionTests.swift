//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

@Suite struct ReconstructionGeometryScanTests {

    static let axial: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    static func slice(_ z: Double, width: Int = 8, orientation: [Float] = axial, x: Double = 0) -> ReconstructionGeometryScan.Slice {
        ReconstructionGeometryScan.Slice(width: width, height: 8, orientation: orientation, originX: x, originY: 0, originZ: z)
    }

    @Test func regularSeries() {
        let scan = ReconstructionGeometryScan.scan([0, 1.25, 2.5, 3.75].map { Self.slice($0) }, interval: -1.25)
        #expect(scan.mismatchedSlices == 0 && scan.mismatchedOrientations == 0)
        #expect(scan.minInterval == 1.25 && scan.maxInterval == 1.25)
    }

    @Test func singleSliceKeepsTheInterval() {
        let scan = ReconstructionGeometryScan.scan([Self.slice(4)], interval: -2.5)
        #expect(scan.minInterval == 2.5 && scan.maxInterval == 2.5)
        #expect(ReconstructionGeometryScan.scan([], interval: 3).maxInterval == 3)
    }

    @Test func mismatchesAndIrregularSteps() {
        var tilted = Self.axial
        tilted[4] = 1.002
        let slices = [Self.slice(0), Self.slice(1, width: 9), Self.slice(2.5, orientation: tilted), Self.slice(3, x: 4)]
        let scan = ReconstructionGeometryScan.scan(slices, interval: 1)
        #expect(scan.mismatchedSlices == 1)
        #expect(scan.mismatchedOrientations == 1)
        #expect(scan.minInterval == 1)
        #expect(scan.maxInterval == (0.25 as Double).addingProduct(4, 4).squareRoot())
    }

    @Test func referenceIsTheSecondSlice() {
        var tilted = Self.axial
        tilted[0] = 0.99
        let scan = ReconstructionGeometryScan.scan([Self.slice(0, orientation: tilted), Self.slice(1), Self.slice(2)], interval: 1)
        #expect(scan.mismatchedOrientations == 1)
    }

    @Test func orientationToleranceIsStrict() {
        var near = Self.axial
        near[4] = 1.0005
        #expect(ReconstructionGeometryScan.scan([Self.slice(0), Self.slice(1), Self.slice(2, orientation: near)], interval: 1).mismatchedOrientations == 0)
    }
}

@Suite struct ThreeDViewerScreenTests {

    @Test func ownScreenWithoutThePreference() {
        #expect(ThreeDViewerScreen.index(viewerScreenOrigin: .zero, screenOrigins: [.zero, CGPoint(x: 1920, y: 0)], onAnotherScreen: false) == nil)
    }

    @Test func firstScreenStartingElsewhere() {
        let origins = [CGPoint.zero, CGPoint(x: 1920, y: 0), CGPoint(x: 0, y: 1080)]
        #expect(ThreeDViewerScreen.index(viewerScreenOrigin: .zero, screenOrigins: origins, onAnotherScreen: true) == 1)
        #expect(ThreeDViewerScreen.index(viewerScreenOrigin: CGPoint(x: 1920, y: 0), screenOrigins: origins, onAnotherScreen: true) == 0)
        #expect(ThreeDViewerScreen.index(viewerScreenOrigin: .zero, screenOrigins: [.zero], onAnotherScreen: true) == nil)
    }
}

@Suite struct KeyImageSearchTests {

    @Test func directions() {
        #expect(KeyImageSearch.runsForward(isPrevious: false, flipped: false))
        #expect(!KeyImageSearch.runsForward(isPrevious: true, flipped: false))
        #expect(!KeyImageSearch.runsForward(isPrevious: false, flipped: true))
        #expect(KeyImageSearch.runsForward(isPrevious: true, flipped: true))
        #expect(!KeyImageSearch.startsFromLastImage(nextSeries: true, flipped: false))
        #expect(KeyImageSearch.startsFromLastImage(nextSeries: true, flipped: true))
        #expect(KeyImageSearch.startsFromLastImage(nextSeries: false, flipped: false))
        #expect(!KeyImageSearch.startsFromLastImage(nextSeries: false, flipped: true))
    }

    @Test func firstMatchStopsAsking() {
        var asked: [Int] = []
        let found = KeyImageSearch.firstKeyImage(in: stride(from: 5, through: 0, by: -1)) { index in
            asked.append(index)
            return index == 3 || index == 1
        }
        #expect(found == 3 && asked == [5, 4, 3])
        #expect(KeyImageSearch.firstKeyImage(in: 0..<4) { _ in false } == nil)
    }
}
