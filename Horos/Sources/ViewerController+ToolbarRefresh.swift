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

// The state of the 2D viewer's toolbar and of what goes with it: the detached
// toolbar panel and the floating thumbnails lists shown for the front viewer,
// the browser following the image shown, the toolbar's customization palette,
// the Cobb angle preference and the 12-bit display item. The selectors are
// those of the former Objective-C methods. A message to nil answered nil, 0 or
// NO: the optional chains below answer the same.

/// MAXSCREENS of ViewerController.m: the thumbnails list panels, one per screen.
private let maxScreens = 10

/// Runs `body`, answering the Objective-C exception it raised, or nil.
private func horosCatchingObjC(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
        return nil
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
}

public extension ViewerController {

    /// Shows the detached toolbar panel for the front viewer and lends the
    /// floating thumbnails list of this viewer's screen.
    @objc(redrawToolbar)
    func redrawToolbar() {
        let defaults = UserDefaults.standard

        if AppController.usetoolbarpanel() {
            if ViewerController.isFrontMost2DViewer(window) && ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: horos_FullScreenOn) {
                if !(horos_toolbarPanel?.window?.toolbar?.customizationPaletteIsRunning ?? false) {
                    horos_toolbarPanel?.window?.orderBack(self)
                }
            } else {
                horos_toolbarPanel?.window?.orderOut(self)
            }
        }

        if defaults.bool(forKey: "UseFloatingThumbnailsList") {
            for i in 0..<min(maxScreens, NSScreen.screens.count) {
                if AppControllerCAPIThumbnailsListPanel(i)?.thumbnailsView === horos_previewMatrixScrollView && window?.screen !== NSScreen.screens[i] {
                    AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
                }
            }

            // Only the front viewer of a screen lends its list to that screen's panel.
            // Viewers also redraw in the background (the next series applied to every
            // viewer, a study opened into the viewers on screen): a list taken then
            // would load a clicked series into that viewer, not into the one in use.
            let front = ViewerController.frontMostDisplayed2DViewer(for: window?.screen)
            var found = false
            for i in 0..<min(maxScreens, NSScreen.screens.count) {
                if window?.screen === NSScreen.screens[i] {
                    if front == nil || front === self {
                        AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(horos_previewMatrixScrollView, viewer: self)
                    }
                    found = true
                }
                // Other screens own independent thumbnail panels. Do not hide them
                // when this viewer redraws or moves between displays.
            }
            if !found {
                N2LogStackTraceMessage("Toolbar NOT found")
            }
        }

        if !AppController.usetoolbarpanel() {
            horos_toolbarPanel?.window?.orderOut(self)
        }

        if !defaults.bool(forKey: "UseFloatingThumbnailsList") || !defaults.bool(forKey: "SeriesListVisible") {
            for i in 0..<min(maxScreens, NSScreen.screens.count) {
                AppControllerCAPIThumbnailsListPanel(i)?.window?.orderOut(self)
            }
        }
    }

    /// Redraws the toolbar, selects the image shown in the browser and updates
    /// the Sync button.
    @objc(refreshToolbar)
    func refreshToolbar() {
        autoHideMatrix()

        redrawToolbar()

        if window?.isVisible ?? false {
            if let e = horosCatchingObjC({
                let files = horos_fileList(at: Int(horos_curMovieIndex))
                if let files, !((((files.object(at: 0) as AnyObject).value(forKey: "completePath") as? NSString)?.lastPathComponent as NSString?)?.isEqual(to: "Empty.tif") ?? false) {
                    let image = Int(horos_imageView?.curImage ?? 0)
                    if image >= 0 {
                        _ = BrowserController.currentBrowser()?.findAndSelectFile(nil, image: files.object(at: image) as? DicomImage, shouldExpand: false)
                    }
                }
            }) {
                NSLog("***** exception in %@: %@", "-[ViewerController refreshToolbar]", e)
            }
        }

        setSyncButtonBehavior(self)
    }

    @objc(customizeViewerToolBar:)
    func customizeViewerToolBar(_ sender: Any!) {
        horos_toolbar?.runCustomizationPalette(sender)
    }

    /// Shows or hides the Cobb angle; showing it shows every ROI's information.
    @objc(switchCobbAngle:)
    func switchCobbAngle(_ sender: Any!) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "displayCobbAngle"), forKey: "displayCobbAngle")

        if defaults.bool(forKey: "ROITEXTIFSELECTED") && defaults.bool(forKey: "displayCobbAngle") {
            defaults.set(false, forKey: "ROITEXTIFSELECTED") // To display the Cobbs value -> show all ROIs information
        }
    }

    // MARK: - 12 bit

    /// The 12-bit toolbar item: its first cell turns the 12-bit LUT on.
    @objc(enable12Bit:)
    func enable12Bit(_ sender: Any!) {
        let t12Bit = ((sender as? NSControl)?.selectedCell()?.tag ?? 0) == 0
        horos_imageView?.setIsLUT12Bit(t12Bit)
        horos_imageView?.updateImage()
    }

    /// Shows in the 12-bit toolbar item whether the image view uses the 12-bit LUT.
    @objc(verify12Bit:)
    func verify12Bit(_ theTimer: Timer!) {
        let t12Bit = horos_imageView?.isLUT12Bit() ?? false
        if t12Bit {
            horos_display12bitToolbarItemMatrix?.selectCell(withTag: 0)
        } else {
            horos_display12bitToolbarItemMatrix?.selectCell(withTag: 1)
        }
    }
}
