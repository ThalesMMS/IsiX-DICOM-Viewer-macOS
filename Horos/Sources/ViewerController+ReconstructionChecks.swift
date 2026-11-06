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

// What the viewer checks before it opens a reconstruction (VR, SR, MPR, CPR,
// endoscopy): whether its 4D frames, and those of a fused series, can be
// reconstructed together, whether its slices have the geometry an MPR
// resamples, and the screen and frame a 3D viewer opens on. The checks are
// ThreeDViewerLauncher's, their rules IsiXImaging's VolumeEligibility,
// ReconstructionGeometryScan and ThreeDViewerScreen. These are the selectors
// of the former Objective-C methods, kept as a façade.

public extension ViewerController {

    /// Why the 4D frames cannot be reconstructed together (too many, a frame
    /// with inconsistent slices, a frame unlike the first), or nil.
    @objc(fourDReconstructionRefusalReason)
    func fourDReconstructionRefusalReason() -> String? {
        threeDViewerLauncher.fourDReconstructionRefusalReason()
    }

    /// Shows why the frames cannot be reconstructed, under `title`; false
    /// when they can.
    @objc(refuseFourDReconstructionWithTitle:)
    func refuseFourDReconstruction(withTitle title: String!) -> Bool {
        let launcher = threeDViewerLauncher
        return launcher.refuse(launcher.fourDReconstructionRefusalReason(), title: title)
    }

    /// Why `overlay` cannot be fused frame by frame with this viewer, or nil
    /// (also without an overlay).
    @objc(fourDFusionRefusalReasonForOverlay:)
    func fourDFusionRefusalReason(forOverlay overlay: ViewerController!) -> String? {
        threeDViewerLauncher.fourDFusionRefusalReason(forOverlay: overlay)
    }

    /// The same for the series fused with this viewer.
    @objc(fourDFusionRefusalReason)
    func fourDFusionRefusalReason() -> String? {
        threeDViewerLauncher.fourDFusionRefusalReason(forOverlay: horos_blending)
    }

    /// Shows why the fusion cannot be reconstructed, under `title`; false
    /// when it can.
    @objc(refuseFourDFusionWithTitle:)
    func refuseFourDFusion(withTitle title: String!) -> Bool {
        let launcher = threeDViewerLauncher
        return launcher.refuse(launcher.fourDFusionRefusalReason(forOverlay: horos_blending), title: title)
    }

    /// The geometry every reconstruction door has to agree about.
    @objc(reconstructionOpeningDecision)
    func reconstructionOpeningDecision() -> MPROpenDecision! {
        threeDViewerLauncher.reconstructionOpeningDecision()
    }

    /// The screen a 3D viewer of `v` opens on: `v`'s, or another one with the
    /// "ThreeDViewerOnAnotherScreen" preference.
    @objc(get3DViewerScreen:)
    func get3DViewerScreen(_ v: ViewerController!) -> NSScreen! {
        threeDViewerLauncher.screen(for: v)
    }

    /// Gives `viewer`'s window the visible frame of that screen.
    @objc(place3DViewerWindow:)
    func place3DViewerWindow(_ viewer: NSWindowController!) {
        threeDViewerLauncher.place(viewer)
    }
}
