/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

// The database window's toolbar and the images with ROIs and the key images
// of its selection, as AppKit, the nib, the menus and the former plugins reach
// them: the toolbar is BrowserToolbar's, which is its delegate and validates
// its items, and the images are SelectionMarkedImages'. The items' target is
// still the browser, and these selectors hand their work over.

public extension BrowserController {

    // MARK: - The window

    @objc(windowDidResignKey:)
    func windowDidResignKey(_ notification: Notification!) {
        self.horos_DatabaseIsEdited = false
    }

    @objc(windowDidBecomeKey:)
    func windowDidBecomeKey(_ notification: Notification!) {
        self.flagsChanged(with: NSApp.currentEvent)

        HorosObjCException.synchronized(self.horos_albumNoOfStudiesCache) {
            if (self.horos_albumNoOfStudiesCache?.count ?? 0) == 0 {
                self.refreshAlbums()
            }
        }
    }

    // [NSApp currentEvent], which -windowDidBecomeKey: sends, can be nil: the
    // parameter stays optional, and nil has no modifier flags.
    override func flagsChanged(with event: NSEvent?) {
        browserToolbar.modifierFlagsChanged(event)
    }

    // MARK: - The toolbar

    @objc(setupToolbar)
    func setupToolbar() {
        browserToolbar.install()
    }

    @objc(validateToolbarItem:)
    func validate(_ toolbarItem: NSToolbarItem!) -> Bool {
        browserToolbar.validate(toolbarItem)
    }

    @objc(openHorosMigrationAssistant:)
    func openHorosMigrationAssistant(_ sender: Any!) {
        browserToolbar.openMigrationAssistant()
    }

    @objc(restoreWindowState:)
    func restoreWindowState(_ sender: Any!) {
        browserToolbar.restoreViews()
    }

    @objc(tileWindows:)
    func tileWindows(_ sender: Any!) {
        AppController.shared()?.windowArranger.tileNow()
    }

    // MARK: - The images with ROIs and the key images of the selection

    @objc(ROIsAndKeyImages:)
    func roisAndKeyImages(_ sender: Any!) -> [Any]! {
        markedImages.roisAndKeyImages(sender).images
    }

    @objc(ROIImages:)
    func roiImages(_ sender: Any!) -> [Any]! {
        markedImages.roiImages(sender).images
    }

    @objc(KeyImages:)
    func keyImages(_ sender: Any!) -> [Any]! {
        markedImages.keyImages(sender)
    }

    @objc(viewerKeyImagesAndROIsImages:)
    func viewerKeyImagesAndROIsImages(_ sender: Any!) {
        markedImages.openInViewer(sender)
    }
}
