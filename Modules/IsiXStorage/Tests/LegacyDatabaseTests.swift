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

/// Synthetic data folders of an earlier application: found by name, read
/// without a byte of them changing, with the tables as Core Data names them.
@Suite struct LegacyDatabaseTests {
    final class Documents {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("IsiXStorage legacy \(UUID().uuidString)/Documentos 日本", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    /// A database with the tables of the earlier applications. `join` is the
    /// table of the albums' studies, whose name and columns carry the
    /// entities' numbers.
    func makeDatabase(in folder: URL, join: (table: String, album: String, study: String) = ("Z_1STUDIES", "Z_1ALBUMS", "Z_5STUDIES"),
                      statements: [String] = []) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(LegacyDatabase.imagesFolderName), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent(LegacyDatabase.storeName).path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        func exec(_ sql: String) { #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        exec("CREATE TABLE ZSTUDY (Z_PK INTEGER PRIMARY KEY, ZSTATETEXT INTEGER, ZSTUDYINSTANCEUID VARCHAR, ZCOMMENT VARCHAR, ZCOMMENT2 VARCHAR, ZCOMMENT3 VARCHAR, ZCOMMENT4 VARCHAR)")
        exec("CREATE TABLE ZALBUM (Z_PK INTEGER PRIMARY KEY, ZINDEX INTEGER, ZSMARTALBUM INTEGER, ZNAME VARCHAR, ZPREDICATESTRING VARCHAR)")
        exec("CREATE TABLE \(join.table) (\(join.album) INTEGER, \(join.study) INTEGER)")
        exec("CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZPATHNUMBER INTEGER, ZSTOREDINDATABASEFOLDER INTEGER, ZPATHSTRING VARCHAR)")
        statements.forEach(exec)
    }

    func bytes(of folder: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            var isDirectory: ObjCBool = false
            let url = folder.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                found[path] = try Data(contentsOf: url)
            }
        }
        return found
    }

    @Test func theFoldersOfEarlierApplicationsAreFoundByName() throws {
        let documents = try Documents()
        #expect(LegacyDatabase.found(inDocuments: documents.root).isEmpty)
        // A folder without a database is not a data folder.
        try FileManager.default.createDirectory(at: documents.root.appendingPathComponent("OsiriX Data"), withIntermediateDirectories: true)
        #expect(LegacyDatabase.found(inDocuments: documents.root).isEmpty)
        try makeDatabase(in: documents.root.appendingPathComponent("Horos Data"))
        #expect(LegacyDatabase.found(inDocuments: documents.root).map(\.folder.lastPathComponent) == ["Horos Data"])
        try makeDatabase(in: documents.root.appendingPathComponent("OsiriX Data"))
        #expect(LegacyDatabase.found(inDocuments: documents.root).map(\.folder.lastPathComponent) == ["Horos Data", "OsiriX Data"])
    }

    @Test func aChosenFolderStandsForItsDataFolder() throws {
        let documents = try Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try makeDatabase(in: data)
        #expect(LegacyDatabase.resolving(data)?.folder == data)
        // The folder chosen as the database location holds the data folder.
        #expect(LegacyDatabase.resolving(documents.root)?.folder.path == data.path)
        #expect(LegacyDatabase.resolving(data.appendingPathComponent(LegacyDatabase.imagesFolderName)) == nil)
    }

    @Test func theStudiesComeWithTheirNotesAndAlbums() throws {
        let documents = try Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try makeDatabase(in: data, statements: [
            "INSERT INTO ZSTUDY VALUES (1, 3, '1.2.3', 'first', NULL, 'third', NULL)",
            "INSERT INTO ZSTUDY VALUES (2, NULL, '1.2.4', NULL, NULL, NULL, NULL)",
            "INSERT INTO ZSTUDY VALUES (3, 0, NULL, 'no identifier', NULL, NULL, NULL)",
            "INSERT INTO ZSTUDY VALUES (4, 1, '1.2.3', 'the same study twice', NULL, NULL, NULL)",
            "INSERT INTO ZALBUM VALUES (1, 1, 0, 'Teaching', NULL)",
            "INSERT INTO ZALBUM VALUES (2, 0, 1, 'Today', 'dateAdded >= $TODAY')",
            "INSERT INTO ZALBUM VALUES (3, 2, 0, 'Empty', NULL)",
            "INSERT INTO Z_1STUDIES VALUES (1, 1)", "INSERT INTO Z_1STUDIES VALUES (1, 2)", "INSERT INTO Z_1STUDIES VALUES (2, 2)",
            "INSERT INTO ZIMAGE VALUES (1, 17, 1, NULL)", "INSERT INTO ZIMAGE VALUES (2, 18, 1, '18.dcm')",
        ])
        let contents = try LegacyDatabase(folder: data).contents()
        #expect(contents.studies == [
            LegacyDatabase.Study(uid: "1.2.3", comments: ["first", "", "third", ""], state: 3, albums: ["Teaching"]),
            LegacyDatabase.Study(uid: "1.2.4", comments: ["", "", "", ""], state: 0, albums: ["Teaching"]),
        ])
        #expect(contents.studies.map(\.hasNotes) == [true, true])
        #expect(!LegacyDatabase.Study(uid: "1").hasNotes)
        // In the order of the list; a smart album carries its rule and no studies.
        #expect(contents.albums == [LegacyDatabase.Album(name: "Today", predicate: "dateAdded >= $TODAY"),
                                    LegacyDatabase.Album(name: "Teaching"), LegacyDatabase.Album(name: "Empty")])
        #expect(contents.imageCount == 2)
        #expect(contents.linkedFiles.isEmpty)
    }

    @Test func theNotesOnlyFillWhatIsEmpty() {
        let study = LegacyDatabase.Study(uid: "1", comments: ["first", "", "third", "fourth"], state: 4, albums: ["Teaching", "Cases"])
        let nothing = study.notesMissing(comments: ["", "", "", ""], state: 0, albums: [])
        #expect(nothing == LegacyDatabase.MissingNotes(comments: [0: "first", 2: "third", 3: "fourth"], state: 4, albums: ["Teaching", "Cases"]))
        let some = study.notesMissing(comments: ["written here", "second", "", "fourth"], state: 2, albums: ["Cases"])
        #expect(some == LegacyDatabase.MissingNotes(comments: [2: "third"], state: nil, albums: ["Teaching"]))
        #expect(study.notesMissing(comments: ["a", "", "c", "d"], state: 1, albums: ["Teaching", "Cases"]).isEmpty)
        #expect(LegacyDatabase.Study(uid: "2").notesMissing(comments: [], state: 0, albums: []).isEmpty)
    }

    @Test func theJoinTableIsFoundWhateverItsNumbers() throws {
        let documents = try Documents()
        let data = documents.root.appendingPathComponent("OsiriX Data")
        try makeDatabase(in: data, join: ("Z_2STUDIES", "Z_2ALBUMS", "Z_7STUDIES"), statements: [
            "INSERT INTO ZSTUDY VALUES (9, 0, '9.9', NULL, NULL, NULL, NULL)",
            "INSERT INTO ZALBUM VALUES (4, 0, 0, 'Cases', NULL)",
            "INSERT INTO Z_2STUDIES VALUES (4, 9)",
        ])
        #expect(try LegacyDatabase(folder: data).contents().studies == [LegacyDatabase.Study(uid: "9.9", albums: ["Cases"])])
    }

    @Test func filesLeftWhereTheyWereAreListedOnce() throws {
        let documents = try Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        let outside = documents.root.appendingPathComponent("Exams/ct.dcm"), gone = documents.root.appendingPathComponent("Exams/gone.dcm")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 3000).write(to: outside)
        let inside = data.appendingPathComponent("DATABASE.noindex/10000/1.dcm")
        try makeDatabase(in: data, statements: [
            "INSERT INTO ZSTUDY VALUES (1, 0, '1.2.3', NULL, NULL, NULL, NULL)",
            "INSERT INTO ZIMAGE VALUES (1, 1, 1, NULL)",
            // A multiframe file, a frame per row; a file that is no longer there; a path inside the data folder.
            "INSERT INTO ZIMAGE VALUES (2, 0, 0, '\(outside.path)')", "INSERT INTO ZIMAGE VALUES (3, 0, 0, '\(outside.path)')",
            "INSERT INTO ZIMAGE VALUES (4, 0, 0, '\(gone.path)')", "INSERT INTO ZIMAGE VALUES (5, 0, 0, '\(inside.path)')",
        ])
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: inside)
        try Data(count: 10).write(to: data.appendingPathComponent("DATABASE.noindex/10000/.DS_Store"))

        let database = LegacyDatabase(folder: data)
        let contents = try database.contents()
        #expect(contents.linkedFiles == [outside.path, gone.path].sorted())
        let files = try #require(database.files(linked: contents.linkedFiles))
        #expect(files.paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == [inside, outside].map { $0.resolvingSymlinksInPath().path })
        #expect(files.bytes >= 8000)
        #expect(database.files(linked: contents.linkedFiles, isCancelled: { true }) == nil)
        #expect((LegacyDatabase.freeSpace(at: data) ?? 0) > 0)
    }

    @Test func readingChangesNothingInTheFolder() throws {
        let documents = try Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try makeDatabase(in: data, statements: ["INSERT INTO ZSTUDY VALUES (1, 2, '1.2.3', 'kept', NULL, NULL, NULL)"])
        let before = try bytes(of: data)
        let database = LegacyDatabase(folder: data)
        _ = try database.contents()
        _ = database.files(linked: [])
        #expect(try bytes(of: data) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path).sorted() == ["DATABASE.noindex", "Database.sql"])
    }

    @Test func aFileThatIsNotSuchADatabaseIsRefused() throws {
        let documents = try Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: data.appendingPathComponent(LegacyDatabase.storeName))
        #expect(throws: LegacyDatabase.Failure.self) { try LegacyDatabase(folder: data).contents() }
        // Another application's SQLite file, with no studies.
        let other = documents.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(other.appendingPathComponent(LegacyDatabase.storeName).path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "CREATE TABLE notes (text VARCHAR)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(throws: LegacyDatabase.Failure.self) { try LegacyDatabase(folder: other).contents() }
    }
}
