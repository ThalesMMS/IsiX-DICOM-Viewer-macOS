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
import IsiXImaging

/// The standardized uptake value of a PET image: the dose decay-corrected to
/// the acquisition, whether the image has what an SUV needs, and the parameters
/// carried from another image. The arithmetic is IsiXImaging's SUVComputation.
extension DCMPix {

    /// The dose decays from the injection to the acquisition; ADMIN and NONE
    /// apply it as injected. Without a usable correction it is zero, which the
    /// SUV callers treat as "no SUV" rather than dividing by it.
    final func correctTotalDose() {
        horos_radionuclideTotalDoseCorrected = horos_radionuclideTotalDose
        SUVComputationBridge.correct(dose: &horos_radionuclideTotalDoseCorrected, decayFactor: &horos_decayFactor,
                                     decayCorrection: horos_decayCorrection as String?, halflife: horos_halflife,
                                     injection: horos_radiopharmaceuticalStartTime as Date?, acquisition: horos_acquisitionTime as Date?)
    }

    final func checkSUVParameters() {
        var correctsDose: ObjCBool = false
        let has = SUVComputationBridge.hasSUV(units: units, decayCorrection: decayCorrection, philipsFactor: horos_philipsFactor,
                                              decayFactor: horos_decayFactor, halflife: horos_halflife,
                                              injection: horos_radiopharmaceuticalStartTime as Date?,
                                              acquisition: horos_acquisitionTime as Date?, dose: radionuclideTotalDose,
                                              isRGB: horos_isRGB, correctsDose: &correctsDose)
        // ADMIN and NONE need the dose correction, which does not depend on the
        // acquisition time; -computeTotalDoseCorrected owns it for load and edit alike.
        if correctsDose.boolValue { computeTotalDoseCorrected() }
        horos_hasSUV = has
    }

    final func copySUV(from other: DCMPix?) {
        radiopharmaceuticalStartTime = other?.radiopharmaceuticalStartTime
        acquisitionTime = other?.acquisitionTime
        acquisitionDate = other?.acquisitionDate
        rescaleType = other?.rescaleType
        radionuclideTotalDose = other?.radionuclideTotalDose ?? 0
        radionuclideTotalDoseCorrected = other?.radionuclideTotalDoseCorrected ?? 0
        patientsWeight = other?.patientsWeight ?? 0
        units = other?.units
        displaySUVValue = other?.displaySUVValue ?? false
        suvConverted = other?.suvConverted ?? false
        factorPET2SUV = other?.factorPET2SUV ?? 0
        slope = other?.slope ?? 0
        decayCorrection = other?.decayCorrection
        maxValueOfSeries = other?.maxValueOfSeries ?? 0
        minValueOfSeries = other?.minValueOfSeries ?? 0
        decayFactor = other?.decayFactor ?? 0
        halflife = other?.halflife ?? 0
        horos_annotationsDictionary = other?.annotationsDictionary
        checkSUV()
    }
}
