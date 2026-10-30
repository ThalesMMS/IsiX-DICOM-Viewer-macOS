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

/// The dataset DICOMExport writes, assembled over the adapter's file: the
/// header of an image without a DICOM source, and the image itself over
/// whatever the source had. What goes in is SecondaryCaptureExport's.
enum SecondaryCaptureDataset {

    // MARK: - The header of an export without a DICOM source

    /// What DicomFile read of a source that is not DICOM, under the keys of
    /// DICOMExport's metaDataDict. As `[NSDictionary
    /// dictionaryWithObjectsAndKeys:]`, the list ends at the first value
    /// missing.
    static func headerValues(of file: DicomFile) -> NSDictionary {
        let values = NSMutableDictionary()
        for (element, key) in [("patientName", "patientsName"), ("patientID", "patientID"),
                               ("patientBirthDate", "patientsBirthdate"), ("patientSex", "patientsSex"),
                               ("studyDate", "studyDate")] {
            guard let value = file.element(forKey: element) else { break }
            values[key] = value
        }
        return values
    }

    /// `[value UTF8String]`, which raises for a value that is not a string,
    /// as the message to it did.
    private static func utf8(_ value: Any) -> UnsafePointer<CChar>? {
        guard let string = value as? NSString else {
            NSException(name: .invalidArgumentException,
                        reason: "-[\(type(of: value)) UTF8String]: unrecognized selector", userInfo: nil).raise()
            return nil
        }
        return string.utf8String
    }

    /// A date as DICOMExport wrote it: DA, or TM of its whole seconds. A value
    /// that is not a date raises, as reading its interval did.
    private static func dateText(_ value: Any, time: Bool) -> String {
        guard let date = value as? Date else {
            NSException(name: .invalidArgumentException,
                        reason: "-[\(type(of: value)) timeIntervalSinceReferenceDate]: unrecognized selector",
                        userInfo: nil).raise()
            return ""
        }
        return time ? DICOMDateTimeText.time(date, fraction: false) : DICOMDateTimeText.date(date)
    }

    /// The patient, study, series and instance of an image with no DICOM
    /// source, from `values` (metaDataDict's keys). Each step runs while the
    /// previous ones succeeded, but the modality is always written; whether
    /// all did.
    static func writeHeader(into dataset: IsiXDCMTKItem, values: NSDictionary) -> Bool {
        var good = true
        func put(_ value: UnsafePointer<CChar>?, _ tag: UInt32) -> Bool {
            putText(value, dataset, tag)
        }
        // The empty type 2 attributes.
        for tag: UInt32 in [0x0008_0020, 0x0008_0030, 0x0008_0050, 0x0008_0070, 0x0008_0090, 0x0020_0010,
                            0x0008_0023, 0x0008_0033, 0x0008_0022, 0x0008_0032, 0x0008_002a, 0x0040_a043] where good {
            good = (try? dataset.insertEmptyElement(forTag: tag)) != nil
        }
        if good { good = put(SecondaryCaptureExport.secondaryCaptureStorage, 0x0008_0016) }
        if good { good = put("ISO_IR 100", 0x0008_0005) }
        // There is no way to determine a meaningful series number: a constant.
        if good { good = put("1", 0x0020_0011) }
        if good, let name = values["patientsName"] { good = put(utf8(name), 0x0010_0010) }
        if good, let patientID = values["patientID"] { good = put(utf8(patientID), 0x0010_0020) }
        if good, let birthDate = values["patientsBirthdate"] { good = put(dateText(birthDate, time: false), 0x0010_0030) }
        if good, let sex = values["patientsSex"] { good = put(utf8(sex), 0x0010_0040) }
        if good, let studyDate = values["studyDate"] { good = put(dateText(studyDate, time: false), 0x0008_0022) }
        if good, let studyDate = values["studyDate"] { good = put(dateText(studyDate, time: true), 0x0008_0032) }
        if good, let description = values["studyDescription"] { good = put(utf8(description), 0x0008_1030) }
        if good, let modality = values["modality"], ((modality as? NSString)?.length ?? 0) > 0 {
            good = put(utf8(modality), 0x0008_0060)
        } else {
            good = put("OT", 0x0008_0060)
        }
        // A UID is made for each level whether or not the values give one.
        let study = IsiXDCMTKFile.generateUID(root: .study)
        if good {
            if let studyUID = values["studyUID"] { good = put(utf8(studyUID), 0x0020_000d) } else { good = put(study, 0x0020_000d) }
        }
        let series = IsiXDCMTKFile.generateUID(root: .series)
        if good {
            if let seriesUID = values["seriesUID"] { good = put(utf8(seriesUID), 0x0020_000e) } else { good = put(series, 0x0020_000e) }
        }
        let instance = IsiXDCMTKFile.generateUID(root: .instance)
        if good { good = put(instance, 0x0008_0018) }
        // The instance's creation date and time.
        if good {
            if let date = IsiXDCMTKFile.currentDate() { good = put(date, 0x0008_0012) } else { good = false }
        }
        if good {
            if let time = IsiXDCMTKFile.currentTime() { good = put(time, 0x0008_0013) } else { good = false }
        }
        return good
    }

    /// `putAndInsertString` of a C string that may be NULL, which writes an
    /// empty value.
    @discardableResult
    static func putText(_ value: UnsafePointer<CChar>?, _ item: IsiXDCMTKItem, _ tag: UInt32) -> Bool {
        if let value { return (try? item.putString(value, forTag: tag)) != nil }
        return (try? item.putString("", forTag: tag)) != nil
    }

    // MARK: - The image

    /// The image written over the file's dataset: the source's pixel module
    /// and multiframe groups gone, the series, the image's attributes, its
    /// pixels and a new identity.
    static func writeImage(into file: IsiXDCMTKFile, image: SecondaryCaptureExport.Image,
                           pixels: UnsafeMutablePointer<UInt8>, seriesUID: String?, seriesDescription: String?,
                           seriesNumber: Int32, instanceNumber: Int32, modalityAsSource: Bool) {
        file.loadAllDataIntoMemory()
        let dataset = file.dataset, meta = file.metaInfo
        dataset.removeAllElements(ofGroup: 0x0028)
        dataset.removeAllElements(ofGroup: 0x5200) // Multiframe is not exported.

        // The description is written in the first character set the dataset declares.
        var encoding = String.Encoding.isoLatin1.rawValue
        if let declared = dataset.string(forTag: 0x0008_0005),
           let sets = NSString(cString: declared, encoding: String.Encoding.isoLatin1.rawValue)?
               .components(separatedBy: "\\") {
            if sets.count >= 10 { NSLog("Encoding number >= 10 ???") }
            if sets.count < 10 { encoding = NSString.encoding(forDICOMCharacterSet: sets[0]) }
        }
        if let seriesUID { _ = try? dataset.putString(seriesUID, forTag: 0x0020_000e) }
        if let seriesDescription {
            putText((seriesDescription as NSString).cString(using: encoding), dataset, 0x0008_103e)
        }
        if seriesNumber != -1 { _ = try? dataset.putString(String(format: "%d", seriesNumber), forTag: 0x0020_0011) }

        var sourceModality: String?
        if let modality = dataset.string(forTag: 0x0008_0060) { sourceModality = String(cString: modality) }
        for edit in SecondaryCaptureExport.imageEdits(image, instanceNumber: instanceNumber,
                                                      modalityAsSource: modalityAsSource,
                                                      sourceModality: sourceModality) {
            switch edit {
            case .put(let tag, let value): _ = try? dataset.putString(value, forTag: tag)
            case .putMeta(let tag, let value): _ = try? meta.putString(value, forTag: tag)
            case .remove(let tag): dataset.removeElement(forTag: tag)
            }
        }

        let length = SecondaryCaptureExport.pixelDataLength(image)
        let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(pixels),
                         count: length.words ? length.count * 2 : length.count, deallocator: .none)
        if length.words {
            _ = try? dataset.putUInt16Array(bytes, forTag: 0x7fe0_0010)
        } else {
            _ = try? dataset.putBytes(bytes, forTag: 0x7fe0_0010)
        }
        for tag in SecondaryCaptureExport.closingRemovals { dataset.removeElement(forTag: tag) }

        let instance = IsiXDCMTKFile.generateUID(root: .instance)
        _ = try? dataset.putString(instance, forTag: 0x0008_0018)
        _ = try? meta.putString(instance, forTag: 0x0002_0003)
    }
}
