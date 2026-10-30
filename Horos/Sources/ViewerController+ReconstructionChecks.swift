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

// What the viewer checks before it opens a reconstruction (VR, SR, MPR, CPR,
// endoscopy): whether its 4D frames, and those of a fused series, can be
// reconstructed together, whether its slices have the geometry an MPR
// resamples, and the screen and frame a 3D viewer opens on. The slice scan is
// IsiXImaging's ReconstructionGeometryScan, the screen choice its
// ThreeDViewerScreen. The selectors are those of the former Objective-C
// methods.

public extension ViewerController {

    /// Why the 4D frames cannot be reconstructed together (too many, a frame
    /// with inconsistent slices, a frame unlike the first), or nil.
    @objc(fourDReconstructionRefusalReason)
    func fourDReconstructionRefusalReason() -> String? {
        let count = Int(horos_maxMovieIndex)
        if count < 1 {
            return FourDSeriesGuard.reconstructionRefusal(comparing: nil, to: nil, at: 0)
        }
        if let capacity = FourDSeriesGuard.capacityReason(at: count - 1, capacity: Int(MAX4D)) {
            return capacity
        }
        if let slices = FourDSeriesGuard.reasonForInconsistentSlices(horos_pixList(at: 0), atTime: 0) {
            return slices
        }
        let reference = FourDSeriesGuard.geometry(fromPixList: horos_pixList(at: 0), volume: horos_volumeData(at: 0) as? NSData)
        if let first = FourDSeriesGuard.reconstructionRefusal(comparing: reference, to: reference, at: 0) {
            return first
        }
        for i in 1..<max(count, 1) {
            if let timeSlices = FourDSeriesGuard.reasonForInconsistentSlices(horos_pixList(at: i), atTime: i) {
                return timeSlices
            }
            let candidate = FourDSeriesGuard.geometry(fromPixList: horos_pixList(at: i), volume: horos_volumeData(at: i) as? NSData)
            if let reason = FourDSeriesGuard.reconstructionRefusal(comparing: candidate, to: reference, at: i) {
                return reason
            }
        }
        return nil
    }

    /// Shows why the frames cannot be reconstructed, under `title`; false
    /// when they can.
    @objc(refuseFourDReconstructionWithTitle:)
    func refuseFourDReconstruction(withTitle title: String!) -> Bool {
        guard let reason = fourDReconstructionRefusalReason() else { return false }
        HorosAlertPanel.run(title: title, message: reason, defaultButton: nil, alternateButton: nil, otherButton: nil)
        return true
    }

    /// Why `overlay` cannot be fused frame by frame with this viewer, or nil
    /// (also without an overlay).
    @objc(fourDFusionRefusalReasonForOverlay:)
    func fourDFusionRefusalReason(forOverlay overlay: ViewerController!) -> String? {
        guard let overlay else { return nil }
        if let overlayReason = overlay.fourDReconstructionRefusalReason() {
            return overlayReason
        }
        return FourDSeriesGuard.fusionRefusal(hostTimes: Int(horos_maxMovieIndex), overlayTimes: Int(overlay.maxMovieIndex()))
    }

    /// The same for the series fused with this viewer.
    @objc(fourDFusionRefusalReason)
    func fourDFusionRefusalReason() -> String? {
        fourDFusionRefusalReason(forOverlay: horos_blending)
    }

    /// Shows why the fusion cannot be reconstructed, under `title`; false
    /// when it can.
    @objc(refuseFourDFusionWithTitle:)
    func refuseFourDFusion(withTitle title: String!) -> Bool {
        guard let reason = fourDFusionRefusalReason() else { return false }
        HorosAlertPanel.run(title: title, message: reason, defaultButton: nil, alternateButton: nil, otherButton: nil)
        return true
    }

    /// The geometry every reconstruction door has to agree about: valid input
    /// gives the expected planes, incompatible input a specific error, for the
    /// oblique and orthogonal MPR and the CPR alike.
    @objc(reconstructionOpeningDecision)
    func reconstructionOpeningDecision() -> MPROpenDecision! {
        let interval = computeInterval()
        // The first slice is read as before: a missing list gives no slice, an
        // empty one raises.
        let list = horos_pixList(at: 0)
        let firstPix = list?.object(at: 0) as? DCMPix
        let slices = list ?? NSMutableArray()

        let scan = ReconstructionGeometryScan.scan(slices.map { item -> ReconstructionGeometryScan.Slice in
            let pix = item as! DCMPix
            var orientation = [Float](repeating: 0, count: 9)
            pix.orientation(&orientation)
            return ReconstructionGeometryScan.Slice(width: Int(pix.pwidth), height: Int(pix.pheight), orientation: orientation,
                                                    originX: Double(pix.originX), originY: Double(pix.originY), originZ: Double(pix.originZ))
        }, interval: interval)

        var roiCount = 0
        for case let sliceROIs as NSArray in horos_roiList(at: Int(horos_curMovieIndex)) ?? NSMutableArray() {
            roiCount += sliceROIs.count
        }

        return MPROpenGeometry.opening(withSliceCount: Int(Int32(truncatingIfNeeded: slices.count)),
                                       spacingX: Double(firstPix?.pixelSpacingX ?? 0), spacingY: Double(firstPix?.pixelSpacingY ?? 0),
                                       sliceInterval: Double(interval),
                                       minInterval: scan.minInterval, maxInterval: scan.maxInterval,
                                       width: Int(firstPix?.pwidth ?? 0), height: Int(firstPix?.pheight ?? 0),
                                       mismatchedSlices: scan.mismatchedSlices,
                                       roiCount: Int(Int32(truncatingIfNeeded: roiCount)),
                                       mismatchedOrientations: scan.mismatchedOrientations)
    }

    /// The screen a 3D viewer of `v` opens on: `v`'s, or another one with the
    /// "ThreeDViewerOnAnotherScreen" preference.
    @objc(get3DViewerScreen:)
    func get3DViewerScreen(_ v: ViewerController!) -> NSScreen! {
        let own = v?.window?.screen
        let screens = NSScreen.screens
        if let index = ThreeDViewerScreen.index(viewerScreenOrigin: own?.frame.origin ?? .zero,
                                                 screenOrigins: screens.map { $0.frame.origin },
                                                 onAnotherScreen: UserDefaults.standard.bool(forKey: "ThreeDViewerOnAnotherScreen")) {
            return screens[index]
        }
        return own
    }

    /// Gives `viewer`'s window the visible frame of that screen.
    @objc(place3DViewerWindow:)
    func place3DViewerWindow(_ viewer: NSWindowController!) {
        viewer?.window?.setFrame(get3DViewerScreen(self)?.visibleFrame ?? .zero, display: false)
    }
}

extension ViewerController {

    /// Whether the slice thickness and interval are to be asked first: no
    /// interval, no pixel spacing, or Shift held. The interval is computed
    /// first, as it always was, and then the first slice is read.
    func needsThicknessAndInterval() -> Bool {
        if computeInterval() == 0 { return true }
        let first = horos_pixList(at: 0)?.object(at: 0) as? DCMPix
        if (first?.pixelSpacingX ?? 0) == 0 || (first?.pixelSpacingY ?? 0) == 0 { return true }
        return NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false
    }
}
