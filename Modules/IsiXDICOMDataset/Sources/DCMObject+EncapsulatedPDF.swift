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
import IsiXDICOMFile

extension DCMObject {

    /// An Encapsulated PDF object holding `pdf`, in UTF-8, with new UIDs and the
    /// patient and study identification left empty for the caller to fill.
    @objc(encapsulatedPDF:)
    public class func encapsulatedPDF(_ pdf: Data) -> DCMObject {
        let object = DCMObject()
        func set(_ name: String, _ value: Any?) {
            object.setAttributeValues(NSMutableArray(array: value.map { [$0] } ?? []), forName: name)
        }
        set("SOPClassUID", DICOMSOPClass.pdfStorageClassUID())
        set("MediaStorageSOPClassUID", DICOMSOPClass.pdfStorageClassUID())
        set("InstanceNumber", "0001")
        set("ContentDate", DICOMCalendarDate.dicomDate(with: Date()))
        set("ContentTime", DICOMCalendarDate.dicomTime(with: Date()))
        set("BurnedInAnnotation", "NO")
        set("AcquisitionDatetime", nil)
        set("DocumentTitle", nil)
        object.setCharacterSet(DICOMCharacterSet(code: "ISO_IR 192"))
        set("PatientsName", nil)
        set("PatientID", nil)
        set("PatientsBirthDate", nil)
        set("PatientsSex", nil)
        set("PatientsAge", nil)
        set("ReferringPhysiciansName", nil)
        set("AccessionNumber", nil)
        set("ConversionType", "WSD")
        set("Manufacturer", "IsiX DICOM Viewer")
        set("Modality", "OT")
        set("SeriesNumber", "6000")
        set("SeriesDescription", "PDF")
        object.setAttribute(DCMSequenceAttribute.sequenceAttribute(withName: "ConceptNameCodeSequence"))
        set("CodeValue", nil)
        set("MIMETypeOfEncapsulatedDocument", "application/pdf")
        set("EncapsulatedDocument", pdf as NSData)
        object.newStudyInstanceUID()
        object.newSeriesInstanceUID()
        object.newSOPInstanceUID()
        return object
    }
}
