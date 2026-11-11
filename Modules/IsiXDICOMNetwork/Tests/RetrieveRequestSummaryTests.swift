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
@testable import IsiXDICOMNetwork

struct RetrieveRequestSummaryTests {

    private func text(_ items: [RetrieveRequestSummary.Item]) -> String {
        RetrieveRequestSummary(items: items).text(studyCount: { $0 == 1 ? "1 study" : "\($0) studies" },
                                                  seriesCount: { "\($0) series" })
    }

    @Test func aStudyIsNamedByItsPatient() {
        #expect(text([.init(isSeries: false, patientName: "DOE^JANE")]) == "1 study - DOE JANE")
        #expect(text([.init(isSeries: false, patientName: nil)]) == "1 study")
    }

    @Test func aSeriesCountsAsASeriesAndShowsItsPatient() {
        #expect(text([.init(isSeries: true, patientName: "DOE^JANE", seriesLabel: "1801")]) == "1 series - DOE JANE - 1801")
        #expect(text([.init(isSeries: true, patientName: nil, seriesLabel: "Lung 1.0")]) == "1 series - Lung 1.0")
    }

    @Test func severalRowsShowThePatientTheyShare() {
        let jane = RetrieveRequestSummary.Item(isSeries: true, patientName: "DOE^JANE", seriesLabel: "2")
        #expect(text([jane, jane]) == "2 series - DOE JANE")
        #expect(text([jane, .init(isSeries: false, patientName: "DOE JANE ")]) == "1 study, 1 series - DOE JANE")
        #expect(text([jane, .init(isSeries: false, patientName: "ROE^RICHARD")]) == "1 study, 1 series")
        #expect(text([jane, .init(isSeries: false, patientName: nil)]) == "1 study, 1 series")
    }
}
