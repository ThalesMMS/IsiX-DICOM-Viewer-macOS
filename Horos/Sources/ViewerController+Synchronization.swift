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

// The "Multi viewport series synchronization" block of ViewerController (4.3):
// the toolbar's "Sync" button (within a study it switches the view's syncro
// mode; across studies it locks the series at their current offset), the
// re-alignment of a fused series ("Re-sync origin") and the settings one
// viewer hands on to the others (window level, zoom, pan, rotation, 4D frame).
// The rules - when the button works across studies, which window level, zoom
// and pan go to another viewer, the origin arithmetic - are IsiXImaging's
// ViewerSynchronization, WindowLevelPropagation, ViewerSettingsPropagation and
// FusionOriginAlignment. The selectors are those of the former Objective-C
// methods.

fileprivate let SyncSeriesToolbarItemIdentifier = "Sync.pdf"
fileprivate let SyncLockToolbarImage = "SyncLock.pdf"

public extension ViewerController {

    /// The "Sync" item of the viewer's toolbar.
    @objc(findSyncSeriesButton)
    func findSyncSeriesButton() -> Any! {
        for item in horos_toolbar?.items ?? [] where viewerIsEqualToString(item.itemIdentifier.rawValue, SyncSeriesToolbarItemIdentifier) {
            return item
        }
        return nil
    }

    /// The series lock changed (OsirixSyncSeriesNotification): across studies,
    /// this viewer locks at its offset from the sender's slice location, or
    /// unlocks; within a study, the button shows the view's syncro mode.
    @objc(notificationSyncSeries:)
    func notificationSyncSeries(_ note: Notification!) {
        let button = findSyncSeriesButton() as? NSToolbarItem
        if SyncButtonBehaviorIsBetweenStudies.boolValue {
            if ViewerController.horos_SYNCSERIES() {
                let sliceLocation = (note?.userInfo?["sliceLocation"] as? NSNumber)?.floatValue ?? 0
                if let imageView = horos_imageView {
                    let current = imageView.dcmPixList?.object(at: Int(imageView.curImage)) as? DCMPix
                    imageView.syncRelativeDiff = Float((current?.sliceLocation ?? 0) - Double(sliceLocation))
                }
                button?.image = NSImage.toolbarImageNamed(SyncLockToolbarImage)
                horos_imageView?.syncSeriesIndex = 0
            } else {
                button?.image = NSImage.toolbarImageNamed(SyncSeriesToolbarItemIdentifier)
                horos_imageView?.syncSeriesIndex = -1
            }
        } else {
            if horos_imageView?.syncro() ?? 0 != Int16(syncroOFF) {
                button?.image = NSImage.toolbarImageNamed(SyncLockToolbarImage)
            } else {
                button?.image = NSImage.toolbarImageNamed(SyncSeriesToolbarItemIdentifier)
            }
        }
    }

    /// Unlocks the series of different studies, if they are locked.
    @objc(turnOffSyncSeriesBetweenStudies:)
    func turnOffSyncSeriesBetweenStudies(_ sender: Any!) {
        if SyncButtonBehaviorIsBetweenStudies.boolValue && ViewerController.horos_SYNCSERIES() {
            syncSeries(self)
        }
    }

    /// Locks the series of different studies at their current offset.
    @objc(activateSYNCSERIESBetweenStudies)
    static func activateSYNCSERIESBetweenStudies() {
        guard SyncButtonBehaviorIsBetweenStudies.boolValue else { return }
        ViewerController.horos_setSYNCSERIES(true)

        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? NSMutableArray() {
            (viewer.findSyncSeriesButton() as? NSToolbarItem)?.image = NSImage.toolbarImageNamed(SyncLockToolbarImage)
            viewer.horos_imageView?.syncSeriesIndex = 0
        }
    }

    /// The "Sync" button: across studies it locks or unlocks the series and
    /// tells the others where this one is; within a study it switches the
    /// view's syncro mode (Option: relative, otherwise by location).
    @objc(SyncSeries:)
    func syncSeries(_ sender: Any!) {
        if SyncButtonBehaviorIsBetweenStudies.boolValue {
            ViewerController.horos_setSYNCSERIES(!ViewerController.horos_SYNCSERIES())

            var sliceLocation: Float = 0
            if let imageView = horos_imageView {
                let current = imageView.dcmPixList?.object(at: Int(imageView.curImage)) as? DCMPix
                sliceLocation = Float(current?.sliceLocation ?? 0)
            }
            NotificationCenter.default.post(name: .OsirixSyncSeries, object: self,
                                            userInfo: ["sliceLocation": NSNumber(value: sliceLocation)])
        } else {
            guard let imageView = horos_imageView else { return }
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

    /// The study of the current movie frame's first image.
    @objc(studyInstanceUID)
    nonisolated func studyInstanceUID() -> String! {
        let files = horos_fileList(at: Int(horos_curMovieIndex))
        return (files?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String
    }

    /// Works out what the "Sync" button does: across studies when the other
    /// displayed viewers are not all of this one's study. Within a study, or on
    /// switching to across studies, the series are unlocked.
    @objc(SetSyncButtonBehavior:)
    func setSyncButtonBehavior(_ sender: Any!) {
        let wasBetweenStudies = SyncButtonBehaviorIsBetweenStudies.boolValue
        let viewers = ViewerController.getDisplayed2DViewers() ?? NSMutableArray()
        viewers.remove(self)
        let others = viewers.compactMap { $0 as? ViewerController }

        let study = others.isEmpty ? nil : studyInstanceUID()
        let betweenStudies = ViewerSynchronization.syncsBetweenStudies(study: study, otherStudies: others.map { $0.studyInstanceUID() })
        SyncButtonBehaviorIsBetweenStudies = ObjCBool(betweenStudies)

        if ViewerSynchronization.resetsSeriesLock(betweenStudies: betweenStudies, wasBetweenStudies: wasBetweenStudies) {
            let app = AppController.shared()
            app?.willChangeValue(forKey: "SYNCSERIES")
            ViewerController.horos_setSYNCSERIES(false)
            app?.didChangeValue(forKey: "SYNCSERIES")
            NotificationCenter.default.post(name: .OsirixSyncSeries, object: nil, userInfo: nil)

            for viewer in others { viewer.horos_imageView?.syncSeriesIndex = -1 }
        }
    }

    /// "Re-sync origin" of a fusion whose settings are not propagated: every
    /// slice gets the spacing and origin that put it where the fused series is
    /// shown, then the views are synchronized by location.
    @objc(reSyncOrigin:)
    func reSyncOrigin(_ sender: Any!) {
        guard let blending = horos_blending else {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                message: NSLocalizedString("Only useful if image fusion is activated.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        guard let imageView = horos_imageView,
              !UserDefaults.standard.bool(forKey: "COPYSETTINGS") || imageView.syncro() != Int16(syncroLOC) else {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                message: NSLocalizedString("Only useful if propagate settings is OFF.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        let fusedView = blending.imageView()
        let fusedSlice = fusedView?.curDCM
        let zShift = Float((fusedSlice?.sliceLocation ?? 0) - (imageView.curDCM?.sliceLocation ?? 0))

        for movie in 0..<horos_movieCount {
            for pic in horos_pixArray(movie) {
                var vectors = [Float](repeating: 0, count: 9)
                pic.orientation(&vectors)

                // The viewer's current image is one of these slices: its
                // spacing is read again for each, as it changes on the way.
                let current = imageView.curDCM
                pic.pixelSpacingX = FusionOriginAlignment.pixelSpacing(current: current?.pixelSpacingX ?? 0, fusedView: fusedView?.pixelSpacingX ?? 0,
                                                                       fusedScale: fusedView?.scaleValue ?? 0, scale: imageView.scaleValue)
                pic.pixelSpacingY = FusionOriginAlignment.pixelSpacing(current: imageView.curDCM?.pixelSpacingY ?? 0, fusedView: fusedView?.pixelSpacingY ?? 0,
                                                                       fusedScale: fusedView?.scaleValue ?? 0, scale: imageView.scaleValue)

                let fused = FusionOriginAlignment.View(
                    origin: (fusedSlice?.originX ?? 0, fusedSlice?.originY ?? 0, fusedSlice?.originZ ?? 0),
                    width: Int(fusedSlice?.pwidth ?? 0), height: Int(fusedSlice?.pheight ?? 0),
                    pixelSpacingX: fusedSlice?.pixelSpacingX ?? 0, pixelSpacingY: fusedSlice?.pixelSpacingY ?? 0,
                    viewOrigin: fusedView?.origin ?? .zero, scale: fusedView?.scaleValue ?? 0,
                    viewPixelSpacingX: fusedView?.pixelSpacingX ?? 0, viewPixelSpacingY: fusedView?.pixelSpacingY ?? 0)
                let own = FusionOriginAlignment.View(
                    origin: (pic.originX, pic.originY, pic.originZ), width: Int(pic.pwidth), height: Int(pic.pheight),
                    pixelSpacingX: pic.pixelSpacingX, pixelSpacingY: pic.pixelSpacingY,
                    viewOrigin: imageView.origin, scale: imageView.scaleValue,
                    viewPixelSpacingX: imageView.pixelSpacingX, viewPixelSpacingY: imageView.pixelSpacingY)
                let o = FusionOriginAlignment.origin((pic.originX, pic.originY, pic.originZ), vectors: vectors,
                                                     width: Int(pic.pwidth), height: Int(pic.pheight),
                                                     spacingX: pic.pixelSpacingX, spacingY: pic.pixelSpacingY,
                                                     fused: fused, view: own, zShift: zShift)
                var origin = [o.0, o.1, o.2]
                pic.setOrigin(&origin)
                pic.computeSliceLocation()
            }
        }

        UserDefaults.standard.set(true, forKey: "COPYSETTINGS")
        imageView.setSyncro(Int16(syncroLOC))
        imageView.sendSyncMessage(0)
        propagateSettings()
    }

    /// Hands this viewer's settings on to `vC`: its 4D frame (same number of
    /// frames, no navigator), and with "propagate settings" on its window level
    /// (same colour table, images of one kind), and between parallel planes its
    /// zoom, pan (same study or registered, overlapping images) and rotation.
    /// A fused viewer passes them on to its fusion.
    @objc(propagateSettingsToViewer:)
    func propagateSettings(to vC: ViewerController!) {
        guard let vC else { return }
        let defaults = UserDefaults.standard
        let imageView = horos_imageView
        let otherView = vC.imageView()

        // 4D data
        if horos_curMovieIndex != vC.curMovieIndex() && horos_maxMovieIndex == vC.horos_maxMovieIndex
            && NavigatorWindowController.navigatorWindowController() == nil {
            vC.setMovieIndex(horos_curMovieIndex)
        }

        let registeredViewers = registeredViewer() == vC || vC.registeredViewer() == self

        if defaults.bool(forKey: "COPYSETTINGS") {
            if viewerIsEqualToString(vC.curCLUTMenu(), curCLUTMenu()) {
                let rule = WindowLevelPropagation(
                    isRGB: imageView?.curDCM?.isRGB ?? false, otherIsRGB: otherView?.curDCM?.isRGB ?? false,
                    modality: modality(), otherModality: vC.modality(),
                    subtraction: subtractionActivated(), otherSubtraction: vC.subtractionActivated(),
                    suvConverted: imageView?.curDCM?.suvConverted ?? false, otherSUVConverted: otherView?.curDCM?.suvConverted ?? false)

                if !defaults.bool(forKey: "DONTCOPYWLWWSETTINGS") && rule.propagates, let imageView, let otherView {
                    var iwl: Float = 0, iww: Float = 0, dwl: Float = 0, dww: Float = 0
                    imageView.getWLWW(&iwl, &iww)
                    otherView.getWLWW(&dwl, &dww)
                    if iwl != dwl || iww != dww { otherView.setWLWW(iwl, iww) }
                }
            }

            var vectorsA = [Float](repeating: 0, count: 9), vectorsB = [Float](repeating: 0, count: 9)
            // The middle slices' orientations (nil lists, as messages to nil, give nothing).
            if let own = horos_pixList(at: 0) { (own.object(at: own.count / 2) as? DCMPix)?.orientation(&vectorsA) }
            if let others = vC.pixList() as NSArray? { (others.object(at: others.count / 2) as? DCMPix)?.orientation(&vectorsB) }

            let angle = vectorsA.withUnsafeMutableBufferPointer { a in
                vectorsB.withUnsafeMutableBufferPointer { b in DCMView.angleBetweenVector(a.baseAddress! + 6, andVector: b.baseAddress! + 6) }
            }
            let tolerance = defaults.float(forKey: "PARALLELPLANETOLERANCE")
            let noPropagation = DCMView.noPropagateSettingsInSeries(forModality: vC.modality()) && DCMView.noPropagateSettingsInSeries(forModality: modality())

            if angle < tolerance || defaults.bool(forKey: "AlwaysPropagateScaleLevel") {
                if !defaults.bool(forKey: "DONTCOPYZOOMSETTINGS") && !noPropagation, let imageView, let otherView,
                   let scale = ViewerSettingsPropagation.scale(imageView.scaleValue, pixelSpacing: imageView.pixelSpacing,
                                                               otherPixelSpacing: otherView.pixelSpacing) {
                    otherView.scaleValue = scale
                }
            }

            if angle < tolerance && !noPropagation, let imageView, let otherView {
                let sameStudy = viewerIsEqualToString(
                    ((fileList() as NSArray?)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String,
                    ((vC.fileList() as NSArray?)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String)
                if !defaults.bool(forKey: "DONTCOPYPANSETTINGS") && (sameStudy || registeredViewers) {
                    // Overlapping images only: not the left and right limbs of one study.
                    if let otherPix = otherView.curDCM, let pix = imageView.curDCM,
                       NSIntersectsRect(otherPix.rectCoordinates(), pix.rectCoordinates()),
                       otherPix.isOriginDefined && pix.isOriginDefined {
                        let delta = DCMPix.originDeltaBetween(otherPix, and: pix)
                        otherView.origin = ViewerSettingsPropagation.pan(imageView.origin, delta: delta, scale: imageView.scaleValue)
                    }
                }

                if !defaults.bool(forKey: "DONTCOPYROTATIONSETTINGS") {
                    otherView.rotation = imageView.rotation
                }
            }
        }

        if let fusion = vC.blending() {
            if fusion != self {
                propagateSettings(to: fusion)
            } else {
                vC.refresh()
            }
        }
    }

    /// Hands this viewer's settings on to every other displayed 2D viewer that
    /// takes them, and refreshes the fusion of the volume renderings fused
    /// with it.
    @objc(propagateSettings)
    func propagateSettings() {
        let firstFile = horos_fileList(at: 0)?.object(at: 0) as? NSObject
        if viewerIsEqualToString(((firstFile?.value(forKey: "completePath") as? NSString)?.lastPathComponent), "Empty.tif") { return }

        if horos_windowWillClose { return }

        let viewers = ViewerController.getDisplayed2DViewers() ?? NSMutableArray()
        viewers.remove(self)

        for case let vC as ViewerController in viewers where vC != self {
            if vC.imageView()?.shouldPropagate() ?? false {
                propagateSettings(to: vC)
            }
        }

        // VR Viewers
        var volumeRenderings: [VRController] = []
        for window in NSApp.windows {
            guard let controller = window.windowController else { continue }
            let nib = controller.windowNibName
            if viewerIsEqualToString(nib, "VR") || viewerIsEqualToString(nib, "VRPanel"),
               controller != self, let vr = controller as? VRController {
                volumeRenderings.append(vr)
            }
        }
        for vr in volumeRenderings where vr.blendingController() != nil {
            vr.updateBlendingImage()
        }
    }
}
