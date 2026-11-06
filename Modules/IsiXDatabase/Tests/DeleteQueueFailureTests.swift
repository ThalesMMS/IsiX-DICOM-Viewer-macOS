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
@testable import IsiXDatabase

@Suite struct DeleteQueueFailureTests {

    /// A folder of its own in the temporary folder, with `names` in it.
    private func folder(with names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("delete-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names {
            try Data("x".utf8).write(to: url.appendingPathComponent(name))
        }
        return url
    }

    @Test func aFileInAFolderWithoutWritePermissionIsReported() throws {
        let locked = try folder(with: ["a.dcm", "b.dcm"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }
        // Without write permission on its folder a file cannot be unlinked.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let path = locked.appendingPathComponent("a.dcm").path

        let failure = DeleteQueueRules.deleteFile(path)
        #expect(failure == DeleteQueueRules.Failure(path: path, code: EACCES))
        #expect(failure?.reason == String(cString: strerror(EACCES)))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func aDeletedOrMissingFileIsNoFailure() throws {
        let open = try folder(with: ["a.dcm"])
        defer { try? FileManager.default.removeItem(at: open) }
        let path = open.appendingPathComponent("a.dcm").path

        #expect(DeleteQueueRules.deleteFile(path) == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        // Queued twice, or deleted by a former run.
        #expect(DeleteQueueRules.deleteFile(path) == nil)
    }

    @Test func theListNamesTheFirstFailuresAndWhy() {
        let failures = (1...7).map { DeleteQueueRules.Failure(path: "/db/\($0).dcm", code: EACCES) }
        let reason = String(cString: strerror(EACCES))
        #expect(DeleteQueueRules.failureList(Array(failures.prefix(2))) == "/db/1.dcm: \(reason)\n/db/2.dcm: \(reason)")
        let lines = DeleteQueueRules.failureList(failures).components(separatedBy: "\n")
        #expect(lines.count == 6)
        #expect(lines.first == "/db/1.dcm: \(reason)")
        #expect(lines.last == "…")
    }
}
