//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Testing
@testable import IsiXImaging

@Suite struct SeriesListStudySelectionTests {
    @Test func comparativesOnAPACSShowOnlyWithSeriesOrWhenListed() {
        // A newer PACS comparative, a loaded study, an older PACS comparative
        // with local series, an older one without.
        var asked = 0
        let selection = SeriesListStudySelection.select(notLoaded: [true, false, true, true], seriesCounts: [0, 3, 2, 0],
                                                        listsComparatives: { asked += 1; return false })
        #expect(selection.shown == [1, 2])
        #expect(selection.hasComparatives)
        #expect(selection.hasComparativesNewerThanLoaded)
        // Asked only for the comparatives without series.
        #expect(asked == 2)
        let listed = SeriesListStudySelection.select(notLoaded: [true, false], seriesCounts: [0, 1], listsComparatives: { true })
        #expect(listed.shown == [0, 1])
    }

    @Test func noComparativeNewerThanTheFirstLoadedStudy() {
        let selection = SeriesListStudySelection.select(notLoaded: [false, true], seriesCounts: [1, 0], listsComparatives: { false })
        #expect(selection.shown == [0])
        #expect(selection.hasComparatives)
        #expect(!selection.hasComparativesNewerThanLoaded)
        let none = SeriesListStudySelection.select(notLoaded: [false, false], seriesCounts: [0, 0], listsComparatives: { false })
        #expect(none.shown == [0, 1] && !none.hasComparatives)
    }

    @Test func numbersColoursAndStates() {
        #expect(SeriesListStudyNumbers.colorIndex(studyIndex: 1, colorCount: 3) == 1)
        #expect(SeriesListStudyNumbers.colorIndex(studyIndex: 5, colorCount: 3) == 2)
        #expect(SeriesListStudyNumbers.colorIndex(studyIndex: Int.max, colorCount: 3) == 2)
        #expect(SeriesListStudyNumbers.colorIndex(studyIndex: 0, colorCount: 0) == nil)
        #expect(SeriesListStudyNumbers.number(studyIndex: 0) == 1)
        // NSNotFound written as (int) index + 1.
        #expect(SeriesListStudyNumbers.number(studyIndex: Int.max) == 0)
        #expect(SeriesListStudyNumbers.stateIndex(0, stateCount: 4) == nil)
        #expect(SeriesListStudyNumbers.stateIndex(3, stateCount: 4) == 3)
        #expect(SeriesListStudyNumbers.stateIndex(4, stateCount: 4) == nil)
        #expect(SeriesListStudyNumbers.stateIndex(-1, stateCount: 4) == nil)
    }
}

@Suite struct SeriesListTitlesTests {
    @Test func patientLine() {
        var formatted = 0
        let line = SeriesListTitles.patientLine(name: "DOE^JANE", hasDateOfBirth: true, formattedDateOfBirth: { formatted += 1; return "1/2/70" },
                                                separator: "\r", isViewerPatient: { _ in false }, showsPatientName: true)
        #expect(line == "DOE^JANE\r1/2/70" && formatted == 1)
        #expect(SeriesListTitles.patientLine(name: "DOE^JANE", hasDateOfBirth: false, formattedDateOfBirth: { formatted += 1; return "x" },
                                             separator: " ", isViewerPatient: { _ in false }, showsPatientName: true) == "")
        #expect(formatted == 1)
        #expect(SeriesListTitles.patientLine(name: "DOE^JANE", hasDateOfBirth: true, formattedDateOfBirth: { nil },
                                             separator: " ", isViewerPatient: { _ in false }, showsPatientName: true) == "DOE^JANE (null)")
        #expect(SeriesListTitles.patientLine(name: "DOE^JANE", hasDateOfBirth: true, formattedDateOfBirth: { "d" },
                                             separator: " ", isViewerPatient: { $0 == "DOE^JANE" }, showsPatientName: true) == "")
        #expect(SeriesListTitles.patientLine(name: "DOE^JANE", hasDateOfBirth: true, formattedDateOfBirth: { "d" },
                                             separator: " ", isViewerPatient: { _ in false }, showsPatientName: false) == "")
    }

    @Test func menuAndCellLines() {
        #expect(SeriesListTitles.menuTitle(date: "d", patient: "", name: "CT", modality: "CT", comment: "") == "d / CT / CT")
        #expect(SeriesListTitles.menuTitle(date: "", patient: "p", name: nil, modality: "", comment: "c") == " / p / c")
        #expect(SeriesListTitles.menuTitle(date: nil, patient: "", name: nil, modality: "OT", comment: nil) == "OT")
        #expect(SeriesListTitles.cellLines(number: " 1 ", patient: "", name: "Head", date: nil, modalityAndSeries: "CT: 2 series",
                                           state: "", comment: "", action: "Hide Series")
                == [" 1 ", "", "Head", "CT: 2 series", "\rHide Series"])
        #expect(SeriesListTitles.cellLines(number: " 2 ", patient: "p", name: nil, date: "", modalityAndSeries: "MR: 1 series",
                                           state: "Read", comment: "c", action: nil)
                == [" 2 ", "", "p", "", "MR: 1 series", "Read", "c"])
        #expect(SeriesListTitles.comparativeCellLines(patient: "", name: "", date: "d", modality: "OT") == ["d", "OT"])
    }

    @Test func comparativesButton() {
        #expect(SeriesListComparativesButton.state(hasComparatives: false, newerThanLoaded: false, listsComparatives: false)
                == SeriesListComparativesButton(checked: false, tint: .plain, hint: nil, clickHides: nil))
        #expect(SeriesListComparativesButton.state(hasComparatives: true, newerThanLoaded: false, listsComparatives: false)
                == SeriesListComparativesButton(checked: false, tint: .available, hint: .available, clickHides: false))
        #expect(SeriesListComparativesButton.state(hasComparatives: true, newerThanLoaded: true, listsComparatives: false)
                == SeriesListComparativesButton(checked: false, tint: .newer, hint: .newer, clickHides: false))
        #expect(SeriesListComparativesButton.state(hasComparatives: true, newerThanLoaded: true, listsComparatives: true)
                == SeriesListComparativesButton(checked: true, tint: .plain, hint: nil, clickHides: true))
    }
}

@Suite struct SeriesListThumbnailRulesTests {
    @Test func imageCounts() {
        var raw = 0, frames = 0
        let images = SeriesListImageCount.of(fileCount: 12, rawFileCount: { raw += 1; return 0 }, frames: { frames += 1; return 0 })
        #expect(images == SeriesListImageCount(count: 12, singular: .image, plural: .images) && raw == 0 && frames == 0)
        #expect(SeriesListImageCount.of(fileCount: 1, rawFileCount: { 0 }, frames: { 40 })
                == SeriesListImageCount(count: 40, singular: .image, plural: .frames))
        #expect(SeriesListImageCount.of(fileCount: 1, rawFileCount: { 0 }, frames: { 1 })
                == SeriesListImageCount(count: 1, singular: .image, plural: .images))
        #expect(SeriesListImageCount.of(fileCount: 0, rawFileCount: { 1 }, frames: { 1 })
                == SeriesListImageCount(count: 1, singular: .object, plural: .images))
        #expect(SeriesListImageCount.of(fileCount: 0, rawFileCount: { 1 }, frames: { 9 })
                == SeriesListImageCount(count: 9, singular: .image, plural: .objects))
        #expect(SeriesListImageCount.of(fileCount: 0, rawFileCount: { 3 }, frames: { 9 })
                == SeriesListImageCount(count: 3, singular: .image, plural: .objects))
    }

    @Test func pictureSizes() {
        #expect(SeriesListPictureSize.of(fontSize: -1) == .scaled(0.6))
        #expect(SeriesListPictureSize.of(fontSize: 0) == .unscaled)
        #expect(SeriesListPictureSize.of(fontSize: 1) == .scaled(1.3))
        #expect(SeriesListPictureSize.of(fontSize: 2) == .none)
    }
}

@Suite struct SeriesListDockTests {
    @Test func dividerSnapsDownASide() {
        // A strip of 110 points, no scroller.
        #expect(SeriesListDock.snappedThickness(80, stripThickness: 110, scrollerWidth: 0, across: false) == 111)
        #expect(SeriesListDock.snappedThickness(40, stripThickness: 110, scrollerWidth: 0, across: false) == 0)
        #expect(SeriesListDock.snappedThickness(500, stripThickness: 110, scrollerWidth: 0, across: false) == 111)
        // A legacy scroller of 15 points.
        #expect(SeriesListDock.snappedThickness(130, stripThickness: 110, scrollerWidth: 15, across: false) == 127)
        // Negative and NaN are no strip, as arm64 converts them.
        #expect(SeriesListDock.snappedThickness(-300, stripThickness: 110, scrollerWidth: 0, across: false) == 0)
        #expect(SeriesListDock.snappedThickness(.nan, stripThickness: 110, scrollerWidth: 0, across: false) == 0)
    }

    @Test func dividerSnapsAcross() {
        #expect(SeriesListDock.snappedThickness(56, stripThickness: 110, scrollerWidth: 15, across: true) == 110)
        #expect(SeriesListDock.snappedThickness(55, stripThickness: 110, scrollerWidth: 15, across: true) == 0)
    }

    @Test func mouseKeepsTheListShown() {
        #expect(SeriesListDock.mouseKeepsListShown(x: 50, y: 10, cellWidth: 100, height: 500, listShown: false))
        #expect(SeriesListDock.mouseKeepsListShown(x: 113, y: 500, cellWidth: 100, height: 500, listShown: true))
        #expect(!SeriesListDock.mouseKeepsListShown(x: 113, y: 490, cellWidth: 100, height: 500, listShown: false))
        #expect(!SeriesListDock.mouseKeepsListShown(x: 114, y: 10, cellWidth: 100, height: 500, listShown: true))
        #expect(!SeriesListDock.mouseKeepsListShown(x: -1, y: 10, cellWidth: 100, height: 500, listShown: true))
    }
}

@Suite struct ViewerKeyTests {
    @Test func commands() {
        func key(_ s: String) -> UInt16 { s.utf16.first! }
        #expect(ViewerKeyCommand.of(character: 13, command: false) == .playStop)
        #expect(ViewerKeyCommand.of(character: 3, command: false) == .playStop)
        #expect(ViewerKeyCommand.of(character: key(" "), command: false) == .playStop)
        #expect(ViewerKeyCommand.of(character: key("1"), command: false) == .shuttle(speed: 2, direction: 1))
        #expect(ViewerKeyCommand.of(character: key("7"), command: true) == .shuttle(speed: 60, direction: 1))
        #expect(ViewerKeyCommand.of(character: key("c"), command: false) == .shuttle(speed: 10, direction: -1))
        #expect(ViewerKeyCommand.of(character: key("h"), command: false) == .other)
        #expect(ViewerKeyCommand.of(character: key("0"), command: false) == .stop)
        #expect(ViewerKeyCommand.of(character: 0xF700, command: false) == .previousTimePoint)
        #expect(ViewerKeyCommand.of(character: 0xF701, command: true) == .nextTimePoint)
        #expect(ViewerKeyCommand.of(character: 0xF702, command: false) == .other)
        #expect(ViewerKeyCommand.of(character: 0xF702, command: true) == .previousSeries)
        #expect(ViewerKeyCommand.of(character: 0xF703, command: true) == .nextSeries)
    }

    @Test func timePointsGoRound() {
        #expect(ViewerKeyCommand.timePoint(after: 0, step: -1, count: 3) == 2)
        #expect(ViewerKeyCommand.timePoint(after: 2, step: 1, count: 3) == 0)
        #expect(ViewerKeyCommand.timePoint(after: 1, step: 1, count: 3) == 2)
    }

    @Test func movieExportPositions() {
        #expect(MovieExportPosition.fieldValue(image: 4, imageCount: 20, flipped: false) == 5)
        #expect(MovieExportPosition.fieldValue(image: 4, imageCount: 20, flipped: true) == 16)
        #expect(MovieExportPosition.fieldValue(image: 21, imageCount: 20, flipped: true) == -1)
        #expect(MovieExportPosition.fieldValue(image: 32_768, imageCount: 32_769, flipped: false) == 32_769)
        #expect(MovieExportPosition.fieldValue(image: 32_768, imageCount: 32_769, flipped: true) == 1)
    }
}
