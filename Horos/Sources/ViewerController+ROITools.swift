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

// The ROI tools of the 2D viewer are implemented in Swift: a Swift extension
// of ViewerController, which stays Objective-C, with the same selectors (the
// brush palette, the calcium scoring window, the calibration warning, the
// ROI lock). -newROI: stays in ViewerController.m, delegating to
// -horosMakeROI: here: Swift would return the result of a new-family method
// retained, the Objective-C returns it autoreleased.

/// Whether a window of the nib `nibName` is open: not one whose controller
/// is closing (horosWindowControllerIsClosing).
@MainActor
fileprivate func toolWindowIsOpen(nibName: String) -> Bool {
    var found = false
    for window in NSApp.windows {
        if let controller = window.windowController, controller.windowNibName == nibName, !horosWindowControllerIsClosing(controller) {
            found = true
        }
    }
    return found
}

public extension ViewerController {

    /// A ROI of the type `type` for the current image, with its pixel
    /// spacing and origin, set in the image view (autoreleased).
    @objc(horosMakeROI:)
    func horosMakeROI(_ type: ToolMode) -> ROI! {
        let curPix = horos_imageView?.curDCM
        let theNewROI = ROI(type: type, Float(curPix?.pixelSpacingX ?? 0), Float(curPix?.pixelSpacingY ?? 0),
                            DCMPix.originCorrected(accordingToOrientation: curPix))
        horos_imageView?.roiSet(theNewROI)
        return theNewROI
    }

    /// Opens the brush palette, unless it is open.
    @objc(brushTool:)
    func brushTool(_ sender: Any!) {
        if !toolWindowIsOpen(nibName: "PaletteBrush") {
            // The palette releases itself when its window closes.
            _ = Unmanaged.passRetained(PaletteController(viewer: self))
        }
    }

    /// The lock of the ROIs of the viewer, which threads that read them take.
    @objc(roiLock)
    nonisolated func roiLock() -> NSRecursiveLock! {
        return horos_roiLock
    }

    /// Opens the calcium scoring window, unless it is open.
    @objc(calciumScoring:)
    @IBAction func calciumScoring(_ sender: Any!) {
        if !toolWindowIsOpen(nibName: "CalciumScoring") {
            // The window controller releases itself when its window closes.
            let calciumScoringWindowController = CalciumScoringWindowController(viewer: self)
            calciumScoringWindowController.showWindow(self)
            _ = Unmanaged.passRetained(calciumScoringWindowController)
        }
    }

    /// Warns that a change of the pixel spacing, the slice interval and the
    /// orientation changes measurements and 3D, then opens their sheet.
    @objc(calibrate:)
    @IBAction func calibrate(_ sender: Any!) {
        let result = HorosAlertPanel.runCritical(title: NSLocalizedString("Warning !", comment: ""),
                                                 message: NSLocalizedString("Modifying these parameters will:\r\r- Change the measurements results (length, surface, volume, ...)\r-Change the orientation of the slices and of the 3D objects (Left, Right, ...)\r-Change the aspect of the 3D images. It can introduce distortions.\r\rONLY change these parameters if you know WHAT and WHY you are doing it.", comment: ""),
                                                 defaultButton: NSLocalizedString("I agree", comment: ""),
                                                 alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

        if result == HorosAlertDefaultResponse {
            computeInterval()
            setThicknessInterval(sender)
        }
    }
}
