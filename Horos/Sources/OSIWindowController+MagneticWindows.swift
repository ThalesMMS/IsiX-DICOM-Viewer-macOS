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

import Carbon
import Cocoa

/// How long the drop check waits between looks at the mouse buttons.
private let magneticDropCheckInterval: TimeInterval = 0.05

// Magnetic windows and tiling: the window delegate messages and the
// notifications OSIWindowController answers, private as they were to its .m.
// The snapping itself is MagneticWindowSnapping's.
//
// The magnets act once, when the user releases the window. While the button is
// down the window follows the mouse: snapping it on every move would pull it away
// from the cursor, and a window could never be dragged onto a neighbour to swap
// places with it. windowDidMove: only records that a user move is in progress; a
// drop check, re-armed while a mouse button is pressed, then snaps the window
// (and swaps it with the window it was dropped on) after the release.
extension OSIWindowController {

    /// The frames of the other visible magnetic viewers on `window`'s
    /// screen, then the usable area of this controller's screen.
    private func magnets(around window: NSWindow?) -> [NSRect] {
        var rects: [NSRect] = []

        // Add the viewers
        for other in NSApp.windows {
            if other != window && other.isVisible && other.windowController is OSIWindowController
                && (other.screen?.isEqual(window?.screen) ?? false) {
                if (other.windowController as! OSIWindowController).magnetic() {
                    rects.append(other.frame)
                }
            }
        }

        // Add the current screen ONLY
        var frame = AppController.usefullRect(for: self.window?.screen)
        frame = NavigatorView.adjustIfScreenAreaIf4DNavigator(frame)
        rects.append(frame)

        return rects
    }

    @objc(windowDidResize:)
    private func windowDidResize(_ aNotification: Notification) {
        if OSIWindowControllerFlags.protectedReentryWindowDidResize { return }

        OSIWindowControllerFlags.protectedReentryWindowDidResize = true
        if magneticWindowActivated {
            if OSIWindowControllerFlags.dontEnterMagneticFunctions == false && GetCurrentButtonState() != 0 {
                if UserDefaults.standard.bool(forKey: "MagneticWindows") {
                    let theWindow = aNotification.object as? NSWindow
                    let myFrame = theWindow?.frame ?? .zero

                    if NSApp.currentEvent?.modifierFlags.contains(.option) ?? false {
                        OSIWindowControllerFlags.protectedReentryWindowDidResize = false
                        return
                    }

                    let dstFrame = MagneticWindowSnapping.resized(myFrame, magnets: magnets(around: theWindow))

                    OSIWindowControllerFlags.dontEnterMagneticFunctions = true
                    theWindow?.setFrame(dstFrame, display: true)
                    OSIWindowControllerFlags.dontEnterMagneticFunctions = false
                }

                if let viewer = self as? ViewerController {
                    if (aNotification.object as AnyObject?) === self.window {
                        viewer.showCurrentThumbnail(self)
                    }
                }

                if NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false {
                    // Apply the same size to all displayed windows
                    for case let loopItem as NSWindowController in ViewerController.getDisplayed2DViewers() ?? NSMutableArray() where loopItem !== self {
                        guard let theWindow = loopItem.window else { continue }

                        var dstFrame = theWindow.frame
                        dstFrame.size = self.window?.frame.size ?? .zero
                        dstFrame.origin.y -= dstFrame.size.height - theWindow.frame.size.height

                        OSIWindowControllerFlags.dontEnterMagneticFunctions = true
                        theWindow.setFrame(dstFrame, display: true)
                        OSIWindowControllerFlags.dontEnterMagneticFunctions = false
                    }
                }
            } else {
                var dstFrame = self.window?.frame ?? .zero
                let visibleRect = AppController.usefullRect(for: self.window?.screen)

                if dstFrame.size.height >= visibleRect.size.height {
                    dstFrame.size.height = visibleRect.size.height
                }

                if dstFrame.size.width >= visibleRect.size.width {
                    dstFrame.size.width = visibleRect.size.width
                }

                let contentMinSize = self.window?.contentMinSize ?? .zero
                if dstFrame.size.height < contentMinSize.height { dstFrame.size.height = contentMinSize.height }
                if dstFrame.size.width < contentMinSize.width { dstFrame.size.width = contentMinSize.width }

                dstFrame = NavigatorView.adjustIfScreenAreaIf4DNavigator(dstFrame)

                if NSEqualRects(dstFrame, self.window?.frame ?? .zero) == false {
                    self.window?.setFrame(dstFrame, display: true)
                }
            }

            if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") == false {
                (self as? ViewerController)?.showCurrentThumbnail(self)
            }
        }

        OSIWindowControllerFlags.protectedReentryWindowDidResize = false
    }

    // MARK: - The drop check

    @objc(scheduleMagneticDropCheck)
    private func scheduleMagneticDropCheck() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(magneticDropCheck), object: nil)
        perform(#selector(magneticDropCheck), with: nil, afterDelay: magneticDropCheckInterval, inModes: [.common])
    }

    @objc(cancelMagneticDropCheck)
    private func cancelMagneticDropCheck() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(magneticDropCheck), object: nil)
        windowIsMovedByTheUser = false
    }

    @objc(magneticDropCheck)
    private func magneticDropCheck() {
        if windowIsMovedByTheUser == false {
            return
        }

        // A closed or hidden window, or one that stopped being magnetic, ends the move without snapping.
        if magneticWindowActivated == false || (self.window?.isVisible ?? false) == false {
            windowIsMovedByTheUser = false
            return
        }

        if NSEvent.pressedMouseButtons != 0 {
            scheduleMagneticDropCheck()
            return
        }

        windowIsMovedByTheUser = false

        if OSIWindowControllerFlags.dontEnterMagneticFunctions == false {
            applyMagnetsAfterUserMove()
        }
    }

    @objc(windowWillMove:)
    private func windowWillMove(_ notification: Notification) {
        if magneticWindowActivated && OSIWindowControllerFlags.dontEnterMagneticFunctions == false {
            // A move that is still in progress keeps the frame it started from: a swap sends the other window there.
            if windowIsMovedByTheUser == false {
                savedWindowsFrame = self.window?.frame ?? .zero
            }

            if NSEvent.pressedMouseButtons != 0 {
                windowIsMovedByTheUser = true
                scheduleMagneticDropCheck()
            }
        }
    }

    @objc(windowDidMove:)
    private func windowDidMove(_ notification: Notification) {
        if magneticWindowActivated && windowIsMovedByTheUser && OSIWindowControllerFlags.dontEnterMagneticFunctions == false {
            scheduleMagneticDropCheck()
        }
    }

    @objc(applyMagnetsAfterUserMove)
    private func applyMagnetsAfterUserMove() {
        guard magneticWindowActivated && UserDefaults.standard.bool(forKey: "MagneticWindows") && NSIsEmptyRect(savedWindowsFrame) == false else {
            return
        }
        let theWindow = self.window
        var myFrame = theWindow?.frame ?? .zero

        // Option held when the button is released leaves the window where it was dropped.
        if NSEvent.modifierFlags.contains(.option) { return }

        myFrame = MagneticWindowSnapping.dropped(myFrame, magnets: magnets(around: theWindow))

        OSIWindowControllerFlags.dontEnterMagneticFunctions = true
        AppController.resizeWindow(withAnimation: theWindow, newSize: myFrame)
        OSIWindowControllerFlags.dontEnterMagneticFunctions = false

        (self as? ViewerController)?.updateNavigator()

        // Is the Origin identical? If yes, switch both windows
        for window in NSApp.windows {
            if window != theWindow && window.isVisible && window.windowController is OSIWindowController {
                if (window.windowController as! OSIWindowController).magnetic() {
                    let frame = window.frame

                    if MagneticWindowSnapping.swaps(frame, with: myFrame) {
                        OSIWindowControllerFlags.dontEnterMagneticFunctions = true

                        window.order(.below, relativeTo: theWindow?.windowNumber ?? 0)
                        AppController.resizeWindow(withAnimation: window, newSize: savedWindowsFrame)

                        savedWindowsFrame = frame

                        AppController.resizeWindow(withAnimation: theWindow, newSize: frame)

                        OSIWindowControllerFlags.dontEnterMagneticFunctions = false

                        if self is ViewerController, let theWindow {
                            (theWindow.windowController as? ViewerController)?.windowDidChangeScreen(
                                Notification(name: NSWindow.didChangeScreenNotification, object: theWindow))
                        }

                        return
                    }
                }
            }
        }
    }

    // MARK: - Closing

    /// A closing window ends its drop check, and has the other windows tiled
    /// again when it was magnetic and the windows tile themselves.
    @objc(windowWillCloseNotification:)
    private func windowWillCloseNotification(_ notification: Notification) {
        if (notification.object as AnyObject?) === self.window {
            cancelMagneticDropCheck()
        }

        if (notification.object as AnyObject?) === self.window && UserDefaults.standard.bool(forKey: "AUTOTILING") && magneticWindowActivated {
            if delayedTileWindows != 0, let app = AppController.shared() {
                NSObject.cancelPreviousPerformRequests(withTarget: app, selector: #selector(AppController.tileWindows(_:)), object: nil)
            }
            delayedTileWindows = 1
            AppController.shared()?.perform(#selector(AppController.tileWindows(_:)), with: nil, afterDelay: 0.3)
        }
    }
}
