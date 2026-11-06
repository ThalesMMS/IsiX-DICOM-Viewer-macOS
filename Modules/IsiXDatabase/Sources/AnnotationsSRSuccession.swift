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

/// Which of a study's annotations SRs give way to the one just written.
///
/// Every change to a study's annotations (its comments, its status, its key
/// images) writes a new "OsiriX Annotations SR" file with a new instance UID,
/// and the most recent one is the one read back. The earlier ones are kept by
/// nothing: they would pile up in the database folder and travel with every
/// export, send and drag of the study. Once the new one is in the database,
/// the earlier ones of the same study go.
///
/// Only the series the app makes for that SR counts (its id, its name and an
/// SR class): the ROI, report and windows-state SRs and any SR another
/// application made stay. Among the rows of that series, a row goes when it is
/// older than the one written, ordered as the app orders them to read the most
/// recent (the content date, then the number of the file in the database
/// folder), so an SR written later by a quicker edit is never removed by the
/// cleanup of an earlier one. A row that shares its file with a row that stays
/// is kept too: removing it would delete that file.
///
/// Once an SR is indexed, the study keeps only the one the app reads back
/// (`supersededOnceIndexed`): the new one, or a later one already there, and
/// then the new one goes too. A shared database's server indexes the SRs its
/// clients write and send, beside the ones it writes itself when a client
/// changes a study's annotations, in whatever order they arrive.
public enum AnnotationsSRSuccession {
    /// The id the app gives its annotations SR series.
    public static let seriesID: Int32 = 5004
    /// The name the app gives its annotations SR series.
    public static let seriesName = "OsiriX Annotations SR"

    /// One image row of a study's series, as the rule reads it.
    public struct Row<ID: Hashable>: Equatable {
        public let id: ID
        public let seriesID: Int32?
        public let seriesName: String?
        /// Whether the series' SOP class is a structured report.
        public let isStructuredReport: Bool
        /// The file of the row, nil when it has none.
        public let path: String?
        /// The SR's content date.
        public let date: Date?
        /// The number of its file in the database folder.
        public let pathNumber: Int64?

        public init(id: ID, seriesID: Int32?, seriesName: String?, isStructuredReport: Bool,
                    path: String?, date: Date?, pathNumber: Int64?) {
            self.id = id
            self.seriesID = seriesID
            self.seriesName = seriesName
            self.isStructuredReport = isStructuredReport
            self.path = path
            self.date = date
            self.pathNumber = pathNumber
        }
    }

    /// Whether a series is the app's annotations SR series.
    public static func isAnnotationsSeries(id: Int32?, name: String?, isStructuredReport: Bool) -> Bool {
        id == seriesID && name == seriesName && isStructuredReport
    }

    /// The rows of `rows` (a study's) that the annotations SR `written` makes
    /// obsolete. None when `written` is not among them, is not in the
    /// annotations series or has no file: nothing goes before the new SR is
    /// known to be in the database.
    public static func superseded<ID: Hashable>(by written: ID, among rows: [Row<ID>]) -> [ID] {
        guard let kept = rows.first(where: { $0.id == written }), isAnnotations(kept),
              let keptPath = normalized(kept.path) else { return [] }

        let older = rows.filter { row in
            row.id != written && isAnnotations(row) && normalized(row.path) != nil && isOlder(row, than: kept)
        }
        let leaving = Set(older.map(\.id))
        var stayingPaths = Set(rows.filter { !leaving.contains($0.id) }.compactMap { normalized($0.path) })
        stayingPaths.insert(keptPath)
        return older.filter { row in normalized(row.path).map { !stayingPaths.contains($0) } ?? false }.map(\.id)
    }

    /// The rows of `rows` (a study's) that go once the annotations SR
    /// `written` is in the database: the annotations SRs older than the
    /// study's most recent one, which the app reads back. That is `written`,
    /// unless a later one is already there; `written` then goes too. None
    /// when `written` is not among them, is not in the annotations series or
    /// has no file: nothing goes before the new SR is known to be in the
    /// database.
    public static func supersededOnceIndexed<ID: Hashable>(_ written: ID, among rows: [Row<ID>]) -> [ID] {
        guard let new = rows.first(where: { $0.id == written }), isAnnotations(new), normalized(new.path) != nil else { return [] }
        let latest = rows.filter { isAnnotations($0) && normalized($0.path) != nil }
            .reduce(new) { latest, row in isOlder(latest, than: row) ? row : latest }
        return superseded(by: latest.id, among: rows)
    }

    private static func isAnnotations<ID>(_ row: Row<ID>) -> Bool {
        isAnnotationsSeries(id: row.seriesID, name: row.seriesName, isStructuredReport: row.isStructuredReport)
    }

    /// The order in which the app reads the most recent SR: the date, then the
    /// file number. A tie is not older.
    private static func isOlder<ID>(_ row: Row<ID>, than kept: Row<ID>) -> Bool {
        let date = row.date ?? .distantPast, keptDate = kept.date ?? .distantPast
        if date != keptDate { return date < keptDate }
        return (row.pathNumber ?? -1) < (kept.pathNumber ?? -1)
    }

    private static func normalized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).standardizingPath
    }
}
