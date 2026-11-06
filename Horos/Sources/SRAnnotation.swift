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
import CoreData
import IsiXDICOMFile

/// The structured reports a study keeps: its annotations, its ROIs, its
/// windows state and its report. This file assembles them - which document,
/// which items, which header values from the image's file or from the study -
/// and DCMTK holds, reads and writes each document through the adapter
/// (IsiXDCMTKStructuredReport). The selectors are those of SRAnnotation.h.
@objc @implementation extension SRAnnotation {

    // MARK: - State

    final var horos_document = IsiXDCMTKStructuredReport()
    /// The image the report refers to, a DicomImage read by key: any object
    /// that answers those keys serves, as +archiveROIsAsDICOM: takes one.
    final var horos_image: NSObject?
    /// The document is new: its series and instance UIDs are made when written.
    final var horos_newSR = false
    final var horos_seriesInstanceUID: String?
    final var horos_description: String?
    final var horos_seriesNumber: String?
    final var horos_reportURL: String?
    // NSData and NSDate: an @implementation cannot store the resilient Data and Date.
    final var horos_dataEncapsulated: NSData?
    final var horos_contentDate: NSDate?

    // MARK: - Reading a report file

    @objc(roiFromDICOM:)
    class func roi(fromDICOM path: String!) -> Data! {
        guard let path else { return nil }
        return IsiXDCMTKStructuredReport.archivedData(ofFileAtPath: path)
    }

    /// All the ROIs of an image are archived as one array. The report is made
    /// with what it needs of them before the archive is added.
    @objc(archiveROIsAsDICOM:toPath:forImage:)
    class func archiveROIs(asDICOM rois: [Any]!, toPath path: String!, forImage image: Any!) -> String! {
        // The image is only kept by the initializer and read by key when the
        // report is written; it is set apart so that any object serves.
        let sr = SRAnnotation(rois: rois, path: path, forImage: nil)
        sr?.horos_image = image as? NSObject
        let study = (image as? NSObject)?.value(forKeyPath: "series.study") as? NSObject
        let roiSRSeries = study?.perform(NSSelectorFromString("roiSRSeries"))?.takeUnretainedValue() as? NSObject
        if let seriesInstanceUID = roiSRSeries?.value(forKey: "seriesDICOMUID") as? String {
            sr?.setSeriesInstanceUID(seriesInstanceUID)
        }
        _ = sr?.writeToFile(atPath: path)
        return nil
    }

    @objc(getImageRefSOPInstanceUID:)
    class func getImageRefSOPInstanceUID(_ path: String!) -> String! {
        let document = IsiXDCMTKStructuredReport()
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        var loaded: ObjCBool = false
        _ = document.readFile(atPath: path, loaded: &loaded, encapsulatedDocument: nil)
        guard loaded.boolValue else { return nil }
        let instanceNumber = formattedCString(document.value(of: .instanceNumber)).intValue
        guard let reference = document.referencedInstanceOfItem(withCode: "IHE.10", scheme: "99HUG",
                                                                meaning: "Image Reference") else { return nil }
        let result = formattedCString(reference)
        return result.length > 0 ? result.appendingFormat("-%d", instanceNumber) as String : nil
    }

    @objc(getReportFilenameFromSR:)
    class func getReportFilename(fromSR path: String!) -> String! {
        let document = IsiXDCMTKStructuredReport()
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        var loaded: ObjCBool = false
        _ = document.readFile(atPath: path, loaded: &loaded, encapsulatedDocument: nil)
        guard loaded.boolValue else { return nil }
        let accessionNumber = formattedCString(document.value(of: .accessionNumber))
        let studyInstanceUID = formattedCString(document.value(of: .studyInstanceUID))
        let patientName = formattedCString(document.value(of: .patientName))
        let patientID = formattedCString(document.value(of: .patientID))
        let patientDOB = formattedCString(document.value(of: .patientBirthDate))
        let record = NSMutableDictionary(dictionary: ["patientName": patientName, "accessionNumber": accessionNumber,
                                                      "patientID": patientID, "studyInstanceUID": studyInstanceUID])
        if let birthDate = DICOMDateTimeText.parseDate(patientDOB as String) {
            record["patientBirthDate"] = birthDate
        }
        return DicomFile.patientUID(record)
    }

    // MARK: - Initializers

    override init() {
        super.init()
        horos_document.createNewDocument(.comprehensive)
        horos_document.addRootContainer(withCode: "1", scheme: "99HUG", meaning: "Annotations")
        horos_newSR = true
    }

    @objc(initWithDictionary:path:forImage:)
    init!(dictionary dict: [AnyHashable: Any]!, path: String!, for im: DicomImage!) {
        super.init()
        horos_description = "OsiriX Annotations SR"
        horos_seriesNumber = "5004"
        reuseOrCreateDocument(path)
        horos_document.addRootContainer(withCode: "1", scheme: "99HUG", meaning: "Annotations")
        horos_document.addText(withCode: "CODE_01", scheme: offisCodingScheme, meaning: "Description",
                               value: dict.map { String(format: "%@", $0 as NSDictionary) } ?? "(null)")
        horos_image = im
        if let dict {
            horos_dataEncapsulated = (try? PropertyListSerialization.data(fromPropertyList: dict as NSDictionary,
                                                                         format: .xml, options: 0)) as NSData?
        }
    }

    @objc(initWithWindowsState:path:forImage:)
    init!(windowsState dict: Data!, path: String!, for im: DicomImage!) {
        super.init()
        horos_description = "OsiriX WindowsState SR"
        horos_seriesNumber = "5006"
        reuseOrCreateDocument(path)
        horos_document.addRootContainer(withCode: "1", scheme: "99HUG", meaning: "Windows State")
        horos_document.addText(withCode: "CODE_01", scheme: offisCodingScheme, meaning: "Description", value: nil)
        horos_image = im
        horos_dataEncapsulated = dict as NSData?
    }

    @objc(initWithFileReport:path:forImage:contentDate:)
    init!(fileReport file: String!, path: String!, for im: DicomImage!, contentDate d: Date!) {
        super.init()
        horos_description = "OsiriX Report SR"
        horos_seriesNumber = "5003"
        if let file {
            horos_dataEncapsulated = NSData(contentsOfFile: file)
            horos_contentDate = d as NSDate?
        }
        reuseOrCreateDocument(path)
        let fileExtension = (file as NSString?)?.pathExtension ?? "(null)"
        horos_document.addRootContainer(withCode: "1", scheme: "99HUG",
                                        meaning: "Study Report - \(fileExtension) File Format")
        horos_image = im
    }

    @objc(initWithROIs:path:forImage:)
    init!(rois ROIs: [Any]!, path: String!, forImage im: NSManagedObject!) {
        super.init()
        horos_description = "OsiriX ROI SR"
        horos_seriesNumber = "5002"
        reuseOrCreateDocument(path)
        horos_document.addRootContainer(withCode: "1", scheme: "99HUG", meaning: "ROI Annotations")
        horos_image = im
        addROIs(ROIs)
    }

    @objc(initWithContentsOfFile:)
    init!(contentsOfFile path: String!) {
        guard let path else {
            N2LogStackTraceMessage("SRAnnotation initWithContentsOfFile, path == nil")
            return nil
        }
        super.init()
        guard FileManager.default.fileExists(atPath: path) else { return }
        var encapsulated: NSData?
        _ = horos_document.readFile(atPath: path, loaded: nil, encapsulatedDocument: &encapsulated)
        if let encapsulated {
            // What the former @try around the copy of the bytes logged.
            if let exception = HorosObjCException.caught({ self.horos_dataEncapsulated = encapsulated }) {
                NSLog("******* SRAnnotation exception: %@", exception.description)
            }
        }
        let meaning = horos_document.currentConceptMeaning as NSString?
        let prefix = "URL:"
        horos_reportURL = meaning?.hasPrefix(prefix) == true ? meaning?.substring(from: (prefix as NSString).length) : nil
    }

    @objc(initWithURLReport:path:forImage:)
    init!(urlReport s: String!, path: String!, for im: DicomImage!) {
        super.init()
        horos_description = "OsiriX Report SR"
        horos_seriesNumber = "5003"
        horos_contentDate = NSDate()
        reuseOrCreateDocument(path)
        horos_document.addRootContainer(withCode: "1", scheme: "99HUG", meaning: "URL:" + (s ?? "(null)"))
        horos_image = im
    }

    /// The report already at `path` keeps its UIDs with its tree emptied; a
    /// missing or unreadable one is replaced by a new Basic Text document.
    final func reuseOrCreateDocument(_ path: String?) {
        horos_newSR = false
        var read = true
        if let path, FileManager.default.fileExists(atPath: path) {
            read = horos_document.readFile(atPath: path, loaded: nil, encapsulatedDocument: nil)
            if read { horos_document.clearTree() }
        }
        if !(path.map { FileManager.default.fileExists(atPath: $0) } ?? false) || !read {
            horos_newSR = true
            horos_document.createNewDocument(.basicText)
        }
    }

    // MARK: - Contents

    func dataEncapsulated() -> Data! { horos_dataEncapsulated as Data? }

    func reportURL() -> String! { horos_reportURL }

    func annotations() -> [AnyHashable: Any]! {
        // A file that does not exist yet, as a study's before its first
        // archive, has none: the deserializer raises when it is given no data.
        guard let data = horos_dataEncapsulated as Data? else { return nil }
        var dict: [AnyHashable: Any]?
        if let exception = HorosObjCException.caught({
            dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [AnyHashable: Any]
        }) {
            _N2LogExceptionImpl(exception, true, "-[SRAnnotation annotations]")
        }
        return dict
    }

    // MARK: - ROIs

    @objc(addROIs:)
    func addROIs(_ someROIs: [Any]!) {
        // Compatibility: the encapsulated ROI payload is the released
        // typedstream format. Changing this writer alone would make these
        // reports unreadable to existing clients.
        if horos_dataEncapsulated == nil {
            horos_dataEncapsulated = typedStreamArchive(NSArray())
        }
        // An archive that is refused or unreadable holds no ROI to keep.
        let preExistingROIs = RestrictedUnarchiver.unarchiveROIs(with: horos_dataEncapsulated as Data?) ?? NSArray()
        horos_dataEncapsulated = typedStreamArchive(preExistingROIs.addingObjects(from: someROIs ?? []) as NSArray)
    }

    @objc(ROIs)
    func rois() -> [Any]! {
        RestrictedUnarchiver.unarchiveROIs(with: horos_dataEncapsulated as Data?) as? [Any]
    }

    // MARK: - Writing

    @objc(writeToFileAtPath:)
    func writeToFile(atPath path: String!) -> Bool {
        let document = horos_document
        let image = horos_image
        let study = image?.value(forKeyPath: "series.study") as? NSObject

        // The UIDs of a report read back are kept.
        if horos_newSR {
            // Without the study's own UID the report would be filed as a study of its own.
            let studyUID = study?.value(forKey: "studyInstanceUID") as? NSString
            guard let studyUID, studyUID.length > 0 else {
                NSLog("***** DICOM SR not written: the study has no StudyInstanceUID")
                return false
            }
            do {
                try document.createNewSeries(inStudy: studyUID as String)
            } catch {
                let text = (error as NSError).userInfo[IsiXDCMTKConditionTextKey] as? String ?? error.localizedDescription
                NSLog("***** DICOM SR not written: the study's StudyInstanceUID was refused: %@", text)
                return false
            }
        }

        let frameID = image?.value(forKey: "frameID")
        document.setValue(NSNumber(value: intValue(frameID)).stringValue, of: .instanceNumber)

        // The original patient's name, from the file of the image referred
        // to. That file can be unreadable at this moment - being rewritten,
        // for one - and the report then took no patient and no series
        // description, and was filed as a study of its own: the study's own
        // values are used instead.
        var namedFromFile = false
        if let completePath = image?.value(forKey: "completePath") as? String,
           FileManager.default.fileExists(atPath: completePath),
           let file = try? IsiXDCMTKFile.file(atPath: completePath) {
            namedFromFile = true
            let dataset = file.dataset
            var encodingArray: [String]?
            if let characterSet = dataset.string(forTag: 0x0008_0005) {
                document.setValue(characterSet, of: .specificCharacterSet)
                encodingArray = NSString(cString: characterSet, encoding: String.Encoding.isoLatin1.rawValue)?
                    .components(separatedBy: "\\")
            }
            let encoding = NSString.encoding(forDICOMCharacterSet: (encodingArray ?? ["ISO_IR 100"])[0])
            if let name = dataset.string(forTag: 0x0010_0010) { document.setValue(name, of: .patientName) }
            if let referring = dataset.string(forTag: 0x0008_0090) {
                document.setValue(referring, of: .referringPhysicianName)
            }
            if let studyDescription = dataset.string(forTag: 0x0008_1030) {
                document.setValue(studyDescription, of: .studyDescription)
            }
            if let description = horos_description as NSString?, description.length > 0 {
                var bytes = [UInt8](description.data(using: encoding, allowLossyConversion: true) ?? Data())
                bytes.append(0)
                bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                        document.setValue($0, of: .seriesDescription)
                    }
                }
            }
            withExtendedLifetime(file) {}
        }
        if !namedFromFile {
            document.setValue("ISO_IR 192", of: .specificCharacterSet) // UTF-8
            if let name = study?.value(forKey: "name") as? NSString { document.setValue(name.utf8String, of: .patientName) }
            if let referring = study?.value(forKey: "referringPhysician") as? NSString {
                document.setValue(referring.utf8String, of: .referringPhysicianName)
            }
            if let description = horos_description { document.setValue(description, of: .seriesDescription) }
            if let studyName = study?.value(forKey: "studyName") as? NSString {
                document.setValue(studyName.utf8String, of: .studyDescription)
            }
        }

        if let birthDate = study?.value(forKey: "dateOfBirth") {
            document.setValue((DICOMCalendarDate.string(from: birthDate, calendarFormat: "%Y%m%d") as NSString?)?.utf8String, of: .patientBirthDate)
        }
        if let sex = study?.value(forKey: "patientSex") as? NSString { document.setValue(sex.utf8String, of: .patientSex) }
        if let patientID = study?.value(forKey: "patientID") as? NSString {
            document.setValue(patientID.utf8String, of: .patientID)
        }
        if let studyID = study?.value(forKey: "id") as? NSString { document.setValue(studyID.utf8String, of: .studyID) }
        if let accession = study?.value(forKey: "accessionNumber") as? NSString {
            document.setValue(accession.utf8String, of: .accessionNumber)
        }
        document.setValue("IsiX DICOM Viewer", of: .manufacturer)
        if let seriesNumber = horos_seriesNumber { document.setValue(seriesNumber, of: .seriesNumber) }

        if let contentDate = horos_contentDate as Date? {
            document.setValue(DICOMDateTimeText.date(contentDate), of: .contentDate)
            document.setValue(DICOMDateTimeText.time(contentDate, fraction: false), of: .contentTime)
        } else if horos_description != "OsiriX Report SR" {
            document.setValue(DICOMDateTimeText.date(Date()), of: .contentDate)
            document.setValue(DICOMDateTimeText.time(Date(), fraction: true), of: .contentTime)
        } else if (horos_dataEncapsulated?.length ?? 0) > 0 {
            NSLog("********** no date for Report SR ?")
        }

        // The image reference, when the image has both UIDs: an empty one
        // made an invalid content item, and the report could not be read back.
        let referencedClass = image?.value(forKeyPath: "series.seriesSOPClassUID") as? NSString
        let referencedInstance = image?.value(forKey: "sopInstanceUID") as? NSString
        if let referencedClass, let referencedInstance, referencedClass.length > 0, referencedInstance.length > 0 {
            document.addImageReference(withCode: "IHE.10", scheme: "99HUG", meaning: "Image Reference",
                                       sopClass: referencedClass as String, instance: referencedInstance as String,
                                       frames: (frameID as? NSNumber)?.stringValue)
        } else {
            NSLog("---- SR: no image of the study with both UIDs to refer to; written without an image reference")
        }

        do {
            try document.prepareFile(withEncapsulatedDocument: horos_dataEncapsulated as Data?,
                                     seriesInstanceUID: horos_seriesInstanceUID)
        } catch {
            return false
        }
        return document.writePreparedFileAtomically(toPath: path)
    }

    // MARK: - Identity

    func seriesInstanceUID() -> String! {
        if horos_seriesInstanceUID == nil {
            horos_seriesInstanceUID = String(data: horos_document.value(of: .seriesInstanceUID), encoding: .utf8)
        }
        return horos_seriesInstanceUID
    }

    func setSeriesInstanceUID(_ seriesInstanceUID: String!) {
        horos_seriesInstanceUID = seriesInstanceUID
    }

    func sopInstanceUID() -> String! { String(data: horos_document.value(of: .sopInstanceUID), encoding: .utf8) }

    func sopClassUID() -> String! { String(data: horos_document.value(of: .sopClassUID), encoding: .utf8) }

    func seriesDescription() -> String! { String(data: horos_document.value(of: .seriesDescription), encoding: .utf8) }

    func seriesNumber() -> String! { String(data: horos_document.value(of: .seriesNumber), encoding: .utf8) }
}

// MARK: - Helpers

/// The coding scheme DCMTK names for its own codes (OFFIS_CODING_SCHEME_DESIGNATOR).
private let offisCodingScheme = "99_OFFIS_DCMTK"

/// The bytes of a C string as `[NSString stringWithFormat:@"%s", ...]` reads them.
private func formattedCString(_ data: Data) -> NSString {
    var bytes = [UInt8](data)
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
            NSString(format: "%s", $0)
        }
    }
}

/// `[value intValue]`: 0 for nil.
private func intValue(_ value: Any?) -> Int32 {
    guard let value = value as AnyObject? else { return 0 }
    return (value.value(forKey: "intValue") as? NSNumber)?.int32Value ?? 0
}

/// The typedstream archive (NSArchiver) of `root`, which the ROI reports have
/// always carried.
private func typedStreamArchive(_ root: NSArray) -> NSData? {
    let archiver = NSClassFromString("NSArchiver") as AnyObject
    return archiver.perform(NSSelectorFromString("archivedDataWithRootObject:"), with: root)?
        .takeUnretainedValue() as? NSData
}
