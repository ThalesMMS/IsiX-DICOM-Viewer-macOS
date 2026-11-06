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

/// What a PET object says that an SUV is computed from: the patient's weight,
/// the unit of the pixels, how they were decay corrected, the dose and when it
/// was injected, and when the image was acquired.
public struct SUVParameters: Equatable, Sendable {
    public var patientsWeight: Float = 0
    public var units: String?
    public var decayCorrection: String?
    public var decayFactor: Float = 0
    public var radionuclideTotalDose: Float = 0
    public var halflife: Float = 0
    /// Injection and acquisition as DICOM date-times (YYYYMMDDHHMMSS.FFFFFF),
    /// set when the object carries all three of a date, an acquisition time
    /// and an injection time; the app parses them with its own date type.
    public var radiopharmaceuticalStartDateTime: String?
    public var acquisitionDateTime: String?
    /// Philips' own SUV scale factor (7053,1000).
    public var philipsFactor: Float = 0

    public init() {}

    /// The date and time attributes, in pairs, that the decay is counted to,
    /// by preference: series, acquisition, content or study first, as chosen
    /// in the preferences.
    public static func acquisitionTimePriority(_ field: Int) -> [String] {
        switch field {
        case 0: return ["SeriesDate", "SeriesTime", "AcquisitionDate", "AcquisitionTime", "ContentDate", "ContentTime", "StudyDate", "StudyTime"]
        case 1: return ["AcquisitionDate", "AcquisitionTime", "SeriesDate", "SeriesTime", "ContentDate", "ContentTime", "StudyDate", "StudyTime"]
        case 2: return ["ContentDate", "ContentTime", "SeriesDate", "SeriesTime", "AcquisitionDate", "AcquisitionTime", "StudyDate", "StudyTime"]
        case 3: return ["StudyDate", "StudyTime", "SeriesDate", "SeriesTime", "AcquisitionDate", "AcquisitionTime", "ContentDate", "ContentTime"]
        default: return []
        }
    }
}

extension ImageAttributeReader {
    /// The values needed for SUV.
    public mutating func readSUVParameters(from dataset: DICOMAttributeSource) throws {
        if dataset.attributeValue(withName: "PatientsWeight") != nil {
            attributes.suv.patientsWeight = AttributeValueCoercion.float(AttributeValueCoercion.numberValue(dataset, "PatientsWeight", file: file))
        } else {
            attributes.suv.patientsWeight = 0
        }
        attributes.suv.units = dataset.attributeValue(withName: "Units") as? String
        attributes.suv.decayCorrection = dataset.attributeValue(withName: "DecayCorrection") as? String

        // Decay Factor is not used: the correction is computed from the times.
        attributes.suv.decayFactor = 1

        let radiopharmaceutical: DICOMAttributeSource
        switch dataset.sequence(named: "RadiopharmaceuticalInformationSequence") {
        case .absent:
            return
        case .notASequence(let attribute):
            throw AttributeReadException.unrecognizedSelector("sequence", sentTo: attribute)
        case .items(let items):
            guard let first = items.first else { return }
            radiopharmaceutical = first
        }

        attributes.suv.radionuclideTotalDose = try ParsedValue.float(radiopharmaceutical.attributeValue(withName: "RadionuclideTotalDose"))
        attributes.suv.halflife = try ParsedValue.float(radiopharmaceutical.attributeValue(withName: "RadionuclideHalfLife"))

        var preferredDate: String?
        var preferredTime: String?
        let priority = SUVParameters.acquisitionTimePriority(context.suvAcquisitionTimeField)
        var v = 0
        while v < priority.count {
            if preferredDate == nil, let value = try ParsedValue.dicomString("dateString", of: dataset.attributeValue(withName: priority[v])) {
                preferredDate = value
            }
            v += 1
            if preferredTime == nil, let value = try ParsedValue.dicomString("timeString", of: dataset.attributeValue(withName: priority[v])) {
                preferredTime = value
            }
            v += 1
        }

        let injection = try ParsedValue.dicomString("timeString", of: radiopharmaceutical.attributeValue(withName: "RadiopharmaceuticalStartTime"))

        // TM values from the DICOM adapter include fractional seconds. A fixed
        // whole-second format rejects that suffix and silently leaves both SUV
        // dates nil, so the app parses the combined DICOM DT value.
        if let preferredDate, let preferredTime, let injection {
            attributes.suv.radiopharmaceuticalStartDateTime = preferredDate + injection
            attributes.suv.acquisitionDateTime = preferredDate + preferredTime
        }

        needsTotalDoseCorrection = true
    }

    /// An NM object places its image by the detector that made it, frame by
    /// frame one slice further along.
    public mutating func readDetectorGeometry(from dataset: DICOMAttributeSource) throws {
        let detector: DICOMAttributeSource
        switch dataset.sequence(named: "DetectorInformationSequence") {
        case .absent:
            return
        case .notASequence(let attribute):
            throw AttributeReadException.unrecognizedSelector("sequence", sentTo: attribute)
        case .items(let items):
            guard let first = items.first else { return }
            detector = first
        }

        if let ipp = detector.attributeArray(withName: "ImagePositionPatient"), ipp.count >= 3 {
            attributes.geometry.originX = AttributeValueCoercion.number(in: ipp, at: 0, name: "ImagePositionPatient", file: file)
            attributes.geometry.originY = AttributeValueCoercion.number(in: ipp, at: 1, name: "ImagePositionPatient", file: file)
            attributes.geometry.originZ = AttributeValueCoercion.number(in: ipp, at: 2, name: "ImagePositionPatient", file: file)
            attributes.geometry.isOriginDefined = true
        }

        let step = attributes.geometry.spacingBetweenSlices != 0 ? attributes.geometry.spacingBetweenSlices : attributes.geometry.sliceThickness
        attributes.geometry.originZ = attributes.geometry.originZ.addingProduct(Double(context.frame), step)

        for j in 0..<6 { attributes.geometry.orientation[j] = 0 }

        if let iop = detector.attributeArray(withName: "ImageOrientationPatient") {
            var allZero = true
            for value in iop {
                if try ParsedValue.float(value) != 0 { allZero = false }
            }

            if !allZero {
                readCosines(iop, name: "ImageOrientationPatient")
            } else if attributes.geometry.orientation[0..<6].allSatisfy({ $0 == 0 }) {
                // Neither the detector nor the object says: an axial image.
                attributes.geometry.orientation.replaceSubrange(0..<6, with: [1, 0, 0, 0, 1, 0])
            }
        }
    }

    /// Philips writes its SUV scale factor in a private element; a value that
    /// is not a number is logged and left out.
    public mutating func readPhilipsFactor(from dataset: DICOMAttributeSource) {
        guard let value = dataset.attributeValue(forKey: "7053,1000") else { return }
        do {
            attributes.suv.philipsFactor = try ParsedValue.float(value)
        } catch let exception as AttributeReadException {
            NSLog("philipsFactor exception")
            NSLog("%@", exception.reason)
        } catch {
            NSLog("philipsFactor exception")
        }
    }
}
