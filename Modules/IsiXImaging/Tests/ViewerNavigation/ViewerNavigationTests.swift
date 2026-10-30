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

@Suite struct SeriesBrowsingTests {

    @Test func indexesAreClampedAndFlipped() {
        #expect(SeriesBrowsing.viewImage(forIndex: -3, count: 10, flipped: false) == 0)
        #expect(SeriesBrowsing.viewImage(forIndex: 12, count: 10, flipped: false) == 9)
        #expect(SeriesBrowsing.viewImage(forIndex: 2, count: 10, flipped: true) == 7)
        #expect(SeriesBrowsing.viewImage(forIndex: 0, count: 0, flipped: false) == -1)
        #expect(SeriesBrowsing.userIndex(ofViewImage: 7, count: 10, flipped: true) == 2)
        #expect(SeriesBrowsing.sliderValue(forViewImage: 0, count: 10, flipped: true) == 9)
        #expect(SeriesBrowsing.edgeImage(movingBy: -1, count: 10, flipped: false) == 9)
        #expect(SeriesBrowsing.edgeImage(movingBy: 1, count: 10, flipped: true) == 9)
        #expect(SeriesBrowsing.edgeImage(movingBy: 1, count: 10, flipped: false) == 0)
    }

    @Test func browsingLoopsOrBounces() {
        #expect(SeriesBrowsing.step(from: 4, direction: 1, flipped: false, count: 5, loops: true) == (0, 1))
        #expect(SeriesBrowsing.step(from: 0, direction: 1, flipped: true, count: 5, loops: true) == (4, 1))
        // Bouncing off the end turns the direction and steps back.
        #expect(SeriesBrowsing.step(from: 4, direction: 1, flipped: false, count: 5, loops: false) == (3, -1))
        #expect(SeriesBrowsing.step(from: 0, direction: -1, flipped: false, count: 5, loops: false) == (1, 1))
        // Two images: the bounce stays inside.
        #expect(SeriesBrowsing.step(from: 1, direction: 1, flipped: false, count: 2, loops: false) == (0, -1))
        // Past the short's range the index goes on to the last image.
        #expect(SeriesBrowsing.step(from: 32_767, direction: 1, flipped: false, count: 32_769, loops: false) == (32_768, 1))
        #expect(SeriesBrowsing.step(from: 32_768, direction: 1, flipped: false, count: 32_769, loops: true) == (0, 1))
    }
}

@Suite struct SynchronizationTests {

    @Test func syncButtonWorksAcrossStudies() {
        #expect(!ViewerSynchronization.syncsBetweenStudies(study: "1.2", otherStudies: []))
        #expect(!ViewerSynchronization.syncsBetweenStudies(study: "1.2", otherStudies: ["1.2", "1.2"]))
        #expect(ViewerSynchronization.syncsBetweenStudies(study: "1.2", otherStudies: ["1.2", "1.3"]))
        #expect(ViewerSynchronization.syncsBetweenStudies(study: nil, otherStudies: [nil]))
        #expect(ViewerSynchronization.resetsSeriesLock(betweenStudies: false, wasBetweenStudies: true))
        #expect(ViewerSynchronization.resetsSeriesLock(betweenStudies: true, wasBetweenStudies: false))
        #expect(!ViewerSynchronization.resetsSeriesLock(betweenStudies: true, wasBetweenStudies: true))
    }

    @Test func windowLevelGoesBetweenImagesOfOneKind() {
        func rule(_ a: String?, _ b: String?, rgb: Bool = false, suv: Bool = false) -> Bool {
            WindowLevelPropagation(isRGB: false, otherIsRGB: rgb, modality: a, otherModality: b, subtraction: false,
                                   otherSubtraction: false, suvConverted: false, otherSUVConverted: suv).propagates
        }
        #expect(rule("CT", "CT"))
        #expect(!rule("CT", "MR"))
        #expect(!rule("CT", "CT", rgb: true))
        #expect(!rule("CR", "CR"))
        #expect(!rule("NM", "NM"))
        #expect(rule("PT", "PT"))
        #expect(!rule("PT", "PT", suv: true))
        #expect(!rule(nil, nil))
    }

    @Test func zoomAndPan() {
        #expect(ViewerSettingsPropagation.scale(0, pixelSpacing: 1, otherPixelSpacing: 2) == nil)
        #expect(ViewerSettingsPropagation.scale(2, pixelSpacing: 0.5, otherPixelSpacing: 1) == 4)
        #expect(ViewerSettingsPropagation.scale(2, pixelSpacing: 0, otherPixelSpacing: 1) == 2)
        #expect(ViewerSettingsPropagation.pan(CGPoint(x: 10, y: 10), delta: CGPoint(x: 1, y: 2), scale: 2) == CGPoint(x: 12, y: 6))
    }
}

@Suite struct RegistrationTests {

    @Test func orientationTransformOfOneOrientationIsTheIdentity() {
        let axial: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let m = PointRegistration.orientationTransform(sensor: axial, model: axial)
        #expect(m == [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
        let coronal: [Float] = [1, 0, 0, 0, 0, -1, 0, 1, 0]
        let r = PointRegistration.orientationTransform(sensor: coronal, model: axial)
        #expect(r[0] == 1 && r[5] == -1 && r[7] == 1)
    }

    @Test func pointsPairByName() {
        let ok = PointRegistration.pair(model: ["A", "B", "C"], sensor: ["A", "B", "C"])
        #expect(ok.succeeds && ok.pairs.map(\.sensor) == [0, 1, 2])
        let few = PointRegistration.pair(model: ["A", "B"], sensor: ["A", "B"])
        #expect(!few.enoughPoints && few.namesMatch && few.pairs.isEmpty)
        let uneven = PointRegistration.pair(model: ["A", "B", "C"], sensor: ["A", "B"])
        #expect(!uneven.sameNumberOfPoints)
        let mismatch = PointRegistration.pair(model: ["A", "B", "C"], sensor: ["A", "B", "D"])
        #expect(!mismatch.namesMatch && mismatch.pairs.count == 2)
        let triplets = PointRegistration.pair(model: ["A", "A", "A"], sensor: ["A", "A", "A"])
        #expect(triplets.triplets && !triplets.succeeds)
    }
}

@Suite struct FusionOriginTests {

    @Test func alignedOriginOfACentredSlice() {
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let fused = FusionOriginAlignment.View(origin: (0, 0, 0), width: 10, height: 10, pixelSpacingX: 1, pixelSpacingY: 1,
                                               viewOrigin: .zero, scale: 1, viewPixelSpacingX: 1, viewPixelSpacingY: 1)
        let o = FusionOriginAlignment.origin((0, 0, 5), vectors: identity, width: 10, height: 10, spacingX: 1, spacingY: 1,
                                             fused: fused, view: fused, zShift: 2)
        #expect(o.0 == 0 && o.1 == 0 && o.2 == 7)
        #expect(FusionOriginAlignment.pixelSpacing(current: 0.5, fusedView: 2, fusedScale: 1, scale: 1) == 2)
    }
}
