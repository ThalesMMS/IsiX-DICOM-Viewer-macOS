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
import SQLite3

/// What "Rebuild SQL File" reads with SQLite itself, around the sqlite3 tool:
/// how far each table of a damaged index can be read, and what the file made out
/// of it holds. Every connection is read-only: a refused index stays byte for byte.
public enum IndexFileProbe {

    /// The first bytes of a file; nil when it cannot be read.
    public static func header(ofFileAtPath path: String) -> Data? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        return (try? file.read(upToCount: IndexRepairRules.headerLength)) ?? nil
    }

    /// Every table of the index, read to its last row, as the dump reads them:
    /// each row out of the table itself and not out of an index of it, with what
    /// it keeps on other pages. Nil when the file does not open, its schema
    /// cannot be read, or something else holds the database. `uri` comes from
    /// `IndexRepairRules.readingURI`.
    public static func tableScans(ofIndexAt uri: String) -> [IndexTableScan]? {
        guard let handle = open(uri) else { return nil }
        defer { sqlite3_close_v2(handle) }
        guard let names = tableNames(handle) else { return nil }
        var scans: [IndexTableScan] = []
        for name in names {
            guard let scan = scan(name, handle) else { return nil }
            scans.append(scan)
        }
        return scans
    }

    /// The new file; nil when it does not open.
    public static func state(ofRepairedIndexAtPath path: String) -> RepairedIndexState? {
        guard let handle = open(path) else { return nil }
        defer { sqlite3_close_v2(handle) }
        // A file too damaged for the check to end does not pass it either.
        let passes = strings(handle, "PRAGMA quick_check") == ["ok"]
        var rows: [String: Int] = [:]
        for table in tableNames(handle) ?? [] {
            if let count = strings(handle, "SELECT count(*) FROM \(quoted(table))")?.first.flatMap({ Int($0) }) {
                rows[table] = count
            }
        }
        return RepairedIndexState(passesQuickCheck: passes, rows: rows)
    }

    private static func open(_ name: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(name, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 5000)
        return handle
    }

    /// The tables with rows of their own. SQLite's statistics come back by
    /// themselves, and a virtual table has nothing in the file.
    private static func tableNames(_ handle: OpaquePointer) -> [String]? {
        return strings(handle, "SELECT name FROM sqlite_master WHERE type = 'table' AND rootpage > 0 AND name NOT GLOB 'sqlite_*'")
    }

    private static func quoted(_ name: String) -> String {
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A table that cannot even be asked for its rows reads as one that stopped.
    private static func scan(_ table: String, _ handle: OpaquePointer) -> IndexTableScan? {
        var scan = IndexTableScan(table: table, rows: 0, isComplete: false)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT * FROM \(quoted(table)) NOT INDEXED", -1, &statement, nil) == SQLITE_OK else { return scan }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                scan.rows += 1
            case SQLITE_DONE:
                scan.isComplete = true
                return scan
            case SQLITE_BUSY, SQLITE_LOCKED:
                return nil
            default:
                return scan
            }
        }
    }

    /// The first column of each row; nil when the statement fails.
    private static func strings(_ handle: OpaquePointer, _ sql: String) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { return nil }
            rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
    }
}

/// The two steps of `IndexRepairRules.replaceIndex` that touch the index.
public enum IndexFileSwap {

    /// A second name for the index, on the same file. A volume with no hard links
    /// gets a copy, compared with the index before it counts.
    public static func keep(_ index: String, as retired: String) throws {
        guard link(index, retired) != 0 else { return }
        let fileManager = FileManager.default
        try fileManager.copyItem(atPath: index, toPath: retired)
        guard fileManager.contentsEqual(atPath: index, andPath: retired) else {
            try? fileManager.removeItem(atPath: retired)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The new file takes the name of the index in one step. `moveItem` would
    /// refuse a name that exists, and a remove before it would leave a moment
    /// without an index.
    public static func replace(_ index: String, with new: String) throws {
        guard rename(new, index) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
