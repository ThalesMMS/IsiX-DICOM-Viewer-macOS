//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation
import Testing
@testable import IsiXDatabase

/// A database of its own in a temporary folder: the data folder with its
/// numbered folders, the incoming and temporary folders beside it, and an
/// index on disk with the Image attributes that say where a file is.
/// `@unchecked Sendable`: its properties never change, and the context is
/// only used on its own queue.
private final class DisposableDatabase: @unchecked Sendable {
    let base: String
    var data: String { (base as NSString).appendingPathComponent("DATABASE.noindex") }
    var incoming: String { (base as NSString).appendingPathComponent("INCOMING.noindex") }
    var temp: String { (base as NSString).appendingPathComponent("TEMP.noindex") }
    let context: NSManagedObjectContext

    init() throws {
        base = (NSTemporaryDirectory() as NSString).appendingPathComponent("unindexed-\(UUID().uuidString)/Horos Data")
        for folder in ["DATABASE.noindex/10000", "DATABASE.noindex/20000", "INCOMING.noindex", "TEMP.noindex"] {
            try FileManager.default.createDirectory(atPath: (base as NSString).appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let image = NSEntityDescription()
        image.name = "Image"
        image.properties = [("pathNumber", NSAttributeType.integer32AttributeType), ("pathString", .stringAttributeType),
                            ("storedInDatabaseFolder", .booleanAttributeType)].map { name, type in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            return attribute
        }
        let model = NSManagedObjectModel()
        model.entities = [image]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                           at: URL(fileURLWithPath: (base as NSString).appendingPathComponent("Database.sql")))
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    deinit {
        try? FileManager.default.removeItem(atPath: ((base as NSString).deletingLastPathComponent))
    }

    /// Adds an image to the index and saves it.
    func index(pathNumber: Int32? = nil, pathString: String? = nil, inDatabaseFolder: Bool? = nil) throws {
        try context.performAndWait {
            let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
            image.setPrimitiveValue(pathNumber.map { NSNumber(value: $0) }, forKey: "pathNumber")
            image.setPrimitiveValue(pathString, forKey: "pathString")
            image.setPrimitiveValue(inDatabaseFolder.map { NSNumber(value: $0) }, forKey: "storedInDatabaseFolder")
            try context.save()
        }
    }

    func indexedPaths() throws -> Set<String> {
        try context.performAndWait { try UnindexedFileRules.indexedPaths(in: context, dataFolder: data, folderSize: 10000) }
    }

    @discardableResult
    func write(_ relative: String, in folder: String? = nil, _ bytes: Data) -> String {
        let path = ((folder ?? data) as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: bytes)
        return path
    }
}

/// A tiny DICOM Part 10 file: the preamble, "DICM" and one element of the
/// file meta information.
private let part10 = Data(repeating: 0, count: 128) + Data("DICM".utf8)
    + Data([0x02, 0x00, 0x10, 0x00, 0x55, 0x49, 0x14, 0x00]) + Data("1.2.840.10008.1.2.1\0".utf8)
/// A dataset written without the preamble: (0008,0016) first, implicit VR little endian.
private let rawDataset = Data([0x08, 0x00, 0x16, 0x00, 0x1A, 0x00, 0x00, 0x00]) + Data("1.2.840.10008.5.1.4.1.1.7\0".utf8)
private let notDICOM = Data("Not an image, only some text that happens to sit in the database folder.\n".utf8)

@Suite struct UnindexedFileSearchTests {
    @Test func theIndexKeepsADcmNameAsItsNumberAndFindsTheFolderFromIt() {
        #expect(UnindexedFileRules.storedName(ofFileNamed: "123.dcm") == "123.dcm")
        #expect(UnindexedFileRules.storedName(ofFileNamed: "abc.dcm") == "0.dcm")
        #expect(UnindexedFileRules.storedName(ofFileNamed: "0123.dcm") == "123.dcm")
        #expect(UnindexedFileRules.storedName(ofFileNamed: "77.hdr") == "77.hdr")
        #expect(UnindexedFileRules.folderName(forStoredName: "1.dcm", folderSize: 10000) == "10000")
        #expect(UnindexedFileRules.folderName(forStoredName: "9999.dcm", folderSize: 10000) == "10000")
        #expect(UnindexedFileRules.folderName(forStoredName: "10000.dcm", folderSize: 10000) == "20000")
        #expect(UnindexedFileRules.folderName(forStoredName: "notes", folderSize: 10000) == "10000")
        #expect(UnindexedFileRules.folderName(forStoredName: "5.dcm", folderSize: 0) == "6")
        #expect(UnindexedFileRules.isWhereTheIndexLooks(name: "12345.dcm", folder: "20000", folderSize: 10000))
        #expect(!UnindexedFileRules.isWhereTheIndexLooks(name: "12345.dcm", folder: "10000", folderSize: 10000))
        #expect(!UnindexedFileRules.isWhereTheIndexLooks(name: "abc.dcm", folder: "10000", folderSize: 10000))
        #expect(!UnindexedFileRules.isWhereTheIndexLooks(name: "0123.dcm", folder: "10000", folderSize: 10000))
    }

    @Test func anImageResolvesToTheFileTheDatabaseOpens() {
        let data = "/db/DATABASE.noindex"
        #expect(UnindexedFileRules.indexedPath(pathNumber: 42, pathString: nil, inDatabaseFolder: nil, dataFolder: data, folderSize: 10000)
                == "/db/DATABASE.noindex/10000/42.dcm")
        #expect(UnindexedFileRules.indexedPath(pathNumber: 10001, pathString: nil, inDatabaseFolder: true, dataFolder: data, folderSize: 10000)
                == "/db/DATABASE.noindex/20000/10001.dcm")
        #expect(UnindexedFileRules.indexedPath(pathNumber: nil, pathString: "15.hdr", inDatabaseFolder: true, dataFolder: data, folderSize: 10000)
                == "/db/DATABASE.noindex/10000/15.hdr")
        #expect(UnindexedFileRules.indexedPath(pathNumber: nil, pathString: "/Volumes/CD/IM1", inDatabaseFolder: false, dataFolder: data, folderSize: 10000)
                == "/Volumes/CD/IM1")
        #expect(UnindexedFileRules.indexedPath(pathNumber: nil, pathString: nil, inDatabaseFolder: true, dataFolder: data, folderSize: 10000) == nil)
    }

    @Test func dicomIsThePart10MarkerOrADatasetThatStartsWithADicomGroup() {
        #expect(UnindexedFileRules.looksLikeDICOM(part10))
        #expect(UnindexedFileRules.looksLikeDICOM(rawDataset))
        #expect(!UnindexedFileRules.looksLikeDICOM(notDICOM))
        #expect(!UnindexedFileRules.looksLikeDICOM(Data(repeating: 0, count: 200)))
        #expect(!UnindexedFileRules.looksLikeDICOM(Data([0x08, 0x00])))
    }

    @Test func aFileChangedWithinTheQuietPeriodIsRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UnindexedFileRules.isRecentlyChanged(lastChange: now.addingTimeInterval(-60), now: now))
        #expect(UnindexedFileRules.isRecentlyChanged(lastChange: now.addingTimeInterval(60), now: now))
        #expect(!UnindexedFileRules.isRecentlyChanged(lastChange: now.addingTimeInterval(-UnindexedFileRules.quietPeriod - 1), now: now))
    }

    @Test func theIncomingAndTemporaryFoldersAndHiddenNamesAreNotSearched() {
        #expect(!UnindexedFileRules.searchesFolder(named: "INCOMING.noindex"))
        #expect(!UnindexedFileRules.searchesFolder(named: "TEMP.noindex"))
        #expect(!UnindexedFileRules.searchesFolder(named: ".Trash"))
        #expect(UnindexedFileRules.searchesFolder(named: "10000"))
        #expect(!UnindexedFileRules.considers(".DS_Store"))
        #expect(UnindexedFileRules.unindexed(["/a", "/b", "/c"], indexed: ["/b"]) == ["/a", "/c"])
    }

    /// The search over a disposable database with synthetic files that the
    /// index does not have: only the DICOM files at their place, unchanged
    /// and closed, are offered; the others are counted and left alone, and
    /// nothing in the folders changes.
    @Test func theSearchOffersOnlyTheFilesThatCanBeIndexedWhereTheyAre() throws {
        let database = try DisposableDatabase()
        let data = database.data
        database.write("10000/1.dcm", part10)
        database.write("10000/6.dcm", part10)
        let linked = database.write("linked/IM1", in: database.base, part10)
        try database.index(pathNumber: 1, inDatabaseFolder: true)
        try database.index(pathNumber: 6)
        try database.index(pathString: linked, inDatabaseFolder: false)

        let offered = [database.write("10000/2.dcm", part10), database.write("10000/raw", rawDataset),
                       database.write("20000/12345.dcm", part10)]
        database.write("10000/3.dcm", notDICOM)
        let open = database.write("10000/4.dcm", part10)
        let recent = database.write("10000/5.dcm", part10)
        database.write("10000/abc.dcm", part10)
        database.write("20000/7.dcm", part10)
        database.write("9.dcm", part10)
        database.write("10000/.DS_Store", notDICOM)
        database.write("INCOMING.noindex/8.dcm", part10)
        database.write("TEMP.noindex/10.dcm", part10)
        database.write("10000/11.dcm", in: database.incoming, part10)
        database.write("10000/13.dcm", in: database.temp, part10)
        let errors = (data as NSString).appendingPathComponent("ERRORS")
        database.write("ERRORS/14.dcm", part10)

        // Every file was made a moment ago; the search runs as if an hour had
        // passed, and one file was changed after that.
        let now = Date().addingTimeInterval(3600)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: recent)
        let handle = try #require(FileHandle(forReadingAtPath: open))
        defer { try? handle.close() }

        let before = try FileManager.default.subpathsOfDirectory(atPath: database.base).sorted()
        let indexed = try database.indexedPaths()
        #expect(indexed == ["\(data)/10000/1.dcm", "\(data)/10000/6.dcm", linked])

        let search = UnindexedFileSearch(dataFolder: data, folderSize: 10000, skippedFolders: [database.incoming, database.temp, errors])
        #expect(search.folders() == ["10000", "20000"])
        var steps: [Int] = []
        let report = search.search(indexed: indexed, openFiles: OpenFileList.paths(under: data), now: now, progress: { done, _ in steps.append(done) })

        #expect(report.unindexed == offered)
        #expect(report.indexedCount == 2)
        #expect(report.count(.notDICOM) == 1)
        #expect(report.count(.open) == 1)
        #expect(report.count(.recentlyChanged) == 1)
        #expect(report.count(.misplaced) == 3)
        #expect(!report.cancelled)
        #expect(steps == [0, 1, 2])
        #expect(try FileManager.default.subpathsOfDirectory(atPath: database.base).sorted() == before)

        // At the import, what was indexed, changed or taken away meanwhile is left out.
        try database.index(pathNumber: 2)
        try FileManager.default.removeItem(atPath: offered[2])
        let still = search.stillUnindexed(offered + [open, "/elsewhere/15.dcm"], indexed: try database.indexedPaths(),
                                          openFiles: OpenFileList.paths(under: data), now: now)
        #expect(still == [offered[1]])
    }

    @Test func aCancelledSearchSaysSoAndStops() throws {
        let database = try DisposableDatabase()
        database.write("10000/2.dcm", part10)
        let search = UnindexedFileSearch(dataFolder: database.data, folderSize: 10000)
        let report = search.search(indexed: [], openFiles: [], now: Date().addingTimeInterval(3600), isCancelled: { true })
        #expect(report.cancelled)
        #expect(report.unindexed.isEmpty)
    }

    @Test func aFileThisProcessHasOpenIsListedByItsRealPath() throws {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = (folder as NSString).appendingPathComponent("1.dcm")
        FileManager.default.createFile(atPath: path, contents: part10)
        let closed = (folder as NSString).appendingPathComponent("2.dcm")
        FileManager.default.createFile(atPath: closed, contents: part10)
        let real = try #require(UnindexedFileSearch.realPath(path))

        let handle = try #require(FileHandle(forReadingAtPath: path))
        let open = OpenFileList.paths(under: folder)
        #expect(open.contains(real))
        #expect(!open.contains(try #require(UnindexedFileSearch.realPath(closed))))
        try handle.close()
        #expect(!OpenFileList.paths(under: folder).contains(real))
    }
}
