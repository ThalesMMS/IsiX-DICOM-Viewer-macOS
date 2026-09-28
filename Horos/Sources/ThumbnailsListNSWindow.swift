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

/// The window of the floating series list.
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/ThumbnailsListNSWindow.h> are those of the former class, and
/// ThumbnailsList.xib uses the name as the window class. The ordering and the
/// owner fallback of -orderOut: are unchanged.
@objc(ThumbnailsListNSWindow)
public final class ThumbnailsListNSWindow: NSPanel {

    public override var canBecomeMain: Bool {
        return false
    }

    public override var canBecomeKey: Bool {
        return false
    }

    // Detach/mode changes must not trigger orderOut's normal owner fallback.
    @objc public func hideForReconfiguration() {
        super.orderOut(self)
    }

    public override func orderOut(_ sender: Any?) {
        // The spare controller has no display of its own. Its nib window can still
        // sit on a real screen: that must not let it borrow the same list as the
        // registered panel, or reveal itself while handling focus notifications.
        if AppController.thumbnailsListPanel(for: self.screen)?.window !== self {
            super.orderOut(sender)
            return
        }

        if UserDefaults.standard.bool(forKey: "SeriesListVisible") == false {
            super.orderOut(sender)
            return
        }

        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
            NSDisableScreenUpdates()

            if let v = ViewerController.frontMostDisplayed2DViewer(for: self.screen) {
                (self.windowController as? ThumbnailsListPanel)?.setThumbnailsView(v.previewMatrixScrollView(), viewer: v)

                if (v.window?.windowNumber ?? 0) > 0 {
                    self.order(.below, relativeTo: v.window?.windowNumber ?? 0)
                }
            } else {
                super.orderOut(sender)
                (self.windowController as? ThumbnailsListPanel)?.setThumbnailsView(nil, viewer: nil)
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
