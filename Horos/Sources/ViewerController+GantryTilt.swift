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
// the same selector (+correctGangtryTilt:). Each slice is reoriented onto the
// plane of the series' middle slice by ITKTransform, with the parameters
// GantryTiltCorrection of the IsiXImaging module computes, and moved onto
// that plane.

public extension ViewerController {

    /// Brings every slice of the viewer's series onto the plane of its middle
    /// slice, when they all have its orientation, and records the degrees the
    /// series was corrected by.
    @objc(correctGangtryTilt:)
    class func correctGangtryTilt(_ viewerController: ViewerController!) {
        let pixList: NSArray = viewerController.pixList() ?? NSMutableArray()
        let curPix = pixList.object(at: pixList.count / 2) as! DCMPix

        let w = viewerController.startWaitProgressWindow(NSLocalizedString("Gantry Tilt Correction", comment: ""), pixList.count)

        let exception = viewerObjCTry {
            var ok = true
            var orientation = [Double](repeating: 0, count: 9)
            curPix.orientationDouble(&orientation)
            let origin = [curPix.originX, curPix.originY, curPix.originZ]

            for case let p as DCMPix in pixList {
                var o = [Double](repeating: 0, count: 9)
                p.orientationDouble(&o)
                if !GantryTiltCorrection.hasModelOrientation(o, model: orientation) {
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Error!", comment: ""),
                                                     message: NSLocalizedString("These slices have not the same orientation. Gantry Tilt Correction cannot be applied to this dataset.", comment: ""),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    ok = false
                    break
                }
            }
            guard ok else { return }

            for case let p as DCMPix in pixList {
                if p !== curPix {
                    var vectorSensor = [Double](repeating: 0, count: 9), vectorModel = [Double](repeating: 0, count: 9)
                    p.orientationDouble(&vectorSensor)
                    curPix.orientationDouble(&vectorModel)
                    let offset = [p.originX - origin[0], p.originY - origin[1], p.originZ - origin[2]]

                    var matrix = GantryTiltCorrection.parameters(sensor: vectorSensor, model: vectorModel, offset: offset)
                    var size = 0
                    guard let resultBuff = ITKTransform.reorient2Dimage(&matrix, firstObject: curPix, firstObjectOriginal: p, length: &size) else {
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

                viewerController.waitIncrement(by: w, 1)
            }

            for case let p as DCMPix in pixList {
                p.sliceInterval = 0
            }

            // The 3D views opened from this viewer say so.
            GantryTiltPolicy.setCorrected(degrees: viewerController.horos_titledGantryDegrees, for: viewerController)
        }
        if let exception {
            _N2LogExceptionImpl(exception, false, "+[ViewerController correctGangtryTilt:]")
        }

        viewerController.endWaitWindow(w)

        // We modified the view: OsiriX please update the display!
        viewerController.needsDisplayUpdate()
    }
}
