/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// Whether a PET image's values can be read as SUV, and the injected dose
/// decay-corrected to the acquisition (PS 3.3 C.8.9.1, C.8.9.2).
public enum SUVComputation {
    /// The dose and decay factor after correction.
    ///
    /// ADMIN and NONE mean the pixel values were not decay corrected back to
    /// the injection time, so the dose applies as injected, with a factor of
    /// one; nil `decayFactor` means it is left as it is. Otherwise the dose
    /// decays over the time from injection to acquisition; without a half-life
    /// or with an acquisition before the injection there is no usable
    /// correction, and the dose is zero, which the SUV callers read as "no SUV".
    public static func correctedDose(decayCorrection: String?, dose: Float, halflife: Float,
                                     injection: Date?, acquisition: Date?) -> (dose: Float, decayFactor: Float?) {
        if let decayCorrection, decayCorrection == "ADMIN" || decayCorrection == "NONE" {
            return (dose, 1)
        }
        let elapsed = Float(-interval(injection, since: acquisition))
        if halflife > 0 && elapsed > 0 {
            // Float arithmetic in the exponent, the exponential and the product in double.
            return (Float(Double(dose) * exp(Double(-elapsed * logf(2) / halflife))), nil)
        }
        return (0, nil)
    }

    /// What deciding whether an image has SUV found: whether it has, and
    /// whether the dose correction has to run first (ADMIN and NONE, which
    /// need no acquisition time).
    public struct Availability: Equatable, Sendable {
        public let hasSUV: Bool
        public let correctsDose: Bool
    }

    /// An image has SUV when its values are activity concentrations (BQML, or
    /// Philips CNTS with a scale factor), its decay correction is one SUV can
    /// undo, it has a dose, and it is not colour.
    public static func availability(units: String?, decayCorrection: String?, philipsFactor: Float, decayFactor: Float,
                                    halflife: Float, hasInjectionAndAcquisition: Bool, dose: Float,
                                    isRGB: Bool) -> Availability {
        let none = Availability(hasSUV: false, correctsDose: false)
        guard units == "BQML" || units == "CNTS" else { return none }
        if units == "CNTS" && philipsFactor == 0 { return none }
        guard let decayCorrection, ["START", "NONE", "ADMIN"].contains(decayCorrection) else { return none }
        let corrects = decayCorrection == "NONE" || decayCorrection == "ADMIN"
        if !corrects {
            if decayFactor == 0 || halflife <= 0 || !hasInjectionAndAcquisition { return none }
        }
        return Availability(hasSUV: dose > 0 && !isRGB, correctsDose: corrects)
    }

    /// The factor that converts the image's values to SUV, once they have
    /// been converted; one before.
    public static func appliedFactor(converted: Bool, factor: Float) -> Float {
        converted ? factor : 1
    }

    /// `-[date timeIntervalSinceDate: other]` as Objective-C answered it: zero
    /// when `date` is nil, and measured from the reference date when `other` is.
    static func interval(_ date: Date?, since other: Date?) -> Double {
        guard let date else { return 0 }
        return date.timeIntervalSinceReferenceDate - (other?.timeIntervalSinceReferenceDate ?? 0)
    }
}
