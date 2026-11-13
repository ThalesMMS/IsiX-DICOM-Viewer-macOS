//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXDatabase

@Suite struct DeleteQueueSparedFilesTests {
    private let data = "/db/DATABASE.noindex"

    @Test func aNumberedFileOfTheDataFolderIsNamedByItsNumber() {
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/5.dcm", dataFolder: data) == .number(5))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/20000/12345.dcm", dataFolder: data) == .number(12345))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/../10000/5.dcm", dataFolder: data + "/") == .number(5))
    }

    @Test func anotherNameInTheDataFolderIsNamedAsItIs() {
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/5.jpg", dataFolder: data) == .name("5.jpg"))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/5.img", dataFolder: data) == .name("5.img"))
        // Not a number a record would have: no record names these by one.
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/scan.dcm", dataFolder: data) == .name("scan.dcm"))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/05.dcm", dataFolder: data) == .name("05.dcm"))
    }

    @Test func aFileOutsideTheFoldersOfTheDataFolderIsNamedByItsPath() {
        #expect(DeleteQueueRules.indexName(ofFileAt: "/elsewhere/5.dcm", dataFolder: data) == .path("/elsewhere/5.dcm"))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/5.dcm", dataFolder: data) == .path("/db/DATABASE.noindex/5.dcm"))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/deeper/5.dcm", dataFolder: data) == .path("/db/DATABASE.noindex/10000/deeper/5.dcm"))
        #expect(DeleteQueueRules.indexName(ofFileAt: "/db/DATABASE.noindex/10000/5.dcm", dataFolder: nil) == .path("/db/DATABASE.noindex/10000/5.dcm"))
    }

    @Test func theFilesRecordsStillNameStay() {
        let files = ["/db/DATABASE.noindex/10000/5.dcm", "/db/DATABASE.noindex/10000/6.dcm", "/db/DATABASE.noindex/10000/7.tif",
                     "/db/DATABASE.noindex/10000/8.tif", "/elsewhere/linked.dcm", "/elsewhere/free.dcm"]
        var asked = 0
        let spared = DeleteQueueRules.spared(files, dataFolder: data) { names in
            asked += 1
            #expect(names == [.number(5), .number(6), .name("7.tif"), .name("8.tif"), .path("/elsewhere/linked.dcm"), .path("/elsewhere/free.dcm")])
            return [.number(5), .name("7.tif"), .path("/elsewhere/linked.dcm"), .number(99)]
        }
        #expect(spared == ["/db/DATABASE.noindex/10000/5.dcm", "/db/DATABASE.noindex/10000/7.tif", "/elsewhere/linked.dcm"])
        // The index is asked once for the batch, not for each file.
        #expect(asked == 1)
    }

    @Test func aFileQueuedTwiceStaysBothTimes() {
        let spared = DeleteQueueRules.spared(["/db/DATABASE.noindex/10000/5.dcm", "/db/DATABASE.noindex/10000/./5.dcm"], dataFolder: data) { $0 }
        #expect(spared == ["/db/DATABASE.noindex/10000/5.dcm", "/db/DATABASE.noindex/10000/./5.dcm"])
    }

    @Test func anEmptyBatchAsksNothing() {
        var asked = false
        let spared = DeleteQueueRules.spared([], dataFolder: data) { names in
            asked = true
            return names
        }
        #expect(spared == [])
        #expect(!asked)
    }
}
