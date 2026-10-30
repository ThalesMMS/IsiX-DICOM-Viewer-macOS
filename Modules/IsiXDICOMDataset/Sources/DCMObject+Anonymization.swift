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

/// Anonymization by attribute: a value given replaces every value of the
/// attribute; otherwise each value is replaced by one of its type - 0, the
/// first of the month at noon, zeroed bytes, a scrambled string.
extension DCMObject {

    /// Anonymizes the file at `file` into `destination`. Each entry of `tags`
    /// is an array: an IsiXDICOMAttributeTag and, optionally, the replacement.
    /// Private tags and the addresses and telephone numbers go as well.
    @objc(anonymizeContentsOfFile:tags:writingToFile:)
    public class func anonymizeContents(ofFile file: String, tags: [Any], writingToFile destination: String) -> Bool {
        let object = DCMObject.object(withContentsOfFile: file, decodingPixelData: false)
        object?.removePrivateTags()
        for name in ["InstitutionAddress", "PatientsAddress", "PatientsTelephoneNumbers"]
        where object?.attributeValue(withName: name) != nil {
            object?.setAttributeValues(NSMutableArray(), forName: name)
        }
        for entry in tags {
            guard let entry = entry as? [Any], let tag = entry.first as? DICOMAttributeTag else { continue }
            let value: Any? = entry.count > 1 ? entry[1] : nil
            if tag.name == "StudyInstanceUID" {
                let attribute = DCMAttribute(attributeTag: tag, vr: tag.vr,
                                             values: NSMutableArray(array: value.map { [$0] } ?? []))
                object?.attributes?.setObject(attribute, forKey: tag.stringValue! as NSString)
            } else {
                object?.anonymizeAttribute(for: tag, replacingWith: value)
            }
            switch tag.name {
            case "PatientID":
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "OtherPatientIDs"), replacingWith: value)
            case "InstanceCreationDate":
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "ContentDate"), replacingWith: value)
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "AcquisitionDate"), replacingWith: value)
            case "InstanceCreationTime":
                NSLog("InstanceCreationTime")
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "ContentTime"), replacingWith: value)
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "AcquisitionTime"), replacingWith: value)
            case "AcquisitionDatetime":
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "AcquisitionDate"), replacingWith: value)
                object?.anonymizeAttribute(for: DICOMAttributeTag.tag(withName: "AcquisitionTime"), replacingWith: value)
            default:
                break
            }
        }
        guard let object else { return false }
        var syntax = object.transferSyntax
        if syntax?.isExplicit != true {
            syntax = DCMTransferSyntax.explicitVRLittleEndianTransferSyntax()
        }
        return object.write(toFile: destination, with: syntax, quality: DCMCompressionQuality.lossless.rawValue,
                            atomically: true)
    }

    /// Replaces the values of the attribute at `tag`, adding it with
    /// `aValue` when absent. The meta header and UIDs are left alone.
    @objc(anonymizeAttributeForTag:replacingWith:)
    public func anonymizeAttribute(for tag: DICOMAttributeTag?, replacingWith aValue: Any?) {
        guard let tag, let key = tag.stringValue else { return }
        var attribute = attributes?.object(forKey: key) as? DCMAttribute
        if let aValue, attribute == nil {
            let added = DCMAttribute(attributeTag: tag)
            added.addValue(aValue)
            attributes?.setObject(added, forKey: key as NSString)
            attribute = added
        }
        guard let attribute, tag.group != 0x0002, tag.vr != "UI", let values = attribute.values else { return }

        var replacement = aValue
        var format: String?
        for index in 0..<values.count {
            let value = values.object(at: index)
            var newValue: Any?
            switch dcmVRCode(tag.vr) {
            case DCM_AT, DCM_UL, DCM_SL, DCM_FL, DCM_FD, DCM_US, DCM_SS:
                newValue = NSNumber(value: 0)
            case DCM_DA, DCM_TM, DCM_DT:
                // The first of the month at noon, in the value's time zone.
                switch dcmVRCode(tag.vr) {
                case DCM_DA: format = format ?? "%Y%m%d"
                case DCM_TM: format = format ?? "%H%M%S"
                default: format = format ?? "%Y%m%d%H%M%S"
                }
                if let date = value as? DICOMCalendarDate {
                    newValue = DICOMCalendarDate.date(withYear: date.yearOfCommonEra(), month: UInt(date.monthOfYear()),
                                                      day: 1, hour: 12, minute: 0, second: 0, timeZone: date.timeZone())
                }
                if !(replacement is DICOMCalendarDate) {
                    if let date = replacement as? Date, let format {
                        let calendarDate = DICOMCalendarDate(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
                        replacement = DICOMCalendarDate.date(with: calendarDate.description(withCalendarFormat: format),
                                                             calendarFormat: format)
                    } else {
                        replacement = nil
                    }
                }
            case DCM_UN, DCM_OB, DCM_OW:
                newValue = NSMutableData(length: (value as? NSData)?.length ?? (value as? NSString)?.length ?? 0)
            case DCM_SH, DCM_DS, DCM_IS:
                newValue = "0"
            case DCM_AS:
                newValue = "000Y"
            case DCM_CS:
                newValue = "0000"
            case DCM_AE, DCM_LO, DCM_LT, DCM_PN, DCM_ST, DCM_UI, DCM_UT, DCM_QQ:
                newValue = anonymizeString(value as? String ?? "")
            default:
                break
            }
            values.replaceObject(at: index, with: replacement ?? newValue ?? NSNull())
        }
    }

    /// A string of the same length scrambled from its characters: the same
    /// string gives the same result.
    @objc(anonymizeString:)
    public func anonymizeString(_ string: String) -> String! {
        // The arithmetic is the Objective-C original's: 32-bit, wrapping, on the
        // signed bytes of the UTF-8 form, one per UTF-16 unit of the string.
        let characters = Array(string.utf8CString)
        let length = string.utf16.count
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.,^".utf8)
        var root: Int32 = 0
        var scrambled = [UInt8](repeating: 0, count: length)
        var newCharacter: UInt8 = 0
        for index in 0..<length {
            let character = Int32(characters[index])
            root = root &+ character
            let value = root &* Int32(truncatingIfNeeded: length) &* character
            let x = Int8(truncatingIfNeeded: value % 65)
            if x >= 0 && Int(x) < alphabet.count {
                newCharacter = alphabet[Int(x)]
            }
            scrambled[index] = newCharacter
        }
        let encoding = String.Encoding(rawValue: specificCharacterSet?.encoding ?? 0)
        return String(data: Data(scrambled), encoding: encoding)
    }
}
