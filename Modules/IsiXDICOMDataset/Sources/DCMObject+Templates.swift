/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXDICOMFile

/// The objects the model makes from nothing: secondary captures, and the
/// coded entries of a structured report.
extension DCMObject {

    private static let secondaryCaptureImageStorage = "1.2.840.10008.5.1.4.1.1.7"
    private static let manufacturer = "IsiX DICOM Viewer"

    // The elements of groups 0008, 0010 and 0020 a secondary capture keeps
    // from its template; the meta header is kept whole, and the rest goes.
    private static let keptGeneralElements: Set<Int32> = [
        0x0005, 0x0020, 0x0030, 0x0080, 0x0081, 0x0082, 0x0090, 0x0092, 0x0094, 0x0096, 0x0116, 0x0201, 0x1010,
        0x1030, 0x1040, 0x1048, 0x1049, 0x1050, 0x1052, 0x1060, 0x1062, 0x1080, 0x1084, 0x1100, 0x1110, 0x1120,
        0x1125, 0x2218, 0x2220, 0x2228, 0x2229, 0x2230]
    private static let keptPatientElements: Set<Int32> = [
        0x0010, 0x0020, 0x0021, 0x0030, 0x0032, 0x0040, 0x0050, 0x0101, 0x0102, 0x1000, 0x1001, 0x1005, 0x1010,
        0x1020, 0x1030, 0x1040, 0x1060, 0x1080, 0x1081, 0x1090, 0x2000, 0x2110, 0x2150, 0x2152, 0x2154, 0x2160,
        0x2180, 0x21A0, 0x21B0, 0x21C0, 0x21D0, 0x21F0, 0x4000]
    private static let keptRelationshipElements: Set<Int32> = [
        0x000D, 0x0010, 0x1070, 0x1200, 0x1202, 0x1204, 0x1206, 0x1208]

    /// A secondary capture of `object`: its meta header, patient, study and
    /// general attributes, new series and instance UIDs, and this computer as
    /// the capture device.
    @objc(secondaryCaptureObjectFromTemplate:)
    public class func secondaryCaptureObject(fromTemplate object: DCMObject) -> DCMObject {
        let capture = DCMObject(object: object)
        let attributes = capture.attributes!
        let removed = capture.keys { attribute in
            guard let tag = attribute.attrTag else { return false }
            switch tag.group {
            case 0x0002: return false
            case 0x0008: return !keptGeneralElements.contains(tag.element)
            case 0x0010: return !keptPatientElements.contains(tag.element)
            case 0x0020: return !keptRelationshipElements.contains(tag.element)
            default: return true
            }
        }
        attributes.removeObjects(forKeys: removed)

        // These are stored under their names, not their tags, as they always were.
        func put(_ name: String, _ value: Any) {
            let tag = DICOMAttributeTag.tag(withName: name)
            attributes.setObject(DCMAttribute(attributeTag: tag, vr: tag?.vr, values: NSMutableArray(object: value)),
                                 forKey: name as NSString)
        }
        put("SOPClassUID", secondaryCaptureImageStorage)
        put("MediaStorageSOPClassUID", secondaryCaptureImageStorage)
        put("SecondaryCaptureDeviceID", macAddress())
        put("Manufacturer", manufacturer)
        put("SecondaryCaptureDeviceManufacturer", manufacturer)
        put("SecondaryCaptureDeviceManufacturersModelName", manufacturer)
        put("SecondaryCaptureDeviceSoftwareVersions", "3.8")
        put("DateofSecondaryCapture", DICOMCalendarDate.calendarDate())
        put("TimeofSecondaryCapture", DICOMCalendarDate.calendarDate())
        put("Modality", "SC")

        capture.newSeriesInstanceUID()
        capture.newSOPInstanceUID()
        capture.updateMetaInformation(withTransferSyntax: capture.transferSyntax, aet: "ISIX")
        return capture
    }

    /// An empty secondary capture of the class the bit depth, samples and
    /// frames call for, with new UIDs and the identification left empty.
    @objc(secondaryCaptureObjectWithBitDepth:samplesPerPixel:numberOfFrames:)
    public class func secondaryCaptureObject(withBitDepth bitDepth: Int32, samplesPerPixel spp: Int32,
                                             numberOfFrames nff: Int32) -> DCMObject {
        let capture = DCMObject()
        let abstractSyntax: String
        if nff > 1 {
            if spp > 1 {
                abstractSyntax = DICOMSOPClass.multiframeTrueColorSecondaryCaptureImageStorage
            } else if bitDepth < 8 {
                abstractSyntax = DICOMSOPClass.multiframeSingleBitSecondaryCaptureImageStorage
            } else if bitDepth == 8 {
                abstractSyntax = DICOMSOPClass.multiframeGrayscaleByteSecondaryCaptureImageStorage
            } else {
                abstractSyntax = DICOMSOPClass.multiframeGrayscaleWordSecondaryCaptureImageStorage
            }
        } else {
            abstractSyntax = DICOMSOPClass.secondaryCaptureImageStorage()
        }
        func set(_ name: String, _ value: Any?) {
            capture.setAttributeValues(NSMutableArray(array: value.map { [$0] } ?? []), forName: name)
        }
        set("SOPClassUID", abstractSyntax)
        set("MediaStorageSOPClassUID", abstractSyntax)
        set("Manufacturer", manufacturer)
        set("SecondaryCaptureDeviceID", macAddress())
        set("SecondaryCaptureDeviceManufacturer", manufacturer)
        set("SecondaryCaptureDeviceManufacturersModelName", manufacturer)
        set("SecondaryCaptureDeviceSoftwareVersions", "3.8")
        set("DateofSecondaryCapture", DICOMCalendarDate.calendarDate())
        set("TimeofSecondaryCapture", DICOMCalendarDate.calendarDate())
        set("Modality", "SC")
        capture.newStudyInstanceUID()
        capture.newSeriesInstanceUID()
        capture.newSOPInstanceUID()
        capture.updateMetaInformation(withTransferSyntax: DCMTransferSyntax.explicitVRLittleEndianTransferSyntax(),
                                      aet: "osirix")
        // Patient, study, series and instance identification, left empty.
        set("PatientsName", nil)
        set("PatientID", nil)
        set("StudyID", nil)
        set("StudyDescription", nil)
        set("StudyDate", DICOMCalendarDate.calendarDate())
        set("StudyTime", DICOMCalendarDate.calendarDate())
        set("SeriesDescription", nil)
        set("SeriesNumber", nil)
        set("SeriesDate", DICOMCalendarDate.calendarDate())
        set("SeriesTime", DICOMCalendarDate.calendarDate())
        set("InstanceNumber", nil)
        set("AcquisitionDate", DICOMCalendarDate.calendarDate())
        set("AcquisitionTime", DICOMCalendarDate.calendarDate())
        capture.updateMetaInformation(withTransferSyntax: DCMTransferSyntax.explicitVRLittleEndianTransferSyntax(),
                                      aet: "ISIX")
        return capture
    }

    /// A coded entry of a structured report.
    @objc(objectWithCodeValue:codingSchemeDesignator:codeMeaning:)
    public class func object(withCodeValue codeValue: String, codingSchemeDesignator: String,
                             codeMeaning: String) -> DCMObject {
        let object = DCMObject()
        object.setAttributeValues(NSMutableArray(object: codeValue), forName: "CodeValue")
        object.setAttributeValues(NSMutableArray(object: codingSchemeDesignator), forName: "CodingSchemeDesignator")
        object.setAttributeValues(NSMutableArray(object: codeMeaning), forName: "CodeMeaning")
        return object
    }
}
