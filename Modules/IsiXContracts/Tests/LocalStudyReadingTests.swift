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

/// A database of a few studies, read the way the port reads: by UID.
private struct StandInStudies: LocalStudyReading {
    let here: [LocalStudySnapshot]
    let failing: Bool

    func studies(withInstanceUIDs studyInstanceUIDs: Set<String>) async throws -> [LocalStudySnapshot] {
        if failing { throw CocoaError(.fileReadUnknown) }
        return here.filter { studyInstanceUIDs.contains($0.studyInstanceUID) }
    }
}

private func study(_ uid: String, files: Int, record: Int, state: Int? = nil, comment: String? = nil) -> LocalStudySnapshot {
    LocalStudySnapshot(identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://STORE/Study/p\(record)")!),
                       studyInstanceUID: uid, fileCount: files, state: state, comment: comment)
}

/// The first port over the local database: which studies are here, with their
/// files, State and Comment, as values a module may keep.
struct LocalStudyReadingTests {

    @Test func theFileCountsAddUpStudiesThatShareAUIDAndLeaveOutWhatIsNotHere() async throws {
        let reader = StandInStudies(here: [study("1.1", files: 12, record: 1), study("1.2", files: 0, record: 2),
                                           study("1.1", files: 3, record: 3), study("9.9", files: 7, record: 4)],
                                    failing: false)
        let counts = try await reader.fileCounts(ofStudyInstanceUIDs: ["1.1", "1.2", "1.3", ""])
        #expect(counts == ["1.1": 15, "1.2": 0])
        #expect(try await reader.fileCounts(ofStudyInstanceUIDs: [""]).isEmpty)
    }

    @Test func aReadThatFailsIsThrown() async {
        let reader = StandInStudies(here: [], failing: true)
        await #expect(throws: CocoaError.self) { try await reader.fileCounts(ofStudyInstanceUIDs: ["1.1"]) }
    }

    @Test func theSnapshotKeepsStateAndCommentAndItsIdentifierRoundTrips() throws {
        let one = study("1.1", files: 4, record: 7, state: 2, comment: "read")
        #expect(one.state == 2 && one.comment == "read")
        #expect(one != study("1.1", files: 4, record: 8, state: 2, comment: "read"))
        let data = try JSONEncoder().encode(one.identifier)
        #expect(try JSONDecoder().decode(LocalRecordIdentifier.self, from: data) == one.identifier)
    }

    @Test func snapshotsCrossToAnotherTask() async throws {
        let reader = StandInStudies(here: [study("1.1", files: 2, record: 1)], failing: false)
        let found = try await Task.detached { try await reader.studies(withInstanceUIDs: ["1.1"]) }.value
        #expect(found.map(\.fileCount) == [2])
    }
}
