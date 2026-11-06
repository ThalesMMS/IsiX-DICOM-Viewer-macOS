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
import IsiXContracts
import Testing

/// What a consumer sees of the port, through the existential it receives.
private struct PreviewDouble: DatabaseCleaning {
    let preview: CleanupPreview
    var cleaningIdentifier: String { "double" }
    func isIdleForCleaning() -> Bool { true }
    func runCleanupPass() async {}
    func previewCleanup() async -> CleanupPreview { preview }
    func cleanForFreeSpace() {}
}

@Suite struct DatabaseCleaningTests {
    private let row = CleanupPreviewRow(rule: "Date", patient: "SYNTHETIC^PATIENT", study: "CT", studyInstanceUID: "1.2.3",
                                        date: Date(timeIntervalSinceReferenceDate: 0))

    @Test func aPreviewCrossesThePortAsItIs() async {
        let preview = CleanupPreview(summary: "Date cleanup: enabled.", rows: [row], failed: false)
        let cleaning: any DatabaseCleaning = PreviewDouble(preview: preview)
        #expect(await cleaning.previewCleanup() == preview)
    }

    @Test func aFailedPreviewIsNotTheSameAsAnEmptyOne() {
        #expect(CleanupPreview(summary: "", rows: [], failed: true) != CleanupPreview(summary: "", rows: [], failed: false))
    }

    @Test func aRowMayHaveNoDate() {
        let undated = CleanupPreviewRow(rule: "Date", patient: "P", study: "S", studyInstanceUID: "U", date: nil)
        #expect(undated.date == nil)
        #expect(undated != row)
    }
}
