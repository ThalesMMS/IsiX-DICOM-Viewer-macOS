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

/// Synthetic data folders whose image folder holds files the database no
/// longer lists: only a list that was read sets a file apart.
@Suite struct LegacyFileIndexTests {
    let databases = LegacyDatabaseTests()

    func write(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: count).write(to: url)
    }

    func names(_ paths: [String], in database: LegacyDatabase) -> [String] {
        paths.map { URL(fileURLWithPath: $0).pathComponents.suffix(2).joined(separator: "/") }.sorted()
    }

    @Test func aFileIsFoundInTheSubfolderOfItsNumber() {
        #expect(LegacyFileIndex.relativePath(ofName: "1.dcm") == "10000/1.dcm")
        #expect(LegacyFileIndex.relativePath(ofName: "9999.dcm") == "10000/9999.dcm")
        #expect(LegacyFileIndex.relativePath(ofName: "10000.dcm") == "20000/10000.dcm")
        #expect(LegacyFileIndex.relativePath(ofName: "123456.dcm") == "130000/123456.dcm")
        // A name that starts with no number counts as 0, as it did there.
        #expect(LegacyFileIndex.relativePath(ofName: "report.pdf") == "10000/report.pdf")
        #expect(LegacyFileIndex.relativePath(ofName: "20001-b.hdr") == "30000/20001-b.hdr")
    }

    @Test func theListAnswersForNumbersNamesAndPathsIntoTheFolder() {
        var index = LegacyFileIndex()
        #expect(index.isEmpty && !index.lists(relativePath: "10000/1.dcm"))
        index.list(number: 1)
        index.list(number: 1)
        index.list(number: 20005)
        index.list(number: -4)
        let ofTheFolder = ["scan.hdr", "/data/DATABASE.noindex/40000/kept.dcm", "/elsewhere/ct.dcm", ""]
            .map { index.list(path: $0, imagesFolders: ["/data/DATABASE.noindex"]) }
        #expect(ofTheFolder == [true, true, false, true])

        #expect(index.lists(relativePath: "10000/1.dcm"))
        #expect(index.lists(relativePath: "30000/20005.dcm"))
        #expect(index.lists(relativePath: "40000/kept.dcm"))
        // The image half of a header and image pair comes with its header.
        #expect(index.lists(relativePath: "10000/scan.hdr") && index.lists(relativePath: "10000/scan.img"))
        // Another number, the number in another subfolder, another extension, another spelling.
        #expect(!index.lists(relativePath: "10000/2.dcm"))
        #expect(!index.lists(relativePath: "20000/1.dcm"))
        #expect(!index.lists(relativePath: "10000/1.zip"))
        #expect(!index.lists(relativePath: "10000/01.dcm"))
        #expect(!index.lists(relativePath: "10000/other.img"))
        #expect(!index.lists(relativePath: "1.dcm"))
    }

    @Test func filesWithoutARowAreSetApart() throws {
        let documents = try LegacyDatabaseTests.Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        let images = data.appendingPathComponent("DATABASE.noindex")
        let outside = documents.root.appendingPathComponent("Exams/ct.dcm")
        try write(3000, to: outside)
        try databases.makeDatabase(in: data, statements: [
            "INSERT INTO ZSTUDY VALUES (1, 0, '1.2.3', NULL, NULL, NULL, NULL)",
            // A numbered file; a multiframe file, a row per frame; a file
            // that is no longer there; a bare name, with the image of its
            // pair; a path from the root into the folder; a file left where
            // it was; a row that records nothing.
            "INSERT INTO ZIMAGE VALUES (1, 1, 1, NULL)",
            "INSERT INTO ZIMAGE VALUES (2, 10002, 1, NULL)", "INSERT INTO ZIMAGE VALUES (3, 10002, 1, NULL)",
            "INSERT INTO ZIMAGE VALUES (4, 7, NULL, NULL)",
            "INSERT INTO ZIMAGE VALUES (5, NULL, 1, 'scan.hdr')",
            "INSERT INTO ZIMAGE VALUES (6, NULL, 0, '\(images.path)/30000/moved.dcm')",
            "INSERT INTO ZIMAGE VALUES (7, NULL, 0, '\(outside.path)')",
            "INSERT INTO ZIMAGE VALUES (8, NULL, NULL, NULL)",
        ])
        let listed = ["10000/1.dcm", "20000/10002.dcm", "10000/scan.hdr", "10000/scan.img", "30000/moved.dcm"]
        // The files of a study deleted there, a number in the wrong
        // subfolder, a file beside the subfolders.
        let orphans = ["10000/2.dcm", "10000/3.dcm", "20000/1.dcm", "stray.dcm"]
        for name in listed { try write(1000, to: images.appendingPathComponent(name)) }
        for name in orphans { try write(2000, to: images.appendingPathComponent(name)) }
        try write(10, to: images.appendingPathComponent("10000/.DS_Store"))

        let database = LegacyDatabase(folder: data)
        let survey = try #require(database.survey())
        #expect(survey.listing == .read)
        #expect(survey.contents.imageCount == 8 && survey.contents.studies.map(\.uid) == ["1.2.3"])
        #expect(names(survey.files.paths, in: database) == (listed + ["Exams/ct.dcm"]).sorted())
        #expect(names(survey.files.unlisted, in: database) == ["10000/2.dcm", "10000/3.dcm", "20000/1.dcm", "DATABASE.noindex/stray.dcm"])
        #expect(survey.files.bytes >= 8000 && survey.files.unlistedBytes >= 8000)
        #expect(Set(survey.files.paths).isDisjoint(with: survey.files.unlisted))
        // Without the list, as before: every file of the folder.
        let everything = try #require(database.files(linked: survey.contents.linkedFiles))
        #expect(everything.unlisted.isEmpty && everything.paths.count == listed.count + orphans.count + 1)
        #expect(Set(everything.paths) == Set(survey.files.paths + survey.files.unlisted))
        #expect(database.survey(isCancelled: { true }) == nil)
        #expect(LegacyDatabase.holding(imagesFolder: images)?.folder.path == data.path)
        #expect(LegacyDatabase.holding(imagesFolder: data) == nil)
        #expect(LegacyDatabase.holding(imagesFolder: documents.root.appendingPathComponent("Exams/DATABASE.noindex")) == nil)
    }

    @Test func aDatabaseThatListsNothingSetsEveryFileApart() throws {
        let documents = try LegacyDatabaseTests.Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try databases.makeDatabase(in: data)
        try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/1.dcm"))
        let survey = try #require(LegacyDatabase(folder: data).survey())
        #expect(survey.listing == .read && survey.files.paths.isEmpty && survey.files.unlisted.count == 1)
    }

    @Test func aDatabaseThatCannotBeReadLeavesNoFileOut() throws {
        let documents = try LegacyDatabaseTests.Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/1.dcm"))
        try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/2.dcm"))
        try Data("not a database".utf8).write(to: data.appendingPathComponent(LegacyDatabase.storeName))
        let survey = try #require(LegacyDatabase(folder: data).survey())
        guard case .unreadable = survey.listing else {
            Issue.record("\(survey.listing)")
            return
        }
        #expect(survey.files.paths.count == 2 && survey.files.unlisted.isEmpty)
        #expect(survey.contents.studies.isEmpty && survey.contents.listedFiles == nil)
    }

    @Test func aTableOfImagesThatDoesNotSayWhereTheFilesAreLeavesNoFileOut() throws {
        let documents = try LegacyDatabaseTests.Documents()
        // No table of images at all, and one without the columns of the paths.
        for (name, table) in [("Horos Data", nil), ("OsiriX Data", "CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZPATH VARCHAR)")] as [(String, String?)] {
            let data = documents.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: data.appendingPathComponent("DATABASE.noindex"), withIntermediateDirectories: true)
            var handle: OpaquePointer?
            #expect(sqlite3_open(data.appendingPathComponent(LegacyDatabase.storeName).path, &handle) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "CREATE TABLE ZSTUDY (Z_PK INTEGER PRIMARY KEY, ZSTUDYINSTANCEUID VARCHAR)", nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "INSERT INTO ZSTUDY VALUES (1, '1.2.3')", nil, nil, nil) == SQLITE_OK)
            if let table {
                #expect(sqlite3_exec(handle, table, nil, nil, nil) == SQLITE_OK)
                #expect(sqlite3_exec(handle, "INSERT INTO ZIMAGE VALUES (1, '1.dcm')", nil, nil, nil) == SQLITE_OK)
            }
            sqlite3_close(handle)
            try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/1.dcm"))
            try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/2.dcm"))
            let survey = try #require(LegacyDatabase(folder: data).survey())
            #expect(survey.listing == .unknown, "\(name)")
            #expect(survey.files.paths.count == 2 && survey.files.unlisted.isEmpty, "\(name)")
            #expect(survey.contents.studies.map(\.uid) == ["1.2.3"], "\(name)")
        }
    }

    @Test func aTableWithOnlyOneOfTheTwoColumnsIsRead() throws {
        let documents = try LegacyDatabaseTests.Documents()
        let data = documents.root.appendingPathComponent("Horos Data")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("DATABASE.noindex"), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(data.appendingPathComponent(LegacyDatabase.storeName).path, &handle) == SQLITE_OK)
        for sql in ["CREATE TABLE ZSTUDY (Z_PK INTEGER PRIMARY KEY, ZSTUDYINSTANCEUID VARCHAR)",
                    "CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZPATHSTRING VARCHAR)",
                    "INSERT INTO ZIMAGE VALUES (1, '5.dcm')"] {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(handle)
        try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/5.dcm"))
        try write(1000, to: data.appendingPathComponent("DATABASE.noindex/10000/6.dcm"))
        let database = LegacyDatabase(folder: data)
        let survey = try #require(database.survey())
        #expect(survey.listing == .read)
        #expect(names(survey.files.paths, in: database) == ["10000/5.dcm"] && names(survey.files.unlisted, in: database) == ["10000/6.dcm"])
    }
}
