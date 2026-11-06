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

/// The bytes of a value up to its first NUL, decoded as a C string is
/// (+[NSString stringWithCString:encoding:]).
func dicomFileString(_ bytes: Data?, _ encoding: String.Encoding) -> NSString? {
    guard let bytes else { return nil }
    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
    return NSString(data: bytes[bytes.startIndex..<end], encoding: encoding.rawValue)
}

/// The values other parts of the application read from a file without
/// importing it: its character sets, one field or several, the acquisition's
/// date and time. DCMTK reads the file through the adapter.
///
/// Each method reads inside its own autorelease pool: the adapter's file, and
/// the items and bytes that keep it alive, are autoreleased, and the whole
/// dataset would otherwise stay in memory until the caller's pool drains - for
/// the import, after a whole batch of files.
@objc(DicomFileDCMTKCategory) @implementation extension DicomFile {

    @objc(getEncodingArrayForFile:)
    class func getEncodingArray(forFile file: String!) -> [Any]! {
        let declared = autoreleasepool {
            (try? IsiXDCMTKFile.file(atPath: file))
                .flatMap({ dicomFileString($0.dataset.string(forTag: DicomFileTag.specificCharacterSet), .isoLatin1) })
        }
        if let declared {
            return declared.components(separatedBy: "\\")
        }
        // The same choice as at index time: a file that states nothing is read as
        // whatever DefaultCharacterSetWhenAbsent names, and as Latin-1 when it
        // names nothing.
        let chosen = DICOMCharacterSet.characterSetWhenAbsent() ?? ""
        return [chosen.isEmpty ? "ISO_IR 100" : chosen]
    }

    @objc(isDICOMFileDCMTK:)
    class func isDICOMFileDCMTK(_ file: String!) -> Bool {
        autoreleasepool { (try? IsiXDCMTKFile.file(atPath: file)) != nil }
    }

    @objc(isNRRDFile:)
    class func isNRRDFile(_ file: String!) -> Bool {
        ((file ?? "") as NSString).pathExtension.lowercased() == "nrrd"
    }

    @objc(getDicomFieldForGroup:element:forDcmFileFormat:)
    class func getDicomField(forGroup gr: Int32, element el: Int32, forDcmFileFormat ff: UnsafeMutableRawPointer!) -> String! {
        guard let ff else { return nil }
        let file = IsiXDCMTKFile(borrowingHandle: ff)
        return field(UInt32(truncatingIfNeeded: gr), UInt32(truncatingIfNeeded: el), of: file) as String?
    }

    /// The first value of (group, element) in the dataset, else in the meta
    /// header, in Latin-1; nil when neither has a value.
    private static func field(_ group: UInt32, _ element: UInt32, of file: IsiXDCMTKFile) -> NSString? {
        let tag = (group & 0xffff) << 16 | (element & 0xffff)
        for item in [file.dataset, file.metaInfo] {
            if let bytes = item.firstString(forTag: tag), !bytes.isEmpty,
               let value = dicomFileString(bytes, .isoLatin1) {
                return value
            }
        }
        return nil
    }

    @objc(getDicomField:forFile:)
    class func getDicomField(_ field: String!, forFile path: String!) -> String! {
        guard let field, !field.isEmpty, let tag = DICOMKeyword.standardTag(for: field),
              tag.group != 0xffff && tag.element != 0xffff else { return nil }
        return autoreleasepool {
            guard let file = lockedFile(atPath: path) else { return nil }
            return self.field(tag.group, tag.element, of: file) as String?
        }
    }

    @objc(acquisitionTimingForFile:)
    class func acquisitionTiming(forFile path: String!) -> [AnyHashable: Any]! {
        autoreleasepool { timing(atPath: path) }
    }

    private static func timing(atPath path: String?) -> [AnyHashable: Any] {
        guard let path, !path.isEmpty, let file = lockedFile(atPath: path) else { return [:] }
        // The four ASCII temporal tags together, with their original precision.
        var record: [AnyHashable: Any] = [:]
        let tags: [(String, UInt32)] = [("AcquisitionDateTime", DicomFileTag.acquisitionDateTime),
                                        ("AcquisitionDate", DicomFileTag.acquisitionDate),
                                        ("AcquisitionTime", DicomFileTag.acquisitionTime),
                                        ("TimezoneOffsetFromUTC", DicomFileTag.timezoneOffsetFromUTC)]
        for (name, tag) in tags {
            if let text = dicomFileString(file.dataset.stringArray(forTag: tag), .ascii) {
                record[name] = text
            }
        }
        return record
    }

    @objc(valuesForDicomFields:forFile:)
    class func values(forDicomFields fields: [Any]!, forFile path: String!) -> [AnyHashable: Any]! {
        autoreleasepool { values(of: fields, atPath: path) }
    }

    private static func values(of fields: [Any]?, atPath path: String?) -> [AnyHashable: Any] {
        guard let fields, !fields.isEmpty, let path, !path.isEmpty, let file = lockedFile(atPath: path) else { return [:] }
        let dataset = file.dataset, meta = file.metaInfo

        // The bytes of a name are in the file's own character set, and reading them
        // as Latin-1 turns a Japanese or Greek name into rubbish that then goes into
        // the file somebody opens in a spreadsheet.
        var encoding = String.Encoding.isoLatin1.rawValue
        if let declared = dicomFileString(dataset.string(forTag: DicomFileTag.specificCharacterSet), .isoLatin1),
           let first = declared.components(separatedBy: "\\").first, !first.isEmpty {
            encoding = DICOMCharacterSet.encoding(forDICOMCharacterSet: first.trimmingCharacters(in: .whitespaces))
        }

        var values: [AnyHashable: Any] = [:]
        for case let field as NSString in fields {
            guard let tag = tag(of: field as String) else { continue } // not a field this can name
            guard let bytes = dataset.stringArray(forTag: tag) ?? meta.stringArray(forTag: tag) else { continue }
            // The declared set may not decode these bytes; Latin-1 decodes any.
            if let value = NSString(data: bytes, encoding: encoding) ?? NSString(data: bytes, encoding: String.Encoding.isoLatin1.rawValue) {
                values[field] = value
            }
        }
        return values
    }

    /// The tag a field specification names: "(gggg,eeee)" in hexadecimal, read
    /// as sscanf reads "%x,%x", or a keyword in either spelling.
    private static func tag(of field: String) -> UInt32? {
        let trimmed = field.trimmingCharacters(in: CharacterSet(charactersIn: "() \t"))
        var group: UInt32 = 0, element: UInt32 = 0
        let read = trimmed.withCString { text in
            withUnsafeMutablePointer(to: &group) { groupPointer in
                withUnsafeMutablePointer(to: &element) { elementPointer in
                    withVaList([groupPointer, elementPointer]) { vsscanf(text, "%x,%x", $0) }
                }
            }
        }
        if read == 2 {
            let key = (group & 0xffff) << 16 | (element & 0xffff)
            return key == 0xffff_ffff ? nil : key
        }
        guard let resolved = DICOMKeyword.standardTag(for: field) else { return nil }
        let key = (resolved.group & 0xffff) << 16 | (resolved.element & 0xffff)
        return key == 0xffff_ffff ? nil : key
    }

    /// The file at `path`, read whole under the parser lock the import shares;
    /// nil when DCMTK cannot read it.
    private static func lockedFile(atPath path: String?) -> IsiXDCMTKFile? {
        PapyrusLock?.lock()
        defer { PapyrusLock?.unlock() }
        return try? IsiXDCMTKFile.file(atPath: path)
    }
}
