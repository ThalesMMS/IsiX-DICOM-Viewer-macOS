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

// The full screen of a 2D viewer: its content moves into a borderless
// window over the whole screen (above the menu bar and the toolbar panel,
// without the slider strip) and back into its own window, keeping the image
// tiling, the zoom fitted or not and the settings propagation. It ends when
// the application is left. The selectors are those of the former Objective-C
// methods.

public extension ViewerController {

    @objc(applicationDidResignActive:)
    func applicationDidResignActive(_ notification: Notification!) {
        ViewerController.clearFrontMost2DViewerCache()

        if horos_FullScreenOn { fullScreenMenu(self) }
    }

    /// Enters or leaves the full screen.
    @objc(fullScreenMenu:)
    func fullScreenMenu(_ sender: Any!) {
        let defaults = UserDefaults.standard

        setUpdateTilingViewsValue(true)
        selectFirstTilingView()

        if horos_FullScreenOn { // we need to go back to non-full screen
            let startingWindow = horos_StartingWindow
            startingWindow?.contentView = horos_contentView

            horos_FullScreenWindow?.delegate = nil
            horos_FullScreenWindow?.close()
            horos_FullScreenWindow = nil

            horos_FullScreenOn = false

            _ = ToolbarPolicy.setStrip(aboveImage: horos_slider?.superview, collapsed: false, restoringHeight: horos_previousSliderStripHeight)
            startingWindow?.setFrame(horos_previousFrameRect, display: true)
            // The viewer the user left full screen is the one they work in. When
            // the fullscreen window closed, another viewer became the main one,
            // and restoring COPYSETTINGS below made that one copy its zoom over
            // the fit this viewer takes back: the zoom flickered twice.
            startingWindow?.makeKeyAndOrderFront(self)

            if defaults.bool(forKey: "NoImageTilingInFullscreen") && (horos_previousFullscreenColumns != 1 || horos_previousFullscreenRows != 1) {
                horos_imageView?.setIndex(Int(truncatingIfNeeded: horos_previousFullscreenCurImage))
                setImageRows(horos_previousFullscreenRows, columns: horos_previousFullscreenColumns, rescale: false)
                _ = window?.makeFirstResponder((horos_seriesView?.imageViews() as NSArray?)?.object(at: Int(horos_previousFullscreenViewIndex)) as? NSResponder)
            }

            if horos_previousScaledFit != 0 {
                // Fitted now, and again once the layout has settled: the key that
                // ended full screen propagates the zoom as soon as this returns,
                // and it sent the other viewers the zoom scaled to the window
                // before the fit replaced it.
                startingWindow?.contentView?.layoutSubtreeIfNeeded()
                horos_imageView?.scaleToFit()
                horos_imageView?.perform(#selector(DCMView.scaleToFit as (DCMView) -> () -> Void), with: nil, afterDelay: 0.01)
            }

            defaults.set(horos_previousPropagate != 0, forKey: "COPYSETTINGS")

            horos_previewMatrix?.sizeToCells()

            redrawToolbar()
        } else {
            horos_previousPropagate = defaults.bool(forKey: "COPYSETTINGS") ? 1 : 0

            if horos_blending == nil {
                defaults.set(false, forKey: "COPYSETTINGS")
            }

            horos_previousFullscreenColumns = Int32(truncatingIfNeeded: horos_imageView?.columns ?? 0)
            horos_previousFullscreenRows = Int32(truncatingIfNeeded: horos_imageView?.rows ?? 0)
            let selectedIndex = horos_imageView?.curImage ?? 0
            horos_previousFullscreenViewIndex = Int32(truncatingIfNeeded: horos_imageView.map { (horos_seriesView?.imageViews() as NSArray?)?.index(of: $0) ?? 0 } ?? NSNotFound)

            // The tiles become one view and back without rescaling: the view
            // already scales its image with its own size, and a second rescale by
            // the number of rows zoomed further at every entry and exit, until the
            // screen showed one flat region of the image.
            if defaults.bool(forKey: "NoImageTilingInFullscreen") && (horos_previousFullscreenColumns != 1 || horos_previousFullscreenRows != 1) {
                setImageRows(1, columns: 1, rescale: false)
            }

            horos_previousFullscreenCurImage = Int32(horos_imageView?.curImage ?? 0)

            horos_imageView?.setIndex(selectedIndex)

            horos_assignStartingWindow(window)
            let startingWindow = horos_StartingWindow
            // The whole screen: no strip is left for the menu bar or the toolbar panel.
            let contentRect = ToolbarPolicy.fullscreenContentRect(on: window?.screen?.frame ?? .zero)

            horos_previousScaledFit = (horos_imageView?.isScaledFit() ?? false) ? 1 : 0
            horos_previousFrameRect = startingWindow?.frame ?? .zero
            startingWindow?.setFrame(contentRect, display: false)

            horos_FullScreenWindow = NSFullScreenWindow(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
            if let fullScreenWindow = horos_FullScreenWindow {
                fullScreenWindow.title = "myWindow"
                fullScreenWindow.isReleasedWhenClosed = false
                fullScreenWindow.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
                fullScreenWindow.backgroundColor = .black

                horos_assignContentView(window?.contentView)
                fullScreenWindow.contentView = horos_contentView

                fullScreenWindow.delegate = self
                fullScreenWindow.windowController = self

                fullScreenWindow.makeKeyAndOrderFront(self)
                _ = fullScreenWindow.makeFirstResponder(horos_imageView)
                fullScreenWindow.acceptsMouseMovedEvents = true

                if horos_previousScaledFit != 0 {
                    horos_imageView?.scaleToFit()
                }

                horos_FullScreenOn = true
                // The detached toolbar is put away while the image has the screen;
                // -redrawToolbar brings it back when fullscreen ends.
                if AppController.usetoolbarpanel() {
                    horos_toolbarPanel?.window?.orderOut(self)
                }
                // So is the strip of the image slider: the wheel and the keys still browse.
                horos_previousSliderStripHeight = ToolbarPolicy.setStrip(aboveImage: horos_slider?.superview, collapsed: true, restoringHeight: horos_previousSliderStripHeight)
            }

            horos_previewMatrix?.sizeToCells()
        }

        setUpdateTilingViewsValue(false)

        if defaults.bool(forKey: "AlwaysScaleToFit") {
            horos_imageView?.scaleToFit()
        }

        horos_imageView?.display()
    }

    @objc(FullScreenON)
    func fullScreenON() -> Bool {
        return horos_FullScreenOn
    }

    @objc(offFullScreen)
    func offFullScreen() {
        if horos_FullScreenOn { fullScreenMenu(self) }
    }
}
