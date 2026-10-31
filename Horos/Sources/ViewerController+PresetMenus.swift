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

// The presets menus of the 2D viewer's popups (window level and width,
// convolution filters, opacity tables), the sheet that names the current
// window level as a preset, and the refresh of the four popups. The menus are
// the process's PresetMenuCache and the work is the viewer's
// ViewerWindowLevel; these are the selectors of the former Objective-C
// methods, which the nibs, the notifications and the former plugins send.

public extension ViewerController {

    /// Tells the menus the current presets and shows them in the popups.
    @objc(refreshMenus)
    func refreshMenus() {
        sessionGraph.windowLevel.refreshMenus(in: self)
    }

    /// The convolution presets changed (a notification with a user info), or
    /// the popup needs its menu.
    @objc(UpdateConvolutionMenu:)
    func updateConvolutionMenu(_ note: Notification!) {
        sessionGraph.windowLevel.updatePresetMenu(.convolution, presetsChanged: note?.userInfo != nil, in: self)
    }

    /// The window level presets changed, or the popup needs its menu.
    @objc(UpdateWLWWMenu:)
    func updateWLWWMenu(_ note: Notification!) {
        sessionGraph.windowLevel.updatePresetMenu(.windowLevel, presetsChanged: note?.userInfo != nil, in: self)
    }

    /// Opens the sheet that names the current window level and width as a preset.
    @objc(AddCurrentWLWW:)
    func AddCurrentWLWW(_ sender: Any!) {
        sessionGraph.windowLevel.openPresetNamingSheet()
    }

    /// Closes the naming sheet; with OK, saves and applies the preset.
    @objc(endNameWLWW:)
    func endNameWLWW(_ sender: Any!) {
        sessionGraph.windowLevel.endPresetNamingSheet(sender)
    }

    @objc(renderButton:)
    func renderButton(_ sender: Any!) {
        NSLog("render Button")
    }

    /// The opacity presets changed, or the popup needs its menu.
    @objc(UpdateOpacityMenu:)
    func updateOpacityMenu(_ note: Notification!) {
        sessionGraph.windowLevel.updatePresetMenu(.opacity, presetsChanged: note?.userInfo != nil, in: self)
    }
}
