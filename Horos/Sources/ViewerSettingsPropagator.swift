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

import AppKit
import IsiXImaging
import IsiXPreferences

// The synchronization between 2D viewers, which the "Multi viewport series
// synchronization" block of the former viewer did: the toolbar's "Sync"
// button (within a study it switches the view's syncro mode; across studies
// it locks the series at their current offset) and the settings one viewer
// hands on to the others (4D frame, window level, zoom, pan, rotation). It
// walks the process's ViewerRegistry and keeps the shared state in the
// process's ViewerSyncState. The rules, when the button works across studies
// and what goes to another viewer, are IsiXImaging's ViewerSynchronization and
// SettingsPropagation; this applies them. ViewerController keeps the former
// selectors, which come here.

/// The synchronization of one 2D viewer with the others, made for one call.
@MainActor final class ViewerSettingsPropagator {
    /// Held strongly for the length of a call: forming an unowned or weak
    /// reference to an object being deallocated traps.
    let viewer: ViewerController
    private let registry: ViewerRegistry
    private let sync: ViewerSyncState
    private let preferences: any PreferenceStore
    /// The process's graph, whose application controller publishes the
    /// series lock to its observers under the key SYNCSERIES.
    private let processGraph: ProcessGraph

    static let syncItemImage = "Sync.pdf"
    static let syncLockItemImage = "SyncLock.pdf"

    init(viewer: ViewerController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.viewer = viewer
        registry = processGraph.viewerRegistry
        sync = processGraph.viewerSync
        self.preferences = preferences
        self.processGraph = processGraph
    }

    // MARK: - The Sync button

    /// The "Sync" item of the viewer's toolbar.
    var syncItem: NSToolbarItem? {
        viewer.horos_toolbar?.items.first { viewerIsEqualToString($0.itemIdentifier.rawValue, Self.syncItemImage) }
    }

    /// The series lock changed (OsirixSyncSeriesNotification, with the
    /// sender's "sliceLocation"): across studies, this viewer locks at its
    /// offset from the sender's slice location, or unlocks; within a study,
    /// the button shows the view's syncro mode.
    func seriesLockDidChange(sliceLocation: Float) {
        let item = syncItem
        if sync.betweenStudies {
            if sync.seriesLocked {
                if let imageView = viewer.horos_imageView {
                    let current = imageView.dcmPixList?.object(at: Int(imageView.curImage)) as? DCMPix
                    imageView.syncRelativeDiff = Float((current?.sliceLocation ?? 0) - Double(sliceLocation))
                    Self.recordLockPan(of: imageView, in: sync)
                }
                item?.image = NSImage.toolbarImageNamed(Self.syncLockItemImage)
                viewer.horos_imageView?.syncSeriesIndex = 0
            } else {
                item?.image = NSImage.toolbarImageNamed(Self.syncItemImage)
                viewer.horos_imageView?.syncSeriesIndex = -1
            }
        } else {
            if viewer.horos_imageView?.syncro() ?? 0 != Int16(syncroOFF) {
                item?.image = NSImage.toolbarImageNamed(Self.syncLockItemImage)
            } else {
                item?.image = NSImage.toolbarImageNamed(Self.syncItemImage)
            }
        }
    }

    /// Unlocks the series of different studies, if they are locked.
    func unlockSeriesBetweenStudies() {
        if sync.betweenStudies && sync.seriesLocked {
            toggleSync()
        }
    }

    /// Locks the series of different studies at their current offset, when
    /// the button works between studies.
    static func lockSeriesBetweenStudies(sync: ViewerSyncState, registry: ViewerRegistry) {
        guard sync.betweenStudies else { return }
        sync.seriesLocked = true

        for viewer in registry.displayedViewers {
            viewer.settingsPropagator.syncItem?.image = NSImage.toolbarImageNamed(syncLockItemImage)
            viewer.horos_imageView?.syncSeriesIndex = 0
            if let imageView = viewer.horos_imageView { recordLockPan(of: imageView, in: sync) }
        }
    }

    /// Takes where `view` is panned as its place in the alignment being locked.
    private static func recordLockPan(of view: DCMView, in sync: ViewerSyncState) {
        sync.setLockPan(SettingsPropagation.imagePan(view.origin, scale: view.scaleValue), of: view)
    }

    /// The "Sync" button: across studies it locks or unlocks the series and
    /// tells the others where this one is; within a study it switches the
    /// view's syncro mode (Option: relative, otherwise by location).
    func toggleSync() {
        if sync.betweenStudies {
            sync.seriesLocked.toggle()

            var sliceLocation: Float = 0
            if let imageView = viewer.horos_imageView {
                let current = imageView.dcmPixList?.object(at: Int(imageView.curImage)) as? DCMPix
                sliceLocation = Float(current?.sliceLocation ?? 0)
            }
            NotificationCenter.default.post(name: .OsirixSyncSeries, object: viewer,
                                            userInfo: ["sliceLocation": NSNumber(value: sliceLocation)])
        } else {
            guard let imageView = viewer.horos_imageView else { return }
            if imageView.syncro() == Int16(syncroOFF) {
                if NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false {
                    imageView.setSyncro(Int16(syncroREL))
                } else {
                    imageView.setSyncro(Int16(syncroLOC))
                }
            } else {
                imageView.setSyncro(Int16(syncroOFF))
            }
            imageView.becomeMainWindow()
        }
    }

    /// Works out what the "Sync" button does: across studies when the other
    /// displayed viewers are not all of this one's study. Within a study, or on
    /// switching to across studies, the series are unlocked.
    func updateSyncButtonBehavior() {
        let wasBetweenStudies = sync.betweenStudies
        let others = registry.displayedViewers.filter { $0 !== viewer }

        let study = others.isEmpty ? nil : viewer.studyInstanceUID()
        let betweenStudies = ViewerSynchronization.syncsBetweenStudies(study: study, otherStudies: others.map { $0.studyInstanceUID() })
        sync.betweenStudies = betweenStudies

        if ViewerSynchronization.resetsSeriesLock(betweenStudies: betweenStudies, wasBetweenStudies: wasBetweenStudies) {
            let app = processGraph.appController
            app?.willChangeValue(forKey: "SYNCSERIES")
            sync.seriesLocked = false
            app?.didChangeValue(forKey: "SYNCSERIES")
            NotificationCenter.default.post(name: .OsirixSyncSeries, object: nil, userInfo: nil)

            for other in others { other.horos_imageView?.syncSeriesIndex = -1 }
        }
    }

    // MARK: - Settings

    /// What the preferences let go on to another viewer.
    private var propagationPreferences: SettingsPropagation.Preferences {
        SettingsPropagation.Preferences(
            propagates: preferences[ViewerPreferences.copySettings],
            copiesWindowLevel: !preferences[ViewerPreferences.dontCopyWindowLevelSettings],
            copiesZoom: !preferences[ViewerPreferences.dontCopyZoomSettings],
            copiesPan: !preferences[ViewerPreferences.dontCopyPanSettings],
            copiesRotation: !preferences[ViewerPreferences.dontCopyRotationSettings],
            alwaysPropagatesZoom: preferences[ViewerPreferences.alwaysPropagateScaleLevel],
            parallelPlaneTolerance: preferences[ViewerPreferences.parallelPlaneTolerance])
    }

    /// `viewer` as the propagation rules see it: its view's window and
    /// viewport, its image, and `orientation`, the planes' comparison. Only
    /// the frames when the settings do not go on (`full` false).
    private func snapshot(of viewer: ViewerController, movieIndex: Int, orientation: () -> [Float], full: Bool) -> SettingsPropagation.Viewer {
        let maxMovieIndex = Int(viewer.horos_maxMovieIndex)
        guard full else {
            return SettingsPropagation.Viewer(windowLevel: nil, viewport: nil, pixelSpacing: 0, image: nil, isRGB: false, suvConverted: false,
                                              modality: nil, subtraction: false, colourTable: nil, orientation: [],
                                              keepsSettingsInSeries: false, studyInstanceUID: nil,
                                              movieIndex: movieIndex, maxMovieIndex: maxMovieIndex)
        }
        let view = viewer.imageView()
        let pix = view?.curDCM
        var windowLevel: WindowLevelState?
        if let view {
            var level: Float = 0, width: Float = 0
            view.getWLWW(&level, &width)
            windowLevel = WindowLevelState(level: level, width: width)
        }
        let modality = viewer.modality()
        let locked = sync.betweenStudies && sync.seriesLocked && view?.syncSeriesIndex != -1
        return SettingsPropagation.Viewer(
            windowLevel: windowLevel,
            viewport: view.map { ViewportState(scale: $0.scaleValue, origin: $0.origin, rotation: $0.rotation) },
            pixelSpacing: view?.pixelSpacing ?? 0,
            image: pix.map { SettingsPropagation.Image(rect: $0.rectCoordinates(), hasOrigin: $0.isOriginDefined) },
            isRGB: pix?.isRGB ?? false, suvConverted: pix?.suvConverted ?? false,
            modality: modality, subtraction: viewer.subtractionActivated(), colourTable: viewer.curCLUTMenu(),
            orientation: orientation(), keepsSettingsInSeries: DCMView.noPropagateSettingsInSeries(forModality: modality),
            studyInstanceUID: viewer.studyInstanceUID(), movieIndex: movieIndex, maxMovieIndex: maxMovieIndex,
            seriesLockPan: locked ? view.map { sync.lockPan(of: $0) } : nil)
    }

    /// What `other` takes from this viewer, on the image it shows now.
    private func plan(for other: ViewerController, preferences: SettingsPropagation.Preferences) -> PropagationPlan {
        let full = preferences.propagates
        // The planes are compared by the middle slice of this viewer's first
        // frame and of the other's current one (zeros without slices).
        let source = snapshot(of: viewer, movieIndex: Int(viewer.horos_curMovieIndex), orientation: { [viewer] in
            var orientation = [Float](repeating: 0, count: 9)
            if let slices = viewer.horos_pixList(at: 0), slices.count > 0 { (slices.object(at: slices.count / 2) as? DCMPix)?.orientation(&orientation) }
            return orientation
        }, full: full)
        let target = snapshot(of: other, movieIndex: Int(other.curMovieIndex()), orientation: {
            var orientation = [Float](repeating: 0, count: 9)
            if let slices = other.pixList(), slices.count > 0 { (slices.object(at: slices.count / 2) as? DCMPix)?.orientation(&orientation) }
            return orientation
        }, full: full)
        var originDelta: CGPoint?
        if full, let otherPix = other.imageView()?.curDCM, let pix = viewer.horos_imageView?.curDCM {
            originDelta = DCMPix.originDeltaBetween(otherPix, and: pix)
        }
        let registered = viewer.registeredViewer() == other || other.registeredViewer() == viewer
        return SettingsPropagation(source: source, target: target, registered: registered,
                                   navigatorShown: NavigatorWindowController.navigatorWindowController() != nil,
                                   originDelta: originDelta, preferences: preferences).plan()
    }

    /// Hands this viewer's settings on to `other`: its 4D frame (same number
    /// of frames, no navigator), and with "propagate settings" on its window
    /// level (same colour table, images of one kind), and between parallel
    /// planes its zoom, pan (same study or registered, overlapping images, or
    /// series locked across studies) and rotation. A fused viewer passes them on to its fusion.
    func propagateSettings(to other: ViewerController) {
        let preferences = propagationPreferences
        var plan = plan(for: other, preferences: preferences)

        // The frame first: the rest is worked out on the image the other
        // viewer shows once it is there.
        if let movieIndex = plan.movieIndex {
            other.setMovieIndex(Int16(truncatingIfNeeded: movieIndex))
            plan = self.plan(for: other, preferences: preferences)
        }

        if let otherView = other.imageView() {
            if let window = plan.window { otherView.setWLWW(window.level, window.width) }
            if let scale = plan.scale { otherView.scaleValue = scale }
            if let origin = plan.origin { otherView.origin = origin }
            if let rotation = plan.rotation { otherView.rotation = rotation }
        }

        if let fusion = other.blending() {
            if fusion != viewer {
                propagateSettings(to: fusion)
            } else {
                other.refresh()
            }
        }
    }

    /// The "Propagate settings" command: hands the settings on now, and redraws.
    func copySettingsToOthers() {
        propagateSettings()

        viewer.horos_imageView?.needsDisplay = true
    }

    /// Hands this viewer's settings on to every other displayed 2D viewer that
    /// takes them, and refreshes the fusion of the volume renderings fused
    /// with it.
    func propagateSettings() {
        if let first = viewer.horos_fileList(at: 0)?.firstObject as? DicomImage,
           viewerIsEqualToString((first.completePath() as NSString?)?.lastPathComponent, "Empty.tif") { return }

        if viewer.horos_windowWillClose { return }

        for other in registry.displayedViewers where other !== viewer {
            if other.imageView()?.shouldPropagate() ?? false {
                propagateSettings(to: other)
            }
        }

        // VR Viewers
        var volumeRenderings: [VRController] = []
        for window in NSApp.windows {
            guard let controller = window.windowController else { continue }
            let nib = controller.windowNibName
            if viewerIsEqualToString(nib, "VR") || viewerIsEqualToString(nib, "VRPanel"),
               controller != viewer, let vr = controller as? VRController {
                volumeRenderings.append(vr)
            }
        }
        for vr in volumeRenderings where vr.blendingController() != nil {
            vr.updateBlendingImage()
        }
    }
}
