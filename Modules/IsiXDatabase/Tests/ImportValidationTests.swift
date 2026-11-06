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

@Suite struct ImportValidationTests {

    /// A stand-in for the Decompress service: it refuses each file whose name
    /// has "bad" and ends without an answer, as a service that crashed, at a
    /// file whose name has "crash". `starts` false: a service that cannot be
    /// started, which tests nothing.
    private struct Tester: ImportValidationTester {
        var starts = true

        func refusedFiles(among files: [String], stop: @Sendable () -> Bool) -> [String]? {
            guard starts else { return [] }
            var refused: [String] = []
            for file in files {
                if stop() { break }
                if file.contains("crash") { return nil }
                if file.contains("bad") { refused.append(file) }
            }
            return refused
        }
    }

    private func names(_ prefix: String, _ count: Int) -> [String] {
        (1...count).map { "/db/\(prefix)\($0).dcm" }
    }

    @Test func theChunksShareTheBatchAmongTheProcessors() {
        #expect(ImportValidation.chunkSize(fileCount: 3, processorCount: 12) == 20)
        #expect(ImportValidation.chunkSize(fileCount: 1200, processorCount: 12) == 120)
        #expect(ImportValidation.chunkSize(fileCount: 60000, processorCount: 12) == 500)
        #expect(ImportValidation.chunkSize(fileCount: 10, processorCount: 0) == 30)
    }

    @Test func onlyTheFilesTheHelperNamesAreRefused() {
        let files = ["/db/a.dcm", "/db/b c.dcm", "/db/é.dcm"]
        let output = "REFUSED\t/db/é.dcm\nsomething else\nREFUSED\t/db/b c.dcm\nREFUSED\t/elsewhere/x.dcm\n"
        #expect(ImportValidation.refusedFiles(inOutput: output, of: files) == ["/db/b c.dcm", "/db/é.dcm"])
        #expect(ImportValidation.refusedFiles(inOutput: "", of: files).isEmpty)
    }

    @Test func aMixedBatchLosesOnlyItsBadFiles() throws {
        // Enough files for several chunks, bad ones in more than one of them.
        let files = (names("good", 40) + names("bad", 3) + names("good-again", 40)).shuffled()

        let refused = ImportValidation.refusedFiles(files, tester: Tester(), shouldStop: nil, whileWaiting: nil)
        #expect(Set(refused) == Set(names("bad", 3)))
        #expect(refused == files.filter { $0.contains("bad") })
        #expect(ImportValidation.refusedFiles(names("good", 5), tester: Tester(), shouldStop: nil, whileWaiting: nil).isEmpty)
    }

    @Test func aChunkTheServiceDidNotSurviveIsRetestedFileByFile() throws {
        let files = names("good", 4) + ["/db/crash.dcm", "/db/bad.dcm"] + names("after", 4)

        let refused = ImportValidation.refusedFiles(files, tester: Tester(), shouldStop: nil, whileWaiting: nil)
        #expect(refused == ["/db/crash.dcm", "/db/bad.dcm"])
    }

    @Test func aServiceThatDoesNotStartLeavesTheFilesUntested() {
        let refused = ImportValidation.refusedFiles(["/db/bad.dcm"], tester: Tester(starts: false),
                                                    shouldStop: nil, whileWaiting: nil)
        #expect(refused.isEmpty)
    }

    @Test func stoppingRefusesNothingMore() throws {
        let refused = ImportValidation.refusedFiles(["/db/bad.dcm"], tester: Tester(),
                                                    shouldStop: { true }, whileWaiting: nil)
        #expect(refused.isEmpty)
    }

    @Test func theNoticeNamesTheFirstRefusedFiles() {
        #expect(ImportValidation.list(ofRefusedFiles: ["/a.dcm", "/b.dcm"], limit: 5) == "/a.dcm\n/b.dcm")
        let lines = ImportValidation.list(ofRefusedFiles: names("x", 7), limit: 5).components(separatedBy: "\n")
        #expect(lines == Array(names("x", 7).prefix(5)) + ["…"])
    }
}
