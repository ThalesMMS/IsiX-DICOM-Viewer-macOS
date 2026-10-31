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
import IsiXContracts

// The rules of the database's import that need no database: where a file goes
// when its name is taken, when the volume is too full to take more, what the
// scan of the incoming folder does with a name, which conversion a file
// gets, how a WADO-RS multipart body is cut into DICOM files, which incoming
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

    /// How long one scan goes on taking files, in seconds: nobody waits more than
    /// three check intervals for what it already took.
    public static func scanDuration(checkInterval: Int) -> TimeInterval {
        TimeInterval(checkInterval * 3)
    }

    /// Why a DICOM file stays out of the database, or nil when the triage lets it
    /// in. An IVUS/US object answers for itself; a file the IVUS gate does not
    /// apply to keeps the answer of the Enhanced one.
    public static func triageRefusal(stackMayMerge: Bool, stackError: String?, ivusApplies: Bool, ivusMayMerge: Bool, ivusError: String?) -> String? {
        if ivusApplies {
            return ivusMayMerge ? nil : nonEmpty(ivusError) ?? "the thumbnail stack cannot load this IVUS/US object"
        }
        return stackMayMerge ? nil : nonEmpty(stackError) ?? "the pixel/thumbnail stack cannot load this object"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text?.isEmpty == false ? text : nil
    }

    /// An archive the decompression helper could not expand comes back under this extension.
    public static func isUnexpandedArchive(named lastPathComponent: String) -> Bool {
        (lastPathComponent as NSString).pathExtension == "horos-unexpanded"
    }

    /// What is done to the scan's compressed files: decompressed when the listener
    /// decompresses (1) or leaves files as they are (0, so that archives are
    /// expanded), compressed when it compresses (2), nothing otherwise.
    public static func conversion(forListenerCompressionSettings settings: Int) -> FileConversionMode? {
        switch settings {
        case 0, 1: return .decompress
        case 2: return .compress
        default: return nil
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

    /// What became of a file that announces DICOM parts.
    public enum Unpacking: Equatable, Sendable {
        /// No part came out of it: the scan takes it as any other file.
        case notSplit
        /// Its parts are written and it has no further use.
        case split
        /// It is cut short, or a part could not be written: kept aside, with
        /// the parts it gave written.
        case keptAside
        /// It could not be kept aside. A file cut short had no part written, or
        /// each scan that finds it there would write them again.
        case stays
    }

    /// Writes the parts of a whole body with `write`. A body cut short is first
    /// kept aside by `keepAside`, which leaves the incoming folder without it and
    /// says whether it did, and only then gives the parts before the cut, so they
    /// are written once.
    public static func unpack(_ data: Data, keepAside: () -> Bool, write: (Data) -> Bool) -> Unpacking {
        let cut = dicomParts(in: data)
        if cut.malformed && !keepAside() { return .stays }
        var written = 0
        for part in cut.parts where write(data.subdata(in: part)) { written += 1 }
        if cut.malformed { return .keptAside }
        if written == 0 { return .notSplit }
        // A part that was not written exists only in this file.
        return written == cut.parts.count ? .split : keepAside() ? .keptAside : .stays
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

/// What counts as a study arriving, for the date its study and series were added.
public enum ImportArrival {
    /// Whether a file read for an image brings it to the database. The date feeds
    /// the albums of what was just added and the grace of the automatic cleanup,
    /// so a study sent again counts: its file comes in under a new name, or from
    /// outside the data folder, and a reread is asked for. The file the index
    /// already names, inside the data folder, is not an arrival: it is what a
    /// rebuild that keeps the index reads, and it brought nothing.
    public static func isArrival(storedPath: String?, file: String?, insideDataFolder: Bool, rereading: Bool) -> Bool {
        guard insideDataFolder, !rereading, let storedPath, let file else { return true }
        return storedPath != (file as NSString).lastPathComponent
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

/// How an import matches a described file to the studies already in the
/// database, and what a study keeps of the files that join it, decided on
/// values. The indexer reads the values from the file's dictionary and the
/// study, and writes what these say.
///
/// A study is found by its Study Instance UID and its patient. A series is the
/// one of the same Series Instance UID, as stored: a series that Reparse split
/// keeps the UID of the original with RP-1, RP-2… after it, so a file of the
/// original series read again makes a series of its own beside them.
public enum ImportMatching {
    /// Whether a file belongs to the patient of a study: the patient UIDs
    /// compare equal ignoring case, diacritics and width. A file without a
    /// patient UID belongs to any study, and a study without one to no file
    /// that has one, as the message to nil answered in the Objective-C.
    public static func isSamePatient(file: String?, study: String?) -> Bool {
        guard let file else { return true }
        guard let study else { return false }
        return (file as NSString).compare(study, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// Whether a study holds nothing but the "No Autodeletion" series, the
    /// marker the albums file (loadAlbums) leaves for a study of an album whose
    /// images are gone: the first file of that study that arrives makes it new
    /// again, with the file's patient and the date it arrived.
    public static func isAlbumMarkerOnly(seriesCount: Int, onlySeriesName: String?, onlySeriesID: Int32) -> Bool {
        seriesCount == 1 && SelectionImages.isNoAutodeletionSeries(name: onlySeriesName, id: onlySeriesID)
    }

    /// Whether the modality of a study gives way to that of the file that
    /// joins it: a study known so far only by a report (SR) or another object
    /// (OT) takes the modality of its images.
    public static func studyTakesFileModality(study: String?) -> Bool {
        same(study, "SR") || same(study, "OT")
    }

    /// Whether a new series gives its study the modality of its file: a study
    /// of secondary captures or other objects (SC, OT) takes a true modality.
    public static func seriesGivesStudyModality(study: String?, file: String?) -> Bool {
        (same(study, "OT") || same(study, "SC")) && !(same(file, "OT") || same(file, "SC"))
    }

    /// Whether a study takes the date of an arriving file: the earliest real
    /// date wins, and `undefined`, the date of a file without one, never does.
    public static func takesStudyDate(_ arriving: Date?, over existing: Date?, undefined: Date) -> Bool {
        guard let arriving, arriving != undefined else { return false }
        guard let existing, existing != undefined else { return true }
        return existing.timeIntervalSince(arriving) >= 0
    }

    /// Whether a study name says nothing, empty or "unnamed", so that the
    /// description of the study, or else of the series, takes its place.
    public static func isMissingStudyName(_ name: String?) -> Bool {
        ((name as NSString?)?.length ?? 0) == 0 || same(name, "unnamed")
    }

    /// Whether a report or a PDF read again writes a value of its file over
    /// the study's: only a value that says something, which a report made
    /// from the study's own fields may not repeat.
    public static func rereadReportWrites(_ value: String?, isDescription: Bool = false) -> Bool {
        ((value as NSString?)?.length ?? 0) != 0 && !(isDescription && same(value, "unnamed"))
    }

    /// The series whose rows a file read into `series` may already have:
    /// that series first and, for a series of the app's own SRs, every other
    /// series of the study with the same id. Each kind of the app's SRs gives
    /// all its files one series id, its name, so a study can hold several such
    /// series (two studies merged leave one each), and the lookup of a series
    /// by id answers only one of them: a file of another one, read again by a
    /// rebuild, would be indexed a second time.
    public static func seriesHoldingRows<Series: AnyObject>(of series: Series, ownSR: Bool, studySeries: [Series],
                                                            id: (Series) -> String?) -> [Series] {
        guard ownSR, let wanted = id(series) else { return [series] }
        return [series] + studySeries.filter { $0 !== series && id($0) == wanted }
    }

    /// `[string isEqualToString:other]`, NO for nil.
    private static func same(_ string: String?, _ other: String) -> Bool {
        (string as NSString?)?.isEqual(to: other) ?? false
    }
}
