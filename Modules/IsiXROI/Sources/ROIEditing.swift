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

import CoreGraphics
import Foundation

/// The rules of DCMView's ROI editing that need neither the view nor AppKit:
/// the shape a ROI read from XML gets, the text the clipboard carries with the
/// copied ROIs, and where a contour's points fall in the plane of an image.
public enum ROIEditing {

    /// The shape of a ROI read from an XML file, from its number of points: a
    /// point for one, a length for two, a closed polygon otherwise.
    public enum XMLShape: Sendable, Equatable {
        case point, length, polygon
    }

    public static func xmlShape(pointCount: Int) -> XMLShape {
        switch pointCount {
        case 1: return .point
        case 2: return .length
        default: return .polygon
        }
    }

    /// The plain text put on the pasteboard with copied ROIs: their
    /// descriptions, one per line, separated by carriage returns.
    public static func clipboardText(_ descriptions: [String]) -> String {
        return descriptions.joined(separator: "\r")
    }

    /// A point in space (`dicom`, millimetres), in the plane of an image whose
    /// origin is `origin` and whose row and column directions are the first
    /// six values of `orientation`: its coordinates along the two, in
    /// millimetres. The products are fused as the Objective-C compiler fused
    /// them (the second, then the first, then the third), for the same bits.
    public static func planePoint(_ dicom: (Double, Double, Double), origin: (Double, Double, Double),
                                  orientation o: UnsafePointer<Double>) -> CGPoint {
        let v0 = dicom.0 - origin.0, v1 = dicom.1 - origin.1, v2 = dicom.2 - origin.2
        let x = (v1 * o[1]).addingProduct(v0, o[0]).addingProduct(v2, o[2])
        let y = (v1 * o[4]).addingProduct(v0, o[3]).addingProduct(v2, o[5])
        return CGPoint(x: x, y: y)
    }
}
