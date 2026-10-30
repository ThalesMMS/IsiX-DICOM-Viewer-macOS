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

private enum OSIWindowFlags {
    /// Whether viewer windows may leave the screen: printing and movie export
    /// resize them past it for a moment.
    // nonisolated(unsafe): a flag set on the main thread, as the Objective-C
    // class variable was, read by class methods any thread may call.
    nonisolated(unsafe) static var dontConstrainWindow = false
}

/// The window of the viewers (Viewer, MPR, CPR, PET-CT, VR and orthogonal MPR
/// nibs), which can be told not to constrain its frame to the screen.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIWindow.h> are those of the former class, the custom class of
/// those nibs' windows.
@objc(OSIWindow)
public final class OSIWindow: NSWindow {

    @objc(dontConstrainWindow)
    public nonisolated class func dontConstrainWindow() -> Bool {
        return OSIWindowFlags.dontConstrainWindow
    }

    @objc(setDontConstrainWindow:)
    public nonisolated class func setDontConstrain(_ v: Bool) {
        OSIWindowFlags.dontConstrainWindow = v
    }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if OSIWindowFlags.dontConstrainWindow {
            return frameRect
        }

        return super.constrainFrameRect(frameRect, to: screen)
    }

    deinit {
        NSLog("OSIWindow dealloc")

        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }
}
