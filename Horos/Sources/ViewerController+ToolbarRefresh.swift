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

// The state of the 2D viewer's toolbar and of what goes with it: the detached
// toolbar panel and the floating thumbnails lists shown for the front viewer,
// the browser following the image shown, the toolbar's customization palette,
// the Cobb angle preference and the 12-bit display item. The selectors are
// those of the former Objective-C methods; the work is the viewer's
// ViewerToolbarItemFactory.

public extension ViewerController {

    /// Shows the detached toolbar panel for the front viewer and lends the
    /// floating thumbnails list of this viewer's screen.
    @objc(redrawToolbar)
    func redrawToolbar() {
        toolbarItems.redrawToolbar(in: self)
    }

    /// Redraws the toolbar, selects the image shown in the browser and updates
    /// the Sync button.
    @objc(refreshToolbar)
    func refreshToolbar() {
        toolbarItems.refreshToolbar(in: self)
    }

    @objc(customizeViewerToolBar:)
    func customizeViewerToolBar(_ sender: Any!) {
        horos_toolbar?.runCustomizationPalette(sender)
    }

    /// Shows or hides the Cobb angle; showing it shows every ROI's information.
    @objc(switchCobbAngle:)
    func switchCobbAngle(_ sender: Any!) {
        toolbarItems.switchCobbAngle()
    }

    // MARK: - 12 bit

    /// The 12-bit toolbar item: its first cell turns the 12-bit LUT on.
    @objc(enable12Bit:)
    func enable12Bit(_ sender: Any!) {
        toolbarItems.enable12Bit(sender, in: self)
    }

    /// Shows in the 12-bit toolbar item whether the image view uses the 12-bit LUT.
    @objc(verify12Bit:)
    func verify12Bit(_ theTimer: Timer!) {
        toolbarItems.verify12Bit(in: self)
    }
}
