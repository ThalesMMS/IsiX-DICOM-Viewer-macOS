/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The rules of the browser's network and file functions that need no
// AppKit, database or DICOM toolkit: which compression a modality gets, the
// layout of raw pixel data turned into secondary captures, the folders the
// delete queue leaves empty, and when a study is linked to a web portal user.

/// The values of the Compression preferences.
public enum CompressionKind {
    public static let sameAsDefault = 0, none = 1, jpeg = 2, jpeg2000 = 3, jpegLS = 4
}

/// The compression, and its quality, the preferences give a modality.
public enum CompressionChoice {
    /// The setting is the first row of `settings` (below the resolution
    /// limit, `lowResolutionSettings`) whose modality occurs in the
    /// modality; a row "same as default" takes the first row's compression.
    /// SR is never compressed. No row matching: the first row; no rows: none.
    /// `quality` is the quality to write, nil when the caller's is left as
    /// it was (SR, no rows); it is the row's for JPEG 2000 and JPEG-LS, 0 for
    /// the others. A nil modality matches the first row, as a message to nil
    /// answered a found range.
    public static func choice(forModality modality: String?, resolution: Int, resolutionLimit: Int,
                              settings: [Any]?, lowResolutionSettings: [Any]?) -> (compression: Int, quality: Int32?) {
        let rows = (resolution < resolutionLimit ? lowResolutionSettings : settings) ?? []
        if let modality, (modality as NSString).isEqual(to: "SR") {
            return (CompressionKind.none, nil)
        }
        for row in rows {
            let searched = value(row, "modality") as? String
            let found: Bool
            if let modality {
                guard let searched else { continue }
                found = (modality as NSString).range(of: searched).location != NSNotFound
            } else {
                found = true
            }
            guard found else { continue }
            var chosen = row
            if intValue(value(row, "compression")) == CompressionKind.sameAsDefault {
                chosen = rows[0]
            }
            let compression = intValue(value(chosen, "compression"))
            let quality = compression == CompressionKind.jpeg2000 || compression == CompressionKind.jpegLS
                ? Int32(truncatingIfNeeded: intValue(value(chosen, "quality"))) : 0
            return (compression, quality)
        }
        guard let first = rows.first else { return (CompressionKind.none, nil) }
        return (intValue(value(first, "compression")), Int32(truncatingIfNeeded: intValue(value(first, "quality"))))
    }

    private static func value(_ row: Any, _ key: String) -> Any? {
        return (row as? NSDictionary)?.value(forKey: key)
    }

    /// -intValue of a number or a string; 0 for anything else.
    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return Int(number.int32Value) }
        if let string = value as? NSString { return Int(string.intValue) }
        return 0
    }
}

/// How the raw data import reads a file: the pixel type chosen in its sheet,
/// and the slices cut from the file as little-endian secondary captures.
public struct RawDataLayout: Equatable, Sendable {
    public let samplesPerPixel: Int
    public let bytesPerSample: Int
    public let highBit: Int
    public let bitsAllocated: Int
    public let isSigned: Bool
    public let isLittleEndian: Bool
    public let photometricInterpretation: String

    /// The rows of the pixel type matrix: RGB 8 bits, 8 bits, 16 bits
    /// unsigned, 16 bits signed, the two 16 bits big endian, 32 bits signed;
    /// anything else is read as 16 bits with 7 as high bit, as it always was.
    public init(pixelType: Int) {
        var spp = 1, bytes = 2, highBit = 7, bits = 8, signed = true, little = true, photometric = "MONOCHROME2"
        switch pixelType {
        case 0: spp = 3; bytes = 1; photometric = "RGB"
        case 1: bytes = 1
        case 2: highBit = 15; bits = 16; signed = false
        case 3: highBit = 15; bits = 16
        case 4: highBit = 15; bits = 16; signed = false; little = false
        case 5: highBit = 15; bits = 16; signed = true; little = false
        case 6: bytes = 4; highBit = 31; bits = 32; signed = true; little = true
        default: break
        }
        samplesPerPixel = spp; bytesPerSample = bytes; self.highBit = highBit; bitsAllocated = bits
        isSigned = signed; isLittleEndian = little; photometricInterpretation = photometric
    }

    /// OB for one byte per sample, OW otherwise.
    public var pixelDataVR: String { bytesPerSample < 2 ? "OB" : "OW" }

    /// The bytes of one slice.
    public func sliceLength(rows: UInt, columns: UInt) -> UInt {
        return UInt(samplesPerPixel) &* UInt(bytesPerSample) &* rows &* columns
    }

    /// Whether the file holds every slice after the offset.
    public func fileHoldsSlices(length: UInt, rows: UInt, columns: UInt, slices: UInt, offset: UInt) -> Bool {
        return length >= sliceLength(rows: rows, columns: columns) &* slices &+ offset
    }

    /// Slice `index`, little endian: big-endian samples are byte-swapped by
    /// pairs, as 16-bit values.
    public func slice(_ index: UInt, of data: Data, rows: UInt, columns: UInt, offset: UInt) -> Data {
        let length = Int(sliceLength(rows: rows, columns: columns))
        let start = data.startIndex + Int(offset) + length * Int(index)
        var slice = Data(data[start ..< start + length])
        if !isLittleEndian {
            slice.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                var pair = 0
                while pair + 1 < (length / 2) * 2 {
                    bytes.swapAt(pair, pair + 1)
                    pair += 2
                }
            }
        }
        return slice
    }
}

/// What the delete queue does around the files it deletes.
public enum DeleteQueueRules {
    /// A queued file that could not be deleted, and the error number of the
    /// attempt.
    public struct Failure: Equatable, Sendable {
        public let path: String
        public let code: Int32
        public init(path: String, code: Int32) {
            self.path = path
            self.code = code
        }
        /// The system's description of the error.
        public var reason: String { String(cString: strerror(code)) }
    }

    /// Deletes one queued file. A file already gone is no failure: the queue
    /// may hold it twice, or a former run may have deleted it.
    public static func deleteFile(_ path: String) -> Failure? {
        if unlink(path) == 0 { return nil }
        let code = errno
        return code == ENOENT ? nil : Failure(path: path, code: code)
    }

    /// The first `limit` failures, one per line: the path and why.
    public static func failureList(_ failures: [Failure], limit: Int = 5) -> String {
        var lines = failures.prefix(limit).map { "\($0.path): \($0.reason)" }
        if failures.count > limit { lines.append("…") }
        return lines.joined(separator: "\n")
    }

    /// The folders of the deleted files, each once, in the order first met.
    public static func parentFolders(of files: [String]) -> [String] {
        // NSString equality, as -containsObject: compared: code unit by code unit.
        let folders = NSMutableOrderedSet()
        var last: String?
        for file in files {
            let parent = (file as NSString).deletingLastPathComponent
            if last.map({ ($0 as NSString).isEqual(to: parent) }) == true { continue }
            folders.add(parent as NSString)
            last = parent
        }
        return folders.array.map { $0 as! String }
    }

    /// Removes those of the folders that the deletion left empty: a folder
    /// (not a file) made at least two minutes ago, or of unknown age, with a
    /// link count below 4 and nothing in it but hidden entries; never one
    /// named ROIs. Returns the folders removed.
    @discardableResult
    public static func removeEmptyFolders(_ folders: [String], fileManager: FileManager = .default, now: Date = Date()) -> [String] {
        var removed: [String] = []
        for folder in folders {
            guard let attributes = try? fileManager.attributesOfItem(atPath: folder),
                  (attributes[.type] as? String) == FileAttributeType.typeDirectory.rawValue else { continue }
            let created = attributes[.creationDate] as? Date
            let links = (attributes[.referenceCount] as? NSNumber)?.int32Value ?? 0
            guard created.map({ now.timeIntervalSince($0) > 120 }) ?? true, links < 4 else { continue }
            let visible = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { !(($0 as NSString).lastPathComponent as NSString).hasPrefix(".") }
            guard visible.isEmpty, !((folder as NSString).lastPathComponent as NSString).isEqual(to: "ROIs") else { continue }
            NSLog("delete Queue: delete folder: %@", folder)
            try? fileManager.removeItem(atPath: folder)
            removed.append(folder)
        }
        return removed
    }
}

/// "Add Studies to User" in the web portal's users.
public enum WebPortalStudyLink {
    /// A study is linked again unless the user already has its UID and a
    /// study of its patient (patient UIDs compared without case, accents or
    /// width).
    /// The linked values are the user's studies' as key-value coding lists
    /// them: entries that are not strings (NSNull) match nothing.
    public static func needsLink(studyUID: String?, patientUID: String?,
                                 linkedStudyUIDs: [Any], linkedPatientUIDs: [Any]) -> Bool {
        let hasStudy = studyUID.map { uid in linkedStudyUIDs.contains { ($0 as? NSString)?.isEqual(to: uid) == true } } ?? false
        let hasPatient = patientUID.map { patient in
            linkedPatientUIDs.contains { linked in
                (linked as? NSString)?.compare(patient, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
            }
        } ?? false
        return !hasStudy || !hasPatient
    }
}
