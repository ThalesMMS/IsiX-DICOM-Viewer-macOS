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
                       hasView: Bool = true, lock: CGPoint? = nil, zoomPan: CGPoint = .zero,
                       lockZoomPan: CGPoint = .zero) -> SettingsPropagation.Viewer {
        SettingsPropagation.Viewer(
            windowLevel: hasView ? WindowLevelState(level: level, width: width) : nil,
            viewport: hasView ? ViewportState(scale: scale, origin: origin, rotation: rotation) : nil,
            pixelSpacing: pixelSpacing, image: rect.map { SettingsPropagation.Image(rect: $0, hasOrigin: true) },
            isRGB: isRGB, suvConverted: suv, modality: modality, subtraction: subtraction, colourTable: colourTable,
            orientation: orientation, keepsSettingsInSeries: keeps, studyInstanceUID: study,
            movieIndex: movieIndex, maxMovieIndex: maxMovieIndex, seriesLockPan: lock, zoomPanOffset: zoomPan,
            lockZoomPanOffset: lockZoomPan)
    }

    /// Every setting but the zoom, which each viewer keeps.
    static let zoomKept: SettingsPropagation.Preferences = {
        var preferences = everything
        preferences.copiesZoom = false
        return preferences
    }()

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

    // MARK: - The zoom kept to each viewer

    /// The rules as they were before the zoom kept to each viewer had a pan of
    /// its own, word for word: what the zoom going on must still give.
    static func formerPlan(_ rule: SettingsPropagation) -> PropagationPlan {
        let source = rule.source, target = rule.target, preferences = rule.preferences
        var plan = PropagationPlan()
        if source.movieIndex != target.movieIndex && source.maxMovieIndex == target.maxMovieIndex && !rule.navigatorShown {
            plan.movieIndex = source.movieIndex
        }
        guard preferences.propagates else { return plan }
        if ViewerSynchronization.same(target.colourTable, source.colourTable) {
            if preferences.copiesWindowLevel && rule.windowLevelPropagates,
               let window = source.windowLevel, let other = target.windowLevel,
               window.level != other.level || window.width != other.width {
                plan.window = WindowLevelState(level: window.level, width: window.width)
            }
        }
        let parallel = rule.normalsAngle < preferences.parallelPlaneTolerance
        let keepsSettings = target.keepsSettingsInSeries && source.keepsSettingsInSeries
        if parallel || preferences.alwaysPropagatesZoom {
            if preferences.copiesZoom && !keepsSettings, let viewport = source.viewport, target.viewport != nil {
                plan.scale = SettingsPropagation.scale(viewport.scale, pixelSpacing: source.pixelSpacing, otherPixelSpacing: target.pixelSpacing)
            }
        }
        if parallel && !keepsSettings, let viewport = source.viewport, let targetViewport = target.viewport {
            let sameStudy = ViewerSynchronization.same(source.studyInstanceUID, target.studyInstanceUID)
            if preferences.copiesPan && (sameStudy || rule.registered) {
                if let otherImage = target.image, let image = source.image, otherImage.rect.intersects(image.rect),
                   otherImage.hasOrigin && image.hasOrigin, let originDelta = rule.originDelta {
                    plan.origin = SettingsPropagation.pan(viewport.origin, delta: originDelta, scale: viewport.scale)
                }
            } else if preferences.copiesPan, let lock = source.seriesLockPan, let targetLock = target.seriesLockPan {
                plan.origin = SettingsPropagation.pan(viewport.origin, scale: viewport.scale, pixelSpacing: source.pixelSpacing, lock: lock,
                                                      otherScale: plan.scale ?? targetViewport.scale, otherPixelSpacing: target.pixelSpacing,
                                                      otherLock: targetLock)
            }
            if preferences.copiesRotation {
                plan.rotation = viewport.rotation
            }
        }
        return plan
    }

    @Test func withTheZoomGoingOnThePlanIsTheFormerOne() {
        let views: [(scale: Float, origin: CGPoint)] = [(2, CGPoint(x: 10, y: 10)), (3.5, CGPoint(x: -37.25, y: 12.5)), (0, CGPoint(x: 4, y: 4)),
                                                        (1.75, CGPoint(x: 3.5, y: -2.25))]
        let spacings: [(Double, Double)] = [(0.5, 0.5), (0.7, 0.9), (0, 1), (1, 0.5)]
        // The offsets each side's zooms kept, and those it had at the lock.
        let offsets: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            (.zero, .zero, .zero, .zero),
            (CGPoint(x: -10, y: 5), CGPoint(x: 3, y: -7.5), CGPoint(x: -4, y: 2.5), CGPoint(x: 6, y: 1))]
        let locks: [(CGPoint?, CGPoint?)] = [(nil, nil), (CGPoint(x: 5, y: -3), CGPoint(x: 1, y: 2)), (CGPoint(x: 5, y: -3), nil)]
        let rects: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 200, y: 0, width: 50, height: 50), nil]
        var compared = 0
        var differing: [String] = []
        for always in [false, true] {
            for copiesPan in [true, false] {
                var preferences = Self.everything
                preferences.alwaysPropagatesZoom = always
                preferences.copiesPan = copiesPan
                for study in ["1.2", "1.3"] {
                    for registered in [false, true] {
                        for (lock, targetLock) in locks {
                            for source in views {
                                for target in views.reversed() {
                                    for (spacing, targetSpacing) in spacings {
                                        for (offset, targetOffset, lockOffset, targetLockOffset) in offsets {
                                            for orientation in [Self.axial, Self.coronal] {
                                                for rect in rects {
                                                    for delta in [CGPoint(x: 1, y: 2), CGPoint(x: -2.5, y: 1.25), nil] {
                                                        let rule = SettingsPropagation(
                                                            source: Self.viewer(scale: source.scale, origin: source.origin, pixelSpacing: spacing,
                                                                                lock: lock, zoomPan: offset, lockZoomPan: lockOffset),
                                                            target: Self.viewer(level: 1, scale: target.scale, origin: target.origin, rotation: 0,
                                                                                pixelSpacing: targetSpacing, rect: rect, orientation: orientation,
                                                                                study: study, lock: targetLock, zoomPan: targetOffset,
                                                                                lockZoomPan: targetLockOffset),
                                                            registered: registered, navigatorShown: false, originDelta: delta, preferences: preferences)
                                                        if rule.plan() != Self.formerPlan(rule) { differing.append("\(rule)") }
                                                        compared += 1
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(compared > 10_000)
        #expect(differing.isEmpty, "\(differing.count) plans differ, the first: \(differing.first ?? "")")
    }

    @Test func withTheZoomKeptThePanGoesInMillimetresAtTheOthersScale() {
        // The source centres the point 5 of its pixels (0.5 mm) from its image's centre; the
        // other's image is 1 and 2 of these pixels away. The other keeps its scale of 1 and its
        // pixels of 1 mm: it centres the same point of the patient.
        let source = Self.viewer(scale: 2, origin: CGPoint(x: 10, y: 10), pixelSpacing: 0.5)
        let plan = Self.plan(source, Self.viewer(scale: 1, origin: .zero, pixelSpacing: 1), preferences: Self.zoomKept)
        #expect(plan.scale == nil)
        #expect(plan.origin == CGPoint(x: 3, y: 1.5))
        // The former pan was the source's, at the source's scale: 12 and 6 points.
        #expect(Self.formerPlan(SettingsPropagation(source: source, target: Self.viewer(scale: 1, origin: .zero, pixelSpacing: 1),
                                                    registered: false, navigatorShown: false, originDelta: CGPoint(x: 1, y: 2),
                                                    preferences: Self.zoomKept)).origin == CGPoint(x: 12, y: 6))
        // At the scale the zoom would have given (4 points per millimetre on both), the pan is the one it gives.
        let sameZoom = Self.viewer(scale: 4, origin: .zero, pixelSpacing: 1)
        #expect(Self.plan(source, sameZoom, preferences: Self.zoomKept).origin == Self.plan(source, sameZoom).origin)
        // A registered pair of different studies, too.
        #expect(Self.plan(source, Self.viewer(scale: 1, origin: .zero, pixelSpacing: 1, study: "1.3"), preferences: Self.zoomKept,
                          registered: true).origin == CGPoint(x: 3, y: 1.5))
    }

    @Test func aZoomSeenMovesTheOffsetAndAPanDoesNot() {
        let start = SettingsPropagation.ZoomPan(scale: 1, origin: .zero)
        // Zoomed to 2 on a point 20 points right and 10 down of the centre: the image pan moved by -10 and 5.
        let zoomed = start.seen(scale: 2, origin: CGPoint(x: -20, y: 10), keepsZoomMoves: true)
        #expect(zoomed == SettingsPropagation.ZoomPan(scale: 2, origin: CGPoint(x: -20, y: 10), offset: CGPoint(x: -10, y: 5)))
        // Zoomed on the centre of the view: the image pan does not move.
        #expect(zoomed.seen(scale: 4, origin: CGPoint(x: -40, y: 20), keepsZoomMoves: true).offset == CGPoint(x: -10, y: 5))
        // Panned at the same scale: the user's pan, which goes on.
        #expect(zoomed.seen(scale: 2, origin: CGPoint(x: -14, y: 6), keepsZoomMoves: true).offset == CGPoint(x: -10, y: 5))
        // With the zoom going on, a zoom moves the other viewers with it: nothing is kept apart.
        #expect(start.seen(scale: 2, origin: CGPoint(x: -20, y: 10), keepsZoomMoves: false)
                == SettingsPropagation.ZoomPan(scale: 2, origin: CGPoint(x: -20, y: 10)))
        // A view without a scale has no pan to compare.
        #expect(SettingsPropagation.ZoomPan(scale: 0, origin: .zero).seen(scale: 2, origin: CGPoint(x: 8, y: 8), keepsZoomMoves: true).offset == .zero)
        #expect(start.seen(scale: 0, origin: CGPoint(x: 8, y: 8), keepsZoomMoves: true).offset == .zero)
        // Locked, the view notes its offset then, and keeps it through the zooms that follow.
        let locked = zoomed.locked
        #expect(locked.lockOffset == CGPoint(x: -10, y: 5))
        #expect(locked.seen(scale: 4, origin: CGPoint(x: -20, y: 20), keepsZoomMoves: true)
                == SettingsPropagation.ZoomPan(scale: 4, origin: CGPoint(x: -20, y: 20), offset: CGPoint(x: -5, y: 5), lockOffset: CGPoint(x: -10, y: 5)))
    }

    @Test func aZoomInOneViewerOfAStudyMovesNeitherViewerInEitherDirection() {
        // A (0.5 mm pixels) and B (1 mm pixels) of one study, centred, at their own zooms.
        var a = SettingsPropagation.ZoomPan(scale: 1, origin: .zero)
        let b = Self.viewer(scale: 1.5, origin: .zero, pixelSpacing: 1)
        func viewerA(_ origin: CGPoint) -> SettingsPropagation.Viewer {
            Self.viewer(scale: a.scale, origin: origin, pixelSpacing: 0.5, zoomPan: a.offset)
        }
        func plan(_ source: SettingsPropagation.Viewer, _ target: SettingsPropagation.Viewer, delta: CGPoint = .zero) -> PropagationPlan {
            Self.plan(source, target, preferences: Self.zoomKept, delta: delta)
        }
        // A is zoomed to 2 on a point off its centre: B stays where it is.
        a = a.seen(scale: 2, origin: CGPoint(x: -20, y: 10), keepsZoomMoves: true)
        #expect(plan(viewerA(a.origin), b).origin == .zero)
        // Without the pan of A's zoom set apart, B followed the point A centres.
        #expect(plan(Self.viewer(scale: 2, origin: a.origin, pixelSpacing: 0.5), b).origin == CGPoint(x: -7.5, y: 3.75))
        // Then B hands its settings on (clicked, scrolled, resized): A stays zoomed where it is.
        #expect(plan(b, viewerA(a.origin)).origin == a.origin)
        // B panned 2 and -4 of its pixels (millimetres): A follows by as many millimetres, 4 and -8 of its pixels.
        let panned = Self.viewer(scale: 1.5, origin: CGPoint(x: 3, y: -6), pixelSpacing: 1)
        #expect(plan(panned, viewerA(a.origin)).origin == CGPoint(x: -12, y: -6))
        // A panned 6 and -4 points at its zoom (1.5 and -1 mm): B follows by as many millimetres.
        a = a.seen(scale: 2, origin: CGPoint(x: -14, y: 6), keepsZoomMoves: true)
        #expect(a.offset == CGPoint(x: -10, y: 5))
        #expect(plan(viewerA(a.origin), b).origin == CGPoint(x: 2.25, y: -1.5))
    }

    @Test func aZoomOffTheCentreRoundTripsBetweenImagesApart() {
        // B's image is 2 and 4 of A's pixels (1 and 2 mm) from A's; each has zoomed on its own.
        let a = Self.viewer(scale: 3, origin: CGPoint(x: -27, y: 15), pixelSpacing: 0.5, zoomPan: CGPoint(x: -6, y: 2))
        let b = Self.viewer(scale: 1.25, origin: CGPoint(x: 5, y: -2.5), pixelSpacing: 1, zoomPan: CGPoint(x: 1, y: 3))
        let toB = Self.plan(a, b, preferences: Self.zoomKept, delta: CGPoint(x: 2, y: 4))
        let movedB = Self.viewer(scale: 1.25, origin: toB.origin ?? .zero, pixelSpacing: 1, zoomPan: CGPoint(x: 1, y: 3))
        // What B takes, handed back, leaves A where it is.
        #expect(Self.plan(movedB, a, preferences: Self.zoomKept, delta: CGPoint(x: -1, y: -2)).origin == CGPoint(x: -27, y: 15))
        // And B again takes what it has.
        #expect(Self.plan(a, movedB, preferences: Self.zoomKept, delta: CGPoint(x: 2, y: 4)).origin == movedB.viewport?.origin)
    }

    @Test func aZoomInOneOfTheLockedSeriesMovesNeitherInEitherDirection() {
        // Locked at pans of 5 (0.5 mm pixels) and 1 (1 mm pixels); A then zoomed from 2 to 4 off its centre.
        var a = SettingsPropagation.ZoomPan(scale: 2, origin: CGPoint(x: 10, y: 10))
        a = a.seen(scale: 4, origin: CGPoint(x: 12, y: 16), keepsZoomMoves: true)
        #expect(a.offset == CGPoint(x: -2, y: -1))
        let lockA = CGPoint(x: 5, y: 5), lockB = CGPoint(x: 1, y: -1)
        let viewerA = Self.viewer(scale: 4, origin: a.origin, pixelSpacing: 0.5, lock: lockA, zoomPan: a.offset)
        let b = Self.viewer(scale: 1, origin: CGPoint(x: 1, y: -1), pixelSpacing: 1, study: "1.3", lock: lockB)
        #expect(Self.plan(viewerA, b, preferences: Self.zoomKept).origin == CGPoint(x: 1, y: -1))
        // Without the pan of A's zoom set apart, B followed the point A centres.
        #expect(Self.plan(Self.viewer(scale: 4, origin: a.origin, pixelSpacing: 0.5, lock: lockA), b, preferences: Self.zoomKept).origin
                == CGPoint(x: 0, y: -1.5))
        // B hands its settings on: A stays where its zoom put it.
        #expect(Self.plan(b, viewerA, preferences: Self.zoomKept).origin == CGPoint(x: 12, y: 16))
        // B panned 2 of its pixels (2 mm): A follows by 2 mm, 4 of its pixels at its zoom of 4.
        let panned = Self.viewer(scale: 1, origin: CGPoint(x: 3, y: -1), pixelSpacing: 1, study: "1.3", lock: lockB)
        #expect(Self.plan(panned, viewerA, preferences: Self.zoomKept).origin == CGPoint(x: 28, y: 16))
    }

    @Test func aLockTakenAfterAKeptZoomIsThePanTheZoomGoingOnReads() {
        // A (0.5 mm pixels) zoomed from 2 to 4 on a point 20 and 10 points off its centre, then the
        // series were locked: A's lock is its pan then, -5 and 2.5 of its pixels, and so is its offset.
        var a = SettingsPropagation.ZoomPan(scale: 2, origin: .zero)
        a = a.seen(scale: 4, origin: CGPoint(x: -20, y: 10), keepsZoomMoves: true).locked
        let lockA = SettingsPropagation.imagePan(a.origin, scale: a.scale)
        #expect(lockA == CGPoint(x: -5, y: 2.5))
        #expect(a.offset == lockA && a.lockOffset == lockA)
        let c = Self.viewer(scale: 1, origin: CGPoint(x: 4, y: -2), pixelSpacing: 1, study: "1.3", lock: CGPoint(x: 4, y: -2))
        func viewerA() -> SettingsPropagation.Viewer {
            Self.viewer(scale: a.scale, origin: a.origin, pixelSpacing: 0.5, lock: lockA, zoomPan: a.offset, lockZoomPan: a.lockOffset)
        }
        // The zoom kept: C stays where it was locked.
        #expect(Self.plan(viewerA(), c, preferences: Self.zoomKept).origin == CGPoint(x: 4, y: -2))
        // The zoom going on, A not moved since the lock: the plan is the former one over the pans
        // at the lock, and C keeps its locked framing at A's scale of 8 points per millimetre.
        let zoomOn = SettingsPropagation(source: viewerA(), target: c, registered: false, navigatorShown: false,
                                         originDelta: CGPoint(x: 1, y: 2), preferences: Self.everything)
        #expect(zoomOn.plan() == Self.formerPlan(zoomOn))
        #expect(zoomOn.plan().origin == CGPoint(x: 32, y: -16))
        // A zoomed again, from 4 to 8 on another point: C still stays, and the zoom going on reads the lock as it was.
        a = a.seen(scale: 8, origin: CGPoint(x: -30, y: 24), keepsZoomMoves: true)
        #expect(a.offset == CGPoint(x: -3.75, y: 3) && a.lockOffset == lockA)
        #expect(Self.plan(viewerA(), c, preferences: Self.zoomKept).origin == CGPoint(x: 4, y: -2))
        let again = SettingsPropagation(source: viewerA(), target: c, registered: false, navigatorShown: false,
                                        originDelta: CGPoint(x: 1, y: 2), preferences: Self.everything)
        #expect(again.plan() == Self.formerPlan(again))
    }
}
