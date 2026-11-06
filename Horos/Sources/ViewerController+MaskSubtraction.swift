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
import IsiXImaging

// The "Mask Subtraction" block of ViewerController's DICOM pipeline
// (4.1.1.2): the actions of the XA subtraction tool and of its menu items,
// whose selectors are those of the former Objective-C methods and which
// Viewer.xib and MainMenu.xib send. Each hands its sender to a
// MaskSubtractionSession, which applies the subtraction.

public extension ViewerController {

    /// The subtraction of this viewer, with the preferences of its graph.
    private var maskSubtraction: MaskSubtractionSession {
        MaskSubtractionSession(viewer: self, preferences: sessionGraph.preferences)
    }

    @objc(subCtrlOnOff:)
    func subCtrlOnOff(_ sender: Any!) {
        maskSubtraction.switchOnOff(sender)
    }

    @objc(subCtrlNewMask:)
    func subCtrlNewMask(_ sender: Any!) {
        maskSubtraction.takeMaskOnScreen()
    }

    @objc(subCtrlOffset:)
    func subCtrlOffset(_ sender: Any!) {
        maskSubtraction.shiftMask(sender)
    }

    @objc(threeTestsFivePosibilities:)
    func threeTestsFivePosibilities(_ f: Int32) -> Int32 {
        return Int32(MaskSubtraction.indicatorIndex(Int(f)))
    }

    @objc(offsetMatrixSetting:)
    func offsetMatrixSetting(_ twentyFiveCodes: Int32) {
        maskSubtraction.lightIndicator(code: Int(twentyFiveCodes))
    }

    @objc(subCtrlSliders:)
    func subCtrlSliders(_ sender: Any!) {
        maskSubtraction.stepSliders(sender)
    }

    @objc(subSumSlider:)
    func subSumSlider(_ sender: Any!) {
        maskSubtraction.sumSlices(sender)
    }

    @objc(subSharpen:)
    func subSharpen(_ sender: Any!) {
        maskSubtraction.sharpen(sender)
    }
}
