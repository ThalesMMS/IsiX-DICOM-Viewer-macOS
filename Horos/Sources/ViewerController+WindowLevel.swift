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

// The window level actions of the 2D viewer: the presets of the WL/WW menu,
// the "Set WL/WW" sheet, the reset of the views, and the conversions of the
// series between black and white and RGB. They are the viewer's
// ViewerWindowLevel; these are the selectors of the former Objective-C
// methods, which the nibs, the menus and the former plugins send.

public extension ViewerController {

    /// The name of the WL/WW preset on screen, shown in the WL/WW popup.
    @objc(setCurWLWWMenu:)
    func setCurWLWWMenu(_ s: String!) {
        if s as NSString? !== horos_curWLWWMenu as NSString? && !viewerIsEqualToString(s, horos_curWLWWMenu) {
            horos_curWLWWMenu = s
            horos_wlwwPopup?.setTitle(horos_curWLWWMenu ?? "")
        }
    }

    @objc(curWLWWMenu)
    func curWLWWMenu() -> String! {
        return horos_curWLWWMenu
    }

    /// Every view of the window back to its origin, fitted, unrotated, at its
    /// image's default window.
    @objc(resetImage:)
    func resetImage(_ sender: Any!) {
        sessionGraph.windowLevel.resetImage()
    }

    /// Converts the black and white images of every movie frame to RGB.
    @objc(ConvertToRGBMenu:)
    func convertToRGBMenu(_ sender: Any!) {
        sessionGraph.windowLevel.convertToRGB(sender)
    }

    /// Converts the RGB images of every movie frame to black and white.
    @objc(ConvertToBWMenu:)
    func convertToBWMenu(_ sender: Any!) {
        sessionGraph.windowLevel.convertToBW(sender)
    }

    /// The end of the alert that asks before deleting a WL/WW preset:
    /// `contextInfo` is the preset's name, retained by the caller and released here.
    @objc(deleteWLWW:returnCode:contextInfo:)
    func deleteWLWW(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        sessionGraph.windowLevel.endDeletePreset(returnCode: returnCode, contextInfo: contextInfo)
    }

    /// A WL/WW menu item: "Other", "Default WL & WW", "Full dynamic" or a
    /// stored preset, deleted instead when Shift is down.
    @objc(ApplyWLWW:)
    func applyWLWW(_ sender: Any!) {
        sessionGraph.windowLevel.applyPreset(sender)
    }

    /// A field of the "Set WL/WW" sheet changed.
    @objc(updateSetWLWW:)
    func updateSetWLWW(_ sender: Any!) {
        sessionGraph.windowLevel.updateSetWindowSheet(sender)
    }

    /// The end of the "Set WL/WW" sheet.
    @objc(endSetWLWW:)
    func endSetWLWW(_ sender: Any!) {
        sessionGraph.windowLevel.endSetWindowSheet(sender)
    }

    /// Opens the "Set WL/WW" sheet at the current window.
    @objc(SetWLWW:)
    func setWLWW(_ sender: Any!) {
        sessionGraph.windowLevel.openSetWindowSheet()
    }
}
