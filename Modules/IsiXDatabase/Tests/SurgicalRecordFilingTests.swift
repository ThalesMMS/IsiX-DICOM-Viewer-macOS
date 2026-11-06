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

/// A folder of written reports and a data folder of real files, so that what is
/// tested is where the files end up.
private final class Folders {
    let root: String
    let written: [String]
    let data: String
    private var nextName = 100

    init(reports: Int) throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        data = (root as NSString).appendingPathComponent("DATABASE.noindex/1000")
        let source = (root as NSString).appendingPathComponent("TEMP.noindex")
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        written = try (0..<reports).map { number in
            let path = (source as NSString).appendingPathComponent("\(number).dcm")
            try Data("report \(number)".utf8).write(to: URL(fileURLWithPath: path))
            return path
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func newDataFilePath() -> String {
        nextName += 1
        return (data as NSString).appendingPathComponent("\(nextName).dcm")
    }

    func filesInData() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: data).sorted()
    }

    func writtenLeft() -> [String] {
        written.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

@Suite struct SurgicalRecordFilingTests {
    private static func everyName(_ paths: [String]) -> Set<String> {
        Set(paths.map { ($0 as NSString).lastPathComponent })
    }

    @Test func theIndexIsGivenTheDataFolderPathsAndTheFilesAreThere() throws {
        let folders = try Folders(reports: 3)
        var indexedPaths: [String] = []
        var heldWhenIndexed: [String] = []
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: { paths in
            indexedPaths = paths
            heldWhenIndexed = (try? folders.filesInData()) ?? []
            return .init(names: Self.everyName(paths), saved: true)
        })
        #expect(outcome == .filed(3))
        #expect(indexedPaths.allSatisfy { $0.hasPrefix(folders.data + "/") })
        #expect(heldWhenIndexed == ["101.dcm", "102.dcm", "103.dcm"])
        #expect(try folders.filesInData() == ["101.dcm", "102.dcm", "103.dcm"])
        #expect(folders.writtenLeft().isEmpty)
        #expect(try String(contentsOfFile: indexedPaths[1], encoding: .utf8) == "report 1")
        #expect(outcome.alertMessage(notMoved: "%@", indexedInPart: "%ld %ld", notSaved: "x") == nil)
    }

    @Test func aMoveThatFailsTakesBackWhatWasMovedAndIndexesNothing() throws {
        let folders = try Folders(reports: 3)
        var asked = 0
        var indexed = false
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: {
            asked += 1
            // A folder that is not there: what a full or missing volume answers.
            return asked == 2 ? "/nonexistent-\(UUID().uuidString)/1.dcm" : folders.newDataFilePath()
        }, index: { _ in
            indexed = true
            return .init(names: [], saved: true)
        })
        guard case .notMoved(let reason) = outcome else {
            Issue.record("expected notMoved, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(!indexed)
        #expect(try folders.filesInData().isEmpty)
        #expect(outcome.alertMessage(notMoved: "failed: %@", indexedInPart: "", notSaved: "") == "failed: " + reason)
    }

    @Test func noPathInTheDataFolderIsAFailureToMove() throws {
        let folders = try Folders(reports: 1)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: { nil }, index: { _ in
            Issue.record("nothing was moved, so nothing is indexed")
            return .init(names: [], saved: true)
        })
        guard case .notMoved = outcome else {
            Issue.record("expected notMoved, got \(outcome)")
            return
        }
        #expect(folders.writtenLeft() == folders.written)
        #expect(try folders.filesInData().isEmpty)
    }

    @Test func whatTheIndexLeavesOutLeavesTheDataFolder() throws {
        let folders = try Folders(reports: 3)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: { paths in
            .init(names: Self.everyName(Array(paths.prefix(2))), saved: true)
        })
        #expect(outcome == .indexedInPart(indexed: 2, offered: 3))
        #expect(try folders.filesInData() == ["101.dcm", "102.dcm"])
        // The sentence counts those left out, out of those offered.
        #expect(outcome.alertMessage(notMoved: "", indexedInPart: "%1$ld of %2$ld", notSaved: "") == "1 of 3")
    }

    @Test func aFileTheImportAlreadyTookAwayIsNoFailure() throws {
        let folders = try Folders(reports: 2)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: { paths in
            try? FileManager.default.removeItem(atPath: paths[1])
            return .init(names: Self.everyName([paths[0]]), saved: true)
        })
        #expect(outcome == .indexedInPart(indexed: 1, offered: 2))
        #expect(try folders.filesInData() == ["101.dcm"])
    }

    @Test func nothingIndexedLeavesNothingInTheDataFolder() throws {
        let folders = try Folders(reports: 2)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: { _ in
            .init(names: [], saved: true)
        })
        #expect(outcome == .indexedInPart(indexed: 0, offered: 2))
        #expect(try folders.filesInData().isEmpty)
    }

    @Test func rowsNotSavedKeepTheirFilesAndSaySo() throws {
        let folders = try Folders(reports: 2)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: { paths in
            .init(names: Self.everyName(paths), saved: false)
        })
        #expect(outcome == .notSaved)
        #expect(try folders.filesInData() == ["101.dcm", "102.dcm"])
        #expect(outcome.alertMessage(notMoved: "", indexedInPart: "", notSaved: "rebuild") == "rebuild")
    }

    @Test func theFormerReportsGoOnlyWhenAllIsFiled() throws {
        let former = ["/data/7.dcm", "/data/8.dcm"]
        let filed = try Folders(reports: 2)
        var retired: [[String]] = []
        var order: [String] = []
        let outcome = SurgicalRecordFiling.file(filed.written, replacing: former, newDataFilePath: filed.newDataFilePath, index: { paths in
            order.append("indexed")
            return .init(names: Self.everyName(paths), saved: true)
        }, retire: {
            order.append("retired")
            retired.append($0)
        })
        #expect(outcome == .filed(2))
        #expect(retired == [former])
        #expect(order == ["indexed", "retired"])

    }

    /// Anything less than all filed leaves the former report as the one that
    /// holds the text.
    @Test func aFilingThatFallsShortRetiresNothing() throws {
        let retire: ([String]) -> Void = { _ in Issue.record("nothing is retired") }
        let part = try Folders(reports: 2)
        let inPart = SurgicalRecordFiling.file(part.written, replacing: ["/data/7.dcm"], newDataFilePath: part.newDataFilePath,
                                               index: { .init(names: Self.everyName([$0[0]]), saved: true) }, retire: retire)
        #expect(inPart == .indexedInPart(indexed: 1, offered: 2))
        let unsaved = try Folders(reports: 2)
        let notSaved = SurgicalRecordFiling.file(unsaved.written, replacing: ["/data/7.dcm"], newDataFilePath: unsaved.newDataFilePath,
                                                 index: { .init(names: Self.everyName($0), saved: false) }, retire: retire)
        #expect(notSaved == .notSaved)
        let unmoved = try Folders(reports: 1)
        let notMoved = SurgicalRecordFiling.file(unmoved.written, replacing: ["/data/7.dcm"], newDataFilePath: { nil },
                                                 index: { _ in .init(names: [], saved: true) }, retire: retire)
        guard case .notMoved = notMoved else {
            Issue.record("expected notMoved, got \(notMoved)")
            return
        }
    }

    @Test func nothingFormerAsksNothing() throws {
        let folders = try Folders(reports: 1)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: {
            .init(names: Self.everyName($0), saved: true)
        }, retire: { _ in Issue.record("no report was replaced") })
        #expect(outcome == .filed(1))
    }

    @Test func rowsNotSavedStillDropWhatHasNoRow() throws {
        let folders = try Folders(reports: 2)
        let outcome = SurgicalRecordFiling.file(folders.written, newDataFilePath: folders.newDataFilePath, index: { paths in
            .init(names: Self.everyName([paths[1]]), saved: false)
        })
        #expect(outcome == .notSaved)
        #expect(try folders.filesInData() == ["102.dcm"])
    }
}
