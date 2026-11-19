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

/// The implementation of N2OpenGLViewWithSplitsWindow, declared in
/// N2OpenGLViewWithSplitsWindow.h: the superclass the plugin SDK of Horos and
/// OsiriX gave the viewers' window.
///
/// The class disabled the screen updates (NSDisableScreenUpdates) until the
/// window's next -flushWindow, so that the OpenGL views of a split view were
/// not seen half resized. Neither exists for the Metal views, and the system
/// no longer lets a process hold the screen: the flag is kept for who reads
/// it, and nothing of NSWindow is overridden, -flushWindow included.
@objc @implementation extension N2OpenGLViewWithSplitsWindow {
    /// The flag: the property of the SDK and, under the same name, its
    /// instance variable, which a plugin built for the SDK binds when it
    /// loads. A plugin reads and writes it from the thread it is on, through
    /// the property or directly, as it did in the SDK, where the atomic
    /// property of a BOOL was a plain load and store.
    ///
    /// `nonisolated(unsafe)`: one byte that nothing in the application reads.
    nonisolated(unsafe) var needsEnableUpdate: Bool = false

    nonisolated func disableUpdatesUntilFlush() {
        FormerSDKFacade.inert("N2OpenGLViewWithSplitsWindow", "-disableUpdatesUntilFlush",
                              because: "the views draw with Metal, and the screen updates are not held back for them")
    }
}
