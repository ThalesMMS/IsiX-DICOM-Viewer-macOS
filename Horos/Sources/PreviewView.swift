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

import Cocoa

/// The image view of the browser's preview. It tells its window delegate when
/// a person changes the window, so that the preview's window policy can tell a
/// manual adjustment from a default it put back; it is never a 2D viewer, and
/// draws its text in the system font.
///
/// A Swift class: Objective-C cannot subclass DCMView, a Swift class.
@objc(PreviewView)
public final class PreviewView: DCMView {

    /// Not retained: the browser owns this view.
    @objc public weak var windowDelegate: PreviewViewWindowDelegate?

    /// More than zero while the policy, not a person, sets the window.
    private var applyingPreviewWindow = 0

    public override dynamic func setWLWW(_ wl: Float, _ ww: Float) {
        super.setWLWW(wl, ww)

        // Everything that is not the policy putting a default back is a person
        // moving the window, and must survive the next scroll.
        if self.applyingPreviewWindow == 0 {
            self.windowDelegate?.previewView(self, didRequestWindowLevel: wl, width: ww)
        }
    }

    /// Applies a window the policy chose. Unlike -setWLWW:: this is not
    /// reported back as a manual adjustment.
    @objc(applyPreviewWindow:)
    public dynamic func apply(_ window: PreviewWindow?) {
        guard let window else { return }

        self.whileApplyingPreviewWindow {
            self.setWLWW(window.level, window.width)
        }
    }

    public override dynamic func updatePresentationState(fromSeriesOnlyImageLevel onlyImage: Bool, scale: Bool, offset: Bool) {
        // In the preview this restores the window the view already has, or the
        // one the file carries. Either way nobody moved it: recording that as a
        // manual adjustment made the first frame of every selection look like a
        // choice somebody had made, and pinned it for the rest of the series.
        self.whileApplyingPreviewWindow {
            super.updatePresentationState(fromSeriesOnlyImageLevel: onlyImage, scale: scale, offset: offset)
        }
    }

    public override dynamic func changeGLFontNotification(_ note: Notification!) {
        if (note?.object as AnyObject?) === self {
            self.horos_fontGL = NSFont.systemFont(ofSize: 12)

            self.horos_stringSize = self.convertToBacking(DCMView.size(ofString: "B", forFont: self.horos_fontGL))

            DCMView.purgeStringTextureCache()

            self.needsDisplay = true
        }
    }

    public override nonisolated dynamic func is2DViewer() -> Bool {
        return false
    }

    public override dynamic func actionForHotKey(_ hotKey: NSString!) -> Bool {
        NSLog("preview Hot Key")
        return super.actionForHotKey(hotKey)
    }

    /// Runs `body` with the window marked as the policy's, unmarked again even
    /// when an Objective-C exception leaves it, which then goes on.
    private func whileApplyingPreviewWindow(_ body: () -> Void) {
        self.applyingPreviewWindow += 1
        let exception = inputCatch(body)
        self.applyingPreviewWindow -= 1
        exception?.raise()
    }
}
