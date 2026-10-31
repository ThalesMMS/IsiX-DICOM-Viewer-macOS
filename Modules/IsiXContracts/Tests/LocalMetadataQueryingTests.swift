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
import IsiXContracts

/// A database of a few images, read the way the port reads: the matches of the
/// query's condition, stopped when the caller says so.
private struct StandInImages: LocalMetadataQuerying {
    let names: [String]
    let failure: LocalMetadataQueryError?

    func records(matching query: LocalMetadataQuery,
                 progress: @Sendable (LocalMetadataProgress) -> Bool) throws -> LocalMetadataResult {
        if let failure { throw failure }
        var records: [LocalMetadataRecord] = []
        var stopped = false
        for (index, name) in names.enumerated() where query.predicate?.evaluate(with: ["name": name]) ?? true {
            records.append(LocalMetadataRecord(identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://S/Image/p\(index)")!),
                                               level: query.level, values: ["name": .text(name)],
                                               files: query.includesFiles ? ["/files/\(name).dcm"] : []))
            if !progress(LocalMetadataProgress(stage: .records, read: records.count, total: names.count)) {
                stopped = true
                break
            }
        }
        return LocalMetadataResult(records: records, matchCount: records.count, stopped: stopped)
    }

    func representativeFile(of record: LocalRecordIdentifier) throws -> String? {
        record.uri.lastPathComponent == "p0" ? "/files/first.dcm" : nil
    }
}

/// The port of the listener's C-FIND, C-MOVE and C-GET over the local
/// database: values a module may keep, and a read its caller may stop.
struct LocalMetadataQueryingTests {

    @Test func aQueryAsksForNothingButItsLevelUnlessToldSo() {
        let query = LocalMetadataQuery(level: .series)
        #expect(query.predicate == nil && query.seriesPredicate == nil && query.filter == nil)
        #expect(query.sortKeyPath == nil && query.limit == nil && query.distinctKeyPath == nil)
        #expect(query.keyPaths.isEmpty && query.primitiveKeys.isEmpty && !query.includesFiles)
        #expect(LocalMetadataLevel.allCases == [.study, .series, .image])
    }

    @Test func theRecordsCarryTheirValuesAndFilesAndTheCallerMayStop() throws {
        let port = StandInImages(names: ["A1", "B1", "A2", "A3"], failure: nil)
        var query = LocalMetadataQuery(level: .image, predicate: NSPredicate(format: "name BEGINSWITH %@", "A"))
        query.includesFiles = true
        let all = try port.records(matching: query) { _ in true }
        #expect(all.records.map(\.values) == [["name": .text("A1")], ["name": .text("A2")], ["name": .text("A3")]])
        #expect(all.records.map(\.files) == [["/files/A1.dcm"], ["/files/A2.dcm"], ["/files/A3.dcm"]])
        #expect(all.records.allSatisfy { $0.level == .image && $0.primitiveValues.isEmpty } && !all.stopped)
        let first = try port.records(matching: query) { $0.read < 1 }
        #expect(first.records.count == 1 && first.stopped)
        #expect(try port.representativeFile(of: all.records[0].identifier) == "/files/first.dcm")
    }

    @Test func aDatabaseThatCannotBeReadSaysWhy() {
        for failure in [LocalMetadataQueryError.noDatabase, .readFailed("disk"), .raised("keypath")] {
            let port = StandInImages(names: ["A"], failure: failure)
            #expect(throws: failure) { try port.records(matching: LocalMetadataQuery(level: .study)) { _ in true } }
        }
    }

    @Test func valuesAreComparedAndCrossToAnotherTask() async throws {
        let date = Date(timeIntervalSinceReferenceDate: 7)
        let value = LocalMetadataValue.collection([.text("CT"), .number(3), .date(date), .null, .record])
        #expect(value == .collection([.text("CT"), .number(NSNumber(value: 3)), .date(date), .null, .record]))
        #expect(value != .collection([.text("MR")]))
        let record = LocalMetadataRecord(identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://S/Study/p1")!),
                                         level: .study, values: ["modality": value])
        let crossed = await Task.detached { record }.value
        #expect(crossed == record)
    }
}
