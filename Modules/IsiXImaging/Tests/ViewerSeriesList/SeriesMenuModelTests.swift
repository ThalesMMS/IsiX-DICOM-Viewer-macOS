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

@Suite struct SeriesMenuModelTests {
    private typealias Series = SeriesMenuModel.Series

    private static func series(_ name: String, _ count: Int, shown: Bool = false, fused: Bool = false, window: Bool = false) -> Series {
        Series(name: name, imageCount: count, isShown: shown, isFused: fused, hasWindowColour: window)
    }

    /// The viewer's study with three series, an older study with one, a PACS
    /// study with none.
    private func patient(lastIsViewerStudyOnPACS: Bool = false) -> SeriesMenuModel {
        SeriesMenuModel(studies: [
            .init(title: "today / CT", picture: .number(studyIndex: 0), isViewerStudyOnPACS: false,
                  series: [Self.series("Axial", 120, shown: true, window: true), Self.series("Scout", 1), Self.series("Fused", 3, fused: true)]),
            .init(title: "last year / MR", picture: .number(studyIndex: 1), isViewerStudyOnPACS: false,
                  series: [Self.series("T1", 20, shown: true, window: true)]),
            .init(title: nil, picture: .retrieve, isViewerStudyOnPACS: lastIsViewerStudyOnPACS, series: []),
        ])
    }

    @Test func itemsInTheOrderOfTheMenu() {
        #expect(patient().items == [.study(0), .series(study: 0, series: 0), .series(study: 0, series: 1), .series(study: 0, series: 2), .separator,
                                    .study(1), .series(study: 1, series: 0), .separator,
                                    .study(2)])
        // The viewer's own study listed from a PACS keeps its separator, also last.
        #expect(patient(lastIsViewerStudyOnPACS: true).items.last == .separator)
        #expect(SeriesMenuModel(studies: []).items.isEmpty)
    }

    @Test func thePopupSelectsTheLastSeriesShown() {
        // Item 6 is T1, after Axial (1): the last one selected stays.
        #expect(patient().selectedItem == 6)
        var none = patient()
        none.studies[0].series[0].isShown = false
        none.studies[1].series[0].isShown = false
        #expect(none.selectedItem == nil)
    }

    @Test func highlightsShownThenFusedThenWindowColour() {
        let model = patient()
        #expect(model.highlight(of: Self.series("a", 1, shown: true, fused: true, window: true)) == .shown)
        #expect(model.highlight(of: Self.series("a", 1, fused: true, window: true)) == .fused)
        #expect(model.highlight(of: Self.series("a", 1, window: true)) == .windowColour)
        #expect(model.highlight(of: Self.series("a", 1)) == SeriesMenuModel.Highlight.none)
    }

    @Test func seriesTitlesCountTheirImages() {
        let decimal = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        #expect(SeriesMenuModel.title(of: Self.series("Scout", 1)) == "Scout / 1 image")
        #expect(SeriesMenuModel.title(of: Self.series("", 0)) == " / 0 images")
        #expect(SeriesMenuModel.title(of: Self.series("Axial", 1200)) == "Axial / \(decimal(1200)) images")
    }
}
