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

/// A few local series, read the way the port reads: by Study Instance UID, and
/// the files of a study by its record (one per instance here).
private struct StandInSeries: LocalSeriesReading {
    let here: [LocalSeriesSnapshot]
    let studies: [LocalRecordIdentifier: String]
    let failing: Bool

    func series(ofStudyInstanceUID studyInstanceUID: String) throws -> [LocalSeriesSnapshot] {
        if failing { throw CocoaError(.fileReadUnknown) }
        return here.filter { $0.studyInstanceUID == studyInstanceUID }
    }

    func fileCount(ofStudy study: LocalRecordIdentifier, seriesInstanceUID: String?) throws -> Int {
        if failing { throw CocoaError(.fileReadUnknown) }
        guard let uid = studies[study] else { return 0 }
        let series = here.filter { $0.studyInstanceUID == uid }
        guard let seriesInstanceUID else { return series.reduce(0) { $0 + $1.sopInstanceUIDs.count } }
        return series.first { $0.seriesInstanceUID == seriesInstanceUID }?.sopInstanceUIDs.count ?? 0
    }
}

private func series(_ study: String, _ uid: String?, _ instances: Set<String>) -> LocalSeriesSnapshot {
    LocalSeriesSnapshot(studyInstanceUID: study, seriesInstanceUID: uid, sopInstanceUIDs: instances)
}

private let record = LocalRecordIdentifier(uri: URL(string: "x-coredata://STORE/Study/p1")!)

/// The port the retrieve reads what is already here through: the instances of
/// a study or of one of its series, and the files of a study's row.
struct LocalSeriesReadingTests {

    private let reader = StandInSeries(here: [series("1.1", "1.1.1", ["a", "b"]), series("1.1", "1.1.2", ["c"]),
                                              series("1.1", nil, ["d"]), series("1.1", "1.1.1", ["b", "e"]),
                                              series("2.2", "2.2.1", ["x"])],
                                       studies: [record: "1.1"], failing: false)

    @Test func theInstancesOfAStudyAreThoseOfEverySeriesOfEveryStudyWithItsUID() throws {
        let uids = try reader.sopInstanceUIDs(ofStudyInstanceUID: "1.1", seriesInstanceUID: nil)
        #expect(uids.sorted() == ["a", "b", "b", "c", "d", "e"])
        // An empty series UID names no series, as none.
        #expect(try reader.sopInstanceUIDs(ofStudyInstanceUID: "1.1", seriesInstanceUID: "").sorted() == uids.sorted())
    }

    @Test func aSeriesUIDKeepsOnlyThatSeriesAndNeverOneWithoutAUID() throws {
        #expect(try reader.sopInstanceUIDs(ofStudyInstanceUID: "1.1", seriesInstanceUID: "1.1.1").sorted() == ["a", "b", "b", "e"])
        #expect(try reader.sopInstanceUIDs(ofStudyInstanceUID: "1.1", seriesInstanceUID: "1.1.9").isEmpty)
        #expect(try reader.sopInstanceUIDs(ofStudyInstanceUID: "3.3", seriesInstanceUID: nil).isEmpty)
    }

    @Test func theFileCountsComeFromTheStudysRecord() throws {
        #expect(try reader.fileCount(ofStudy: record, seriesInstanceUID: nil) == 6)
        #expect(try reader.fileCount(ofStudy: record, seriesInstanceUID: "1.1.2") == 1)
        #expect(try reader.fileCount(ofStudy: LocalRecordIdentifier(uri: URL(string: "x-coredata://STORE/Study/p9")!),
                                     seriesInstanceUID: nil) == 0)
    }

    @Test func aReadThatFailsIsThrown() {
        let failing = StandInSeries(here: [], studies: [:], failing: true)
        #expect(throws: CocoaError.self) { try failing.sopInstanceUIDs(ofStudyInstanceUID: "1.1", seriesInstanceUID: nil) }
        #expect(throws: CocoaError.self) { try failing.fileCount(ofStudy: record, seriesInstanceUID: nil) }
    }
}
