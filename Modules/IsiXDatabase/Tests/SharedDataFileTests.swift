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

@Suite struct SharedDataFileTests {
    @Test func theFramesOfAFileAreToldWithoutReadingIt() {
        #expect(!SharedDataFile.needsReading(recordIdentifiers: ["1.2.3", "1.2.3", "1.2.3"]))
        #expect(!SharedDataFile.needsReading(recordIdentifiers: ["1.2.3"]))
        #expect(!SharedDataFile.needsReading(recordIdentifiers: [String?]()))
        // A record without an identifier is of no other image.
        #expect(!SharedDataFile.needsReading(recordIdentifiers: ["1.2.3", nil]))
        #expect(SharedDataFile.needsReading(recordIdentifiers: ["1.2.3", "1.2.4"]))
        #expect(SharedDataFile.needsReading(recordIdentifiers: ["1.2.3", "1.2.3", "1.2.4"]))
    }

    @Test func theRecordThatIsNotOfTheFileIsTheStranger() {
        #expect(SharedDataFile.strangers(recordIdentifiers: ["1.2.3", "1.2.4"], fileIdentifiers: ["1.2.4"]) == [0])
        #expect(SharedDataFile.strangers(recordIdentifiers: ["1.2.4", "1.2.3", "1.2.5"], fileIdentifiers: ["1.2.4"]) == [1, 2])
    }

    @Test func theFramesOfTheFileStayWhenAStrangerNamesItToo() {
        #expect(SharedDataFile.strangers(recordIdentifiers: ["1.2.4", "1.2.3", "1.2.4", "1.2.4"], fileIdentifiers: ["1.2.4"]) == [1])
    }

    @Test func theSeriesOfAFileThatIsNotDICOMAreAllOfIt() {
        #expect(SharedDataFile.strangers(recordIdentifiers: ["scan", "scan1", "scan2"], fileIdentifiers: ["scan", "scan1", "scan2"]) == [])
        #expect(SharedDataFile.strangers(recordIdentifiers: ["scan", "scan1", "1.2.3"], fileIdentifiers: ["scan", "scan1"]) == [2])
    }

    @Test func aFileThatDoesNotReadTellsNothing() {
        #expect(SharedDataFile.strangers(recordIdentifiers: ["1.2.3", "1.2.4"], fileIdentifiers: nil) == [])
        #expect(SharedDataFile.strangers(recordIdentifiers: ["1.2.3", "1.2.4"], fileIdentifiers: []) == [])
    }

    @Test func aFileNoneOfTheRecordsIsOfTellsNothing() {
        // Written anew in its place, with an identifier of its own.
        #expect(SharedDataFile.strangers(recordIdentifiers: ["1.2.3", "1.2.4"], fileIdentifiers: ["1.2.9"]) == [])
    }

    @Test func aRecordWithoutAnIdentifierIsNeverAStranger() {
        #expect(SharedDataFile.strangers(recordIdentifiers: [nil, "1.2.3", "1.2.4"], fileIdentifiers: ["1.2.4"]) == [1])
        #expect(SharedDataFile.strangers(recordIdentifiers: [String?.none, nil], fileIdentifiers: ["1.2.4"]) == [])
    }
}
