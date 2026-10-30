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

/// A consistent copy of an SQLite database, made with SQLite's online backup.
///
/// Copying the file of a database that is open copies a state that never
/// existed: the latest transactions may still be in its write-ahead log (the
/// `-wal` file beside it), and a writer may change pages during the copy.
/// The backup reads the database through SQLite, log included, inside one read
/// transaction, so the copy is the database as it was at one moment.
enum SQLiteSnapshot {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Copies the database at `source` into a new file at `destination`.
    ///
    /// The source is opened read-only. With no write-ahead log beside it, no
    /// connection has it open, and it is opened as immutable, which creates no
    /// file beside it and takes no lock. With a log, it is read through the
    /// log; SQLite may then refresh the shared-memory index (`-shm`) beside it,
    /// which holds no data.
    static func copy(from source: URL, to destination: URL) throws {
        let log = source.path + "-wal"
        let reader = try open(source, parameters: FileManager.default.fileExists(atPath: log) ? "mode=ro" : "immutable=1",
                              flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(reader) }
        let writer = try open(destination, parameters: nil, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close_v2(writer) }
        guard let backup = sqlite3_backup_init(writer, "main", reader, "main") else {
            throw Failure(description: "cannot start the copy: \(message(writer))")
        }
        var result: Int32
        repeat {
            result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { sqlite3_sleep(50) }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw Failure(description: "the copy did not finish: \(message(writer))")
        }
        // The copy keeps the source's journal mode; in rollback mode it is one
        // file, complete by itself. Core Data turns the log back on when it
        // opens the store.
        guard try strings(writer, "PRAGMA journal_mode=DELETE") == ["delete"] else {
            throw Failure(description: "the copy kept its write-ahead log")
        }
    }

    /// Whether the database at `url` passes SQLite's integrity check and
    /// has the same tables and indexes as `reference`. Opens both as immutable:
    /// nothing is written beside either.
    static func validate(_ url: URL, against reference: URL) throws {
        let copy = try open(url, parameters: "immutable=1", flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(copy) }
        let verdict = try strings(copy, "PRAGMA integrity_check")
        guard verdict == ["ok"] else {
            throw Failure(description: "the copy is damaged: \(verdict.prefix(3).joined(separator: "; "))")
        }
        let log = reference.path + "-wal"
        let original = try open(reference, parameters: FileManager.default.fileExists(atPath: log) ? "mode=ro" : "immutable=1",
                                flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(original) }
        let schema = "SELECT type || ' ' || name FROM sqlite_master ORDER BY type, name"
        guard try strings(copy, schema) == strings(original, schema) else {
            throw Failure(description: "the copy does not have the tables of the original")
        }
    }

    private static func open(_ url: URL, parameters: String?, flags: Int32) throws -> OpaquePointer {
        var uri = url.absoluteString
        if let parameters { uri += "?" + parameters }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(uri, &handle, flags | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let handle else {
            let reason = handle.map(message) ?? String(cString: sqlite3_errstr(result))
            sqlite3_close_v2(handle)
            throw Failure(description: "cannot open \(url.lastPathComponent): \(reason)")
        }
        sqlite3_busy_timeout(handle, 5000)
        return handle
    }

    private static func strings(_ handle: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: message(handle))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(description: message(handle)) }
            rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return rows
    }

    private static func message(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
