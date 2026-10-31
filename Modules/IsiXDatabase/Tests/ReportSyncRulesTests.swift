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

/// A report and its SR as the check sees them: whether their contents are the
/// same now, whether archiving makes them the same, and what was asked.
private final class ArchivedReport {
    var same: Bool
    let archiveSucceeds: Bool
    var comparisons = 0
    var archives = 0

    init(same: Bool, archiveSucceeds: Bool = true) {
        self.same = same
        self.archiveSucceeds = archiveSucceeds
    }

    func check(_ record: ReportSyncRecord, modified: Date? = Date(timeIntervalSinceReferenceDate: 100),
               signature: String?) -> ReportSyncRecord {
        ReportSyncRules.check(record, modified: modified, signature: signature,
                              matchesArchive: { comparisons += 1; return same },
                              archive: { archives += 1; if archiveSucceeds { same = true } })
    }
}

private let modified = Date(timeIntervalSinceReferenceDate: 100)

@Suite struct ReportSyncRulesTests {

    @Test func aReportJustOpenedIsCompared() {
        #expect(ReportSyncRecord.unverified.verifiedModificationDate == .distantPast)
        #expect(ReportSyncRecord.unverified.signature == nil)
        #expect(ReportSyncRules.needsComparison(.unverified, signature: "a"))
        #expect(ReportSyncRules.needsComparison(.unverified, signature: nil))
    }

    @Test func onlyTheRecordedSignatureSkipsTheComparison() {
        let record = ReportSyncRecord(verifiedModificationDate: modified, signature: "a")
        #expect(!ReportSyncRules.needsComparison(record, signature: "a"))
        #expect(ReportSyncRules.needsComparison(record, signature: "b"))
        // A file that could not be examined has no signature, which never matches.
        #expect(ReportSyncRules.needsComparison(ReportSyncRecord(verifiedModificationDate: modified, signature: nil), signature: nil))
    }

    @Test func aMatchingReportRecordsItsDateAndSignature() {
        let report = ArchivedReport(same: true)
        let checked = report.check(.unverified, signature: "a")
        #expect(checked == ReportSyncRecord(verifiedModificationDate: modified, signature: "a"))
        #expect(report.comparisons == 1)
        #expect(report.archives == 0)
    }

    @Test func anUnchangedReportIsNotReadAgain() {
        let report = ArchivedReport(same: false)
        let recorded = ReportSyncRecord(verifiedModificationDate: modified, signature: "a")
        let checked = report.check(recorded, modified: Date(timeIntervalSinceReferenceDate: 200), signature: "a")
        #expect(checked == recorded)
        #expect(report.comparisons == 0)
        #expect(report.archives == 0)
    }

    @Test func aChangedReportIsArchivedAndItsNewSRIsRecordedNextTime() {
        let report = ArchivedReport(same: false)
        let recorded = ReportSyncRecord(verifiedModificationDate: .distantPast, signature: "a")
        let checked = report.check(recorded, signature: "b")
        #expect(report.archives == 1)
        #expect(report.comparisons == 2)
        // The archive wrote a new SR: its signature is not the one taken before.
        #expect(checked == ReportSyncRecord(verifiedModificationDate: modified, signature: nil))

        let next = report.check(checked, signature: "c")
        #expect(next == ReportSyncRecord(verifiedModificationDate: modified, signature: "c"))
        #expect(report.archives == 1)
    }

    @Test func aFailedArchiveStaysPending() {
        let report = ArchivedReport(same: false, archiveSucceeds: false)
        let recorded = ReportSyncRecord(verifiedModificationDate: Date(timeIntervalSinceReferenceDate: 50), signature: "a")
        let checked = report.check(recorded, signature: "b")
        #expect(report.archives == 1)
        #expect(checked == ReportSyncRecord(verifiedModificationDate: Date(timeIntervalSinceReferenceDate: 50), signature: nil))

        // Pending: the next activation compares and archives again, even with the same files.
        _ = report.check(checked, signature: "b")
        #expect(report.archives == 2)
    }

    @Test func aReportWithoutSignatureIsComparedEveryTime() {
        let report = ArchivedReport(same: true)
        let checked = report.check(.unverified, signature: nil)
        #expect(checked == ReportSyncRecord(verifiedModificationDate: modified, signature: nil))
        _ = report.check(checked, signature: nil)
        #expect(report.comparisons == 2)
    }

    @Test func aReportWhoseFileIsGoneIsLeftAsItWas() {
        let report = ArchivedReport(same: false)
        let recorded = ReportSyncRecord(verifiedModificationDate: modified, signature: "a")
        #expect(report.check(recorded, modified: nil, signature: nil) == recorded)
        #expect(report.comparisons == 0)
        #expect(report.archives == 0)
    }
}
