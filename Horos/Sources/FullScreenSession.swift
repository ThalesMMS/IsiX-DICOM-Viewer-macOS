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

/// The full screen of a 2D viewer: its content moves into a borderless window
/// over the whole screen (above the menu bar and the toolbar panel, without
/// the slider strip) and back into its own window, keeping the image tiling,
/// the zoom fitted or not and the settings propagation (COPYSETTINGS, off
/// while a viewer without a fusion is full screen).
///
/// The propagation is off for this process, by a hold the viewer keeps from
/// entering to leaving (TemporaryPreferenceHolds): nothing is stored, so an
/// application that ends while a viewer is full screen leaves the person's
/// choice as it was, and a viewer that closes or goes while full screen gives
/// its hold back. What the person chooses meanwhile shows at once and stays.
///
/// Made for one call, holding the viewer strongly; what the full screen
/// keeps between entering and leaving is the viewer's window layout state.
@MainActor struct FullScreenSession {
    let viewer: ViewerController
    let preferences: any PreferenceStore

    /// Enters the full screen, or leaves it.
    func toggle() {
        viewer.setUpdateTilingViewsValue(true)
        viewer.selectFirstTilingView()

        if viewer.horos_FullScreenOn {
            leave()
        } else {
            enter()
        }

        viewer.setUpdateTilingViewsValue(false)

        if preferences[ViewerPreferences.alwaysScaleToFit] {
            viewer.horos_imageView?.scaleToFit()
        }

        viewer.horos_imageView?.display()
    }

    /// Whether the tiling of `columns` × `rows` views becomes one view in full
    /// screen.
    private func untilesImages(columns: Int32, rows: Int32) -> Bool {
        preferences[ViewerPreferences.noImageTilingInFullscreen] && (columns != 1 || rows != 1)
    }

    private func leave() {
        let startingWindow = viewer.horos_StartingWindow
        startingWindow?.contentView = viewer.horos_contentView

        viewer.horos_FullScreenWindow?.delegate = nil
        viewer.horos_FullScreenWindow?.close()
        viewer.horos_FullScreenWindow = nil

        viewer.horos_FullScreenOn = false

        _ = ToolbarPolicy.setStrip(aboveImage: viewer.horos_slider?.superview, collapsed: false, restoringHeight: viewer.horos_previousSliderStripHeight)
        startingWindow?.setFrame(viewer.horos_previousFrameRect, display: true)
        // The viewer the user left full screen is the one they work in. When
        // the fullscreen window closed, another viewer became the main one,
        // and restoring COPYSETTINGS below made that one copy its zoom over
        // the fit this viewer takes back: the zoom flickered twice.
        startingWindow?.makeKeyAndOrderFront(viewer)

        let columns = viewer.horos_previousFullscreenColumns, rows = viewer.horos_previousFullscreenRows
        if untilesImages(columns: columns, rows: rows) {
            viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: viewer.horos_previousFullscreenCurImage))
            viewer.setImageRows(rows, columns: columns, rescale: false)
            _ = viewer.window?.makeFirstResponder(viewer.horos_seriesView?.imageViews()?.object(at: Int(viewer.horos_previousFullscreenViewIndex)) as? NSResponder)
        }

        if viewer.horos_previousScaledFit != 0 {
            // Fitted now, and again once the layout has settled: the key that
            // ended full screen propagates the zoom as soon as this returns,
            // and it sent the other viewers the zoom scaled to the window
            // before the fit replaced it.
            startingWindow?.contentView?.layoutSubtreeIfNeeded()
            viewer.horos_imageView?.scaleToFit()
            viewer.horos_imageView?.perform(#selector(DCMView.scaleToFit as (DCMView) -> () -> Void), with: nil, afterDelay: 0.01)
        }

        TemporaryPreferenceHolds.standard.release(ViewerPreferences.copySettings, keptBy: viewer)

        viewer.horos_previewMatrix?.sizeToCells()

        viewer.redrawToolbar()
    }

    private func enter() {
        viewer.horos_previousPropagate = preferences[ViewerPreferences.copySettings] ? 1 : 0

        if viewer.horos_blending == nil {
            TemporaryPreferenceHolds.standard.hold(ViewerPreferences.copySettings, at: false, keptBy: viewer)
        }

        let imageView = viewer.horos_imageView
        viewer.horos_previousFullscreenColumns = Int32(truncatingIfNeeded: imageView?.columns ?? 0)
        viewer.horos_previousFullscreenRows = Int32(truncatingIfNeeded: imageView?.rows ?? 0)
        let selectedIndex = imageView?.curImage ?? 0
        viewer.horos_previousFullscreenViewIndex = Int32(truncatingIfNeeded: imageView.map { viewer.horos_seriesView?.imageViews()?.index(of: $0) ?? 0 } ?? NSNotFound)

        // The tiles become one view and back without rescaling: the view
        // already scales its image with its own size, and a second rescale by
        // the number of rows zoomed further at every entry and exit, until the
        // screen showed one flat region of the image.
        if untilesImages(columns: viewer.horos_previousFullscreenColumns, rows: viewer.horos_previousFullscreenRows) {
            viewer.setImageRows(1, columns: 1, rescale: false)
        }

        viewer.horos_previousFullscreenCurImage = Int32(viewer.horos_imageView?.curImage ?? 0)

        viewer.horos_imageView?.setIndex(selectedIndex)

        viewer.horos_assignStartingWindow(viewer.window)
        let startingWindow = viewer.horos_StartingWindow
        // The whole screen: no strip is left for the menu bar or the toolbar panel.
        let contentRect = ToolbarPolicy.fullscreenContentRect(on: viewer.window?.screen?.frame ?? .zero)

        viewer.horos_previousScaledFit = (viewer.horos_imageView?.isScaledFit() ?? false) ? 1 : 0
        viewer.horos_previousFrameRect = startingWindow?.frame ?? .zero
        startingWindow?.setFrame(contentRect, display: false)

        viewer.horos_FullScreenWindow = NSFullScreenWindow(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        if let fullScreenWindow = viewer.horos_FullScreenWindow {
            fullScreenWindow.title = "myWindow"
            fullScreenWindow.isReleasedWhenClosed = false
            fullScreenWindow.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            fullScreenWindow.backgroundColor = .black

            viewer.horos_assignContentView(viewer.window?.contentView)
            fullScreenWindow.contentView = viewer.horos_contentView

            fullScreenWindow.delegate = viewer
            fullScreenWindow.windowController = viewer

            fullScreenWindow.makeKeyAndOrderFront(viewer)
            _ = fullScreenWindow.makeFirstResponder(viewer.horos_imageView)
            fullScreenWindow.acceptsMouseMovedEvents = true

            if viewer.horos_previousScaledFit != 0 {
                viewer.horos_imageView?.scaleToFit()
            }

            viewer.horos_FullScreenOn = true
            // The detached toolbar is put away while the image has the screen;
            // -redrawToolbar brings it back when fullscreen ends.
            if AppController.usetoolbarpanel() {
                viewer.horos_toolbarPanel?.window?.orderOut(viewer)
            }
            // So is the strip of the image slider: the wheel and the keys still browse.
            viewer.horos_previousSliderStripHeight = ToolbarPolicy.setStrip(aboveImage: viewer.horos_slider?.superview, collapsed: true,
                                                                            restoringHeight: viewer.horos_previousSliderStripHeight)
        }

        viewer.horos_previewMatrix?.sizeToCells()
    }
}
