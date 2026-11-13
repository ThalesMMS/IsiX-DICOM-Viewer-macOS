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
import Synchronization
import Testing
@testable import IsiXStorage

@Suite struct DataFileAllocatorTests {

    /// A data folder of its own, removed after the test.
    private func withDataFolder(_ body: (String) throws -> Void) rethrows {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("isix-data-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try body(folder)
    }

    private func makeFolder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func touch(_ path: String) {
        makeFolder((path as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    @Test func aFileGoesToTheNextMultipleOfTheFolderSize() {
        #expect(DataFileNumbering.folder(forIndex: 1, folderSize: 10000) == 10000)
        #expect(DataFileNumbering.folder(forIndex: 9999, folderSize: 10000) == 10000)
        #expect(DataFileNumbering.folder(forIndex: 10000, folderSize: 10000) == 20000)
        #expect(DataFileNumbering.folder(forIndex: 7, folderSize: 0) == 8)
        let place = DataFileNumbering.path(forIndex: 12, extension: "dcm", inDataFolder: "/d", folderSize: 10)
        #expect(place.folder == "/d/20" && place.file == "/d/20/12.dcm")
    }

    @Test func anExtensionOfThreeOrFourCharactersIsKept() {
        #expect(DataFileNumbering.fileExtension("dcm") == ("dcm", false))
        #expect(DataFileNumbering.fileExtension("tiff") == ("tiff", false))
        #expect(DataFileNumbering.fileExtension("jpegxl") == ("dcm", true))
        #expect(DataFileNumbering.fileExtension("gz") == ("dcm", true))
        #expect(DataFileNumbering.fileExtension("") == ("dcm", false))
        #expect(DataFileNumbering.fileExtension(nil) == ("dcm", false))
    }

    @Test func numbersAreReadAsIntegerValueReadsThem() {
        #expect(DataFileNumbering.number(inName: "123.dcm") == 123)
        #expect(DataFileNumbering.number(inName: "123") == 123)
        #expect(DataFileNumbering.number(inName: "readme.txt") == 0)
        #expect(DataFileNumbering.number(inName: "12abc.dcm") == 12)
    }

    @Test func anEmptyFolderStartsAtOneAndTheFirstFileIsTwo() throws {
        try withDataFolder { data in
            let allocator = DataFileAllocator()
            #expect(allocator.resume(fromDataFolder: data, folderSize: 100) == 1)
            #expect(allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, prepareFolder: makeFolder)
                    == (data as NSString).appendingPathComponent("100/2.dcm"))
        }
    }

    @Test func theCountGoesOnFromTheLastFileOfTheLastFolder() throws {
        try withDataFolder { data in
            touch(data + "/100/42.dcm")
            touch(data + "/200/150.dcm")
            touch(data + "/200/151.dcm")
            makeFolder(data + "/300")
            touch(data + "/400/notes.txt")
            let allocator = DataFileAllocator()
            #expect(allocator.resume(fromDataFolder: data, folderSize: 100) == 151)
            // Folders without a numbered file go.
            #expect(!FileManager.default.fileExists(atPath: data + "/300"))
            #expect(!FileManager.default.fileExists(atPath: data + "/400"))
            #expect(FileManager.default.fileExists(atPath: data + "/200/151.dcm"))
            #expect(allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, prepareFolder: makeFolder)
                    == data + "/200/152.dcm")
        }
    }

    @Test func aNumberAlreadyGivenIsNeverGivenAgain() throws {
        try withDataFolder { data in
            let allocator = DataFileAllocator()
            allocator.raise(toAtLeast: 500)
            // The folder holds less than was given: the files of numbers given
            // may not be written yet.
            touch(data + "/100/7.dcm")
            #expect(allocator.resume(fromDataFolder: data, folderSize: 100) == 500)
            #expect(allocator.next() == 501)
        }
    }

    @Test func aTakenNumberSendsTheCountPastWhatTheFolderHolds() throws {
        try withDataFolder { data in
            let allocator = DataFileAllocator()
            allocator.raise(toAtLeast: 3)
            // Another program wrote files the count does not know of.
            for number in 4...9 { touch(data + "/100/\(number).dcm") }
            #expect(allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, prepareFolder: makeFolder)
                    == data + "/100/10.dcm")
        }
    }

    @Test func concurrentAllocationsNeverShareAName() throws {
        try withDataFolder { data in
            let allocator = DataFileAllocator()
            touch(data + "/100/50.dcm")
            let names = Mutex<[String]>([])
            DispatchQueue.concurrentPerform(iterations: 16) { worker in
                var mine: [String] = []
                for _ in 0..<200 {
                    let path = allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, prepareFolder: makeFolder)
                    // Written as the callers write them, so that a number given
                    // twice would also find its file there.
                    FileManager.default.createFile(atPath: path, contents: Data("\(worker)".utf8))
                    mine.append(path)
                }
                names.withLock { $0 += mine }
            }
            let all = names.withLock { $0 }
            #expect(all.count == 16 * 200)
            #expect(Set(all).count == all.count)
            #expect(!all.contains(data + "/100/50.dcm"))
        }
    }

    @Test func aNumberTheIndexUsesIsNeverGivenThoughItsFileIsGone() throws {
        try withDataFolder { data in
            // The index has records for files 3 and 5; file 5 went from the
            // folder from outside, and 4 and 6 were deleted with their records.
            touch(data + "/100/3.dcm")
            let allocator = DataFileAllocator()
            let first = allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, highestRecorded: { 5 }, prepareFolder: makeFolder)
            let second = allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, highestRecorded: { 5 }, prepareFolder: makeFolder)
            #expect(first == data + "/100/6.dcm")
            #expect(second == data + "/100/7.dcm")
            #expect(!FileManager.default.fileExists(atPath: data + "/100/5.dcm"))
        }
    }

    @Test func theIndexCountsWhenTheFolderHoldsNothing() throws {
        try withDataFolder { data in
            let allocator = DataFileAllocator()
            #expect(allocator.resume(fromDataFolder: data, folderSize: 100, highestRecorded: { 250 }) == 250)
            #expect(allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, highestRecorded: { 250 }, prepareFolder: makeFolder)
                    == data + "/300/251.dcm")
        }
    }

    @Test func theFolderCountsWhenItHoldsMoreThanTheIndex() throws {
        try withDataFolder { data in
            touch(data + "/200/151.dcm")
            let allocator = DataFileAllocator()
            #expect(allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, highestRecorded: { 40 }, prepareFolder: makeFolder)
                    == data + "/200/152.dcm")
        }
    }

    @Test func theIndexIsAskedWhenTheFolderIsReadAndNotForEachFile() throws {
        try withDataFolder { data in
            touch(data + "/100/3.dcm")
            let allocator = DataFileAllocator()
            let asked = Mutex(0)
            let highest: () -> UInt64 = {
                asked.withLock { $0 += 1 }
                return 5
            }
            var paths: Set<String> = []
            for _ in 0..<1000 {
                let path = allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, highestRecorded: highest, prepareFolder: makeFolder)
                FileManager.default.createFile(atPath: path, contents: Data())
                paths.insert(path)
            }
            #expect(paths.count == 1000)
            #expect(asked.withLock { $0 } == 1)
            // A number whose file is already there has the folder, and the index, read again.
            touch(data + "/1100/1006.dcm")
            touch(data + "/1100/1007.dcm")
            #expect(allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: 100, highestRecorded: { asked.withLock { $0 += 1 }; return 1500 },
                                         prepareFolder: makeFolder) == data + "/1600/1501.dcm")
            #expect(asked.withLock { $0 } == 2)
        }
    }
}
