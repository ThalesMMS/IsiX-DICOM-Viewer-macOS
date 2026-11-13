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
@testable import IsiXImaging

/// A file is loaded as the image of the record that names it unless it
/// states the SOP Instance UID of another image.
struct RecordedInstanceTests {
    private let recorded = "1.2.826.0.1.3680043.8.498.6000.1"
    private let another = "1.2.826.0.1.3680043.8.498.6000.2"

    @Test func theRecordsOwnFileIsLoaded() {
        #expect(RecordedInstance.accepts(fileUID: recorded, forRecordUID: recorded, numberOfFrames: 1))
        #expect(RecordedInstance.accepts(fileUID: recorded, forRecordUID: recorded, numberOfFrames: 0), "a record that counts no frame is one image")
    }

    @Test func theFileOfAnotherImageIsRefused() {
        #expect(!RecordedInstance.accepts(fileUID: another, forRecordUID: recorded, numberOfFrames: 1))
        #expect(!RecordedInstance.accepts(fileUID: another, forRecordUID: recorded, numberOfFrames: 0))
        #expect(!RecordedInstance.accepts(fileUID: recorded + "0", forRecordUID: recorded, numberOfFrames: 1), "a longer UID is another one")
    }

    @Test func paddingIsNoDifference() {
        #expect(RecordedInstance.accepts(fileUID: recorded + "\0", forRecordUID: recorded, numberOfFrames: 1), "an odd length is padded with a NUL")
        #expect(RecordedInstance.accepts(fileUID: recorded + " ", forRecordUID: " " + recorded, numberOfFrames: 1))
    }

    @Test func whatCannotBeToldApartIsLoaded() {
        // A record that keeps no UID, or an empty one.
        #expect(RecordedInstance.accepts(fileUID: another, forRecordUID: nil, numberOfFrames: 1))
        #expect(RecordedInstance.accepts(fileUID: another, forRecordUID: "", numberOfFrames: 1))
        #expect(RecordedInstance.accepts(fileUID: another, forRecordUID: " \0", numberOfFrames: 1))
        // A file that states none.
        #expect(RecordedInstance.accepts(fileUID: nil, forRecordUID: recorded, numberOfFrames: 1))
        #expect(RecordedInstance.accepts(fileUID: "", forRecordUID: recorded, numberOfFrames: 1))
        // A UID written with another character than digits and dots: the record keeps something else of it.
        #expect(RecordedInstance.accepts(fileUID: "1.2.826.0.1.A7", forRecordUID: recorded, numberOfFrames: 1))
        #expect(RecordedInstance.accepts(fileUID: "1.2 826", forRecordUID: "1.27826", numberOfFrames: 1))
        #expect(RecordedInstance.accepts(fileUID: recorded + "\\" + another, forRecordUID: recorded, numberOfFrames: 1))
        // The frames of a multi-frame object: one file, one UID, a record for each frame.
        #expect(RecordedInstance.accepts(fileUID: another, forRecordUID: recorded, numberOfFrames: 2))
        #expect(RecordedInstance.accepts(fileUID: another, forRecordUID: recorded, numberOfFrames: 120))
    }
}
