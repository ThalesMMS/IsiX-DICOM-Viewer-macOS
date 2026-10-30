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

// The navigator (the thumbnails of every slice and frame of a 4D series) and
// the 3D position panel of the 2D viewer. The selectors are those of the
// former Objective-C methods.

public extension ViewerController {

    /// Opens the navigator for this viewer, or gives it this viewer. It needs
    /// a volume of identical matrices, not RGB.
    @objc(navigator:)
    func navigator(_ sender: Any!) {
        if horos_imageView?.curDCM?.isRGB ?? false {
            HorosAlertPanel.run(title: NSLocalizedString("Data Error", comment: ""),
                                message: NSLocalizedString("This tool currently does not work with RGB data series.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        if NavigatorWindowController.navigatorWindowController() == nil {
            if !isDataVolumicIn4D(true) {
                HorosAlertPanel.run(title: NSLocalizedString("Data Error", comment: ""),
                                    message: NSLocalizedString("This tool works only with 3D data series with identical matrix sizes.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                return
            }

            let navigatorWindowController = NavigatorWindowController(viewer: self)
            // It lives until its window closes, which releases it.
            _ = Unmanaged.passRetained(navigatorWindowController)
            navigatorWindowController.showWindow(self)
            AppController.shared()?.tileWindows(nil)
        } else {
            NavigatorWindowController.navigatorWindowController()?.setViewer(self)
        }
    }

    /// Opens the 3D position panel for this viewer, or gives it this viewer.
    /// It needs a volume of identical matrices.
    @objc(threeDPanel:)
    func threeDPanel(_ sender: Any!) {
        if ThreeDPositionController.threeDPositionController() == nil {
            if !isDataVolumicIn4D(true) {
                HorosAlertPanel.run(title: NSLocalizedString("Data Error", comment: ""),
                                    message: NSLocalizedString("This tool works only with 3D data series with identical matrix sizes.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                return
            }

            let threeDPositionController = ThreeDPositionController(viewer: self)
            // It lives until its window closes, which releases it.
            _ = Unmanaged.passRetained(threeDPositionController)
            threeDPositionController.showWindow(self)
        } else {
            ThreeDPositionController.threeDPositionController()?.setViewer(self)
        }
    }

    /// Gives the navigator and the 3D position panel this viewer, the
    /// navigator across the whole width of the viewer's screen.
    @objc(updateNavigator)
    func updateNavigator() {
        ThreeDPositionController.threeDPositionController()?.setViewer(self)

        NavigatorWindowController.navigatorWindowController()?.setViewer(self)

        let navigatorWindow = NavigatorWindowController.navigatorWindowController()?.window
        var navigatorFrame = navigatorWindow?.frame ?? .zero
        navigatorFrame.origin.x = window?.screen?.visibleFrame.origin.x ?? 0
        navigatorFrame.size.width = window?.screen?.visibleFrame.size.width ?? 0
        navigatorWindow?.setFrame(navigatorFrame, display: true)
    }
}
