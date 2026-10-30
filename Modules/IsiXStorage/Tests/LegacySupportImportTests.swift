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
import Testing
@testable import IsiXStorage

/// Synthetic old and new support folders: the source never changes, what is
/// already in the destination is never replaced, plugins are never copied.
@Suite struct LegacySupportImportTests {
    let items = LegacySupportImport.Item.standard(includingAccounts: true)

    /// A fresh domain, its name with spaces, accents and CJK characters.
    final class Domain {
        let root: URL
        let user: String
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("IsiXStorage import \(UUID().uuidString)", isDirectory: true)
            user = root.appendingPathComponent("Usuário Ünïcode 日本/com espaços", isDirectory: true).path
            try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        }
        var old: URL { URL(fileURLWithPath: StorageLocations.legacySupportFolder(inDomain: user), isDirectory: true) }
        var new: URL { URL(fileURLWithPath: StorageLocations.supportFolder(for: .direct, inDomain: user), isDirectory: true) }
        deinit {
            _ = try? FileManager.default.subpathsOfDirectory(atPath: root.path).forEach {
                chmod(root.appendingPathComponent($0).path, 0o755)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: fixtures

    /// Writes files, making their folders.
    func write(_ files: [String: String], in folder: URL) throws {
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    /// A Web Portal accounts database in WAL mode. With `keepOpen`, the
    /// returned connection still holds rows only in the write-ahead log.
    @discardableResult
    func makeAccounts(at url: URL, users: [String], keepOpen: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        func exec(_ sql: String) { #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA wal_autocheckpoint=0")
        exec("CREATE TABLE ZWEBPORTALUSER (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT)")
        for user in users { exec("INSERT INTO ZWEBPORTALUSER (ZNAME) VALUES ('\(user)')") }
        if keepOpen { return handle }
        sqlite3_close(handle)
        return nil
    }

    func users(in url: URL) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT ZNAME FROM ZWEBPORTALUSER ORDER BY Z_PK", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }
        return names
    }

    /// Every file under a folder with its SHA-256, and every folder. A
    /// database's shared-memory index (`-shm`) is left out: SQLite rewrites it
    /// whenever a connection reads the database through its log, and it holds
    /// no data.
    func snapshot(_ folder: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        var result: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) where !path.hasSuffix("-shm") {
            do {
                result[path] = try LegacySupportImport.digest(of: folder.appendingPathComponent(path))
            } catch {
                Issue.record("\(path): \(error)")
                throw error
            }
        }
        return result
    }

    func fullSource(_ domain: Domain) throws {
        try makeAccounts(at: domain.old.appendingPathComponent("WebUsers.sql"), users: ["ana", "bruno"])
        try write(["WebServicesHTML/index.html": "<p>página</p>", "WebServicesHTML/css/café.css": "body{}",
                   "WebServicesHTML/日本 語/ページ.html": "<p>ページ</p>",
                   "Weasis/conf/ext-config.properties": "weasis.theme=dark",
                   "Plugins/Legacy.horosplugin/Contents/Info.plist": "<plist/>",
                   "Plugins Disabled/Old.osirixplugin/Contents/Info.plist": "<plist/>",
                   "Plugin_Loading.thalesmms.isis.workstation": "/somewhere/Legacy.horosplugin"], in: domain.old)
    }

    // MARK: cases

    @Test func absentSource() throws {
        let domain = try Domain()
        let migration = LegacySupportImport(userDomain: domain.user, items: items)
        #expect(migration.survey().map(\.status) == [.sourceAbsent, .sourceAbsent, .sourceAbsent])
        #expect(migration.run().map(\.status) == [.sourceAbsent, .sourceAbsent, .sourceAbsent])
        // Nothing to import makes no folder, and nothing is recorded.
        #expect(!FileManager.default.fileExists(atPath: domain.new.path))
        #expect(!migration.isSettled)
    }

    @Test func onlySourceIsCopiedWithoutPluginsAndSourceUnchanged() throws {
        let domain = try Domain()
        try fullSource(domain)
        let before = try snapshot(domain.old)
        let migration = LegacySupportImport(userDomain: domain.user, items: items)
        #expect(migration.survey().map(\.status) == [.pending, .pending, .pending])

        #expect(migration.run().map(\.status) == [.imported, .imported, .imported])
        #expect(try snapshot(domain.old) == before)
        #expect(users(in: domain.new.appendingPathComponent("WebUsers.sql")) == ["ana", "bruno"])
        for folder in ["WebServicesHTML", "Weasis"] {
            #expect(try LegacySupportImport.digest(of: domain.new.appendingPathComponent(folder))
                    == LegacySupportImport.digest(of: domain.old.appendingPathComponent(folder)))
        }
        let copied = try FileManager.default.contentsOfDirectory(atPath: domain.new.path).sorted()
        #expect(copied == [LegacySupportImport.stateFileName, "Weasis", "WebServicesHTML", "WebUsers.sql"])
        #expect(migration.isComplete)

        // Again: nothing changes, in either folder.
        let after = try snapshot(domain.new)
        #expect(migration.run().map(\.status) == [.imported, .imported, .imported])
        #expect(try snapshot(domain.new) == after)
        #expect(try snapshot(domain.old) == before)
    }

    @Test func openDatabaseIsCopiedWithItsWriteAheadLog() throws {
        let domain = try Domain()
        let accounts = domain.old.appendingPathComponent("WebUsers.sql")
        let writer = try makeAccounts(at: accounts, users: ["carla", "dora"], keepOpen: true)
        defer { sqlite3_close(writer) }
        #expect(FileManager.default.fileExists(atPath: accounts.path + "-wal"))
        let main = try LegacySupportImport.digest(of: accounts), log = try LegacySupportImport.digest(of: URL(fileURLWithPath: accounts.path + "-wal"))

        let migration = LegacySupportImport(userDomain: domain.user, items: [.webPortalAccounts])
        #expect(migration.run().map(\.status) == [.imported])
        // The rows that were only in the log are in the copy, which has no log of its own.
        #expect(users(in: domain.new.appendingPathComponent("WebUsers.sql")) == ["carla", "dora"])
        #expect(!FileManager.default.fileExists(atPath: domain.new.appendingPathComponent("WebUsers.sql-wal").path))
        #expect(try LegacySupportImport.digest(of: accounts) == main)
        #expect(try LegacySupportImport.digest(of: URL(fileURLWithPath: accounts.path + "-wal")) == log)
    }

    @Test func onlyDestinationIsLeftAlone() throws {
        let domain = try Domain()
        try makeAccounts(at: domain.new.appendingPathComponent("WebUsers.sql"), users: ["eva"])
        try write(["WebServicesHTML/index.html": "<p>new</p>"], in: domain.new)
        let before = try snapshot(domain.new)
        let migration = LegacySupportImport(userDomain: domain.user, items: items)
        #expect(migration.run().map(\.status) == [.sourceAbsent, .sourceAbsent, .sourceAbsent])
        var after = try snapshot(domain.new)
        after[LegacySupportImport.stateFileName] = nil
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: domain.old.path))
    }

    @Test func conflictKeepsDestinationAndIsNotMerged() throws {
        let domain = try Domain()
        try fullSource(domain)
        try makeAccounts(at: domain.new.appendingPathComponent("WebUsers.sql"), users: ["fábio"])
        try write(["WebServicesHTML/index.html": "<p>mine</p>", "WebServicesHTML/extra.html": "x"], in: domain.new)
        // The same Weasis customization in both is not a conflict.
        try FileManager.default.copyItem(at: domain.old.appendingPathComponent("Weasis"), to: domain.new.appendingPathComponent("Weasis"))
        let source = try snapshot(domain.old), destination = try snapshot(domain.new)

        let migration = LegacySupportImport(userDomain: domain.user, items: items)
        #expect(migration.survey().map(\.status) == [.conflict, .conflict, .imported])
        let results = migration.run()
        #expect(results.map(\.status) == [.conflict, .conflict, .imported])
        #expect(try snapshot(domain.old) == source)
        var now = try snapshot(domain.new)
        now[LegacySupportImport.stateFileName] = nil
        #expect(now == destination)
        #expect(users(in: domain.new.appendingPathComponent("WebUsers.sql")) == ["fábio"])
        #expect(!migration.isSettled)

        // Once the user has been told, the destination's are kept for good.
        try migration.keepExisting(results)
        #expect(migration.survey().map(\.status) == [.keptExisting, .keptExisting, .imported])
        #expect(migration.isComplete)
        now = try snapshot(domain.new)
        now[LegacySupportImport.stateFileName] = nil
        #expect(now == destination)
    }

    @Test func permissionDeniedIsRecoverable() throws {
        let domain = try Domain()
        try fullSource(domain)
        let locked = domain.old.appendingPathComponent("WebServicesHTML/日本 語")
        #expect(chmod(locked.path, 0) == 0)
        let migration = LegacySupportImport(userDomain: domain.user, items: items)
        let first = migration.run()
        #expect(first.map(\.status)[0] == .imported)
        guard case .failed(let reason) = first[1].status else {
            Issue.record("expected a failure, got \(first[1].status)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(first[2].status == .imported)
        #expect(!FileManager.default.fileExists(atPath: domain.new.appendingPathComponent("WebServicesHTML").path))
        #expect(!FileManager.default.fileExists(atPath: domain.new.appendingPathComponent(LegacySupportImport.stagingFolderName).path))
        #expect(!migration.isComplete)

        #expect(chmod(locked.path, 0o755) == 0)
        let before = try snapshot(domain.old)
        #expect(migration.run().map(\.status) == [.imported, .imported, .imported])
        #expect(try snapshot(domain.old) == before)
        #expect(migration.isComplete)
    }

    @Test func unwritableDestinationFailsWithoutTouchingTheSource() throws {
        let domain = try Domain()
        try fullSource(domain)
        let before = try snapshot(domain.old)
        let parent = domain.root.appendingPathComponent("read only", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect(chmod(parent.path, 0o555) == 0)
        let migration = LegacySupportImport(source: domain.old, destination: parent.appendingPathComponent("IsiX"), items: items)
        let results = migration.run()
        #expect(results.allSatisfy { if case .failed = $0.status { return true } else { return false } })
        #expect(try snapshot(domain.old) == before)
        #expect(!migration.isSettled)
    }

    @Test func interruptedRunsResume() throws {
        let domain = try Domain()
        try fullSource(domain)
        let before = try snapshot(domain.old)

        // Stopped after the pages were copied and checked, before their rename.
        var migration = LegacySupportImport(userDomain: domain.user, items: items)
        migration.stopsAt = { item, moment in item == .customWebPages && moment == .staged }
        #expect(migration.run().map(\.status) == [.imported])
        #expect(FileManager.default.fileExists(atPath: domain.new.appendingPathComponent(LegacySupportImport.stagingFolderName).path))
        #expect(!FileManager.default.fileExists(atPath: domain.new.appendingPathComponent("WebServicesHTML").path))
        #expect(!migration.isComplete)

        // Stopped right after Weasis was renamed into place, before that was recorded.
        migration.stopsAt = { item, moment in item == .weasis && moment == .renamed }
        #expect(migration.run().map(\.status) == [.imported, .imported])
        #expect(!migration.isComplete)

        migration.stopsAt = nil
        #expect(migration.survey().map(\.status) == [.imported, .imported, .imported])
        #expect(migration.run().map(\.status) == [.imported, .imported, .imported])
        #expect(migration.isComplete)
        #expect(!FileManager.default.fileExists(atPath: domain.new.appendingPathComponent(LegacySupportImport.stagingFolderName).path))
        #expect(try snapshot(domain.old) == before)
        #expect(try LegacySupportImport.digest(of: domain.new.appendingPathComponent("WebServicesHTML"))
                == LegacySupportImport.digest(of: domain.old.appendingPathComponent("WebServicesHTML")))
    }

    @Test func declineCopiesNothing() throws {
        let domain = try Domain()
        try fullSource(domain)
        let migration = LegacySupportImport(userDomain: domain.user, items: items)
        try migration.decline()
        #expect(migration.isSettled)
        #expect(!migration.isComplete)
        #expect(try FileManager.default.contentsOfDirectory(atPath: domain.new.path) == [LegacySupportImport.stateFileName])
    }
}
