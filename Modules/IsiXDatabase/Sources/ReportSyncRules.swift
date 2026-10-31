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

/// What the application remembers of a report opened in the session between two
/// checks against the DICOM SR the database keeps of it.
public struct ReportSyncRecord: Sendable, Equatable {
    /// The modification date of the report when its SR last matched it; the
    /// distant past until a check has matched.
    public var verifiedModificationDate: Date
    /// The signature of the report and its SR taken before the last check that
    /// found them equal without archiving; nil when the next check has to read
    /// the contents.
    public var signature: String?

    public init(verifiedModificationDate: Date, signature: String?) {
        self.verifiedModificationDate = verifiedModificationDate
        self.signature = signature
    }

    /// A report just opened, created or attached: the next check reads it, even
    /// when the archive of its previous session failed.
    public static let unverified = ReportSyncRecord(verifiedModificationDate: .distantPast, signature: nil)
}

/// When a report opened in the session is archived again as the DICOM SR of its
/// study.
///
/// Each time the application becomes active, before it draws its windows, every
/// report opened in the session is compared with its SR, and archived again when
/// they differ. Reading the SR and comparing the contents costs milliseconds per
/// megabyte of every report, so the comparison is skipped while the signature
/// of the report and its SR (identity, size, mode, modification and status
/// change times of every item, packages included) is the one recorded at the
/// last check that found them equal. A modification date alone is not enough:
/// an editor can keep it, and a document package changes its inner files
/// without touching the date of the package.
public enum ReportSyncRules {

    /// Whether the report has to be compared with its SR: always, unless the
    /// files carry the signature recorded at the last check. A signature that
    /// could not be taken (nil) never matches.
    public static func needsComparison(_ record: ReportSyncRecord, signature: String?) -> Bool {
        guard let signature else { return true }
        return record.signature != signature
    }

    /// One check of a report: what to remember of it afterwards.
    ///
    /// - Parameters:
    ///   - modified: the modification date of the report; nil when its file
    ///     cannot be read, which leaves the record as it was.
    ///   - signature: the signature of the report and its SR, taken before the
    ///     comparison, so that a change made during it is seen next time.
    ///   - matchesArchive: whether the report and its SR have the same contents.
    ///   - archive: archives the report as a new SR of its study.
    ///
    /// A report that differs is archived and compared again. One that matches
    /// records its date, and its signature unless it was just archived: the new
    /// SR has a signature of its own, which the next check records. One that
    /// still differs, because the archive failed, stays pending: a matching
    /// date is not proof that the document was archived.
    public static func check(_ record: ReportSyncRecord, modified: Date?, signature: String?,
                             matchesArchive: () -> Bool, archive: () -> Void) -> ReportSyncRecord {
        guard let modified, needsComparison(record, signature: signature) else { return record }
        var matches = matchesArchive()
        let archived = !matches
        if archived {
            archive()
            matches = matchesArchive()
        }
        var checked = record
        if matches {
            checked.verifiedModificationDate = modified
            checked.signature = archived ? nil : signature
        } else {
            checked.signature = nil
        }
        return checked
    }
}
