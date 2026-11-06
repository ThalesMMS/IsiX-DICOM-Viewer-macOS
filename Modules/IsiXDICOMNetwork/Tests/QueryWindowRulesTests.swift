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
@testable import IsiXDICOMNetwork

/// The rules of the Query window. Their comparison with the Objective-C++ they
/// replaced is tests/test-query-window-rules-equivalence.py.
struct QueryWindowRulesTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-28 14:05:09.75 UTC
    private var now: Date { Date(timeIntervalSince1970: 1_793_196_309.75) }

    private func criteria(_ tag: Int32, from: Date? = nil, to: Date? = nil, future: Bool = false) -> QueryDateFilter.Criteria {
        QueryDateFilter.criteria(tag: tag, from: from ?? now, to: to ?? now, now: now, allowFutureQuery: future, timeZone: utc)
    }

    @Test func aRangeIsWrittenEarlierFirst() {
        let later = now.addingTimeInterval(3 * 86_400)
        let range = criteria(QueryDateFilter.between, from: later, to: now)
        #expect(range.date == .init(value: .text("20261028-20261031"), match: .exactMatch) && range.time == nil)
        #expect(criteria(QueryDateFilter.on, from: later).date == .init(value: .date(later), match: .exactDate))
        #expect(criteria(QueryDateFilter.anyDate).date == .init(value: .none, match: .after))
    }

    @Test func daysAreCalendarDaysAndPeriodsAreSeconds() {
        #expect(criteria(QueryDateFilter.today).date == .init(value: .date(now), match: .exactDate))
        #expect(criteria(QueryDateFilter.yesterday).date.value == .date(now.addingTimeInterval(-86_400)))
        #expect(criteria(QueryDateFilter.dayBeforeYesterday).date.value == .date(now.addingTimeInterval(-2 * 86_400)))
        #expect(criteria(QueryDateFilter.last7Days).date == .init(value: .date(now.addingTimeInterval(-604_801)), match: .after))
        #expect(criteria(QueryDateFilter.lastYear).date.value == .date(now.addingTimeInterval(-31_536_001)))
    }

    @Test func halfDaysAndRecentHoursAddATime() {
        #expect(criteria(QueryDateFilter.todayAM).time == "000000.000-120000.000")
        #expect(criteria(QueryDateFilter.todayPM).time == "120000.000-235959.000")
        #expect(criteria(102).time == "120509.000-140509.000")
        #expect(criteria(102, future: true).time == "120509.000-")
        #expect(criteria(230).time == "133509.000-140509.000")
        // 200 is still read as hours.
        #expect(criteria(200).date.value == .date(now.addingTimeInterval(-100 * 3_600)))
        let unknown = criteria(50)
        #expect(unknown.unknownTag && unknown.date == .init(value: .none, match: .after) && unknown.time == nil)
    }

    @Test func eachFieldSendsItsFilter() {
        #expect(QueryWindowField.patientName.filterValue("  doe ") == "doe*")
        #expect(QueryWindowField.studyDescription.filterValue("  ct ") == "  ct *")
        #expect(QueryWindowField.patientID.filterValue(" 12 ") == "12")
        #expect(QueryWindowField.accessionNumber.filterValue(" \n") == nil)
        #expect(QueryWindowField.customField.key == nil && QueryWindowField.customField.filterValue("x") == "x")
        #expect(QueryWindowField.patientBirthDate.filterValue("x") == nil)
        #expect(!QueryWindowField.patientID.checksEncoding && QueryWindowField.studyComments.checksEncoding)
        #expect(QueryDateFilter.birthDateFormat(forTag: -1) == "-%Y%m%d" && QueryDateFilter.birthDateFormat(forTag: 2) == nil)
    }

    @Test func modalitiesGoInOneValue() {
        #expect(QueryModalityFilter.key(supportsModalitiesInStudy: true) == "ModalitiesinStudy")
        #expect(QueryModalityFilter.key(supportsModalitiesInStudy: false) == "Modality")
        #expect(QueryModalityFilter.value(["CT", "MR"]) == "CT\\MR" && QueryModalityFilter.value([]) == nil)
    }

    @Test func studyQueriesKeepWhatThePreferencesAllow() {
        let filters: [String: Any] = ["patientName": "DOE*", "PatientID": "**", "accessionNumber": "A1",
                                      "modality": ["CT", "MR"], "date": NSNumber(value: 1), "Comments": "x"]
        let none = QueryStudyFilters.build(filters, permissions: .init(), birthDate: { $0 },
                                           studyDateAndTime: { _, _, _ in ("D", "T") })
        #expect(none.filters.isEmpty && none.removed.isEmpty)
        let all = QueryStudyFilters.build(filters, permissions: .init(accessionNumber: true, comments: true, identifiers: true,
                                                                      name: true, studyDate: true, modalitiesInStudy: true),
                                          birthDate: { $0 }, studyDateAndTime: { code, _, _ in ("D\(code)", nil) })
        #expect(all.filters["PatientsName"] as? String == "DOE*" && all.filters["AccessionNumber"] as? String == "A1")
        #expect(all.filters["StudyComments"] as? String == "x" && all.filters["StudyDate"] as? String == "D1")
        #expect(all.filters["ModalitiesinStudy"] as? String == "CT\\MR" && all.filters["StudyTime"] == nil)
        #expect(all.filters["PatientID"] == nil)
        #expect(all.removed == [.tooShort(key: "PatientID", value: "**"), .empty(key: "PatientID")])
        let short = QueryStudyFilters.build(["PatientsName": "ab*"], permissions: .init(name: true), birthDate: { $0 },
                                            studyDateAndTime: { _, _, _ in (nil, nil) })
        #expect(short.filters.isEmpty && short.removed == [.tooShort(key: "PatientsName", value: "ab*")])
        // Modalities alone need their own permission.
        let alone = QueryStudyFilters.build(["modality": ["CT"]], permissions: .init(), birthDate: { $0 },
                                            studyDateAndTime: { _, _, _ in (nil, nil) })
        #expect(alone.filters.isEmpty)
    }

    @Test func theCopyWithMoreImagesWins() {
        struct Study: Equatable { var uid: String?; var images: Int32?; var tag: String }
        var studies = [Study(uid: "1", images: 3, tag: "a"), Study(uid: nil, images: 1, tag: "b")]
        let found = [Study(uid: "1", images: 5, tag: "c"), Study(uid: "2", images: 1, tag: "d"),
                     Study(uid: "2", images: 9, tag: "e"), Study(uid: nil, images: 1, tag: "f")]
        var indexed = studies
        QueryResultMerge.merge(found, into: &indexed, indexingAdditions: true, uid: { $0.uid }, images: { $0.images })
        #expect(indexed.map(\.tag) == ["c", "b", "e", "f"])
        QueryResultMerge.merge(found, into: &studies, indexingAdditions: false, uid: { $0.uid }, images: { $0.images })
        #expect(studies.map(\.tag) == ["c", "b", "d", "e", "f"])
        var unknownCount = [Study(uid: "1", images: nil, tag: "a")]
        QueryResultMerge.merge([Study(uid: "1", images: 4, tag: "b")], into: &unknownCount, indexingAdditions: true,
                               uid: { $0.uid }, images: { $0.images })
        #expect(unknownCount.map(\.tag) == ["a"])
    }
}
