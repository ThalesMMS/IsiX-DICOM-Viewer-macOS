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

import Foundation

// The volume of the ROIs named like a given one through the slices of the
// frame shown, with the selectors of the former Objective-C methods. The work
// is ViewerROIVolume's, over IsiXROI's ROIVolumeJob.

public extension ViewerController {

    @objc(computeVolume:points:error:)
    func computeVolume(_ selectedRoi: ROI!, points pts: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Float {
        computeVolume(selectedRoi, points: pts, generateMissingROIs: false, generatedROIs: nil, computeData: nil, error: error)
    }

    @objc(computeVolume:points:generateMissingROIs:error:)
    func computeVolume(_ selectedRoi: ROI!, points pts: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!,
                       generateMissingROIs: Bool, error: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Float {
        computeVolume(selectedRoi, points: pts, generateMissingROIs: generateMissingROIs, generatedROIs: nil, computeData: nil, error: error)
    }

    /// The volume in cm³ of the ROIs named like `selectedRoi` (0 with
    /// `error` set when it cannot be computed).
    ///
    /// With `generateMissingROIs`, ROIs are morphed into the slices between
    /// two ROIs of that name first (and, without `generatedROIs`, the ones
    /// generated before are deleted); `generatedROIs` collects the new ones.
    /// `pts` receives the contour points in patient coordinates, closed by
    /// three points above and below; `data` the statistics of the values
    /// under the ROIs, with the volume and the ROIs.
    @objc(computeVolume:points:generateMissingROIs:generatedROIs:computeData:error:)
    func computeVolume(_ selectedRoi: ROI!, points pts: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!,
                       generateMissingROIs: Bool, generatedROIs: NSMutableArray!, computeData data: NSMutableDictionary!,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Float {
        let measurement = ViewerROIVolume.measure(selectedRoi, in: self, surface: pts != nil, values: data != nil,
                                                  generateMissingROIs: generateMissingROIs, keepsGenerated: generatedROIs != nil,
                                                  generated: { generatedROIs?.add($0) })
        pts?.pointee = NSMutableArray(array: measurement.surface)
        error?.pointee = measurement.failure.map { NSLocalizedString($0.message, comment: "") as NSString }
        if let statistics = measurement.statistics {
            data?.addEntries(from: statistics)
        }
        return measurement.volume
    }
}
