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

@Suite struct SeriesListModelTests {
    private typealias Series = SeriesListModel.Series

    private static let plain = Series(isShown: false, isFused: false, isInAWindow: false)
    private static let shown = Series(isShown: true, isFused: false, isInAWindow: true)
    private static let fused = Series(isShown: false, isFused: true, isInAWindow: false)
    private static let elsewhere = Series(isShown: false, isFused: false, isInAWindow: true)

    /// The viewer's study with three series, an older study with its series
    /// hidden, a PACS study with a local copy of one series.
    private func patient() -> SeriesListModel {
        SeriesListModel(studies: [
            .init(kind: .local, isViewerStudy: true, seriesHidden: false, series: [Self.shown, Self.plain, Self.fused], excludedCount: 2),
            .init(kind: .local, isViewerStudy: false, seriesHidden: true, series: [Self.plain, Self.elsewhere, Self.fused, Self.shown], excludedCount: 1),
            .init(kind: .distant, isViewerStudy: false, seriesHidden: false, series: [Self.plain], excludedCount: 0),
        ], countedCells: 6)
    }

    @Test func cellsInTheOrderTheListFillsThem() {
        let model = patient()
        #expect(model.cells == [.study(0), .series(study: 0, series: 0), .series(study: 0, series: 1), .series(study: 0, series: 2),
                                .excluded(study: 0, placeholder: 0), .excluded(study: 0, placeholder: 1),
                                .study(1),
                                .study(2), .series(study: 2, series: 0)])
        // The layout's count: a cell per study and what the patient's studies counted.
        #expect(model.cellCount == 9)
    }

    @Test func tintsOfSeriesAndStudies() {
        let model = patient()
        #expect(model.tint(of: .study(0)) == .none)
        #expect(model.tint(of: .series(study: 0, series: 0)) == .shown(.current))
        #expect(model.tint(of: .series(study: 0, series: 1)) == .none)
        #expect(model.tint(of: .series(study: 0, series: 2)) == .fused)
        #expect(model.tint(of: .excluded(study: 0, placeholder: 1)) == .none)
        // Hidden series: the first that tints, fused before the shown one after it.
        #expect(model.tint(of: .study(1)) == .fused)
        #expect(model.tint(of: .study(2)) == .otherStudy)
        #expect(model.tint(of: .series(study: 2, series: 0)) == .otherStudy)
    }

    /// The window of the list shows a previous study of the patient: the
    /// series it shows are tinted as that study, and nothing else changes.
    @Test func theSeriesShownTakeTheStudyOfTheWindow() {
        var model = patient()
        #expect(model.windowStudy == .current)
        let current = model.cells.map { model.tint(of: $0) }
        model.windowStudy = .previous
        #expect(model.tint(of: .series(study: 0, series: 0)) == .shown(.previous))
        #expect(model.colour(of: .series(study: 0, series: 0)) == .shown(.previous))
        let previous = model.cells.map { model.tint(of: $0) }
        #expect(zip(current, previous).allSatisfy { $0 == $1 || ($0 == .shown(.current) && $1 == .shown(.previous)) })
        #expect(previous.filter { $0 == .shown(.previous) }.count == 1 && !previous.contains(.shown(.current)))
        // A study with its series hidden takes the tint of the series shown, in the same study's colour.
        let hidden = SeriesListModel(studies: [
            .init(kind: .local, isViewerStudy: true, seriesHidden: true, series: [Self.plain, Self.shown, Self.fused], excludedCount: 0),
        ], countedCells: 0, windowStudy: .previous)
        #expect(hidden.tint(of: .study(0)) == .shown(.previous) && hidden.framingSeries(ofStudy: 0) == 1)
        // The fused series and the other studies keep their own.
        #expect(model.tint(of: .series(study: 0, series: 2)) == .fused && model.tint(of: .study(2)) == .otherStudy)
        // The two models are not one: a change of the window's study recolours the list.
        #expect(model != patient())
    }

    @Test func framingStopsAtTheSeriesThatTints() {
        let model = patient()
        #expect(model.framingSeries(ofStudy: 1) == 1)
        let tintedFirst = SeriesListModel(studies: [
            .init(kind: .local, isViewerStudy: false, seriesHidden: true, series: [Self.fused, Self.elsewhere], excludedCount: 0),
        ], countedCells: 0)
        #expect(tintedFirst.framingSeries(ofStudy: 0) == nil)
        #expect(tintedFirst.tint(of: .study(0)) == .fused)
        // A study whose series show is framed by none.
        #expect(model.framingSeries(ofStudy: 0) == nil)
    }

    @Test func actionsOfTheStudies() {
        let model = SeriesListModel(studies: [
            .init(kind: .local, isViewerStudy: true, seriesHidden: false, series: [], excludedCount: 0),
            .init(kind: .local, isViewerStudy: false, seriesHidden: true, series: [], excludedCount: 0),
            .init(kind: .viewerStudyOnPACS, isViewerStudy: true, seriesHidden: false, series: [], excludedCount: 0),
            .init(kind: .distant, isViewerStudy: false, seriesHidden: false, series: [], excludedCount: 0),
        ], countedCells: 0)
        #expect(model.action(ofStudy: 0) == .hideSeries)
        #expect(model.action(ofStudy: 1) == .showSeries)
        #expect(model.action(ofStudy: 2) == nil)
        #expect(model.action(ofStudy: 3) == nil)
    }
}

@Suite struct SeriesListDockDecisionTests {
    @Test func thumbnailHeight() {
        #expect(SeriesListDock.thumbnailHeight(cellHeight: nil) == 120)
        #expect(SeriesListDock.thumbnailHeight(cellHeight: 0.5) == 120)
        #expect(SeriesListDock.thumbnailHeight(cellHeight: 96) == 96)
    }

    @Test func scrollerSetAside() {
        #expect(SeriesListDock.scrollerWidth(across: true, overlayScrollers: false, shownScrollerWidth: 15) == 0)
        #expect(SeriesListDock.scrollerWidth(across: false, overlayScrollers: true, shownScrollerWidth: 15) == 0)
        #expect(SeriesListDock.scrollerWidth(across: false, overlayScrollers: false, shownScrollerWidth: nil) == 0)
        #expect(SeriesListDock.scrollerWidth(across: false, overlayScrollers: false, shownScrollerWidth: 15) == 15)
    }

    @Test func automaticHiding() {
        var asked = 0
        let mouseAway = { () -> Bool in asked += 1; return false }
        // A window not key hides the list without asking where the mouse is.
        #expect(SeriesListDock.autoHiddenVisibility(fullScreen: false, windowIsKey: false, listShown: true, mouseKeepsListShown: mouseAway) == false)
        #expect(asked == 0)
        #expect(SeriesListDock.autoHiddenVisibility(fullScreen: false, windowIsKey: false, listShown: false, mouseKeepsListShown: mouseAway) == nil)
        // Key window: the mouse decides.
        #expect(SeriesListDock.autoHiddenVisibility(fullScreen: false, windowIsKey: true, listShown: true, mouseKeepsListShown: mouseAway) == false)
        #expect(asked == 1)
        #expect(SeriesListDock.autoHiddenVisibility(fullScreen: false, windowIsKey: true, listShown: false, mouseKeepsListShown: { true }) == true)
        #expect(SeriesListDock.autoHiddenVisibility(fullScreen: true, windowIsKey: false, listShown: true, mouseKeepsListShown: { true }) == nil)
    }

    @Test func propagationAndScrolling() {
        #expect(SeriesListDock.propagatesVisibility(autoHides: false, fullScreen: false, optionDown: false))
        #expect(!SeriesListDock.propagatesVisibility(autoHides: true, fullScreen: false, optionDown: false))
        #expect(!SeriesListDock.propagatesVisibility(autoHides: false, fullScreen: true, optionDown: false))
        #expect(!SeriesListDock.propagatesVisibility(autoHides: false, fullScreen: false, optionDown: true))
        #expect(SeriesListDock.syncsScrolling(preference: true, commandDown: false))
        #expect(!SeriesListDock.syncsScrolling(preference: true, commandDown: true))
        #expect(SeriesListDock.syncsScrolling(preference: false, commandDown: true))
    }
}
