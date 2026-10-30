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

// The full screen every 3D viewer has of its own: the window's content view
// moves into a borderless window that covers the main screen, above the other
// windows, and back. It is not the native full-screen Space, which these
// windows decline (Window3DController.swift).
@objc(FullScreen) @implementation extension Window3DController {

    func offFullScreen() {
        if fullScreenOn {
            fullScreenMenu(self)
        }
    }

    @objc(fullScreenMenu:)
    func fullScreenMenu(_ sender: Any!) {
        if fullScreenOn {
            // Back to the window.
            startingWindow?.contentView = savedContentView

            fullScreenWindow?.delegate = nil
            fullScreenWindow?.close()
            fullScreenWindow = nil

            startingWindow?.makeKeyAndOrderFront(self)
            fullScreenOn = false
        } else {
            startingWindow = window
            let contentRect = NSScreen.main?.frame ?? .zero
            let fullScreen = NSFullScreenWindow(contentRect: contentRect, styleMask: .borderless,
                                                backing: .buffered, defer: false)
            fullScreenWindow = fullScreen

            NSLog("Window was created")
            fullScreen.title = "myWindow"
            fullScreen.isReleasedWhenClosed = false
            fullScreen.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            fullScreen.backgroundColor = .black

            savedContentView = window?.contentView
            fullScreen.contentView = savedContentView

            fullScreen.makeKeyAndOrderFront(self)
            fullScreen.makeFirstResponder(view() as? NSResponder)

            fullScreen.delegate = self
            fullScreen.windowController = self

            fullScreenOn = true
        }
    }
}
