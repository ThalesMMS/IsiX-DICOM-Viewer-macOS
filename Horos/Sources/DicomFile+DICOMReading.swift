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

import AppKit
import IsiXDICOMFile
import IsiXImaging

/// The tags the DICOM reading and the field queries read, (group << 16) | element.
enum DicomFileTag {
    static let transferSyntaxUID: UInt32 = 0x0002_0010
    static let mediaStorageSOPInstanceUID: UInt32 = 0x0002_0003
    static let privateInformationCreatorUID: UInt32 = 0x0002_0100
    static let specificCharacterSet: UInt32 = 0x0008_0005
    static let imageType: UInt32 = 0x0008_0008
    static let sopClassUID: UInt32 = 0x0008_0016
    static let sopInstanceUID: UInt32 = 0x0008_0018
    static let studyDate: UInt32 = 0x0008_0020
    static let seriesDate: UInt32 = 0x0008_0021
    static let acquisitionDate: UInt32 = 0x0008_0022
    static let contentDate: UInt32 = 0x0008_0023
    static let acquisitionDateTime: UInt32 = 0x0008_002A
    static let studyTime: UInt32 = 0x0008_0030
    static let seriesTime: UInt32 = 0x0008_0031
    static let acquisitionTime: UInt32 = 0x0008_0032
    static let contentTime: UInt32 = 0x0008_0033
    static let accessionNumber: UInt32 = 0x0008_0050
    static let modality: UInt32 = 0x0008_0060
    static let institutionName: UInt32 = 0x0008_0080
    static let referringPhysicianName: UInt32 = 0x0008_0090
    static let codeMeaning: UInt32 = 0x0008_0104
    static let timezoneOffsetFromUTC: UInt32 = 0x0008_0201
    static let studyDescription: UInt32 = 0x0008_1030
    static let procedureCodeSequence: UInt32 = 0x0008_1032
    static let seriesDescription: UInt32 = 0x0008_103E
    static let performingPhysicianName: UInt32 = 0x0008_1050
    static let referencedSOPClassUID: UInt32 = 0x0008_1150
    static let referencedSOPInstanceUID: UInt32 = 0x0008_1155
    static let derivationDescription: UInt32 = 0x0008_2111
    static let sourceImageSequence: UInt32 = 0x0008_2112
    static let patientName: UInt32 = 0x0010_0010
    static let patientID: UInt32 = 0x0010_0020
    static let patientBirthDate: UInt32 = 0x0010_0030
    static let patientSex: UInt32 = 0x0010_0040
    static let patientAge: UInt32 = 0x0010_1010
    static let scanOptions: UInt32 = 0x0018_0022
    static let echoTime: UInt32 = 0x0018_0081
    static let protocolName: UInt32 = 0x0018_1030
    static let acquisitionDeviceProcessingDescription: UInt32 = 0x0018_1400
    static let cardiacSynchronizationSequence: UInt32 = 0x0018_9118
    static let studyInstanceUID: UInt32 = 0x0020_000D
    static let seriesInstanceUID: UInt32 = 0x0020_000E
    static let studyID: UInt32 = 0x0020_0010
    static let seriesNumber: UInt32 = 0x0020_0011
    static let instanceNumber: UInt32 = 0x0020_0013
    static let imagePositionPatient: UInt32 = 0x0020_0032
    static let imageOrientationPatient: UInt32 = 0x0020_0037
    static let imageComments: UInt32 = 0x0020_4000
    static let inStackPositionNumber: UInt32 = 0x0020_9057
    static let frameContentSequence: UInt32 = 0x0020_9111
    static let planePositionSequence: UInt32 = 0x0020_9113
    static let planeOrientationSequence: UInt32 = 0x0020_9116
    static let nominalCardiacTriggerDelayTime: UInt32 = 0x0020_9153
    static let imagePositionVolume: UInt32 = 0x0020_9301
    static let imageOrientationVolume: UInt32 = 0x0020_9302
    static let planePositionVolumeSequence: UInt32 = 0x0020_930E
    static let planeOrientationVolumeSequence: UInt32 = 0x0020_930F
    static let samplesPerPixel: UInt32 = 0x0028_0002
    static let photometricInterpretation: UInt32 = 0x0028_0004
    static let numberOfFrames: UInt32 = 0x0028_0008
    static let rows: UInt32 = 0x0028_0010
    static let columns: UInt32 = 0x0028_0011
    static let pixelSpacing: UInt32 = 0x0028_0030
    static let bitsAllocated: UInt32 = 0x0028_0100
    static let studyComments: UInt32 = 0x0032_4000
    static let performedProcedureStepDescription: UInt32 = 0x0040_0254
    static let encapsulatedDocument: UInt32 = 0x0042_0011
    static let iconImageSequence: UInt32 = 0x0088_0200
    static let interpretationStatusID: UInt32 = 0x4008_0212
    static let sharedFunctionalGroupsSequence: UInt32 = 0x5200_9229
    static let perFrameFunctionalGroupsSequence: UInt32 = 0x5200_9230
    static let floatPixelData: UInt32 = 0x7FE0_0008
    static let doubleFloatPixelData: UInt32 = 0x7FE0_0009
    static let pixelData: UInt32 = 0x7FE0_0010
}

/// The value of a C string the file holds, in an encoding, as
/// +[NSString stringWithCString:encoding:] makes it: nil for bytes the
/// encoding cannot read.
func dicomFileString(_ value: UnsafePointer<CChar>?, _ encoding: String.Encoding) -> NSString? {
    guard let value else { return nil }
    return NSString(cString: value, encoding: encoding.rawValue)
}

/// The reading of a DICOM file for the import: what the database stores of
/// the file (its identifiers, descriptions, dates, size and frames), and the
/// identifiers that group it into a series and a study. DCMTK reads the file
/// through the adapter (Adapters/DCMTK/IsiXDCMTKFile); the rules are the
/// IsiXDICOMFile module's (DICOMImportRules).
@objc(DICOMReading) @implementation extension DicomFile {

    @objc(getDicomFileDCMTK) func getDCMTK() -> Int16 {
        // The adapter's file and the items and bytes that keep it alive are
        // autoreleased: the dataset goes when this file has been read, not when
        // the import's pool drains after a batch.
        autoreleasepool {
            PapyrusLock?.lock()
            let file = try? IsiXDCMTKFile.file(atPath: horos_filePath)
            PapyrusLock?.unlock()
            guard let file else { return -1 }
            return withExtendedLifetime(file) { read(file) ? 0 : -1 }
        }
    }

    // MARK: - The reading

    /// Reads `file` into the state and the elements: whether it has what a
    /// database row needs.
    private final func read(_ file: IsiXDCMTKFile) -> Bool {
        let dataset = file.dataset, meta = file.metaInfo
        let elements = horos_dicomElements
        let path = horos_filePath

        // Both MPEG-2 syntaxes, Main Level and High Level: the viewer decodes
        // neither, and only the first was being recognised.
        let mpeg2: Set<String> = ["1.2.840.10008.1.2.4.100", "1.2.840.10008.1.2.4.101"]
        if let syntax = dicomFileString(meta.string(forTag: DicomFileTag.transferSyntaxUID), .ascii),
           mpeg2.contains(syntax as String) {
            horos_fileType = "DICOMMPEG2"
        } else {
            horos_fileType = "DICOM"
        }
        elements.setObject(horos_fileType as Any, forKey: "fileType" as NSString)

        if let creator = dicomFileString(meta.string(forTag: DicomFileTag.privateInformationCreatorUID), .isoLatin1) {
            elements.setObject(creator, forKey: "PrivateInformationCreatorUID" as NSString)
        }

        // Not Latin-1 outright: a file that states no Specific Character Set is
        // read as whatever DefaultCharacterSetWhenAbsent names, which is empty by
        // default and then means Latin-1 as before.
        var encodings = DICOMCharacterSet.encodings(
            forSpecificCharacterSet: dicomFileString(dataset.string(forTag: DicomFileTag.specificCharacterSet), .isoLatin1) as String?)

        return encodings.withUnsafeMutableBufferPointer { table in
            readAttributes(of: file, dataset: dataset, meta: meta, encodings: table.baseAddress!, path: path)
        }
    }

    /// A text value decoded in the file's character sets (+stringWithBytes:encodings:).
    private final func text(_ value: UnsafePointer<CChar>?, _ encodings: UnsafeMutablePointer<UInt>,
                            replacingBadCharacters: Bool = true) -> NSMutableString? {
        guard let value else { return nil }
        let bytes = UnsafeMutablePointer(mutating: value)
        return replacingBadCharacters ? DicomFile.string(withBytes: bytes, encodings: encodings)
            : DicomFile.string(withBytes: bytes, encodings: encodings, replaceBadCharacters: false)
    }

    private final func readAttributes(of file: IsiXDCMTKFile, dataset: IsiXDCMTKItem, meta: IsiXDCMTKItem,
                                      encodings: UnsafeMutablePointer<UInt>, path: String?) -> Bool {
        let elements = horos_dicomElements
        let fileName = ((path ?? "") as NSString).lastPathComponent
        func set(_ value: Any?, _ key: String) {
            if let value { elements.setObject(value, forKey: key as NSString) }
        }
        func ascii(_ tag: UInt32) -> NSString? { dicomFileString(dataset.string(forTag: tag), .ascii) }
        func latin1(_ tag: UInt32) -> NSString? { dicomFileString(dataset.string(forTag: tag), .isoLatin1) }
        func value(_ tag: UInt32) -> UnsafePointer<CChar>? { dataset.string(forTag: tag) }

        if autoFillComments() {
            readCommentsAutoFill(dataset: dataset, meta: meta, encodings: encodings)
        }

        // SOP Class
        let sopClassUID = ascii(DicomFileTag.sopClassUID) as String?
        set(sopClassUID, "SOPClassUID")

        // Image Type
        var imageTypeArray: NSMutableArray?
        if let imageType = latin1(DicomFileTag.imageType) {
            imageTypeArray = NSMutableArray(array: imageType.components(separatedBy: "\\"))
            if let types = imageTypeArray, types.count > 2 {
                horos_imageType = types[2] as? NSString
            }
        } else {
            horos_imageType = nil
        }
        set(horos_imageType, "imageType")

        horos_sopUID = latin1(DicomFileTag.sopInstanceUID)
        set(horos_sopUID, "SOPUID")

        // Study Description, or the meaning of the first procedure code
        if let description = value(DicomFileTag.studyDescription) {
            horos_study = text(description, encodings)
        } else if let procedure = dataset.item(at: 0, ofSequence: DicomFileTag.procedureCodeSequence),
                  let meaning = procedure.string(forTag: DicomFileTag.codeMeaning) {
            horos_study = text(meaning, encodings)
        }
        if horos_study == nil { horos_study = "unnamed" }
        set(horos_study, "studyDescription")

        horos_modality = value(DicomFileTag.modality) != nil ? ascii(DicomFileTag.modality) : "OT"
        set(horos_modality, "modality")

        readStudyDate(dataset: dataset, fileName: fileName)

        // Series Description
        if let description = value(DicomFileTag.seriesDescription) {
            horos_serie = text(description, encodings)
        } else if let description = value(DicomFileTag.performedProcedureStepDescription) {
            horos_serie = text(description, encodings)
        } else if let description = value(DicomFileTag.acquisitionDeviceProcessingDescription) {
            horos_serie = text(description, encodings)
        } else if horos_serie == nil {
            horos_serie = "unnamed"
        }
        set(horos_serie, "seriesDescription")

        if let institution = value(DicomFileTag.institutionName) {
            set(text(institution, encodings), "institutionName")
        }
        if let physician = value(DicomFileTag.referringPhysicianName) {
            set(text(physician, encodings), "referringPhysiciansName")
        }
        if let physician = value(DicomFileTag.performingPhysicianName) {
            set(text(physician, encodings), "performingPhysiciansName")
        }
        if let accession = value(DicomFileTag.accessionNumber) {
            set(text(accession, encodings, replacingBadCharacters: false), "accessionNumber")
        }

        if let patient = value(DicomFileTag.patientName) {
            horos_name = text(patient, encodings, replacingBadCharacters: false)
            if horos_name == nil { horos_name = NSString(cString: patient, encoding: encodings[0]) }
        } else {
            horos_name = "No name"
        }
        set(horos_name, "patientName")

        if let patient = value(DicomFileTag.patientID) {
            horos_patientID = text(patient, encodings, replacingBadCharacters: false)
            set(horos_patientID, "patientID")
        }
        if value(DicomFileTag.patientAge) != nil {
            set(ascii(DicomFileTag.patientAge), "patientAge")
        }
        if let birthDate = ascii(DicomFileTag.patientBirthDate) {
            set(DICOMCalendarDate.date(with: birthDate as String, calendarFormat: "%Y%m%d"), "patientBirthDate")
        }
        if value(DicomFileTag.patientSex) != nil {
            set(ascii(DicomFileTag.patientSex), "patientSex")
        }

        var cardiacTime = -1
        if let options = value(DicomFileTag.scanOptions) {
            cardiacTime = DICOMImportRules.cardiacTime(scanOptions: Array(UnsafeBufferPointer(start: options, count: strlen(options)))
                .map { UInt8(bitPattern: $0) })
            set(NSNumber(value: cardiacTime), "cardiacTime")
        }

        if let protocolName = value(DicomFileTag.protocolName) {
            var name: NSString? = text(protocolName, encodings)
            if name == nil { name = NSString(cString: protocolName, encoding: encodings[0]) }
            set(name, "protocolName")
        }

        let echoTime = value(DicomFileTag.echoTime) != nil ? ascii(DicomFileTag.echoTime) as String? : nil

        if value(DicomFileTag.instanceNumber) != nil {
            horos_imageID = DICOMImportRules.imageIdentifier(instanceNumber: ascii(DicomFileTag.instanceNumber)?.intValue ?? 0)
        } else {
            horos_imageID = nil
        }

        // The slice location, from the position and the orientation the file states.
        var origin = [Double](repeating: 0, count: 3)
        var orientation: [Double] = [1, 0, 0, 0, 1, 0]
        _ = origin.withUnsafeMutableBufferPointer {
            dataset.getFloat64Values($0.baseAddress!, count: 3, forTag: DicomFileTag.imagePositionPatient)
        }
        _ = orientation.withUnsafeMutableBufferPointer {
            dataset.getFloat64Values($0.baseAddress!, count: 6, forTag: DicomFileTag.imageOrientationPatient)
        }
        let location = DICOMImportRules.sliceLocation(origin: origin, orientation: orientation)
        set(NSNumber(value: location), "sliceLocation")

        if DICOMImportRules.needsLocationIdentifier(horos_imageID) {
            horos_imageID = DICOMImportRules.imageIdentifier(sliceLocation: location)
        }
        set(NSNumber(value: Int((horos_imageID as NSString?)?.intValue ?? 0)), "imageID")

        horos_seriesNo = value(DicomFileTag.seriesNumber) != nil ? ascii(DicomFileTag.seriesNumber) : "0"
        if let seriesNo = horos_seriesNo {
            set(NSNumber(value: seriesNo.intValue), "seriesNumber")
        }

        // The series this file is grouped in.
        if let seriesUID = ascii(DicomFileTag.seriesInstanceUID) {
            serieID = seriesUID as String
            set(seriesUID, "seriesDICOMUID")
        } else {
            serieID = horos_name as String?
        }
        var grouping = DICOMImportRules.SeriesGrouping()
        grouping.seriesInstanceUID = serieID
        grouping.cardiacTime = cardiacTime
        grouping.separateCardiac4D = separateCardiac4D()
        grouping.modality = horos_modality as String?
        grouping.seriesNumber = horos_seriesNo as String?
        grouping.imageType = horos_imageType as String?
        grouping.seriesDescription = horos_serie as String?
        grouping.useSeriesDescription = useSeriesDescription()
        if let sopClassUID, (DICOMSOPClass.hiddenImageSyntaxes() as NSArray?)?.contains(sopClassUID) == true {
            grouping.hiddenSOPClassUID = sopClassUID
        }
        grouping.echoTime = echoTime
        grouping.splitMultiEchoMR = splitMultiEchoMR()
        serieID = grouping.identifier

        // The study.
        if value(DicomFileTag.studyInstanceUID) != nil {
            horos_studyID = ascii(DicomFileTag.studyInstanceUID) as String?
        } else {
            // The patient's name used to stand in for the identifier, and it is
            // what the C-FIND SCP then answers with as a UI. Derived from the
            // same name, so files that grouped together still do, but a value
            // that UI can hold.
            horos_studyID = DerivedUID.studyUID(forKey: horos_name as String?)
            NSLog("---- %@ has no StudyInstanceUID; indexed under %@", fileName, horos_studyID ?? "(null)")
        }
        set(horos_studyID, "studyID")

        horos_studyIDs = value(DicomFileTag.studyID) != nil ? ascii(DicomFileTag.studyID) : "0"
        set(horos_studyIDs, "studyNumber")

        if commentsFromDICOMFiles() {
            if value(DicomFileTag.studyComments) != nil { set(ascii(DicomFileTag.studyComments), "studyComments") }
            if value(DicomFileTag.imageComments) != nil { set(ascii(DicomFileTag.imageComments), "seriesComments") }
            if value(DicomFileTag.interpretationStatusID) != nil {
                set(NSNumber(value: ascii(DicomFileTag.interpretationStatusID)?.intValue ?? 0), "stateText")
            }
        }

        var rows: UInt16 = 0, columns: UInt16 = 0
        if dataset.getUInt16(&rows, forTag: DicomFileTag.rows, index: 0) { horos_height = Int(rows) }
        if dataset.getUInt16(&columns, forTag: DicomFileTag.columns, index: 0) { horos_width = Int(columns) }
        if let frames = value(DicomFileTag.numberOfFrames) { horos_numberOfFrames = Int(atoi(frames)) }

        readPixelDataProblem(of: file, dataset: dataset, rows: rows, columns: columns, sopClassUID: sopClassUID,
                             fileName: fileName)
        readFrames(of: dataset)

        // An encapsulated PDF takes its page count and size from the document.
        if sopClassUID == DICOMSOPClass.pdfStorageClassUID() {
            if let document = dataset.bytes(forTag: DicomFileTag.encapsulatedDocument), document.count > 0 {
                adoptRenderedDocument(NSPDFImageRep(data: document), elements: elements)
            } else {
                adoptRenderedDocument(nil, elements: elements)
            }
        }

        if let sopClassUID, sopClassUID.hasPrefix("1.2.840.10008.5.1.4.1.1.88") {
            readStructuredReport(sopClassUID: sopClassUID, path: path)
        }

        horos_numberOfSeries = 1
        if horos_patientID == nil { horos_patientID = "" }

        if horos_numberOfFrames > 1 { // SERIES ID MUST BE UNIQUE!!!!!
            serieID = String(format: "%@-%@-%@", serieID ?? "(null)", horos_imageID ?? "(null)",
                             (elements.object(forKey: "SOPUID") as? String) ?? "(null)")
        }

        if horos_numberOfFrames <= 1 && noLocalizer()
            && (contains("LOCALIZER", in: imageTypeArray as? [Any]) || contains("REF", in: imageTypeArray as? [Any])
                || containsLocalizer(in: horos_serie as String?))
            && DICOMSOPClass.isImageStorage(sopClassUID) {
            serieID = "LOCALIZER"
            horos_serie = "Localizers"
            set(horos_serie, "seriesDescription")
            // seriesDICOMUID keeps the SeriesInstanceUID read from the file. It
            // used to be overwritten with "LOCALIZER" and the study identifier,
            // and that value is what the C-FIND SCP answers with: 74 characters
            // of letters and digits, where UI allows 64 and only digits and
            // dots. The grouping that puts the localizers of a study in one
            // series is serieID, above, which the importer matches on; the DICOM
            // identifier is stored beside it and is not what merges anything.
        }

        set(patientUID(), "patientUID")

        if serieID == nil { serieID = horos_name as String? }

        // Same for the series. seriesDICOMUID is only set above when the file
        // carries one, so a file without it produced a series row whose DICOM
        // identifier was empty - and an empty UI in every C-FIND answer about
        // it. Derived from what the importer groups this series on, so the
        // grouping is unchanged and re-importing the file lands in the same
        // series.
        if ((elements.object(forKey: "seriesDICOMUID") as? NSString)?.length ?? 0) == 0 {
            let derived = DerivedUID.seriesUID(forKey: String(format: "%@|%@", horos_studyID ?? "(null)",
                                                              serieID ?? "(null)"))
            set(derived, "seriesDICOMUID")
            NSLog("---- %@ has no SeriesInstanceUID; indexed under %@", fileName, derived)
        }

        groupSeries(sopClassUID: sopClassUID, fileName: fileName)

        if horos_studyID == nil {
            horos_studyID = horos_name as String?
            set(horos_studyID, "studyID")
        }
        if horos_imageID == nil {
            horos_imageID = horos_name as String?
            set(horos_imageID, "SOPUID")
        }
        if horos_date == nil {
            horos_date = DICOMCalendarDate.date(withYear: 1901, month: 1, day: 1, hour: 0, minute: 0, second: 0,
                                              timeZone: nil) as NSDate?
            set(horos_date, "studyDate")
        }
        set(NSNumber(value: true), "hasDICOM")

        return horos_name != nil && horos_studyID != nil && serieID != nil && horos_imageID != nil
            && horos_width != 0 && horos_height != 0
    }

    // MARK: - Parts of the reading

    /// The comments the preferences name, up to four attributes joined by " / ".
    private final func readCommentsAutoFill(dataset: IsiXDCMTKItem, meta: IsiXDCMTKItem,
                                            encodings: UnsafeMutablePointer<UInt>) {
        let elements = horos_dicomElements
        let pairs = [(commentsGroup(), commentsElement()), (commentsGroup2(), commentsElement2()),
                     (commentsGroup3(), commentsElement3()), (commentsGroup4(), commentsElement4())]
        var comments: NSString?
        for (index, (group, element)) in pairs.enumerated() where group != 0 && element != 0 {
            let tag = (UInt32(truncatingIfNeeded: group) & 0xffff) << 16 | (UInt32(truncatingIfNeeded: element) & 0xffff)
            let items = group == 2 ? meta : dataset // the meta header
            guard let value = items.string(forTag: tag) else { continue }
            let decoded = text(value, encodings)
            if index == 0 {
                comments = decoded
                continue
            }
            if let current = comments {
                comments = current.appendingFormat(" / %@", decoded ?? "(null)" as NSString)
            } else {
                comments = decoded
            }
            if let comments { elements.setObject(comments, forKey: "commentsAutoFill" as NSString) }
        }
        if let comments { elements.setObject(comments, forKey: "commentsAutoFill" as NSString) }
    }

    /// The study's date and time: the acquisition's, else the content's, the
    /// series' or the study's, read as DICOM DA and TM.
    private final func readStudyDate(dataset: IsiXDCMTKItem, fileName: String) {
        func first(_ tags: [UInt32], _ accept: (UnsafePointer<CChar>) -> Bool) -> NSString? {
            for tag in tags {
                if let value = dataset.string(forTag: tag), strlen(value) > 0, accept(value) {
                    return dicomFileString(value, .ascii)
                }
            }
            return nil
        }
        var studyDate = first([DicomFileTag.acquisitionDate, DicomFileTag.contentDate, DicomFileTag.seriesDate,
                               DicomFileTag.studyDate]) { _ in true }
        if let date = studyDate, date.length != 8 {
            studyDate = date.replacingOccurrences(of: ".", with: "") as NSString
        }
        var studyTime = first([DicomFileTag.acquisitionTime, DicomFileTag.contentTime, DicomFileTag.seriesTime,
                               DicomFileTag.studyTime]) { atof($0) > 0 }
        studyTime = studyTime.map { $0.replacingOccurrences(of: ":", with: "") as NSString }

        // Most CT, MR and PET equipment writes the time with a fraction of a
        // second (103015.123456), and some writes only HHMM or HH: the date and
        // the time are read as DICOM DA and TM, not as one fixed pattern.
        if let studyDate {
            horos_date = DICOMCalendarDate.dicomDate(studyDate as String, time: studyTime as String?) as NSDate?
        } else {
            horos_date = DICOMCalendarDate.date(withYear: 1901, month: 1, day: 1, hour: 0, minute: 0, second: 0,
                                              timeZone: nil) as NSDate?
        }

        // A date that is there and cannot be read ends the same way as no date
        // at all - the study is filed without one, because 1901 is the marker
        // the importer refuses to store. The difference is worth a line: one is
        // a study that never carried a date, the other is a file whose date this
        // could not make sense of.
        if horos_date == nil && ((studyDate?.length ?? 0) > 0 || (studyTime?.length ?? 0) > 0) {
            NSLog("---- %@: the study date could not be read (date \"%@\", time \"%@\"); the study is filed without one",
                  fileName, studyDate ?? "", studyTime ?? "")
        }
        if let date = horos_date { horos_dicomElements.setObject(date, forKey: "studyDate" as NSString) }
    }

    /// What is said of an image object whose pixels are missing, short, or
    /// somewhere this application does not read them, and of an object of a
    /// kind it does not show.
    private final func readPixelDataProblem(of file: IsiXDCMTKFile, dataset: IsiXDCMTKItem, rows: UInt16,
                                            columns: UInt16, sopClassUID: String?, fileName: String) {
        let elements = horos_dicomElements
        // An image object that declares a size and carries nothing to fill it is
        // indexed like any other and counted in the study's image total, and
        // nothing anywhere says it has no picture in it. It stays indexed -
        // refusing it would lose everything else the file carries - but it is
        // named. An object that states Rows and Columns is claiming to be a
        // picture, whatever its SOP class is called.
        let claimsAPicture = rows > 0 || columns > 0
        if claimsAPicture && (rows == 0 || columns == 0) {
            let problem = DICOMImportRules.pixelDataProblem(columns: columns, rows: rows, bitsAllocated: 0,
                                                            samplesPerPixel: 0, frames: horos_numberOfFrames,
                                                            pixels: .encapsulated)
            elements.setObject(problem as Any, forKey: "pixelDataProblem" as NSString)
            NSLog("---- %@: %@", fileName, problem ?? "(null)")
        } else if claimsAPicture {
            var allocated: UInt16 = 0, samples: UInt16 = 1
            dataset.getUInt16(&allocated, forTag: DicomFileTag.bitsAllocated, index: 0)
            dataset.getUInt16(&samples, forTag: DicomFileTag.samplesPerPixel, index: 0)
            var length: UInt = 0
            let pixels: DICOMImportRules.PixelData
            if !dataset.hasElement(forTag: DicomFileTag.pixelData, length: &length) {
                // Float Pixel Data and Double Float Pixel Data are pixel data, and
                // an object that carries them carries a picture; an icon is a
                // preview of the image, not the image (PS 3.3 C.7.6.1.1.6).
                var icon: (columns: UInt16, rows: UInt16)?
                if let item = dataset.item(at: 0, ofSequence: DicomFileTag.iconImageSequence) {
                    var iconRows: UInt16 = 0, iconColumns: UInt16 = 0
                    item.getUInt16(&iconRows, forTag: DicomFileTag.rows, index: 0)
                    item.getUInt16(&iconColumns, forTag: DicomFileTag.columns, index: 0)
                    icon = (iconColumns, iconRows)
                }
                pixels = .absent(floatPixels: dataset.hasElement(forTag: DicomFileTag.floatPixelData, length: nil),
                                 doubleFloatPixels: dataset.hasElement(forTag: DicomFileTag.doubleFloatPixelData, length: nil),
                                 icon: icon)
            } else if file.originalTransferSyntaxIsNative {
                pixels = .native(length: length)
            } else {
                // Encapsulated pixel data lives in fragments, and the element
                // itself reports no length: only its absence says anything.
                pixels = .encapsulated
            }
            let photometric = dataset.string(forTag: DicomFileTag.photometricInterpretation).map { String(cString: $0) }
            if let problem = DICOMImportRules.pixelDataProblem(columns: columns, rows: rows, bitsAllocated: allocated,
                                                               samplesPerPixel: samples,
                                                               photometricInterpretation: photometric,
                                                               frames: horos_numberOfFrames, pixels: pixels) {
                elements.setObject(problem, forKey: "pixelDataProblem" as NSString)
                NSLog("---- %@: %@; it is indexed and counted as an image anyway", fileName, problem)
            }
        } else if let sopClassUID, !sopClassUID.isEmpty,
                  !DICOMSOPClass.isImageStorage(sopClassUID), !DICOMSOPClass.isStructuredReport(sopClassUID),
                  !DICOMSOPClass.isPDF(sopClassUID), !DICOMSOPClass.isPresentationState(sopClassUID),
                  !DICOMSOPClass.isRadiotherapy(sopClassUID), !DICOMSOPClass.isWaveform(sopClassUID),
                  !DICOMSOPClass.isDirectory(sopClassUID) {
            // An instance that is not a picture and is not one of the kinds this
            // application shows is still received, still kept and still listed,
            // as a series with nothing to look at. The SOP class it came as is
            // what lets it be found again.
            let problem = DICOMImportRules.undisplayableObjectProblem(sopClassUID: sopClassUID)
            elements.setObject(problem, forKey: "pixelDataProblem" as NSString)
            NSLog("---- %@: %@", fileName, problem)
        }
    }

    /// The slice location, the trigger delay and the place in its stack of each
    /// frame of a multiframe object, from its functional groups.
    private final func readFrames(of dataset: IsiXDCMTKItem) {
        let elements = horos_dicomElements
        let sliceLocations = NSMutableArray(), triggers = NSMutableArray()
        // Where each frame sits in its stack, if the acquisition says so. Without
        // it a frame's instance number is only its place in the file.
        let stackPositions = NSMutableArray()

        var originMultiFrame = [Double](repeating: 0, count: 3)
        var orientationMultiFrame: [Double] = [1, 0, 0, 0, 1, 0]
        var sharedOrientation: [Double] = [1, 0, 0, 0, 1, 0]
        var hasSharedOrientation = false
        func readValues(_ values: inout [Double], _ count: Int, _ tag: UInt32, of item: IsiXDCMTKItem) -> Int {
            values.withUnsafeMutableBufferPointer { Int(item.getFloat64Values($0.baseAddress!, count: UInt(count), forTag: tag)) }
        }

        // An Enhanced CT or MR states the orientation once, in the shared
        // groups, because every frame shares it, and gives each frame only its
        // position. ImageOrientationVolume lives in PlaneOrientationVolumeSequence.
        if let shared = dataset.item(at: 0, ofSequence: DicomFileTag.sharedFunctionalGroupsSequence) {
            if let plane = shared.item(at: 0, ofSequence: DicomFileTag.planeOrientationSequence) {
                hasSharedOrientation = readValues(&sharedOrientation, 6, DicomFileTag.imageOrientationPatient, of: plane) == 6
            }
            if !hasSharedOrientation, let plane = shared.item(at: 0, ofSequence: DicomFileTag.planeOrientationVolumeSequence) {
                let count = readValues(&sharedOrientation, 6, DicomFileTag.imageOrientationVolume, of: plane)
                hasSharedOrientation = count == 6
                if count != 6 && count != 0 { NSLog("******* DCM_ImageOrientationVolume : count != 6 && count != 0") }
            }
            if hasSharedOrientation { orientationMultiFrame = sharedOrientation }
        }

        // Per frame
        var index = 0
        var frame: IsiXDCMTKItem?
        repeat {
            frame = dataset.item(at: index, ofSequence: DicomFileTag.perFrameFunctionalGroupsSequence)
            index += 1
            guard let frameItem = frame else { continue }
            var x = 0
            var item: IsiXDCMTKItem?
            repeat {
                item = frameItem.item(at: x, ofSequence: DicomFileTag.cardiacSynchronizationSequence)
                if let trigger = item {
                    var delay = 0.0
                    if trigger.getFloat64(&delay, forTag: DicomFileTag.nominalCardiacTriggerDelayTime, index: 0) {
                        triggers.add(String(format: "%lf", delay))
                    }
                }
                if x == 0 {
                    item = frameItem.item(at: 0, ofSequence: DicomFileTag.frameContentSequence)
                    if let content = item {
                        var position: UInt32 = 0
                        if content.getUInt32(&position, forTag: DicomFileTag.inStackPositionNumber, index: 0) {
                            stackPositions.add(NSNumber(value: position))
                        }
                    }
                }

                var succeed = true
                item = frameItem.item(at: x, ofSequence: DicomFileTag.planePositionVolumeSequence)
                if let position = item {
                    if readValues(&originMultiFrame, 3, DicomFileTag.imagePositionVolume, of: position) != 3 { succeed = false }
                } else {
                    succeed = false
                }
                if !succeed {
                    succeed = true
                    item = frameItem.item(at: x, ofSequence: DicomFileTag.planePositionSequence)
                    if let position = item {
                        if readValues(&originMultiFrame, 3, DicomFileTag.imagePositionPatient, of: position) != 3 { succeed = false }
                    } else {
                        succeed = false
                    }
                    item = frameItem.item(at: x, ofSequence: DicomFileTag.planeOrientationSequence)
                    if let plane = item {
                        let count = readValues(&orientationMultiFrame, 6, DicomFileTag.imageOrientationPatient, of: plane)
                        if count != 6 && count != 0 { succeed = false }
                    } else if hasSharedOrientation {
                        // The frame carries only its position, which is what the
                        // shared orientation is there for.
                        orientationMultiFrame = sharedOrientation
                    } else {
                        succeed = false
                    }
                }
                if succeed {
                    let location = Float(DICOMImportRules.sliceLocation(origin: originMultiFrame,
                                                                         orientation: orientationMultiFrame))
                    sliceLocations.add(NSNumber(value: location))
                }
                x += 1
            } while item != nil
        } while frame != nil

        let frames = horos_numberOfFrames
        if sliceLocations.count > 0 {
            if frames == sliceLocations.count {
                elements.setObject(sliceLocations, forKey: "sliceLocationArray" as NSString)
            } else {
                NSLog("*** NoOfFrames != sliceLocationArray.count for MR/CT/US multiframe sliceLocation computation (%d, %d)",
                      Int32(truncatingIfNeeded: frames), Int32(truncatingIfNeeded: sliceLocations.count))
            }
        }
        // Only if every frame said where it sits, and no two said the same thing:
        // an object with several stacks numbers each of them from one, and a
        // repeated number would sort no better than the frame index does.
        if stackPositions.count == frames && frames > 1 && NSSet(array: stackPositions as [AnyObject]).count == stackPositions.count {
            elements.setObject(stackPositions, forKey: "instanceNumberArray" as NSString)
        }
        if triggers.count > 0 {
            if frames == triggers.count {
                elements.setObject(triggers, forKey: "imageCommentPerFrame" as NSString)
            } else {
                NSLog("*** NoOfFrames != imageCardiacTriggerArray.count for MR/CT multiframe image type frame computation (%d, %d)",
                      Int32(truncatingIfNeeded: frames), Int32(truncatingIfNeeded: triggers.count))
            }
        }
    }

    /// A structured report: rendered when the database shows it as a document,
    /// with the image it refers to and, for an ROI report, the ROIs it holds.
    private final func readStructuredReport(sopClassUID: String, path: String?) {
        let elements = horos_dicomElements
        if DicomStudy.displaySeries(withSOPClassUID: sopClassUID,
                                    andSeriesDescription: elements.object(forKey: "seriesDescription") as? String) {
            adoptRenderedDocument(pdfImageRep(), elements: elements)
        }
        if let referenced = SRAnnotation.getImageRefSOPInstanceUID(path) {
            elements.setObject(referenced, forKey: "referencedSOPInstanceUID" as NSString)
        }
        if let exception = HorosObjCException.caught({
            guard (elements.object(forKey: "seriesDescription") as? NSString)?.hasPrefix("OsiriX ROI SR") == true else { return }
            if let referenced = SRAnnotation.getImageRefSOPInstanceUID(path) {
                elements.setObject(referenced, forKey: "referencedSOPInstanceUID" as NSString)
            }
            // An SR without ROI data hands back nil, which the unarchiver does not survive.
            let roiData = SRAnnotation.roi(fromDICOM: path)
            let count = RestrictedUnarchiver.unarchiveROIs(with: roiData)?.count ?? 0
            elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: count)), forKey: "numberOfROIs" as NSString)
        }) {
            _N2LogExceptionImpl(exception, true, "-[DicomFile(DICOMReading) getDicomFileDCMTK]")
        }
    }

    /// Where the import files the series: the file alone for ultrasound when
    /// the preferences say so, one series for the projection images of a study
    /// or one per image, or the grouping identifier.
    private final func groupSeries(sopClassUID: String?, fileName: String) {
        let elements = horos_dicomElements
        let modality = horos_modality as String?
        if modality == "US" && oneFileOnSeriesForUS() {
            elements.setObject((serieID ?? "") + fileName, forKey: "seriesID" as NSString)
        } else if combineProjectionSeries() && ["MG", "CR", "DR", "DX", "RF"].contains(modality ?? "") {
            if !combineProjectionSeriesMode() { // Combine all CR and DR Modality series in a study into one series
                if let sopClassUID, (DICOMSOPClass.hiddenImageSyntaxes() as NSArray?)?.contains(sopClassUID) == true {
                    elements.setObject(serieID as Any, forKey: "seriesID" as NSString)
                } else {
                    elements.setObject(horos_studyID as Any, forKey: "seriesID" as NSString)
                }
                let series = ((serieID ?? "") as NSString).intValue, image = ((horos_imageID ?? "") as NSString).intValue
                elements.setObject(NSNumber(value: Int(series &* 1000 &+ image)), forKey: "imageID" as NSString)
            } else { // Split all CR and DR Modality series in a study into one series
                elements.setObject((serieID ?? "") + (horos_imageID ?? ""), forKey: "seriesID" as NSString)
            }
        } else {
            elements.setObject(serieID as Any, forKey: "seriesID" as NSString)
        }
    }

    // MARK: - Documents

    /// A PDF-backed object takes its page count and size from the rendered
    /// document. One that renders to nothing - no pages, or an empty image -
    /// used to come out 0x0, which the parser reports as unreadable and the
    /// import deletes by default (DELETEFILELISTENER). It is a DICOM object like
    /// any other: it keeps the 1x1 placeholder and says why it cannot be shown,
    /// as a non-image class does.
    private final func adoptRenderedDocument(_ rep: NSPDFImageRep?, elements: NSMutableDictionary) {
        let pages = rep?.pageCount ?? 0
        var width = 0, height = 0
        if pages > 0, let rep {
            let image = NSImage()
            image.addRepresentation(rep)
            let bitmap = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
            if let bitmap, CGFloat(bitmap.pixelsWide) > image.size.width {
                height = bitmap.pixelsHigh
                width = bitmap.pixelsWide
            } else {
                height = Int(image.size.height)
                width = Int(image.size.width)
            }
        }
        if pages > 0 && width > 0 && height > 0 {
            horos_numberOfFrames = pages
            horos_width = width
            horos_height = height
            return
        }
        let problem = "its document could not be rendered, so it is kept but cannot be displayed"
        elements.setObject(problem, forKey: "pixelDataProblem" as NSString)
        NSLog("---- %@: %@", ((horos_filePath ?? "") as NSString).lastPathComponent, problem)
    }
}
