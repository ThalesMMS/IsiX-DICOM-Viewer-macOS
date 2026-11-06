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

// The gantry tilt correction of the 2D viewer's series is implemented in
// Swift: a Swift extension of ViewerController, which stays Objective-C, with
// the same selector (+correctGangtryTilt:). GantryTiltSlices reorients each
// slice onto the plane of the series' middle slice with ITKTransform, by the
// parameters GantryTiltCorrection of the IsiXImaging module computes, and
// moves it onto that plane.

/// The slices of a tilted series, brought onto the plane of their middle one,
/// on the main actor, where ITKTransform reorients them.
@MainActor struct GantryTiltSlices {

    let slices: [DCMPix]

    /// Reorients every slice but the middle one onto its plane, calling
    /// `progress` after each slice, then clears their intervals; false, with
    /// nothing changed, when they do not all have the middle slice's
    /// orientation. A slice that cannot be reoriented stops the correction.
    func correct(progress: () -> Void) -> Bool {
        guard !slices.isEmpty else { return false }
        let model = slices[slices.count / 2]
        var orientation = [Double](repeating: 0, count: 9)
        model.orientationDouble(&orientation)
        let origin = [model.originX, model.originY, model.originZ]

        for p in slices {
            var o = [Double](repeating: 0, count: 9)
            p.orientationDouble(&o)
            if !GantryTiltCorrection.hasModelOrientation(o, model: orientation) {
                HorosAlertPanel.runInformational(title: NSLocalizedString("Error!", comment: ""),
                                                 message: NSLocalizedString("These slices have not the same orientation. Gantry Tilt Correction cannot be applied to this dataset.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return false
            }
        }

        for p in slices {
            if p !== model {
                var vectorSensor = [Double](repeating: 0, count: 9), vectorModel = [Double](repeating: 0, count: 9)
                p.orientationDouble(&vectorSensor)
                model.orientationDouble(&vectorModel)
                let offset = [p.originX - origin[0], p.originY - origin[1], p.originZ - origin[2]]

                var matrix = GantryTiltCorrection.parameters(sensor: vectorSensor, model: vectorModel, offset: offset)
                var size = 0
                guard let resultBuff = ITKTransform.reorient2Dimage(&matrix, firstObject: model, firstObjectOriginal: p, length: &size) else {
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Error!", comment: ""), message: NSLocalizedString("Not Enough Memory", comment: ""),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    break
                }
                memcpy(p.fImage, resultBuff, size)
                free(resultBuff)

                // Project the 3D point on the plane : dot product of normal plane vector (vectorModel) and distance between point and plane origin
                var outputOrigin = GantryTiltCorrection.projectedOrigin(modelOrigin: origin, model: vectorModel, offset: offset)
                p.setOriginDouble(&outputOrigin)
            }

            progress()
        }

        for p in slices {
            p.sliceInterval = 0
        }
        return true
    }
}

public extension ViewerController {

    /// Brings every slice of the viewer's series onto the plane of its middle
    /// slice, when they all have its orientation, and records the degrees the
    /// series was corrected by.
    @objc(correctGangtryTilt:)
    class func correctGangtryTilt(_ viewerController: ViewerController!) {
        let slices = GantryTiltSlices(slices: viewerController.pixList() as? [DCMPix] ?? [])

        let w = viewerController.startWaitProgressWindow(NSLocalizedString("Gantry Tilt Correction", comment: ""), slices.slices.count)

        let exception = HorosObjCException.caught {
            // The 3D views opened from this viewer say so.
            if slices.correct(progress: { viewerController.waitIncrement(by: w, 1) }) {
                GantryTiltPolicy.setCorrected(degrees: viewerController.horos_titledGantryDegrees, for: viewerController)
            }
        }
        if let exception {
            _N2LogExceptionImpl(exception, false, "+[ViewerController correctGangtryTilt:]")
        }

        viewerController.endWaitWindow(w)

        // We modified the view: OsiriX please update the display!
        viewerController.needsDisplayUpdate()
    }
}
