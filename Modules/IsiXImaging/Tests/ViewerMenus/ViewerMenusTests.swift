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

@Suite struct ViewerImageTilingTests {

    @Test func tagOfEachLayout() {
        #expect(ViewerImageTiling.tag(rows: 1, columns: 1) == 0)
        #expect(ViewerImageTiling.tag(rows: 2, columns: 3) == 6)
        #expect(ViewerImageTiling.tag(rows: 4, columns: 4) == 15)
        #expect(ViewerImageTiling.tag(rows: 0, columns: 0) == -5)
    }

    @Test func layoutOfEachTag() {
        for tag in 0..<16 {
            let layout = ViewerImageTiling.layout(tag: tag)
            #expect(ViewerImageTiling.tag(rows: Int(layout.rows), columns: Int(layout.columns)) == tag)
        }
        #expect(ViewerImageTiling.layout(tag: 16) == (1, 1))
        // Divisions that round toward zero, as in C.
        #expect(ViewerImageTiling.layout(tag: -1) == (1, 0))
        #expect(ViewerImageTiling.layout(tag: -5) == (0, 0))
        // A tag counted in 32 bits.
        #expect(ViewerImageTiling.layout(tag: 4_294_967_297) == (1, 2))
    }

    @Test func rowsAndColumnsStayBetweenOneAndEight() {
        #expect(ViewerImageTiling.clamped(rows: 0, columns: 9) == (1, 8))
        #expect(ViewerImageTiling.clamped(rows: -3, columns: 5) == (1, 5))
    }
}

@Suite struct ViewerPresetMenusTests {

    @Test func namesSortedWithoutCase() {
        #expect(ViewerPresetMenus.sortedNames(["lung", "Brain", "abdomen", "Bone"]) == ["abdomen", "Bone", "Brain", "lung"])
        // Names that differ only by case keep their order.
        #expect(ViewerPresetMenus.sortedNames(["b", "A", "a"]) == ["A", "a", "b"])
        #expect(ViewerPresetMenus.sortedNames(["a", "A"]) == ["a", "A"])
    }

    @Test func windowLevelTitlesNumberedFromOne() {
        #expect(ViewerPresetMenus.wlwwPresetTitle(index: 0, name: "Brain") == "1 - Brain")
        #expect(ViewerPresetMenus.wlwwPresetTitle(index: 11, name: "Lung") == "12 - Lung")
    }

    @Test func windowLevelItemChecked() {
        #expect(ViewerPresetMenus.checksWLWWItem(title: "1 - Brain", current: "Brain"))
        #expect(ViewerPresetMenus.checksWLWWItem(title: "Other", current: "Other"))
        #expect(!ViewerPresetMenus.checksWLWWItem(title: "Other", current: nil))
        #expect(!ViewerPresetMenus.checksWLWWItem(title: "abc", current: "Brain"))
        // Only the four characters of a number below 10 are dropped.
        #expect(!ViewerPresetMenus.checksWLWWItem(title: "12 - Lung", current: "Lung"))
        #expect(ViewerPresetMenus.checksWLWWItem(title: "12 - Lung", current: " Lung"))
        // Characters compared one by one: a composed é is not e and an accent.
        #expect(!ViewerPresetMenus.checksWLWWItem(title: "Caf\u{e9}", current: "Cafe\u{301}"))
    }
}

@Suite struct ViewerContextualMenusTests {

    @Test func composedTitleFromTheOutermostMenu() {
        #expect(ViewerContextualMenus.composedTitle(itemTitle: "Nodule", enclosingMenuTitles: ["Lung", "Findings"]) == "Findings Lung Nodule")
        #expect(ViewerContextualMenus.composedTitle(itemTitle: "?", enclosingMenuTitles: []) == "?")
    }
}

@Suite struct ViewerReportIconTests {

    @Test func iconOfEachReportsApplication() {
        #expect(ViewerReportIcon.name(reportsMode: nil) == "ReportWord.icns")
        #expect(ViewerReportIcon.name(reportsMode: "0") == "ReportWord.icns")
        #expect(ViewerReportIcon.name(reportsMode: "1") == "ReportRTF.icns")
        #expect(ViewerReportIcon.name(reportsMode: " 2abc") == "ReportPages.icns")
        #expect(ViewerReportIcon.name(reportsMode: "3") == "Report.icns")
        #expect(ViewerReportIcon.name(reportsMode: "x") == "ReportWord.icns")
    }
}
