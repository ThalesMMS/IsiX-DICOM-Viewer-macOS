//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CryptoKit
import Foundation
import Testing
import IsiXDatabase

@Suite struct IdentifierListExportTests {

    @Test func theListIsReadOneIdentifierPerLineEachOnce() {
        let identifiers = IdentifierListExport.identifiers(fromText: """
        MRN-1
          MRN-2  # the second

        MRN-1
        # a whole line
        "MRN-3",Silva Maria,2026
        """)
        #expect(identifiers == ["MRN-1", "MRN-2", "MRN-3"])
        #expect(IdentifierListExport.identifiers(fromText: "").isEmpty)
    }

    @Test func aRowSaysAllOfItInTheHeadersOrder() {
        let row = IdentifierListExport.row(identifier: "MRN-1", status: "exported", names: ["A", "B"],
                                           studies: 2, files: 5, bytes: 1234, digest: "abc", detail: "")
        #expect(row.count == IdentifierListExport.header.count)
        #expect(row == ["MRN-1", "exported", "A; B", "2", "5", "1234", "abc", ""])
        #expect(IdentifierListExport.row(identifier: "MRN-9", status: .notFound)
                == ["MRN-9", "not found", "", "0", "0", "0", "", ""])
    }

    @Test func theStatusSaysCancelledThenFailedThenTheKindOfRun() {
        typealias Status = IdentifierListExport.Status
        #expect(Status.ofFoundStudies(cancelled: true, troubled: true, dryRun: true) == .cancelled)
        #expect(Status.ofFoundStudies(cancelled: false, troubled: true, dryRun: true) == .failed)
        #expect(Status.ofFoundStudies(cancelled: false, troubled: false, dryRun: true) == .dryRun)
        #expect(Status.ofFoundStudies(cancelled: false, troubled: false, dryRun: false) == .exported)
        #expect(Status.ofRun(cancelled: true, dryRun: true).rawValue == "cancelled")
        #expect(Status.ofRun(cancelled: false, dryRun: true).rawValue == "dry run")
        #expect(Status.ofRun(cancelled: false, dryRun: false).rawValue == "exported")
        #expect(Status.notFound.rawValue == "not found")
    }

    @Test func theNamesAreEachOnceInOrderWithoutEmptyOnes() {
        #expect(IdentifierListExport.names(["Silva^Maria", nil, "", "Souza^Ana", "Silva^Maria"]) == ["Silva^Maria", "Souza^Ana"])
    }

    @Test func theDetailsNameTheStudyOrTheFile() {
        #expect(IdentifierListExport.missingFile(studyInstanceUID: "1.2.3") == "missing file for 1.2.3")
        #expect(IdentifierListExport.missingFile(studyInstanceUID: nil) == "missing file for (null)")
        #expect(IdentifierListExport.unreadable(path: "/tmp/a/IM-1.dcm") == "unreadable IM-1.dcm")
        #expect(IdentifierListExport.reportFileName == "horos-export-manifest.csv")
        #expect(IdentifierListExport.report(rows: [IdentifierListExport.header]).hasSuffix("Detail\r\n"))
    }

    @Test func theDigestIsOverTheFilesNotTheirOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("isix-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = ["first", "second", "third"].map { Data($0.utf8) }
        var paths: [String] = []
        for (index, data) in contents.enumerated() {
            let url = folder.appendingPathComponent("file-\(index).bin")
            try data.write(to: url)
            paths.append(url.path)
        }
        // Computed apart: SHA-256 over the sorted hexadecimal digests of the files.
        var expected = SHA256()
        for digest in contents.map({ SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }).sorted() {
            expected.update(data: Data(digest.utf8))
        }
        let expectedHex = expected.finalize().map { String(format: "%02x", $0) }.joined()

        var digest = IdentifierListExport.FileSetDigest()
        for path in paths {
            let added = digest.add(path: path)
            #expect(added)
        }
        #expect(digest.fileCount == 3)
        #expect(digest.byteCount == Int64(contents.map(\.count).reduce(0, +)))
        #expect(digest.unreadable.isEmpty)
        #expect(digest.hexDigest == expectedHex)

        var reversed = IdentifierListExport.FileSetDigest()
        for path in paths.reversed() { reversed.add(path: path) }
        #expect(reversed.hexDigest == digest.hexDigest)

        var fewer = IdentifierListExport.FileSetDigest()
        for path in paths.dropLast() { fewer.add(path: path) }
        #expect(fewer.hexDigest != digest.hexDigest)
        #expect(IdentifierListExport.FileSetDigest().hexDigest == "")

        var missing = IdentifierListExport.FileSetDigest()
        let added = missing.add(path: paths[0] + "-not-here")
        #expect(!added)
        #expect(missing.unreadable.count == 1 && missing.fileCount == 0)
    }
}
