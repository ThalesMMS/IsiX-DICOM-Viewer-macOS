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

// The SUV (standardized uptake value) of the PET series of the 2D viewer: the
// selectors of the former Objective-C methods (-displaySUV:,
// -updateSUVValues:, -endDisplaySUV:, -editSUVinjectionTime: with -ok: and
// -cancel:, -convertPETtoSUV, -factorPET2SUV, -recomputePixMinMax), which the
// nibs, the loading of the series and the former plugins send. The work is
// the viewer's ViewerWindowLevel, over IsiXImaging's PETSUVConversion and
// SUVWindowScaling.

public extension ViewerController {

    /// Ends the injection time sheet without a date.
    @objc(cancel:)
    @IBAction func cancel(_ sender: Any!) {
        sessionGraph.windowLevel.cancelInjectionTime()
    }

    /// Ends the injection time sheet with its date.
    @objc(ok:)
    @IBAction func ok(_ sender: Any!) {
        sessionGraph.windowLevel.acceptInjectionTime()
    }

    /// Edits the injection (tag 0) or acquisition (tag 1) time of every slice.
    @objc(editSUVinjectionTime:)
    @IBAction func editSUVinjectionTime(_ sender: Any!) {
        sessionGraph.windowLevel.editInjectionTime(sender)
    }

    /// The factor of the last conversion to SUV.
    @objc(factorPET2SUV)
    func factorPET2SUV() -> Float {
        return horos_factorPET2SUV
    }

    /// Recomputes the minimum and maximum of every slice, and of the series.
    @objc(recomputePixMinMax)
    func recomputePixMinMax() {
        sessionGraph.windowLevel.recomputePixMinMax()
    }

    /// Converts the values of every slice not converted yet to SUV.
    @objc(convertPETtoSUV)
    func convertPETtoSUV() {
        sessionGraph.windowLevel.convertToSUV()
    }

    /// Puts back ConvertPETtoSUVautomatically, which -endDisplaySUV: turns
    /// off while a series is reverted.
    @objc(restoreConvertPETtoSUVautomaticallyValue:)
    func restoreConvertPETtoSUVautomaticallyValue(_ valueToRestore: NSNumber!) {
        sessionGraph.windowLevel.restoreAutomaticConversion(valueToRestore.boolValue)
    }

    /// Ends the SUV sheet.
    @objc(endDisplaySUV:)
    @IBAction func endDisplaySUV(_ sender: Any!) {
        sessionGraph.windowLevel.endSUVSheet(sender)
    }

    /// Applies the dose and the injection time of the SUV sheet to every slice.
    @objc(updateSUVValues:)
    @IBAction func updateSUVValues(_ sender: Any!) {
        sessionGraph.windowLevel.updateSUVValues()
    }

    /// Opens the SUV sheet with the values of the current slice.
    @objc(displaySUV:)
    func displaySUV(_ sender: Any!) {
        sessionGraph.windowLevel.openSUVSheet()
    }
}
