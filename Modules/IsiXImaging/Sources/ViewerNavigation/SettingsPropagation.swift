/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

// The settings one 2D viewer hands on to another: its 4D frame, and with
// "propagate settings" on its window level, its zoom, its pan and its
// rotation. The app takes a snapshot of both viewers and of the preferences;
// the rules here say what the other viewer takes, as a PropagationPlan, and
// the app applies it. They are the rules of the viewer's former code, with its
// arithmetic.

/// What one viewer hands on to another, worked out from a snapshot of both.
public struct SettingsPropagation: Sendable {

    /// The preferences that decide what goes on, read by the app through the
    /// typed keys of IsiXPreferences.
    public struct Preferences: Sendable, Equatable {
        /// "Propagate settings" (COPYSETTINGS): nothing but the 4D frame goes
        /// on without it.
        public var propagates: Bool
        /// The window level (not DONTCOPYWLWWSETTINGS).
        public var copiesWindowLevel: Bool
        /// The zoom (not DONTCOPYZOOMSETTINGS).
        public var copiesZoom: Bool
        /// The pan (not DONTCOPYPANSETTINGS).
        public var copiesPan: Bool
        /// The rotation (not DONTCOPYROTATIONSETTINGS).
        public var copiesRotation: Bool
        /// The zoom goes on between planes that are not parallel too
        /// (AlwaysPropagateScaleLevel).
        public var alwaysPropagatesZoom: Bool
        /// The angle, in radians, under which two planes are parallel
        /// (PARALLELPLANETOLERANCE).
        public var parallelPlaneTolerance: Float

        public init(propagates: Bool, copiesWindowLevel: Bool, copiesZoom: Bool, copiesPan: Bool, copiesRotation: Bool,
                    alwaysPropagatesZoom: Bool, parallelPlaneTolerance: Float) {
            self.propagates = propagates
            self.copiesWindowLevel = copiesWindowLevel
            self.copiesZoom = copiesZoom
            self.copiesPan = copiesPan
            self.copiesRotation = copiesRotation
            self.alwaysPropagatesZoom = alwaysPropagatesZoom
            self.parallelPlaneTolerance = parallelPlaneTolerance
        }
    }

    /// The image a view shows, where the pan is worked out from.
    public struct Image: Sendable, Equatable {
        /// The image's rectangle in the patient's coordinates.
        public var rect: CGRect
        /// Whether the image has an origin.
        public var hasOrigin: Bool

        public init(rect: CGRect, hasOrigin: Bool) {
            self.rect = rect
            self.hasOrigin = hasOrigin
        }
    }

    /// A viewer as the rules see it.
    public struct Viewer: Sendable {
        /// The window its view shows; nil without a view.
        public var windowLevel: WindowLevelState?
        /// Its view's scale, pan and rotation; nil without a view.
        public var viewport: ViewportState?
        /// Its view's pixel spacing, 0 when unknown.
        public var pixelSpacing: Double
        /// Its view's current image; nil without one.
        public var image: Image?
        /// Whether the current image is RGB, and in SUV.
        public var isRGB: Bool
        public var suvConverted: Bool
        public var modality: String?
        /// Whether the mask subtraction is on.
        public var subtraction: Bool
        /// The name of its colour table.
        public var colourTable: String?
        /// The orientation the planes are compared with (nine values, the
        /// normal last); zeros when the viewer has no slices.
        public var orientation: [Float]
        /// Whether its modality keeps each image's own window, which neither
        /// zoom nor pan nor rotation then follows.
        public var keepsSettingsInSeries: Bool
        /// The study of its first image.
        public var studyInstanceUID: String?
        /// Its 4D frame and its last frame.
        public var movieIndex: Int
        public var maxMovieIndex: Int
        /// Where it was panned when the series of different studies were
        /// locked, in pixels of its image (`imagePan`); nil when it is not locked.
        public var seriesLockPan: CGPoint?
        /// How far the zooms kept to it have moved its pan, in pixels of its
        /// image (ZoomPan's offset). Read only when the zoom does not go on.
        public var zoomPanOffset: CGPoint
        /// What that offset was when the series were locked (ZoomPan's
        /// lockOffset): the zooms kept since the lock moved its pan by the
        /// difference. Read only between locked series when the zoom does not
        /// go on.
        public var lockZoomPanOffset: CGPoint

        public init(windowLevel: WindowLevelState?, viewport: ViewportState?, pixelSpacing: Double, image: Image?,
                    isRGB: Bool, suvConverted: Bool, modality: String?, subtraction: Bool, colourTable: String?,
                    orientation: [Float], keepsSettingsInSeries: Bool, studyInstanceUID: String?,
                    movieIndex: Int, maxMovieIndex: Int, seriesLockPan: CGPoint? = nil, zoomPanOffset: CGPoint = .zero,
                    lockZoomPanOffset: CGPoint = .zero) {
            self.windowLevel = windowLevel
            self.viewport = viewport
            self.pixelSpacing = pixelSpacing
            self.image = image
            self.isRGB = isRGB
            self.suvConverted = suvConverted
            self.modality = modality
            self.subtraction = subtraction
            self.colourTable = colourTable
            self.orientation = orientation
            self.keepsSettingsInSeries = keepsSettingsInSeries
            self.studyInstanceUID = studyInstanceUID
            self.movieIndex = movieIndex
            self.maxMovieIndex = maxMovieIndex
            self.seriesLockPan = seriesLockPan
            self.zoomPanOffset = zoomPanOffset
            self.lockZoomPanOffset = lockZoomPanOffset
        }
    }

    /// The viewer the settings come from and the one they go to.
    public var source: Viewer
    public var target: Viewer
    /// Whether one of the two is registered on the other.
    public var registered: Bool
    /// Whether the 4D navigator is open: it moves the frames itself.
    public var navigatorShown: Bool
    /// The shift from the centre of the source's image to the centre of the
    /// target's, in pixels of the source's image (DCMPix's
    /// originDeltaBetween:And:); nil without both images.
    public var originDelta: CGPoint?
    public var preferences: Preferences

    public init(source: Viewer, target: Viewer, registered: Bool, navigatorShown: Bool, originDelta: CGPoint?, preferences: Preferences) {
        self.source = source
        self.target = target
        self.registered = registered
        self.navigatorShown = navigatorShown
        self.originDelta = originDelta
        self.preferences = preferences
    }

    /// What the target takes. The frame goes first: the target's image
    /// changes with it, so a plan with a frame is worked out again on the
    /// image the target then shows, for the rest.
    public func plan() -> PropagationPlan {
        var plan = PropagationPlan()

        // 4D data: the same number of frames, and no navigator.
        if source.movieIndex != target.movieIndex && source.maxMovieIndex == target.maxMovieIndex && !navigatorShown {
            plan.movieIndex = source.movieIndex
        }

        guard preferences.propagates else { return plan }

        if ViewerSynchronization.same(target.colourTable, source.colourTable) {
            if preferences.copiesWindowLevel && windowLevelPropagates,
               let window = source.windowLevel, let other = target.windowLevel,
               window.level != other.level || window.width != other.width {
                plan.window = WindowLevelState(level: window.level, width: window.width)
            }
        }

        let angle = normalsAngle
        let parallel = angle < preferences.parallelPlaneTolerance
        let keepsSettings = target.keepsSettingsInSeries && source.keepsSettingsInSeries

        if parallel || preferences.alwaysPropagatesZoom {
            if preferences.copiesZoom && !keepsSettings, let viewport = source.viewport, target.viewport != nil {
                plan.scale = Self.scale(viewport.scale, pixelSpacing: source.pixelSpacing, otherPixelSpacing: target.pixelSpacing)
            }
        }

        if parallel && !keepsSettings, let viewport = source.viewport, let targetViewport = target.viewport {
            let sameStudy = ViewerSynchronization.same(source.studyInstanceUID, target.studyInstanceUID)
            if preferences.copiesPan && (sameStudy || registered) {
                // Overlapping images only: not the left and right limbs of one study.
                if let otherImage = target.image, let image = source.image, otherImage.rect.intersects(image.rect),
                   otherImage.hasOrigin && image.hasOrigin, let originDelta {
                    if preferences.copiesZoom {
                        plan.origin = Self.pan(viewport.origin, delta: originDelta, scale: viewport.scale)
                    } else {
                        // The other keeps its zoom: the point this view centres
                        // goes on in millimetres, at the other's scale, and the
                        // pan that each one's own zooms moved stays where it is.
                        // `originDelta` is in pixels of this image, its vertical
                        // part against the pan's, as in `pan(_:delta:scale:)`.
                        let from = CGPoint(x: source.zoomPanOffset.x - originDelta.x, y: source.zoomPanOffset.y + originDelta.y)
                        plan.origin = Self.pan(viewport.origin, scale: viewport.scale, pixelSpacing: source.pixelSpacing, lock: from,
                                               otherScale: targetViewport.scale, otherPixelSpacing: target.pixelSpacing,
                                               otherLock: target.zoomPanOffset)
                    }
                }
            } else if preferences.copiesPan, let lock = source.seriesLockPan, let targetLock = target.seriesLockPan {
                // Patient coordinates cannot be compared between studies: the
                // pan follows from the alignment the user locked them at.
                if preferences.copiesZoom {
                    plan.origin = Self.pan(viewport.origin, scale: viewport.scale, pixelSpacing: source.pixelSpacing, lock: lock,
                                           otherScale: plan.scale ?? targetViewport.scale, otherPixelSpacing: target.pixelSpacing, otherLock: targetLock)
                } else {
                    // Each keeps its zoom, and the pan its zooms moved since
                    // the lock. The locks are the pans as they were, which the
                    // zoom going on reads again.
                    let from = CGPoint(x: lock.x + source.zoomPanOffset.x - source.lockZoomPanOffset.x,
                                       y: lock.y + source.zoomPanOffset.y - source.lockZoomPanOffset.y)
                    let to = CGPoint(x: targetLock.x + target.zoomPanOffset.x - target.lockZoomPanOffset.x,
                                     y: targetLock.y + target.zoomPanOffset.y - target.lockZoomPanOffset.y)
                    plan.origin = Self.pan(viewport.origin, scale: viewport.scale, pixelSpacing: source.pixelSpacing, lock: from,
                                           otherScale: targetViewport.scale, otherPixelSpacing: target.pixelSpacing, otherLock: to)
                }
            }
            if preferences.copiesRotation {
                plan.rotation = viewport.rotation
            }
        }
        return plan
    }

    /// Whether the window level goes between the two images: of one kind,
    /// both RGB or both not, the same modality, the subtraction on both or
    /// neither; never to or from CR, never to NM; between PET only when both
    /// are in SUV or neither.
    public var windowLevelPropagates: Bool {
        let same = ViewerSynchronization.same
        var propagate = true
        if source.isRGB != target.isRGB { propagate = false }
        if !same(target.modality, source.modality) { propagate = false }
        if source.subtraction != target.subtraction { propagate = false }
        if same(target.modality, "CR") { propagate = false }
        if same(source.modality, "CR") { propagate = false }
        if same(target.modality, "NM") { propagate = false }
        if same(target.modality, "PT") && same(source.modality, "PT") && source.suvConverted != target.suvConverted { propagate = false }
        return propagate
    }

    /// The angle between the two planes' normals, in radians.
    var normalsAngle: Float {
        let a = Self.normal(source.orientation), b = Self.normal(target.orientation)
        return a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in PlaneGeometry.angle(a.baseAddress!, b.baseAddress!) } }
    }

    /// The normal of an orientation: its last three values, zeros when short.
    static func normal(_ orientation: [Float]) -> [Float] {
        orientation.count >= 9 ? Array(orientation[6..<9]) : [0, 0, 0]
    }

    /// The zoom the other viewer gets, or nil when it keeps its own: the same
    /// scale per millimetre when both views know their pixel spacing, the same
    /// scale otherwise; nothing from a view without a scale. The arithmetic is
    /// the viewer's: a float scale over a double spacing.
    public static func scale(_ scale: Float, pixelSpacing: Double, otherPixelSpacing: Double) -> Float? {
        guard scale != 0 else { return nil }
        if pixelSpacing != 0 && otherPixelSpacing != 0 {
            let perMillimetre = Float(Double(scale) / pixelSpacing)
            return Float(Double(perMillimetre) * otherPixelSpacing)
        }
        return scale
    }

    /// The other view's pan when it takes this view's zoom: this view's, moved
    /// by the shift between the centres of the two images (`delta`, in pixels
    /// of this view's image) at this view's scale.
    public static func pan(_ origin: CGPoint, delta: CGPoint, scale: Float) -> CGPoint {
        let x = delta.x * CGFloat(scale), y = delta.y * CGFloat(scale)
        return CGPoint(x: origin.x + x, y: origin.y - y)
    }

    /// A view's pan in pixels of its image, which a zoom centred on the view
    /// leaves as it is; zero for a view without a scale.
    public static func imagePan(_ origin: CGPoint, scale: Float) -> CGPoint {
        guard scale != 0 else { return .zero }
        return CGPoint(x: origin.x / CGFloat(scale), y: origin.y / CGFloat(scale))
    }

    /// The other view's pan relative to this one's, at the other's scale: its
    /// pan at `otherLock`, moved as far as this view has moved from `lock`
    /// (image pans), the same distance in millimetres when both views know
    /// their pixel spacing and the same number of pixels otherwise. Between
    /// locked series the locks are their pans at the lock. Nil from a view
    /// without a scale.
    public static func pan(_ origin: CGPoint, scale: Float, pixelSpacing: Double, lock: CGPoint,
                           otherScale: Float, otherPixelSpacing: Double, otherLock: CGPoint) -> CGPoint? {
        guard scale != 0 else { return nil }
        let ratio = pixelSpacing != 0 && otherPixelSpacing != 0 ? CGFloat(pixelSpacing / otherPixelSpacing) : 1
        let pan = imagePan(origin, scale: scale)
        return CGPoint(x: ((pan.x - lock.x) * ratio + otherLock.x) * CGFloat(otherScale),
                       y: ((pan.y - lock.y) * ratio + otherLock.y) * CGFloat(otherScale))
    }

    /// What the settings last saw of a view's zoom and pan, and how far the
    /// zooms kept to it have moved its pan. A zoom that is not centred on the
    /// view (on the mouse, or on the image's centre) moves the point the view
    /// centres. When the zoom does not go on, the pan that goes between
    /// viewers leaves that move out: a zoom moves no other viewer, and the pan
    /// of another viewer does not take a zoomed one back. Only a pan at the
    /// same scale goes on. A fresh one, offsets at zero, is a view aligned
    /// with the others as the zoom going on aligns it.
    public struct ZoomPan: Sendable, Equatable {
        /// The view's scale and pan when the settings last went from or to it.
        public var scale: Float
        public var origin: CGPoint
        /// The pan its own zooms have moved, in pixels of its image.
        public var offset: CGPoint
        /// The offset when the series of different studies were locked: the
        /// lock keeps the pan as it was, which the zoom going on reads, and the
        /// zooms kept since moved it by `offset - lockOffset`.
        public var lockOffset: CGPoint

        public init(scale: Float, origin: CGPoint, offset: CGPoint = .zero, lockOffset: CGPoint = .zero) {
            self.scale = scale
            self.origin = origin
            self.offset = offset
            self.lockOffset = lockOffset
        }

        /// The view seen again at `scale` and `origin`. When its zoom changed
        /// since and `keepsZoomMoves` (the zoom does not go on), what its pan
        /// moved goes into the offset; a pan at the same scale stays out of it.
        /// A view without a scale has no pan to compare.
        public func seen(scale: Float, origin: CGPoint, keepsZoomMoves: Bool) -> ZoomPan {
            var seen = ZoomPan(scale: scale, origin: origin, offset: offset, lockOffset: lockOffset)
            if keepsZoomMoves && scale != self.scale && scale != 0 && self.scale != 0 {
                let before = SettingsPropagation.imagePan(self.origin, scale: self.scale)
                let after = SettingsPropagation.imagePan(origin, scale: scale)
                seen.offset = CGPoint(x: offset.x + after.x - before.x, y: offset.y + after.y - before.y)
            }
            return seen
        }

        /// The view as the series are locked: the zooms kept from now on
        /// move the pan from the lock.
        public var locked: ZoomPan {
            var locked = self
            locked.lockOffset = offset
            return locked
        }
    }
}

/// What a viewer takes from another; nil for what it keeps. The app applies
/// it in this order: the frame, the window, the zoom, the pan, the rotation.
public struct PropagationPlan: Sendable, Equatable {
    /// The 4D frame.
    public var movieIndex: Int?
    /// The window level and width.
    public var window: WindowLevelState?
    public var scale: Float?
    /// The pan.
    public var origin: CGPoint?
    /// The rotation, in degrees.
    public var rotation: Float?

    public init(movieIndex: Int? = nil, window: WindowLevelState? = nil, scale: Float? = nil, origin: CGPoint? = nil, rotation: Float? = nil) {
        self.movieIndex = movieIndex
        self.window = window
        self.scale = scale
        self.origin = origin
        self.rotation = rotation
    }
}
