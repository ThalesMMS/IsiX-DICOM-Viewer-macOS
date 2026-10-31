//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// What the 2D viewer's series list shows, in values: the studies it lists in
/// their order, the series of each, the cells they fill, the tint of each cell
/// and which series frames a study whose series are hidden. The application
/// reads the database objects once into this and fills the list's cells from it.
public struct SeriesListModel: Sendable, Equatable {

    /// How a study of the list is held.
    public enum StudyKind: Sendable, Equatable {
        /// A study of the database.
        case local
        /// The viewer's own study, listed as found on a PACS: its database copy
        /// shows, with the picture of a study to retrieve and no action.
        case viewerStudyOnPACS
        /// A study on a PACS, with the database copy's series when it has some.
        case distant
    }

    /// The colour behind a cell.
    public enum Tint: Sendable, Equatable {
        /// The list's own background: a study of the viewer's or one of its series.
        case none
        /// Another study, or one of its series.
        case otherStudy
        /// A series this viewer shows, or a study with series hidden that has one.
        case shown
        /// The series fused in this viewer.
        case fused
    }

    /// The action written under a study of the database.
    public enum StudyAction: Sendable, Equatable {
        case showSeries
        case hideSeries
    }

    /// A series of a listed study.
    public struct Series: Sendable, Equatable {
        /// One of the viewer's time points shows it.
        public var isShown: Bool
        /// The viewer fuses it.
        public var isFused: Bool
        /// A window shows it (its frame takes that window's colour or number).
        public var isInAWindow: Bool

        public init(isShown: Bool, isFused: Bool, isInAWindow: Bool) {
            self.isShown = isShown
            self.isFused = isFused
            self.isInAWindow = isInAWindow
        }
    }

    /// A listed study.
    public struct Study: Sendable, Equatable {
        public var kind: StudyKind
        /// The viewer shows this study.
        public var isViewerStudy: Bool
        /// Its series are hidden: the study's cell stands for them.
        public var seriesHidden: Bool
        public var series: [Series]
        /// The placeholders of the series a DICOMweb node's rule left out.
        public var excludedCount: Int

        public init(kind: StudyKind, isViewerStudy: Bool, seriesHidden: Bool, series: [Series], excludedCount: Int) {
            self.kind = kind
            self.isViewerStudy = isViewerStudy
            self.seriesHidden = seriesHidden
            self.series = series
            self.excludedCount = excludedCount
        }
    }

    /// A cell of the list, by the study (its index in `studies`) and the
    /// series or placeholder it shows.
    public enum Cell: Sendable, Equatable {
        case study(Int)
        case series(study: Int, series: Int)
        case excluded(study: Int, placeholder: Int)
    }

    /// The studies the list shows, most recent first.
    public var studies: [Study]
    /// The cells the list is laid out for: one per listed study and the
    /// cells counted for the series and placeholders of the patient's studies.
    public var cellCount: Int
    /// The list colours the series shown and fused (the identification preference).
    public var showsSeriesColors: Bool

    /// `countedCells` is what the patient's studies count for their series and
    /// placeholders: the series of each database study whose series show, its
    /// placeholders, counted over every study of the patient, listed or not.
    public init(studies: [Study], countedCells: Int, showsSeriesColors: Bool) {
        self.studies = studies
        cellCount = countedCells + studies.count
        self.showsSeriesColors = showsSeriesColors
    }

    /// The cells in the order the list fills them: each study, then, unless
    /// its series are hidden, its series and its placeholders.
    public var cells: [Cell] {
        var cells: [Cell] = []
        for (index, study) in studies.enumerated() {
            cells.append(.study(index))
            guard !study.seriesHidden else { continue }
            cells += study.series.indices.map { .series(study: index, series: $0) }
            cells += (0..<study.excludedCount).map { .excluded(study: index, placeholder: $0) }
        }
        return cells
    }

    /// The tint of a cell: its colour, or else its background.
    public func tint(of cell: Cell) -> Tint {
        colour(of: cell) ?? background(of: cell)
    }

    /// The background a cell gets first: none for the viewer's study and its
    /// series and placeholders, the other studies' colour for the rest.
    public func background(of cell: Cell) -> Tint {
        switch cell {
        case .study(let index), .series(let index, _), .excluded(let index, _):
            return studies[index].isViewerStudy ? .none : .otherStudy
        }
    }

    /// The colour that comes over the background, when the list colours
    /// series: a series shown, else fused; a study whose series are hidden
    /// takes it from the first of its series that has one. Nil for none.
    public func colour(of cell: Cell) -> Tint? {
        switch cell {
        case .study(let index):
            return studies[index].seriesHidden ? hiddenSeriesDecoration(of: index).tint : nil
        case .series(let index, let series):
            return seriesTint(studies[index].series[series])
        case .excluded:
            return nil
        }
    }

    /// The series whose window frames a study with hidden series: the first one
    /// in a window, looked for up to the first series that tints the study.
    public func framingSeries(ofStudy index: Int) -> Int? {
        studies[index].seriesHidden ? hiddenSeriesDecoration(of: index).framing : nil
    }

    /// The action written under a study of the database; none for one to
    /// retrieve (on a PACS, or the viewer's own listed from it).
    public func action(ofStudy index: Int) -> StudyAction? {
        let study = studies[index]
        guard study.kind == .local else { return nil }
        return study.seriesHidden ? .showSeries : .hideSeries
    }

    private func seriesTint(_ series: Series) -> Tint? {
        guard showsSeriesColors else { return nil }
        if series.isShown { return .shown }
        if series.isFused { return .fused }
        return nil
    }

    /// The study's series in order: the first one in a window frames it, and
    /// the first one that tints ends the search.
    private func hiddenSeriesDecoration(of index: Int) -> (tint: Tint?, framing: Int?) {
        var framing: Int?
        for (position, series) in studies[index].series.enumerated() {
            if framing == nil && series.isInAWindow { framing = position }
            if let tint = seriesTint(series) { return (tint, framing) }
        }
        return (nil, framing)
    }
}
