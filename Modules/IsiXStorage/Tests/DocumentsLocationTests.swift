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
import Testing
@testable import IsiXStorage

// The documents, incoming and temporary folders of a database, in a folder of
// the test's own: plain folders, a data folder kept elsewhere, and an
// incoming folder replaced by a symbolic link to another place.
@Suite struct DocumentsLocationTests {
    /// A new folder in the temporary folder, with its links resolved, removed by `body`'s end.
    func withFolder(_ body: (String) throws -> Void) throws {
        let made = (NSTemporaryDirectory() as NSString).appendingPathComponent("DocumentsLocationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: made) }
        // The real path (/private/var...), which the resolution gives.
        let real = realpath(made, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        try body(real ?? made)
    }

    @Test func foldersOfTheDataFolder() throws {
        try withFolder { root in
            let documents = (root as NSString).appendingPathComponent("Database")
            let data = (root as NSString).appendingPathComponent("Moved")
            let location = DocumentsLocation(documentsDirectory: documents, dataDirectory: data)
            #expect(location.documentsDirectory == documents)
            // A folder that does not exist yet is named as it will be.
            #expect(location.incomingDirectory == data + "/INCOMING.noindex")
            #expect(location.temporaryDirectory == data + "/TEMP.noindex")
        }
    }

    @Test func linksAreFollowed() throws {
        try withFolder { root in
            let data = (root as NSString).appendingPathComponent("Data")
            let elsewhere = (root as NSString).appendingPathComponent("Other disk/Incoming")
            try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: (data as NSString).appendingPathComponent(DocumentsLocation.incomingFolderName),
                                                       withDestinationPath: elsewhere)
            let location = DocumentsLocation(documentsDirectory: data, dataDirectory: data)
            #expect(location.incomingDirectory == elsewhere)
            #expect(location.temporaryDirectory == data + "/TEMP.noindex")
        }
    }

    /// Every folder the database's accessors give (-dataDirPath to
    /// -presetsDirPath), by the name the former Objective-C appended.
    @Test func everyFolderOfTheDataFolder() throws {
        try withFolder { root in
            let data = (root as NSString).appendingPathComponent("Data")
            let location = DocumentsLocation(documentsDirectory: root, dataDirectory: data)
            let names = ["DATABASE.noindex", "INCOMING.noindex", "DECOMPRESSION.noindex", "TOBEINDEXED.noindex", "TEMP.noindex",
                         "DUMP", "NOT READABLE", "REPORTS", "PAGES", "ROIs", "HTML_TEMPLATES", "3DSTATE", "CLUTs", "3DPRESETS"]
            #expect(DocumentsLocation.DataFolder.allCases.map(\.rawValue) == names)
            for folder in DocumentsLocation.DataFolder.allCases {
                #expect(location.path(of: folder) == data + "/" + folder.rawValue)
            }
            #expect(location.path(of: .incoming) == location.incomingDirectory)
            #expect(location.path(of: .temporary) == location.temporaryDirectory)
            #expect(DocumentsLocation(documentsDirectory: root, dataDirectory: nil).path(of: .reports) == nil)
        }
    }

    @Test func withoutADataFolder() {
        #expect(DocumentsLocation(documentsDirectory: nil, dataDirectory: nil).incomingDirectory == nil)
        #expect(DocumentsLocation(documentsDirectory: "/x", dataDirectory: nil).temporaryDirectory == nil)
        // A relative folder is not resolved.
        #expect(DocumentsLocation(documentsDirectory: "x", dataDirectory: "x").incomingDirectory == nil)
    }
}
