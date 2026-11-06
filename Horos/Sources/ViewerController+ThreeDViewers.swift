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

// Opening the 3D and MPR viewers from the 2D viewer (volume rendering, the
// panel, surface rendering, the orthogonal MPR and its PET-CT fusion,
// endoscopy, the oblique MPR, the CPR and the 3D region growing) is
// ThreeDViewerLauncher's. These are the selectors of the former Objective-C
// methods, which the nib, the menus and the plugins send, kept as a façade.

public extension ViewerController {

    /// The volume rendering panel (MIP), on the frame the player shows.
    @objc(Panel3D:)
    func panel3D(_ sender: Any!) {
        threeDViewerLauncher.openVolumeRenderingPanel(sender)
    }

    /// The 3D region growing, on volumic data, or in 2D otherwise.
    @objc(segmentationTest:)
    func segmentationTest(_ sender: Any!) {
        threeDViewerLauncher.openRegionGrowing(sender)
    }

    /// The volume rendering window in `mode` ("VR" or "MIP"), prepared and
    /// ready to be shown; nil when the frames cannot be reconstructed.
    @objc(openVRViewerForMode:)
    func openVRViewer(forMode mode: String!) -> VRController! {
        threeDViewerLauncher.volumeRenderingWindow(mode: mode)
    }

    /// Volume rendering (tag 3: MIP), in a window of its own.
    @objc(VRViewer:)
    func vrViewer(_ sender: Any!) {
        threeDViewerLauncher.openVolumeRendering(sender)
    }

    /// The surface rendering open on these slices, or a new one.
    @objc(openSRViewer)
    internal func openSRViewer() -> SRController! {
        threeDViewerLauncher.surfaceRenderingWindow()
    }

    /// Surface rendering.
    @objc(SRViewer:)
    func srViewer(_ sender: Any!) {
        threeDViewerLauncher.openSurfaceRendering(sender)
    }

    /// The orthogonal MPR open on these slices (its PET-CT fusion with a
    /// fused series), or a new one.
    @objc(openOrthogonalMPRViewer)
    func openOrthogonalMPRViewer() -> OrthogonalMPRViewer! {
        threeDViewerLauncher.orthogonalMPRWindow()
    }

    /// The orthogonal MPR of this series fused with its PET series.
    @objc(openOrthogonalMPRPETCTViewer)
    func openOrthogonalMPRPETCTViewer() -> OrthogonalMPRPETCTViewer! {
        threeDViewerLauncher.orthogonalPETCTWindow()
    }

    /// The orthogonal MPR (PET-CT with a fused series).
    @objc(orthogonalMPRViewer:)
    func orthogonalMPRViewer(_ sender: Any!) {
        threeDViewerLauncher.openOrthogonalMPR(sender)
    }

    /// The endoscopy viewer open on these slices, or a new one.
    @objc(openEndoscopyViewer)
    func openEndoscopyViewer() -> EndoscopyViewer! {
        threeDViewerLauncher.endoscopyWindow()
    }

    /// The endoscopy viewer.
    @objc(endoscopyViewer:)
    func endoscopyViewer(_ sender: Any!) {
        threeDViewerLauncher.openEndoscopy(sender)
    }

    /// The oblique MPR open on these slices, or a new one on every frame.
    @objc(openMPRViewer)
    func openMPRViewer() -> MPRController! {
        threeDViewerLauncher.obliqueMPRWindow()
    }

    /// The oblique MPR. From the Series Selection item of an MPR (`sender`),
    /// the new MPR takes the frame of the one it replaces.
    @objc(mprViewer:)
    func mprViewer(_ sender: Any!) {
        threeDViewerLauncher.openObliqueMPR(sender)
    }

    /// The CPR open on these slices, or a new one on every frame.
    @objc(openCPRViewer)
    func openCPRViewer() -> CPRController! {
        threeDViewerLauncher.curvedMPRWindow()
    }

    /// The CPR (curved MPR), on volumic black and white data.
    @objc(cprViewer:)
    func cprViewer(_ sender: Any!) {
        threeDViewerLauncher.openCurvedMPR(sender)
    }
}

extension ViewerController {

    /// The launcher of this viewer's 3D and MPR viewers, made for each call
    /// over the viewer's graph; it holds the viewer for that call only.
    var threeDViewerLauncher: ThreeDViewerLauncher {
        ThreeDViewerLauncher(viewer: self, windowArranger: sessionGraph.processGraph.windowArranger,
                             preferences: sessionGraph.preferences)
    }
}
