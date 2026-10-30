//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

// The rules of the database's import that need no database: where a file goes
// when its name is taken, when the volume is too full to take more, what the
// scan of the incoming folder does with a name, which conversion queue a file
// joins, how a WADO-RS multipart body is cut into DICOM files, which incoming
// file may be a report from the cloud, how the compression work is shared out,
// and what an incomplete copy from a medium says. The application's
// DicomDatabase applies them to its folders and its index.

/// A name of its own in a folder. Two archives can each hold a readme.txt, and
/// two senders can each send a file called IM1: moving the second onto the
/// first fails, and the fallback then deleted it.
public enum AvailablePath {
    /// `directory/name`, or `directory/stem-1.ext`, `stem-2.ext`… up to 999,
    /// the first that `exists` says is free. After 999 the last one tried is
    /// answered, taken or not.
    public static func inDirectory(_ directory: String, name: String,
                                   exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let folder = directory as NSString
        var candidate = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var attempt = 1
        while exists(candidate) && attempt < 1000 {
            var unique = String(format: "%@-%d", stem, Int32(attempt))
            if (pathExtension as NSString).length != 0 {
                unique = (unique as NSString).appendingPathExtension(pathExtension) ?? unique
            }
            candidate = folder.appendingPathComponent(unique)
            attempt += 1
        }
        return candidate
    }
}

/// When the volume of a database is too full to take more files.
public enum StorageFreeSpace {
    /// How long a verdict is kept before the volume is asked again, in seconds.
    public static let verificationInterval: TimeInterval = 20

    /// Below 300 MB free, or below a hundredth of the volume when that is less:
    /// a small disk would otherwise never be allowed to fill.
    public static func isBelowLimit(sizeBytes: UInt64, freeBytes: UInt64) -> Bool {
        let sizeMegaBytes = sizeBytes / 1024 / 1024
        let freeMegaBytes = freeBytes / 1024 / 1024
        let thresholdMegaBytes = min(300, sizeMegaBytes / 100)
        return freeMegaBytes < thresholdMegaBytes
    }
}

/// What the scan of the incoming folder does with what it finds.
public enum IncomingScanRules {
    /// What a name in the incoming folder is, before its contents are looked at.
    public enum Entry: Equatable, Sendable {
        /// .DS_Store or __MACOSX: removed.
        case systemLitter
        /// A name that starts with a dot: a file still being written, or the
        /// Decompress helper's staging folder. Not taken, and removed once old.
        case hidden
        /// Anything else: looked at.
        case candidate
    }

    /// A hidden entry older than this, in seconds, is removed.
    public static let hiddenEntryLifetime: TimeInterval = 60 * 60 * 24
    /// An empty file that has not changed for this long, in seconds, has stopped being written.
    public static let stalledEmptyFileAge: TimeInterval = 60 * 5

    public static func entry(named lastPathComponent: String) -> Entry {
        let uppercase = (lastPathComponent as NSString).uppercased
        if uppercase == ".DS_STORE" || uppercase == "__MACOSX" { return .systemLitter }
        let name = lastPathComponent as NSString
        if name.length > 0 && name.character(at: 0) == UInt16(UInt8(ascii: ".")) { return .hidden }
        return .candidate
    }

    /// How many files one scan takes: the maxNumberOfFilesForCheckIncoming
    /// preference, kept between 100 and 30000.
    public static func maximumFiles(preference: Int) -> Int {
        var maximum = Int(Int32(truncatingIfNeeded: preference))
        if maximum < 100 { maximum = 100 }
        if maximum > 30000 { maximum = 30000 }
        return maximum
    }

    /// Whether a DICOM image goes to the conversion queue instead of the
    /// database: the listener decompresses (1) a compressed one, or compresses
    /// (2) an uncompressed one that `needsCompression` says is worth it. The
    /// closure reads the file, so it is asked last, as before.
    public static func queuesForConversion(mayTranscode: Bool, isCompressed: Bool, listenerCompressionSettings: Int,
                                           needsCompression: () -> Bool) -> Bool {
        return mayTranscode && ((isCompressed && listenerCompressionSettings == 1) ||
                                (!isCompressed && listenerCompressionSettings == 2 && needsCompression()))
    }

    /// Whether a file is moved into the database: a DICOM file always; another
    /// file the readers take only when the database folder has no file of its
    /// name. The closures read the file and the folder, in that order.
    public static func takesFile(isDICOM: Bool, readableOtherwise: () -> Bool, destinationTaken: () -> Bool) -> Bool {
        return isDICOM || (readableOtherwise() && !destinationTaken())
    }

    /// The queue the scan's compressed files join.
    public enum ConversionQueue: Equatable, Sendable {
        case decompress, compress, none
    }

    /// Decompressed when the listener decompresses (1) or leaves files as they
    /// are (0, so that archives are expanded), compressed when it compresses (2).
    public static func queue(forListenerCompressionSettings settings: Int) -> ConversionQueue {
        switch settings {
        case 0, 1: return .decompress
        case 2: return .compress
        default: return .none
        }
    }
}

/// A WADO-RS response saved whole into the incoming folder: a MIME multipart
/// body whose parts are DICOM files.
public enum WADORSMultipart {
    /// How much of a file is read to know whether it is one.
    public static let probeLength = 0x500

    private static let applicationDICOM = Data("application/dicom;".utf8)
    private static let dicomMagic = Data("DICM".utf8)
    private static let dashes = Data([0x2D, 0x2D])
    private static let lineBreak = Data([0x0D, 0x0A])

    /// Whether the first bytes of a file announce DICOM parts: the file is at
    /// least `probeLength` long and they say "application/dicom;".
    public static func announcesDICOMParts(_ head: Data) -> Bool {
        guard head.count >= probeLength else { return false }
        return find(applicationDICOM, in: head, from: 0, length: probeLength) != nil
    }

    /// The DICOM files of the whole body, as byte ranges, in order, each from
    /// the 128-byte preamble before "DICM" to the line break before the next
    /// boundary. `malformed` says that a part claimed bytes the body does not
    /// have, where reading stopped: the parts before it are good.
    ///
    /// The boundary is the first "--" up to its line break, when that "--" is
    /// at least 75 bytes before the end; neither the preamble nor the boundary
    /// may contain "--".
    public static func dicomParts(in data: Data) -> (parts: [Range<Int>], malformed: Bool) {
        let bytes = [UInt8](data)
        let length = UInt(bytes.count)
        var parts: [Range<Int>] = []
        guard let first = find(dashes, in: bytes, from: 0, length: bytes.count) else { return (parts, false) }
        var lastBoundary = UInt(first)
        // Unsigned, as the lengths were: a body under 75 bytes passes this test
        // and then has no 75 bytes to look for the line break in.
        guard lastBoundary < length &- 75 else { return (parts, false) }
        guard lastBoundary + 75 <= length else { return (parts, true) }
        guard let firstLineBreak = find(lineBreak, in: bytes, from: Int(lastBoundary), length: 75) else { return (parts, false) }
        let boundary = Array(bytes[Int(lastBoundary)..<firstLineBreak])
        let boundaryLength = UInt(boundary.count)
        while lastBoundary < length {
            let from = Int(lastBoundary), remaining = Int(length - lastBoundary)
            guard let application = find(applicationDICOM, in: bytes, from: from, length: remaining),
                  let magic = find(dicomMagic, in: bytes, from: from, length: remaining) else {
                lastBoundary = length
                continue
            }
            guard lastBoundary + boundaryLength <= length else { return (parts, true) }
            let next = find(boundary, in: bytes, from: Int(lastBoundary + boundaryLength),
                            length: Int(length - lastBoundary - boundaryLength)).map { UInt($0) } ?? UInt(NSNotFound)
            if magic > application && next > UInt(magic) {
                let offset = UInt(magic) &- 128
                let partLength = next &- 2 &- offset
                guard offset <= length && partLength <= length - offset else { return (parts, true) }
                parts.append(Int(offset)..<Int(offset + partLength))
            }
            lastBoundary = next
        }
        return (parts, false)
    }

    private static func find<Bytes: RandomAccessCollection>(_ needle: Data, in haystack: Bytes, from: Int, length: Int) -> Int?
    where Bytes.Element == UInt8, Bytes.Index == Int {
        return find([UInt8](needle), in: haystack, from: from, length: length)
    }

    /// The first index of `needle` inside `haystack[from ..< from + length]`.
    private static func find<Bytes: RandomAccessCollection>(_ needle: [UInt8], in haystack: Bytes, from: Int, length: Int) -> Int?
    where Bytes.Element == UInt8, Bytes.Index == Int {
        let base = haystack.startIndex
        let end = from + length
        guard !needle.isEmpty, length >= needle.count else { return nil }
        let first = needle[0]
        var index = from
        while index <= end - needle.count {
            if haystack[base + index] == first {
                var matches = true
                var k = 1
                while k < needle.count {
                    if haystack[base + index + k] != needle[k] { matches = false; break }
                    k += 1
                }
                if matches { return index }
            }
            index += 1
        }
        return nil
    }
}

/// Whether an incoming file may be a report from the cloud, to be joined to the
/// study it references. Missing metadata says no: it must not set off the
/// search of every study and SOP Instance of the database.
public enum CloudReportCandidate {
    public static func looksLikeReport(isPDFOrStructuredReport: Bool, modality: String?, seriesDescription: String?,
                                       manufacturer: String?) -> Bool {
        if isPDFOrStructuredReport { return true }
        if let modality, (modality as NSString).length != 0,
           (modality as NSString).caseInsensitiveCompare("DOC") == .orderedSame { return true }
        if let seriesDescription, (seriesDescription as NSString).length != 0,
           (seriesDescription as NSString).range(of: "Cloud", options: .caseInsensitive).location != NSNotFound { return true }
        if let manufacturer, (manufacturer as NSString).length != 0,
           (manufacturer as NSString).range(of: "Cloud", options: .caseInsensitive).location != NSNotFound { return true }
        return false
    }
}

/// How the compression or decompression of a batch of files is shared out.
public enum ConversionBatches {
    /// At most this many chunks.
    public static let maximumChunks = 10

    /// The smallest chunk: a tenth of the batch, and never under 100 files.
    public static func minimumChunkSize(fileCount: Int) -> Int {
        let chunkSize = fileCount / maximumChunks
        return chunkSize < 100 ? 100 : chunkSize
    }

    /// The chunks run at the same time: one per processor but one, and at least one.
    public static func concurrentChunks(processorCount: Int) -> Int {
        return max(processorCount - 1, 1)
    }
}

/// What an import that took less than it was given says about itself.
public enum ImportShortfall {
    /// Whether the copy from a medium logs its counts: a file could not be
    /// copied, or fewer files were indexed than copied.
    public static func copyIsIncomplete(failedCopies: Int, copied: Int, indexed: Int) -> Bool {
        return failedCopies != 0 || copied != indexed
    }

    /// The log line of an incomplete copy from a medium.
    public static func copyLogLine(offered: Int, copied: Int, indexed: Int, failedCopies: Int, firstFailure: String?) -> String {
        return String(format: "(copyFilesThread): %lu file(s) offered, %lu copied, %lu indexed, %lu could not be copied%@%@",
                      UInt(offered), UInt(copied), UInt(indexed), UInt(failedCopies),
                      firstFailure != nil ? ": " : "", firstFailure ?? "")
    }

    /// The text of the "Import incomplete" alert, or nil when nothing is
    /// missing. `copyFailed` is the localized format of the copy failure, with
    /// the count and the first failure; `oneRefused` and `manyRefused` (with
    /// the count) the localized sentences of the files the validation before
    /// importing refused, which the first five of them follow.
    public static func alertMessage(failedCopies: Int, firstFailure: String?, refusedFiles: [String],
                                    copyFailed: String, oneRefused: String, manyRefused: String) -> String? {
        var incomplete: [String] = []
        if failedCopies != 0 {
            incomplete.append(String(format: copyFailed, UInt(failedCopies), firstFailure ?? "(null)"))
        }
        if !refusedFiles.isEmpty {
            let count = refusedFiles.count == 1 ? oneRefused : String(format: manyRefused, UInt(refusedFiles.count))
            incomplete.append(String(format: "%@\n\n%@", count, ImportValidation.list(ofRefusedFiles: refusedFiles, limit: 5)))
        }
        return incomplete.isEmpty ? nil : incomplete.joined(separator: "\n\n")
    }

    /// The `done` an import's progress shows at file `index` of `total`: the
    /// index, and the total at the last one.
    public static func progressDone(index: Int, total: Int) -> Int {
        return index + 1 == total ? total : index
    }
}
