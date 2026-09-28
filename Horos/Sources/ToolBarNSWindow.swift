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

/// Window with only a toolbar
///
/// Implemented in Swift since #714: the Objective-C name and
/// <Horos/ToolBarNSWindow.h> are those of the former class, and ToolbarPanel.xib
/// uses the name as the window class. The ordering, main and key status and the
/// active appearance are unchanged.
@objc(ToolBarNSWindow)
public final class ToolBarNSWindow: NSPanel {

    public override func resignMain() {
    }

    public override var canBecomeMain: Bool {
        return true
    }

    public override var canBecomeKey: Bool {
        return true
    }

    // The panel floats behind the viewer and hands the key status back to it, so
    // AppKit draws its toolbar as inactive. AppKit asks the window for its active
    // appearance through this private hook; answer with the viewer's key status,
    // because the panel is part of that window's chrome. Verified on macOS 26:
    // overriding isKeyWindow does not change the drawing, this does.
    @objc(_hasActiveAppearance)
    func _hasActiveAppearance() -> Bool {
        if let controller = self.windowController as? ToolbarPanelController {
            let viewerWindow = controller.viewer?.window
            if viewerWindow?.isVisible == true && viewerWindow?.isKeyWindow == true {
                return true
            }
        }
        return super.isKeyWindow
    }

    public override func orderBack(_ sender: Any?) {
        let v = self.toolbar?.delegate as? ViewerController

        if v?.window?.isVisible == true {
            NSDisableScreenUpdates()
            super.orderBack(self)
            v?.toolbarPanel?.applicationDidChangeScreenParameters(nil)
            self.order(.above, relativeTo: v?.window?.windowNumber ?? 0)
            NSEnableScreenUpdates()
        }
    }

    public override func orderOut(_ sender: Any?) {
        if UserDefaults.standard.bool(forKey: "hideToolbarIfNotActive") == false && AppController.usetoolbarpanel() == true {
            NSDisableScreenUpdates()

            let v = ViewerController.frontMostDisplayed2DViewer(for: self.screen)

            if v?.toolbarPanel?.window !== self {
                if !(self.toolbar?.customizationPaletteIsRunning ?? false) {
                    super.orderOut(sender)
                }
            }

            if let v = v {
                if !(v.toolbarPanel?.window?.toolbar?.customizationPaletteIsRunning ?? false) {
                    v.toolbarPanel?.window?.orderBack(self)
                }
            }
            NSEnableScreenUpdates()
        } else {
            super.orderOut(sender)
        }
    }

    public override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        return 0
    }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect // not movable, and OsiriX knows where to place toolbars ;)
    }
}
