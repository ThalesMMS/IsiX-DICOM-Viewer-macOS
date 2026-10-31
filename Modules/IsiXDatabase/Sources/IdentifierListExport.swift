//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CryptoKit
import Foundation

/// Exporting the studies named by a list of identifiers, and saying what happened.
///
/// The request behind this is five hundred medical record numbers and no wish to
/// find each one by hand. Two things make that safe to run unattended: the list
/// is resolved by identifier and never by name, so two patients who share a name
/// are never merged; and the export leaves a report saying, per identifier, what
/// was found, how many files, how many bytes, and a digest of them, so a run can
/// be checked afterwards instead of trusted. Finding the studies and copying
/// their files is the app's; the list, the report and the digest are here.
public enum IdentifierListExport {

    /// One identifier per line. Blank lines and `#` comments are dropped, and an
    /// identifier written twice is kept once, in the order it was first written -
    /// a list pasted from a spreadsheet usually has both.
    public static func identifiers(fromText text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var value = line
            if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex ..< hash]) }
            // A CSV column, not just a bare list: take the first field.
            if let comma = value.firstIndex(of: ",") { value = String(value[value.startIndex ..< comma]) }
            value = value.trimmingCharacters(in: .whitespaces)
                         .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty, !seen.contains(value) else { continue }
            seen.insert(value)
            out.append(value)
        }
        return out
    }

    /// The report's columns.
    public static let header = ["Identifier", "Status", "PatientNames", "Studies",
                                "Files", "Bytes", "Digest", "Detail"]

    /// The report, beside the exported studies.
    public static let reportFileName = "horos-export-manifest.csv"

    /// What became of one identifier.
    public enum Status: String, Sendable, CaseIterable {
        case exported = "exported"
        case dryRun = "dry run"
        case failed = "failed"
        case notFound = "not found"
        case cancelled = "cancelled"

        /// The status of an identifier whose studies were found: cancelled
        /// wins over a trouble met, which wins over the kind of run.
        public static func ofFoundStudies(cancelled: Bool, troubled: Bool, dryRun: Bool) -> Status {
            cancelled ? .cancelled : (troubled ? .failed : (dryRun ? .dryRun : .exported))
        }

        /// How the whole run ended, for the log.
        public static func ofRun(cancelled: Bool, dryRun: Bool) -> Status {
            cancelled ? .cancelled : (dryRun ? .dryRun : .exported)
        }
    }

    public static func row(identifier: String, status: String, names: [String], studies: Int,
                           files: Int, bytes: Int64, digest: String, detail: String) -> [String] {
        [identifier, status, names.joined(separator: "; "), String(studies),
         String(files), String(bytes), digest, detail]
    }

    /// The row of an identifier that was not exported at all.
    public static func row(identifier: String, status: Status) -> [String] {
        row(identifier: identifier, status: status.rawValue, names: [], studies: 0, files: 0, bytes: 0,
            digest: "", detail: "")
    }

    /// The names an identifier answers to, each once, in the order of its
    /// studies, empty names left out. More than one is worth saying out loud:
    /// it is either a correction or two people in one record.
    public static func names(_ names: [String?]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            guard let name, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// The detail of a file the database names and the disk does not have.
    public static func missingFile(studyInstanceUID: String?) -> String {
        "missing file for " + (studyInstanceUID ?? "(null)")
    }

    /// The detail of a file that could not be read for the digest.
    public static func unreadable(path: String) -> String {
        "unreadable " + (path as NSString).lastPathComponent
    }

    /// The report file of the rows, as the metadata export writes its CSV.
    public static func report(rows: [[String]]) -> String {
        StudyMetadataCSV.csv(fromRows: rows)
    }

    /// A digest of a set of files that does not depend on the order they were read.
    ///
    /// Each file is hashed on its own and the hexadecimal digests are sorted before
    /// being hashed together, so two runs that enumerate the same files in different
    /// orders produce the same answer - and a file that changed, went missing or
    /// arrived produces a different one.
    public struct FileSetDigest: Sendable {
        private var digests: [String] = []
        public private(set) var fileCount: Int = 0
        public private(set) var byteCount: Int64 = 0
        /// Files that could not be read, by path, in the order they failed.
        public private(set) var unreadable: [String] = []

        public init() {}

        @discardableResult
        public mutating func add(path: String) -> Bool {
            guard let handle = FileHandle(forReadingAtPath: path) else {
                unreadable.append(path)
                return false
            }
            defer { try? handle.close() }
            var hasher = SHA256()
            var read: Int64 = 0
            while true {
                guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                read += Int64(chunk.count)
            }
            digests.append(hasher.finalize().map { String(format: "%02x", $0) }.joined())
            fileCount += 1
            byteCount += read
            return true
        }

        /// The digest of everything added so far, or an empty string when nothing was.
        public var hexDigest: String {
            guard !digests.isEmpty else { return "" }
            var hasher = SHA256()
            for digest in digests.sorted() { hasher.update(data: Data(digest.utf8)) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
