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
import IsiXDatabase
import IsiXDICOMFile

// DicomDatabase (DICOMDIR): the entries a medium's DICOMDIR names, read
// through Adapters/DCMTK/IsiXDCMTKDicomDir in one pass, as the dictionaries
// -addFilesDescribedInDictionaries:... indexes, and the files the scan reads
// anyway because the index cannot be trusted with them.

/// The tags an entry is made of, which the adapter reads from each record.
private enum DirectoryTag {
    static let referencedFileID: UInt32 = 0x0004_1500
    static let referencedSOPClassUIDInFile: UInt32 = 0x0004_1510
    static let referencedSOPInstanceUIDInFile: UInt32 = 0x0004_1511
    static let referencedTransferSyntaxUIDInFile: UInt32 = 0x0004_1512
    static let specificCharacterSet: UInt32 = 0x0008_0005
    static let sopClassUID: UInt32 = 0x0008_0016
    static let sopInstanceUID: UInt32 = 0x0008_0018
    static let studyDate: UInt32 = 0x0008_0020
    static let studyTime: UInt32 = 0x0008_0030
    static let accessionNumber: UInt32 = 0x0008_0050
    static let modality: UInt32 = 0x0008_0060
    static let institutionName: UInt32 = 0x0008_0080
    static let referringPhysicianName: UInt32 = 0x0008_0090
    static let studyDescription: UInt32 = 0x0008_1030
    static let seriesDescription: UInt32 = 0x0008_103E
    static let performingPhysicianName: UInt32 = 0x0008_1050
    static let patientName: UInt32 = 0x0010_0010
    static let patientID: UInt32 = 0x0010_0020
    static let patientBirthDate: UInt32 = 0x0010_0030
    static let patientSex: UInt32 = 0x0010_0040
    static let studyInstanceUID: UInt32 = 0x0020_000D
    static let seriesInstanceUID: UInt32 = 0x0020_000E
    static let studyID: UInt32 = 0x0020_0010
    static let seriesNumber: UInt32 = 0x0020_0011
    static let instanceNumber: UInt32 = 0x0020_0013
    static let numberOfFrames: UInt32 = 0x0028_0008
    static let rows: UInt32 = 0x0028_0010
    static let columns: UInt32 = 0x0028_0011
    static let iconImageSequence: UInt32 = 0x0088_0200

    static let read: [NSNumber] = [
        referencedFileID, referencedSOPClassUIDInFile, referencedSOPInstanceUIDInFile, referencedTransferSyntaxUIDInFile,
        specificCharacterSet, sopClassUID, sopInstanceUID, studyDate, studyTime, accessionNumber, modality,
        institutionName, referringPhysicianName, studyDescription, seriesDescription, performingPhysicianName,
        patientName, patientID, patientBirthDate, patientSex, studyInstanceUID, seriesInstanceUID, studyID,
        seriesNumber, instanceNumber, numberOfFrames, rows, columns, iconImageSequence,
    ].map { NSNumber(value: $0) }
}

/// The elements of one DICOMDIR record, read once each: an element read is
/// taken out, as the entry is built from what remains.
private struct DirectoryElements {
    var values: [UInt32: Any]

    init(_ record: IsiXDCMTKDirectoryRecord) {
        var values: [UInt32: Any] = [:]
        for (tag, value) in record.values { values[tag.uint32Value] = value }
        self.values = values
    }

    /// Whether the record has the element, read or not.
    func has(_ tag: UInt32) -> Bool { values[tag] != nil }

    /// Takes the element out; nil when it is not there.
    mutating func remove(_ tag: UInt32) -> Any? { values.removeValue(forKey: tag) }

    /// The element's text as Latin-1; nil when it is absent or has none.
    static func string(_ value: Any?) -> String? {
        guard let data = value as? Data else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    /// The element's text decoded with the encodings of the entry.
    static func string(_ value: Any?, encodings: UnsafeMutablePointer<UInt>) -> String? {
        guard let data = value as? Data else { return nil }
        var bytes = [CChar](repeating: 0, count: data.count + 1)
        bytes.withUnsafeMutableBytes { buffer in _ = data.copyBytes(to: buffer) }
        return bytes.withUnsafeMutableBufferPointer { buffer in
            DicomFile.string(withBytes: buffer.baseAddress, encodings: encodings, replaceBadCharacters: true) as String?
        }
    }

    /// `[[element stringValue] integerValue]`: 0 when it is absent or has no text.
    static func integer(_ value: Any?) -> Int {
        guard let string = string(value) else { return 0 }
        return (string as NSString).integerValue
    }

    /// An NSNumber of `integer` when the element is there, nil when it is not.
    static func integerNumber(_ value: Any?) -> NSNumber? {
        value == nil ? nil : NSNumber(value: integer(value))
    }

    mutating func takeString(_ tag: UInt32) -> String? { DirectoryElements.string(remove(tag)) }
}

extension DicomDatabase {

    /// The images a DICOMDIR's entries indexed. Files it names that are
    /// multi-frame and alone in their series, and, when the DICOMDIR looks
    /// incomplete, the files a full parse finds, go to `pathsToScanAnyway`.
    /// Empty when the validation before importing refuses the DICOMDIR, or a
    /// record names its file with no text, which stops the reading of the index.
    func scanDicomdir(at path: String, withPaths allpaths: NSArray, pathsToScanAnyway: NSMutableArray) -> [Any] {
        let thread = Thread.current

        if UserDefaults.standard.bool(forKey: "validateFilesBeforeImporting") {
            // The DICOMDIR is read in the Decompress service first, where one
            // that brings DCMTK down ends only the service. A DICOMDIR that
            // cannot be validated is refused, as one that fails; a service that
            // will not answer reaches the same answer instead of waiting forever.
            if let service = DecompressService.shared {
                switch service.testDicomDir(atPath: path, timeout: 60) {
                case .success(true):
                    break
                case .success(false), .failure(.crashed):
                    NSLog("****** failed to read DICOMDIR: %@", path)
                    return []
                case .failure(let error):
                    if error == .timedOut { service.terminate() }
                    NSLog("****** could not validate DICOMDIR %@: %@", path, "\(error)")
                    return []
                }
            }
        }

        guard let items = dicomdirItems(at: path) else { return [] }

        var notFoundFiles = false

        // file paths are sometimes wrong the DICOMDIR, see if these files exist
        let listed = allpaths.compactMap { $0 as? String }
        var i = items.count - 1
        while i >= 0 {
            let item = items.object(at: i) as! NSMutableDictionary

            var filepath = item["filePath"] as? String
            if !FileManager.default.fileExists(atPath: filepath ?? "") { // reference invalid, try and find the file...
                filepath = MediaScanRules.listedPath(matching: filepath ?? "", in: listed)

                if let filepath { item["filePath"] = filepath }

                notFoundFiles = true
            }

            // some DICOMDIR files only list 1 image for 1 multiframe DICOM file
            let scuid = item["SOPClassUID"] as? String
            if DICOMSOPClass.isMultiframe(scuid)
                && MediaScanRules.isOnlyEntryOfItsSeries(at: i, seriesIDs: items.map { ($0 as? NSDictionary)?["seriesID"] as? String }) {
                if let filepath { pathsToScanAnyway.add(filepath) }
                items.removeObject(at: i)
            }

            if thread.isCancelled { break }
            i -= 1
        }

        // DUMP the DICOMDIR... did we miss some files??
        if items.count <= 1 || notFoundFiles {
            NSLog("dcmdump DICOMDIR")
            do {
                try HorosObjCException.perform {
                    let files = NSMutableArray()
                    let parsed = DicomDirParser(path)
                    parsed.parseArray(files)

                    if files.count > items.count * 2 { // We found more than 50% more files... Let's use only the files discovered by the DicomDirParser
                        items.removeAllObjects()
                        pathsToScanAnyway.addObjects(from: files as! [Any])
                    } else {
                        for case let item as NSDictionary in items {
                            if let listedPath = item["filePath"] { files.remove(listedPath) }
                        }
                        pathsToScanAnyway.addObjects(from: files as! [Any])
                    }
                }
            } catch {
                if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    N2LogStackTraceMessage("\(exception)")
                }
            }
        }

        var objectIDs: [Any]? = nil
        if items.count != 0 {
            thread.status = String(format: NSLocalizedString("Importing %@...", comment: ""),
                                   singularPluralCount(items.count, NSLocalizedString("file", comment: ""),
                                                       NSLocalizedString("files", comment: "")))
            objectIDs = addFilesDescribed(inDictionaries: items as? [Any], postNotifications: false, rereadExistingItems: false,
                                          generatedByOsiriX: false, importedFiles: false, returnArray: true)
        }

        return objects(withIDs: objectIDs) ?? []
    }

    /// The entries of the DICOMDIR's records that name a file, as
    /// -addFilesDescribedInDictionaries:... takes them. nil when a record
    /// names its file with no text: the path could not be made, and the index
    /// was given up.
    private func dicomdirItems(at path: String) -> NSMutableArray? {
        let items = NSMutableArray()
        let basePath = (path as NSString).deletingLastPathComponent
        let records: [IsiXDCMTKDirectoryRecord]
        do {
            records = try IsiXDCMTKDicomDir.fileRecords(ofDicomDirAtPath: path, tags: DirectoryTag.read)
        } catch {
            NSLog("(scanAtPath): the DICOMDIR %@ could not be read: %@", path, error.localizedDescription)
            return items
        }

        for record in records {
            var elements = DirectoryElements(record)

            guard let fileID = DirectoryElements.string(elements.values[DirectoryTag.referencedFileID]) else {
                N2LogStackTraceMessage("(scanAtPath): a DICOMDIR record names its file with no text; the index of "
                                       + path + " is not used")
                return nil
            }
            let filePath = MediaScanRules.referencedFilePath(fileID, basePath: basePath)

            guard MediaScanRules.acceptsReferencedFilePath(filePath) else {
                N2LogStackTraceMessage(String(format: "path > MAXPATHLEN : %d characters, %@",
                                              Int32((filePath as NSString).length), filePath))
                continue
            }

            let item = NSMutableDictionary(object: filePath, forKey: "filePath" as NSString)
            func set(_ value: Any?, _ key: String) { if let value { item[key] = value } }

            item["fileType"] = MediaScanRules.fileType(forTransferSyntax: elements.takeString(DirectoryTag.referencedTransferSyntaxUIDInFile))

            set(NSNumber(value: true), "hasDICOM")

            var temp = elements.takeString(DirectoryTag.sopClassUID)
            if temp == nil { temp = DirectoryElements.string(elements.values[DirectoryTag.referencedSOPClassUIDInFile]) }
            set(temp, "SOPClassUID")
            _ = elements.remove(DirectoryTag.referencedSOPClassUIDInFile)

            temp = elements.takeString(DirectoryTag.sopInstanceUID)
            if temp == nil { temp = DirectoryElements.string(elements.values[DirectoryTag.referencedSOPInstanceUIDInFile]) }
            set(temp, "SOPUID")
            set(elements.takeString(DirectoryTag.referencedSOPInstanceUIDInFile), "referencedSOPInstanceUID")

            // The names are decoded in the character set the record states (its
            // own, or that of the records above it), as the file's are.
            let characterSet = elements.takeString(DirectoryTag.specificCharacterSet)
            set(characterSet, "specificCharacterSet")
            var encodings = DICOMCharacterSet.encodings(forSpecificCharacterSet: characterSet)

            set(elements.takeString(DirectoryTag.studyInstanceUID), "studyID")
            set(elements.takeString(DirectoryTag.studyID), "studyNumber")

            encodings.withUnsafeMutableBufferPointer { encodings in
                let list = encodings.baseAddress!
                set(DirectoryElements.string(elements.remove(DirectoryTag.studyDescription), encodings: list), "studyDescription")

                let studyDate = elements.takeString(DirectoryTag.studyDate)
                let studyTime = elements.takeString(DirectoryTag.studyTime)
                set(NSDate.date(withYYYYMMDD: studyDate as NSString?, hhmmss: studyTime as NSString?), "studyDate")
                set(elements.takeString(DirectoryTag.modality), "modality")
                set(elements.takeString(DirectoryTag.patientID), "patientID")

                set(DirectoryElements.string(elements.remove(DirectoryTag.patientName), encodings: list), "patientName")

                set(NSDate.date(withYYYYMMDD: elements.takeString(DirectoryTag.patientBirthDate) as NSString?, hhmmss: nil), "patientBirthDate")
                set(elements.takeString(DirectoryTag.patientSex), "patientSex")

                set(elements.takeString(DirectoryTag.accessionNumber), "accessionNumber")
            }

            set(DicomFile.patientUID(item), "patientUID")

            set(NSNumber(value: 1), "numberOfSeries")

            set(DirectoryElements.integerNumber(elements.remove(DirectoryTag.numberOfFrames)), "numberOfFrames")
            // SERIES ID MUST BE UNIQUE!!!!!
            set(MediaScanRules.seriesDICOMUID(seriesInstanceUID: elements.takeString(DirectoryTag.seriesInstanceUID),
                                              sopInstanceUID: item["SOPUID"] as? String,
                                              numberOfFrames: (item["numberOfFrames"] as? NSNumber)?.intValue ?? 0),
                "seriesDICOMUID")

            let seriesNumberAttribute = elements.remove(DirectoryTag.seriesNumber)
            set(MediaScanRules.seriesID(seriesNumber: DirectoryElements.string(seriesNumberAttribute),
                                        seriesDICOMUID: item["seriesDICOMUID"] as? String), "seriesID")

            encodings.withUnsafeMutableBufferPointer { encodings in
                let list = encodings.baseAddress!
                set(DirectoryElements.string(elements.remove(DirectoryTag.seriesDescription), encodings: list), "seriesDescription")
                set(DirectoryElements.integerNumber(seriesNumberAttribute), "seriesNumber")
                set(DirectoryElements.integerNumber(elements.remove(DirectoryTag.instanceNumber)), "imageID")

                set(DirectoryElements.string(elements.remove(DirectoryTag.institutionName), encodings: list), "institutionName")
                set(DirectoryElements.string(elements.remove(DirectoryTag.referringPhysicianName), encodings: list), "referringPhysiciansName")
                set(DirectoryElements.string(elements.remove(DirectoryTag.performingPhysicianName), encodings: list), "performingPhysiciansName")
            }

            var tempi = DirectoryElements.integer(elements.remove(DirectoryTag.rows))
            set(NSNumber(value: tempi != 0 ? tempi : Int(OsirixDicomImageSizeUnknown)), "height")
            tempi = DirectoryElements.integer(elements.remove(DirectoryTag.columns))
            set(NSNumber(value: tempi != 0 ? tempi : Int(OsirixDicomImageSizeUnknown)), "width")

            // thumbnail
            if let icon = record.icon, let image = DicomDatabase.iconImage(icon) {
                item["NSImageThumbnail"] = image
            }

            items.add(item)
        }
        return items
    }

    /// The icon of a record as an image: monochrome samples of 1 or 8 bits;
    /// nil for any other (ftp://medical.nema.org/medical/dicom/2011/11_03pu.pdf
    /// F.7 ICON IMAGE KEY DEFINITION).
    private static func iconImage(_ icon: IsiXDCMTKDirectoryIcon) -> NSImage? {
        // Pixel samples have a Value of either 1 or 8 for Bits Allocated (0028,0100) and Bits Stored (0028,0101)
        let bitsAllocated = Int(icon.bitsAllocated), bitsStored = Int(icon.bitsStored)
        if bitsAllocated != 1 && bitsAllocated != 8 { return nil }
        if bitsStored != 1 && bitsStored != 8 { return nil }
        let width = Int(icon.columns), height = Int(icon.rows)
        let data = icon.pixels

        // Photometric Interpretation (0028,0004) shall have a Value of either MONOCHROME 1, MONOCHROME 2 or PALETTE COLOR
        guard let spi = icon.photometricInterpretation as NSString? else { return nil }

        let rep: NSBitmapImageRep?
        if spi.isEqual(to: "MONOCHROME1") {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: bitsStored,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: 0, bitsPerPixel: bitsAllocated)
            if let bitmapData = rep?.bitmapData {
                // invert data
                data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    for i in 0..<min(width * height * bitsAllocated / 8, source.count) {
                        if bitsAllocated == 1 {
                            bitmapData[i] = source[i] ^ 0xff
                        } else {
                            bitmapData[i] = 0xff - source[i]
                        }
                    }
                }
            }
        } else if spi.isEqual(to: "MONOCHROME2") {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: bitsStored,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: width * 8 / bitsAllocated, bitsPerPixel: bitsAllocated)
            if let bitmapData = rep?.bitmapData {
                let count = Int(ceilf(Float(1.0) * Float(width * height * bitsAllocated) / 8))
                data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    if let base = source.baseAddress { memcpy(bitmapData, base, min(count, source.count)) }
                }
            }
        } else {
            // PALETTE COLOR: this type of thumbnail should be read too...
            return nil
        }

        guard let rep else { return nil }
        let im = NSImage()
        im.addRepresentation(rep)
        return im
    }
}

/// N2LocalizedSingularPluralCount(c, s, p) of N2Stuff.h.
private func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                  count == 1 ? singular : plural)
}
