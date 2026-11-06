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

// The "blending" selectors of ViewerController (fusion of two series), which
// the menus, the nibs, the views and the plugins send: the work is
// ViewerFusion's, made for each call. blendingController, the fused viewer,
// is the viewer's own ViewerFusionState; -blendedWindow, the getter of the
// declared property, is in ViewerController.swift.

public extension ViewerController {

    @objc(blendWindows:)
    func blendWindows(_ sender: Any!) {
        fusion.blendWindows(sender)
    }

    @objc(ActivateBlending:)
    func activateBlending(_ bC: ViewerController!) {
        fusion.activateBlending(bC)
    }

    @objc(endBlendingType:)
    func endBlendingType(_ sender: Any!) {
        fusion.endBlendingType(sender)
    }

    @objc(blendingSheetDidEnd:returnCode:contextInfo:)
    func blendingSheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        fusion.blendingSheetDidEnd(sheet, returnCode: returnCode, contextInfo: contextInfo)
    }

    @objc(blendWithViewer:blendingType:)
    func blend(withViewer bc: ViewerController!, blendingType: Int32) {
        fusion.blend(withViewer: bc, blendingType: blendingType)
    }

    @objc(blendingSlider)
    func blendingSlider() -> NSSlider! { return self.horos_blendingSlider }

    @objc(blendingSlider:)
    func blendingSlider(_ sender: Any!) {
        fusion.blendingSlider(sender)
    }

    @objc(blendingMode:)
    func blendingMode(_ sender: Any!) {
        fusion.blendingMode(sender)
    }

    @objc(copySettingsToOthers:)
    func copySettingsToOthers(_ sender: Any!) {
        settingsPropagator.copySettingsToOthers()
    }

    @objc(blendingController)
    func blending() -> ViewerController! {
        return self.horos_blending
    }
}
