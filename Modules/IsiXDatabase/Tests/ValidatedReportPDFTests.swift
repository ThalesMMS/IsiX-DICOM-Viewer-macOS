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

@Suite struct ValidatedReportPDFTests {

    @Test func becomingValidatedMakesThePDF() {
        for previous: Int32 in [0, 1, 2, 3, 5] {
            #expect(ValidatedReportPDF.isDue(from: previous, to: 4), "from \(previous)")
        }
    }

    @Test func validatedAgainMakesNone() {
        #expect(!ValidatedReportPDF.isDue(from: 4, to: 4))
    }

    @Test func anotherStatusMakesNone() {
        for status: Int32 in [0, 1, 2, 3, 5] {
            #expect(!ValidatedReportPDF.isDue(from: 0, to: status), "to \(status)")
            #expect(!ValidatedReportPDF.isDue(from: 4, to: status), "from 4 to \(status)")
        }
    }
}
