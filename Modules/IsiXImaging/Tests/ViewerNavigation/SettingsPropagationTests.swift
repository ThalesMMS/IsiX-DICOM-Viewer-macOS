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

@Suite struct SettingsPropagationTests {

    static let axial: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    static let coronal: [Float] = [1, 0, 0, 0, 0, -1, 0, 1, 0]

    static let everything = SettingsPropagation.Preferences(
        propagates: true, copiesWindowLevel: true, copiesZoom: true, copiesPan: true, copiesRotation: true,
        alwaysPropagatesZoom: false, parallelPlaneTolerance: 0.01)

    static func viewer(level: Float = 40, width: Float = 400, scale: Float = 2, origin: CGPoint = CGPoint(x: 10, y: 10),
                       rotation: Float = 90, pixelSpacing: Double = 0.5, rect: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 100),
                       modality: String? = "CT", isRGB: Bool = false, suv: Bool = false, subtraction: Bool = false,
                       colourTable: String? = "No CLUT", orientation: [Float] = axial, keeps: Bool = false,
                       study: String? = "1.2", movieIndex: Int = 0, maxMovieIndex: Int = 0,
                       hasView: Bool = true, lock: CGPoint? = nil) -> SettingsPropagation.Viewer {
        SettingsPropagation.Viewer(
            windowLevel: hasView ? WindowLevelState(level: level, width: width) : nil,
            viewport: hasView ? ViewportState(scale: scale, origin: origin, rotation: rotation) : nil,
            pixelSpacing: pixelSpacing, image: rect.map { SettingsPropagation.Image(rect: $0, hasOrigin: true) },
            isRGB: isRGB, suvConverted: suv, modality: modality, subtraction: subtraction, colourTable: colourTable,
            orientation: orientation, keepsSettingsInSeries: keeps, studyInstanceUID: study,
            movieIndex: movieIndex, maxMovieIndex: maxMovieIndex, seriesLockPan: lock)
    }

    static func plan(_ source: SettingsPropagation.Viewer, _ target: SettingsPropagation.Viewer,
                     preferences: SettingsPropagation.Preferences = everything, registered: Bool = false,
                     navigator: Bool = false, delta: CGPoint? = CGPoint(x: 1, y: 2)) -> PropagationPlan {
        SettingsPropagation(source: source, target: target, registered: registered, navigatorShown: navigator,
                            originDelta: delta, preferences: preferences).plan()
    }

    @Test func everythingGoesBetweenParallelImagesOfOneStudy() {
        let plan = Self.plan(Self.viewer(), Self.viewer(level: 50, width: 300, scale: 1, origin: .zero, rotation: 0, pixelSpacing: 1))
        #expect(plan == PropagationPlan(window: WindowLevelState(level: 40, width: 400), scale: 4,
                                        origin: CGPoint(x: 12, y: 6), rotation: 90))
    }

    @Test func theSameWindowIsNotSetAgain() {
        #expect(Self.plan(Self.viewer(), Self.viewer()).window == nil)
    }

    @Test func windowLevelGoesBetweenImagesOfOneKind() {
        func rule(_ a: String?, _ b: String?, rgb: Bool = false, suv: Bool = false, subtraction: Bool = false) -> Bool {
            SettingsPropagation(source: Self.viewer(modality: a), target: Self.viewer(modality: b, isRGB: rgb, suv: suv, subtraction: subtraction),
                                registered: false, navigatorShown: false, originDelta: nil, preferences: Self.everything).windowLevelPropagates
        }
        #expect(rule("CT", "CT"))
        #expect(!rule("CT", "MR"))
        #expect(!rule("CT", "CT", rgb: true))
        #expect(!rule("CT", "CT", subtraction: true))
        #expect(!rule("CR", "CR"))
        #expect(!rule("NM", "NM"))
        #expect(rule("PT", "PT"))
        #expect(!rule("PT", "PT", suv: true))
        #expect(!rule(nil, nil))
        // Another kind of image keeps its window; another colour table too.
        #expect(Self.plan(Self.viewer(), Self.viewer(level: 1, modality: "MR")).window == nil)
        #expect(Self.plan(Self.viewer(), Self.viewer(level: 1, colourTable: "PET")).window == nil)
        #expect(Self.plan(Self.viewer(colourTable: nil), Self.viewer(level: 1, colourTable: nil)).window == nil)
    }

    @Test func zoomAndPan() {
        #expect(SettingsPropagation.scale(0, pixelSpacing: 1, otherPixelSpacing: 2) == nil)
        #expect(SettingsPropagation.scale(2, pixelSpacing: 0.5, otherPixelSpacing: 1) == 4)
        #expect(SettingsPropagation.scale(2, pixelSpacing: 0, otherPixelSpacing: 1) == 2)
        #expect(SettingsPropagation.pan(CGPoint(x: 10, y: 10), delta: CGPoint(x: 1, y: 2), scale: 2) == CGPoint(x: 12, y: 6))
        // A view without a scale hands on no zoom.
        #expect(Self.plan(Self.viewer(scale: 0), Self.viewer(scale: 3)).scale == nil)
    }

    @Test func eachSettingFollowsItsPreference() {
        var preferences = Self.everything
        preferences.copiesWindowLevel = false
        preferences.copiesZoom = false
        preferences.copiesPan = false
        preferences.copiesRotation = false
        #expect(Self.plan(Self.viewer(), Self.viewer(level: 1, scale: 1, rotation: 0), preferences: preferences) == PropagationPlan())
        preferences = Self.everything
        preferences.propagates = false
        #expect(Self.plan(Self.viewer(movieIndex: 2, maxMovieIndex: 4), Self.viewer(level: 1, maxMovieIndex: 4), preferences: preferences)
                == PropagationPlan(movieIndex: 2))
    }

    @Test func zoomPanAndRotationNeedParallelPlanes() {
        let plan = Self.plan(Self.viewer(), Self.viewer(level: 1, scale: 1, rotation: 0, orientation: Self.coronal))
        #expect(plan == PropagationPlan(window: WindowLevelState(level: 40, width: 400)))
        // Unless the zoom always goes on.
        var preferences = Self.everything
        preferences.alwaysPropagatesZoom = true
        let zoom = Self.plan(Self.viewer(), Self.viewer(scale: 1, pixelSpacing: 1, orientation: Self.coronal), preferences: preferences)
        #expect(zoom == PropagationPlan(scale: 4))
        // A viewer without slices has a null normal: it is never parallel to one with slices, always to another without.
        #expect(Self.plan(Self.viewer(), Self.viewer(rotation: 0, orientation: [])).rotation == nil)
        #expect(Self.plan(Self.viewer(orientation: Array(repeating: 0, count: 9)), Self.viewer(rotation: 0, orientation: [])).rotation == 90)
    }

    @Test func modalitiesWithTheirOwnWindowKeepZoomPanAndRotation() {
        let both = Self.plan(Self.viewer(keeps: true), Self.viewer(level: 1, scale: 1, rotation: 0, keeps: true))
        #expect(both == PropagationPlan(window: WindowLevelState(level: 40, width: 400)))
        // Only when both keep them.
        #expect(Self.plan(Self.viewer(keeps: true), Self.viewer(scale: 1, rotation: 0)).rotation == 90)
    }

    @Test func panOnlyWithinAStudyOrARegisteredPairOverOverlappingImages() {
        let other = Self.viewer(origin: .zero, study: "1.3")
        #expect(Self.plan(Self.viewer(), other).origin == nil)
        #expect(Self.plan(Self.viewer(), other, registered: true).origin == CGPoint(x: 12, y: 6))
        #expect(Self.plan(Self.viewer(study: nil), Self.viewer(origin: .zero, study: nil)).origin == nil)
        // The left and right limbs of one study.
        #expect(Self.plan(Self.viewer(), Self.viewer(origin: .zero, rect: CGRect(x: 200, y: 0, width: 50, height: 50))).origin == nil)
        #expect(Self.plan(Self.viewer(), Self.viewer(origin: .zero, rect: nil)).origin == nil)
        #expect(Self.plan(Self.viewer(), Self.viewer(origin: .zero), delta: nil).origin == nil)
        var withoutOrigin = Self.viewer(origin: .zero)
        withoutOrigin.image?.hasOrigin = false
        #expect(Self.plan(Self.viewer(), withoutOrigin).origin == nil)
        // The rotation does not need the images to overlap.
        #expect(Self.plan(Self.viewer(), Self.viewer(rotation: 0, study: "1.3")).rotation == 90)
    }

    @Test func lockedSeriesOfDifferentStudiesFollowFromTheirAlignment() {
        // Locked at pans of 5 and 1 image pixels: the other keeps its pan while this one has not moved.
        let source = Self.viewer(scale: 2, origin: CGPoint(x: 10, y: 10), pixelSpacing: 0.5, lock: CGPoint(x: 5, y: 5))
        let target = Self.viewer(scale: 2, origin: CGPoint(x: 2, y: -2), pixelSpacing: 0.5, study: "1.3", lock: CGPoint(x: 1, y: -1))
        #expect(Self.plan(source, target).origin == CGPoint(x: 2, y: -2))
        // Panned 20 points further: the other follows, keeping the difference.
        let moved = Self.viewer(scale: 2, origin: CGPoint(x: 30, y: 10), pixelSpacing: 0.5, lock: CGPoint(x: 5, y: 5))
        #expect(Self.plan(moved, target).origin == CGPoint(x: 22, y: -2))
        // Zoomed to 4 around the periphery: the difference is scaled as well.
        let zoomed = Self.viewer(scale: 4, origin: CGPoint(x: 60, y: 20), pixelSpacing: 0.5, lock: CGPoint(x: 5, y: 5))
        let plan = Self.plan(zoomed, target)
        #expect(plan.scale == 4)
        #expect(plan.origin == CGPoint(x: 44, y: -4))
    }

    @Test func lockedSeriesFollowInMillimetres() {
        // 10 pixels at 1 mm are 20 pixels at 0.5 mm, at the scale that keeps 2 points per millimetre.
        let source = Self.viewer(scale: 2, origin: CGPoint(x: 20, y: 0), pixelSpacing: 1, lock: .zero)
        let target = Self.viewer(scale: 1, origin: .zero, pixelSpacing: 0.5, study: "1.3", lock: .zero)
        let plan = Self.plan(source, target)
        #expect(plan.scale == 1)
        #expect(plan.origin == CGPoint(x: 20, y: 0))
        // Spacing unknown on one side: the same number of pixels.
        let unknown = Self.viewer(scale: 2, origin: .zero, pixelSpacing: 0, study: "1.3", lock: .zero)
        #expect(Self.plan(source, unknown).origin == CGPoint(x: 20, y: 0))
    }

    @Test func aLockThatOnlyOneSideHasOrThePreferenceKeepsThePan() {
        let source = Self.viewer(lock: .zero)
        #expect(Self.plan(source, Self.viewer(origin: .zero, study: "1.3")).origin == nil)
        #expect(Self.plan(Self.viewer(), Self.viewer(origin: .zero, study: "1.3", lock: .zero)).origin == nil)
        var preferences = Self.everything
        preferences.copiesPan = false
        #expect(Self.plan(source, Self.viewer(origin: .zero, study: "1.3", lock: .zero), preferences: preferences).origin == nil)
        // Planes that are not parallel, or a view without a scale.
        #expect(Self.plan(source, Self.viewer(origin: .zero, orientation: Self.coronal, study: "1.3", lock: .zero)).origin == nil)
        #expect(Self.plan(Self.viewer(scale: 0, lock: .zero), Self.viewer(origin: .zero, study: "1.3", lock: .zero)).origin == nil)
    }

    @Test func aLockChangesNothingWithinAStudy() {
        let plan = Self.plan(Self.viewer(lock: CGPoint(x: 9, y: 9)), Self.viewer(origin: .zero, lock: .zero))
        #expect(plan.origin == CGPoint(x: 12, y: 6))
    }

    @Test func theImagePanDoesNotChangeWithTheZoom() {
        #expect(SettingsPropagation.imagePan(CGPoint(x: 10, y: -4), scale: 2) == CGPoint(x: 5, y: -2))
        #expect(SettingsPropagation.imagePan(CGPoint(x: 10, y: -4), scale: 0) == .zero)
    }

    @Test func theFourDFrameGoesBetweenSeriesOfOneLength() {
        #expect(Self.plan(Self.viewer(movieIndex: 3, maxMovieIndex: 9), Self.viewer(maxMovieIndex: 9)).movieIndex == 3)
        #expect(Self.plan(Self.viewer(movieIndex: 3, maxMovieIndex: 9), Self.viewer(maxMovieIndex: 8)).movieIndex == nil)
        #expect(Self.plan(Self.viewer(movieIndex: 3, maxMovieIndex: 9), Self.viewer(maxMovieIndex: 9), navigator: true).movieIndex == nil)
        #expect(Self.plan(Self.viewer(movieIndex: 3, maxMovieIndex: 9), Self.viewer(movieIndex: 3, maxMovieIndex: 9)).movieIndex == nil)
    }

    @Test func viewersWithoutAViewTakeOnlyTheFrame() {
        let plan = Self.plan(Self.viewer(movieIndex: 1, maxMovieIndex: 2, hasView: false), Self.viewer(level: 1, maxMovieIndex: 2))
        #expect(plan == PropagationPlan(movieIndex: 1))
        #expect(Self.plan(Self.viewer(), Self.viewer(hasView: false)) == PropagationPlan())
    }
}
