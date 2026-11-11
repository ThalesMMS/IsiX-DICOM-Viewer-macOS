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
import IsiXPreferences

/// Window with only a toolbar
///
/// Implemented in Swift: the Objective-C name and
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

    /// Draws the toolbar again with the appearance the viewer's key status
    /// gives it. AppKit tells a window's views that its key status changed
    /// only when that window's own status does; this panel borrows the
    /// viewer's, so a viewer that takes or loses the keyboard without the
    /// panel being touched (a click in its image, another viewer clicked)
    /// left the toolbar drawn as it was before.
    @objc(refreshActiveAppearance)
    func refreshActiveAppearance() {
        guard let frame = contentView?.superview else { return }
        // What AppKit sends a window's views when its key status changes: the
        // toolbar's controls take their active or inactive state from it, and
        // only part of them from being drawn again.
        let keyStatusChanged = NSSelectorFromString("_windowChangedKeyState")
        if frame.responds(to: keyStatusChanged) {
            _ = frame.perform(keyStatusChanged)
        }
        var pending: [NSView] = [frame]
        while let view = pending.popLast() {
            view.needsDisplay = true
            pending.append(contentsOf: view.subviews)
        }
    }

    public override func orderBack(_ sender: Any?) {
        let v = self.toolbar?.delegate as? ViewerController

        if v?.window?.isVisible == true {
            super.orderBack(self)
            v?.toolbarPanel?.applicationDidChangeScreenParameters(nil)
            self.order(.above, relativeTo: v?.window?.windowNumber ?? 0)
            hideOtherToolbarsOfScreen()
        }
    }

    /// Every viewer of a screen has its toolbar in the same place, and only
    /// the front viewer's is shown. A panel that was clicked stayed on
    /// screen when another viewer came to the front some other way (the
    /// Window menu, a click in its image): that viewer's toolbar was ordered
    /// in under it, and the one on top was drawn inactive, being another
    /// viewer's. The panel ordered in for the front viewer takes the others out.
    private func hideOtherToolbarsOfScreen() {
        for case let other as ToolBarNSWindow in NSApp.windows
        where other !== self && other.isVisible && other.screen == self.screen && !(other.toolbar?.customizationPaletteIsRunning ?? false) {
            other.orderOutLeavingFrontViewer()
        }
    }

    /// Out of the screen, without the hand-over to the front viewer's panel
    /// that -orderOut: does.
    private func orderOutLeavingFrontViewer() {
        super.orderOut(nil)
    }

    public override func orderOut(_ sender: Any?) {
        if PreferencesSource.process.preferences[ApplicationPreferences.hidesToolbarIfNotActive] == false && AppController.usetoolbarpanel() == true {

            let v = ViewerController.frontMostDisplayed2DViewer(for: self.screen)
            // The front viewer keeps its panel, except in full screen, where
            // the image has the whole screen.
            let frontViewerKeepsPanel = ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: v?.fullScreenON() ?? false)

            if v?.toolbarPanel?.window !== self || !frontViewerKeepsPanel {
                if !(self.toolbar?.customizationPaletteIsRunning ?? false) {
                    super.orderOut(sender)
                }
            }

            if let v = v, frontViewerKeepsPanel {
                if !(v.toolbarPanel?.window?.toolbar?.customizationPaletteIsRunning ?? false) {
                    v.toolbarPanel?.window?.orderBack(self)
                }
            }
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
