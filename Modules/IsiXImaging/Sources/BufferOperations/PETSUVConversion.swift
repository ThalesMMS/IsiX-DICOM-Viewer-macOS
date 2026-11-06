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

// The conversion of PET values to SUV (standardized uptake values) of the
// 2D viewer: when the values of a slice allow it, the factor of a slice, and
// the scaling of its pixels. The app reads and writes the DCMPix; the
// arithmetic, in the precision the Objective-C used, is here.

public enum PETSUVConversion {

    /// Whether the values of the current slice allow a conversion: grey
    /// pixels, Philips counts with their factor or a positive corrected dose
    /// and weight, and SUV values at all.
    public static func canConvert(isRGB: Bool, units: String?, philipsFactor: Float,
                                  radionuclideTotalDoseCorrected: Float, patientsWeight: Float, hasSUV: Bool) -> Bool {
        if isRGB { return false }
        if !(units == "CNTS" && philipsFactor != 0) {
            if radionuclideTotalDoseCorrected <= 0 { return false }
            if patientsWeight <= 0 { return false }
        }
        return hasSUV
    }

    /// The factor that turns the values of a slice into SUV: the Philips
    /// factor of counts ("CNTS"), otherwise weight (kg) × 1000 / (corrected
    /// dose × decay factor), the dose times the decay in float.
    public static func factor(units: String?, philipsFactor: Float, patientsWeight: Float,
                              radionuclideTotalDoseCorrected: Float, decayFactor: Float) -> Double {
        if units == "CNTS" { return Double(philipsFactor) }
        return Double(patientsWeight) * 1000.0 / Double(radionuclideTotalDoseCorrected * decayFactor)
    }

    /// Multiplies the `count` floats at `pixels` by `factor`.
    public static func scale(_ pixels: UnsafeMutablePointer<Float>, count: Int, by factor: Float) {
        var i = 0
        while i < count {
            pixels[i] *= factor
            i += 1
        }
    }
}
