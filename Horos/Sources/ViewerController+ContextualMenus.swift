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

// The contextual menus of the 2D viewer's image and of its ROIs, their
// actions and the comments menu. The selectors are those of the former
// Objective-C methods, which the image view, the menus and the former plugins
// send; the menus are the viewer's ViewerContextualMenuBuilder.

public extension ViewerController {

    /// The contextual menus of this viewer.
    internal var contextualMenus: ViewerContextualMenuBuilder { ViewerContextualMenuBuilder(sessionGraph) }

    /// Drops the shared contextual menu: the next one is built anew, with the
    /// presets menus as they are then.
    internal func dropViewerContextualMenu() {
        ViewerContextualMenuBuilder.dropSharedMenu()
    }

    @available(*, deprecated)
    @objc(contextualDictionaryPath:)
    func contextualDictionaryPath(_ newContextualDictionaryPath: String!) {
    }

    @available(*, deprecated)
    @objc(contextualDictionaryPath)
    func contextualDictionaryPath() -> String! {
        return "default"
    }

    /// Gives the image view the contextual menu of a click on the image,
    /// after plugins have added to it, without the commands that do not apply.
    @objc(computeContextualMenu)
    func computeContextualMenu() {
        contextualMenus.computeContextualMenu(in: self)
    }

    /// Gives the image view the contextual menu of a click on `roi`.
    @objc(computeContextualMenuForROI:)
    func computeContextualMenu(for roi: ROI!) {
        contextualMenus.computeContextualMenu(for: roi, in: self)
    }

    /// The menu of a click on `roi`.
    @objc(contextualMenuForROI:)
    func contextualMenu(for roi: ROI!) -> NSMenu! {
        contextualMenus.contextualMenu(for: roi, in: self)
    }

    /// Remove, in the menu of a ROI: takes the ROI off its image.
    @objc(roiContextualMenuActionRemove:)
    func roiContextualMenuActionRemove(_ source: NSMenuItem!) {
        contextualMenus.removeROI(of: source)
    }

    /// A hanging protocol of the contextual menu.
    @objc(applyWindowProtocol:)
    func applyWindowProtocol(_ sender: Any!) {
        contextualMenus.applyWindowProtocol(sender, in: self)
    }

    /// The contextual menu of a click on the image, built anew.
    @objc(contextualMenu)
    func contextualMenu() -> NSMenu! {
        contextualMenus.contextualMenu(in: self)
    }

    /// An item of the comments menu.
    @objc(contextualMenuEvent:)
    func contextualMenuEvent(_ sender: Any!) {
        contextualMenus.contextualMenuEvent(sender, in: self)
    }
}
