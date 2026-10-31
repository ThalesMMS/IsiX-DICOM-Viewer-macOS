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
import IsiXDatabase

@Suite struct GeneratedImageImportTests {
    /// A database with its data folder and the paths it indexed.
    private final class Database {
        let folder: String
        var indexed: [String] = []
        private var next = 0

        init(_ folder: String) { self.folder = folder }

        func newFile() -> String {
            next += 1
            return folder + "/\(next).dcm"
        }
    }

    /// The image of a viewer of `viewer`'s database while the window shows
    /// `shown`: what was written where, and what each database indexed.
    private func add(into viewer: Database?, shown: Database, writes: Bool = true) -> (written: [String], answer: [String]?) {
        var written: [String] = []
        let answer = GeneratedImageImport.add(into: viewer,
                                              newFile: { $0.newFile() },
                                              write: { path in
                                                  guard writes else { return nil }
                                                  written.append(path)
                                                  return path
                                              },
                                              index: { path, database in
                                                  database.indexed.append(path)
                                                  return [path]
                                              })
        return (written, answer)
    }

    @Test func theImageOfAViewerOfAnotherDatabaseIsWrittenAndIndexedInThatDatabase() {
        let shown = Database("/local/DATABASE.noindex"), viewer = Database("/remote/DATABASE.noindex")
        let result = add(into: viewer, shown: shown)
        #expect(result.written == ["/remote/DATABASE.noindex/1.dcm"])
        #expect(viewer.indexed == result.written)
        #expect(result.answer == result.written)
        // Nothing reaches the folder or the index of the database shown.
        #expect(shown.indexed.isEmpty)
        #expect(!result.written.contains { $0.hasPrefix(shown.folder + "/") })
    }

    @Test func theImageOfAViewerOfTheDatabaseShownStaysInIt() {
        let shown = Database("/local/DATABASE.noindex")
        let result = add(into: shown, shown: shown)
        #expect(result.written == ["/local/DATABASE.noindex/1.dcm"])
        #expect(shown.indexed == result.written)
    }

    @Test func withoutADatabaseNothingIsWritten() {
        let shown = Database("/local/DATABASE.noindex")
        let result = add(into: nil, shown: shown)
        #expect(result.written.isEmpty)
        #expect(result.answer == nil)
        #expect(shown.indexed.isEmpty)
    }

    @Test func withoutAPathNothingIsWritten() {
        var wrote = false
        let answer = GeneratedImageImport.add(into: Database("/remote"), newFile: { _ in nil },
                                              write: { path in wrote = true; return path },
                                              index: { path, _ in [path] })
        #expect(!wrote)
        #expect(answer == nil)
    }

    @Test func anImageNotWrittenIsNotIndexed() {
        let viewer = Database("/remote/DATABASE.noindex")
        let result = add(into: viewer, shown: Database("/local/DATABASE.noindex"), writes: false)
        #expect(result.answer == nil)
        #expect(viewer.indexed.isEmpty)
    }
}
