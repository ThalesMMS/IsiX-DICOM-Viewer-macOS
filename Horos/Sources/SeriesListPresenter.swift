//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging
import IsiXPreferences

/// The series list of a 2D viewer and its dock. The dock: its place on an edge
/// of the window's split view or in the floating panel, its thickness, shown or
/// hidden in step with the other viewers, hidden automatically away from the
/// mouse, and the split view's delegate that keeps it at the list's thickness.
/// The list: a thumbnail cell for each of the patient's studies and for each
/// series of a shown study (with the placeholders of the series a DICOMweb
/// node's rule left out), filled from a SeriesListModel, the comparatives
/// button, the clicks on its cells, and its scrolling kept in step with the
/// other viewers of the study.
///
/// The viewer keeps the selectors the nib, the notifications, the menus and
/// plugins send, and hands them to a presenter made over its graph: the
/// presenter holds nothing but the viewer and what the graph gives, the
/// preferences and the browser's comparative studies; what the list keeps
/// between calls is the viewer's ViewerSeriesListState.
@MainActor final class SeriesListPresenter {
    /// Held strongly for the length of a call: the viewer's teardown, which
    /// its deinit runs, reaches the list (a fused viewer rebuilds it as the
    /// fusion ends), and forming an unowned or weak reference to an object
    /// being deallocated traps.
    let viewer: ViewerController
    let processGraph: ProcessGraph
    let preferences: UserDefaults

    init(viewer: ViewerController, processGraph: ProcessGraph) {
        self.viewer = viewer
        self.processGraph = processGraph
        preferences = processGraph.preferences
    }

    /// Set while a viewer propagates its list's visibility to the other
    /// viewers, or re-places its own list. The split view resizes this causes are
    /// the app's own, not the user's, and must not be propagated back: another
    /// viewer may not be re-placed yet, and answering it would bounce between the
    /// two viewers. Every viewer's list runs on the main actor, which keeps it.
    static var resizeInProgress = false

    /// Set while a change of SeriesListVisible is passed to the viewers.
    static var visibilityChangeInProgress = false

    /// Set while a viewer scrolls the other viewers' lists: their scrolling is
    /// not to be answered.
    static var scrollingOtherLists = false

    /// The stored edge of the list.
    var placement: SeriesListPlacement {
        SeriesListLayout.storedPlacement(in: preferences)
    }

    /// The list is in the floating panel rather than docked.
    var isFloating: Bool {
        preferences[ViewerPreferences.useFloatingThumbnailsList]
    }

    /// The process's 2D viewers shown, as the register lists them.
    static func displayedViewers() -> [ViewerController] {
        ViewerController.getDisplayed2DViewers()?.compactMap { $0 as? ViewerController } ?? []
    }

    /// The image views of the viewer, as it lists them.
    func imageViews() -> [DCMView] {
        viewer.imageViews()?.compactMap { $0 as? DCMView } ?? []
    }
}

extension ViewerController {

    /// The presenter of the viewer's series list and dock, over the viewer's graph.
    var seriesListPresenter: SeriesListPresenter {
        SeriesListPresenter(viewer: self, processGraph: sessionGraph.processGraph)
    }
}

// MARK: - The dock

extension SeriesListPresenter {

    /// How thick the series list strip has to be on the stored edge.
    func thickness() -> CGFloat {
        let placement = self.placement
        let height = SeriesListDock.thumbnailHeight(cellHeight: viewer.horos_previewMatrix?.cellSize.height)
        return SeriesListLayout.thickness(for: placement, thumbnailWidth: CGFloat(ThumbnailCell.thumbnailCellWidth()), thumbnailHeight: height)
    }

    /// Places the list for the stored mode, edge and visibility.
    func updateMode() {
        guard viewer.horos_windowWillClose == false, let splitView = viewer.horos_splitView else {
            return
        }

        let wasInProgress = Self.resizeInProgress
        Self.resizeInProgress = true

        let floating = isFloating
        let visible = preferences[ViewerPreferences.seriesListVisible]
        let placement = self.placement
        if let scrollView = viewer.horos_previewMatrixScrollView {
            SeriesListLayout.place(scrollView, in: splitView, floating: floating, visible: visible, thumbnailWidth: thickness(),
                                   placement: placement)
        }
        splitView.resizeSubviews(withOldSize: splitView.bounds.size)
        if visible && viewer.horos_needsToBuildSeriesMatrix {
            viewer.buildMatrixPreview(false)
        } else if visible, let matrix = viewer.horos_previewMatrix {
            SeriesListLayout.layOut(matrix, count: matrix.cells.count, placement: placement, floating: floating)
        }

        Self.resizeInProgress = wasInProgress
    }

    /// Shows or hides the dock on the stored edge, never the image pane, and
    /// stores the visibility.
    func setListVisible(_ visible: Bool) {
        if viewer.horos_windowWillClose {
            return
        }

        if isListVisible() != visible {
            let placement = self.placement
            let thickness = self.thickness()
            if let splitView = viewer.horos_splitView {
                SeriesListLayout.setListVisible(visible, in: splitView, placement: placement, thickness: thickness)
            }
            viewer.horos_splitView?.resizeSubviews(withOldSize: viewer.horos_splitView?.bounds.size ?? .zero)

            if visible && viewer.horos_needsToBuildSeriesMatrix {
                viewer.buildMatrixPreview(false)
            }
        }

        preferences.set(visible, for: ViewerPreferences.seriesListVisible)
    }

    /// Whether the list shows: always in the floating panel, else whether its
    /// dock is open, which the stored visibility follows.
    func isListVisible() -> Bool {
        if isFloating {
            return true
        }

        let placement = self.placement
        let thickness = self.thickness()
        let visible = viewer.horos_splitView.map { SeriesListLayout.isListVisible(in: $0, placement: placement, thickness: thickness) } ?? false

        if preferences[ViewerPreferences.seriesListVisible] != visible {
            preferences.set(visible, for: ViewerPreferences.seriesListVisible)
        }

        return visible
    }

    /// A preference the viewer observes changed: the visibility of a docked
    /// list passes to every viewer.
    func preferenceChanged(_ keyPath: String?, newValue: Bool) {
        if isFloating {
            return
        }

        if viewerSameString(keyPath, ViewerPreferences.seriesListVisible.name) && Self.visibilityChangeInProgress == false {
            Self.visibilityChangeInProgress = true
            for other in Self.displayedViewers() {
                other.setMatrixVisible(newValue)
            }
            Self.visibilityChangeInProgress = false
        }
    }

    /// Hides the docked list away from the mouse, or shows it again, keeping
    /// the views' scale and origin.
    func autoHide() {
        if isFloating || preferences[ViewerPreferences.autoHidesMatrix] == false || viewer.horos_windowWillClose {
            return
        }

        let fullScreen = viewer.fullScreenON()
        let window = fullScreen ? viewer.horos_FullScreenWindow : viewer.window
        let windowIsKey = fullScreen || window?.isKeyWindow == true
        let mouse = window?.mouseLocationOutsideOfEventStream ?? .zero
        let shown = isListVisible()

        let changed = SeriesListDock.autoHiddenVisibility(fullScreen: fullScreen, windowIsKey: windowIsKey, listShown: shown) {
            SeriesListDock.mouseKeepsListShown(x: mouse.x, y: mouse.y, cellWidth: self.viewer.horos_previewMatrix?.cellSize.width ?? 0,
                                               height: self.viewer.horos_splitView?.frame.size.height ?? 0, listShown: shown)
        }
        guard let visible = changed else { return }

        // The origin goes through its text and back, as it always did.
        var scales: [Float] = []
        var origins: [String] = []
        for view in seriesViews() {
            scales.append(view.scaleValue)
            origins.append(NSStringFromPoint(view.origin))
        }

        setListVisible(visible)

        for (index, view) in seriesViews().enumerated() {
            view.displayIfNeeded()
            view.scaleValue = scales[index]
            view.origin = NSPointFromString(origins[index])
        }

        viewer.propagateSettings()

        for view in seriesViews() {
            view.displayIfNeeded()
        }
    }

    /// The image views of the viewer's series view.
    private func seriesViews() -> [DCMView] {
        viewer.horos_seriesView?.imageViews()?.compactMap { $0 as? DCMView } ?? []
    }

    /// The divider can be dragged only with the list docked.
    func effectiveRect(of splitView: NSSplitView, proposed: NSRect) -> NSRect {
        if splitView === viewer.horos_splitView && isFloating {
            return .zero
        }
        return proposed
    }

    /// After the split view resized its panes: the matrix fits its cells, and
    /// the other viewers' lists show or hide with this one.
    func splitViewDidResize(_ notification: Notification) {
        if viewer.horos_windowWillClose {
            return
        }

        guard (notification.object as AnyObject?) === viewer.horos_splitView else { return }
        viewer.horos_previewMatrix?.sizeToCells()

        let propagates = SeriesListDock.propagatesVisibility(autoHides: preferences[ViewerPreferences.autoHidesMatrix],
                                                             fullScreen: viewer.horos_FullScreenOn,
                                                             optionDown: NSApplication.shared.currentEvent?.modifierFlags.contains(.option) == true)
        guard propagates, Self.resizeInProgress == false else { return }
        Self.resizeInProgress = true

        let showsList = isListVisible()

        for other in ViewerController.get2DViewers()?.compactMap({ $0 as? ViewerController }) ?? [] {
            if other !== viewer {
                if showsList != other.matrixIsVisible() {
                    other.setMatrixVisible(showsList)
                }
            } else if other.matrixIsVisible() && viewer.horos_needsToBuildSeriesMatrix {
                viewer.buildMatrixPreview(false)
            }
        }
        Self.resizeInProgress = false
    }

    /// The whole window redraws while the split view resizes its panes.
    func splitViewWillResize(_ notification: Notification) {
        if viewer.horos_windowWillClose {
            return
        }

        if (notification.object as AnyObject?) === viewer.horos_splitView && isFloating == false {
            viewer.window?.contentView?.needsDisplay = true
        }
    }

    /// The image pane never collapses, whichever edge the list is docked on.
    func canCollapse(_ subview: NSView, of splitView: NSSplitView) -> Bool {
        !(splitView === viewer.horos_splitView && subview === SeriesListLayout.imagePane(of: splitView, placement: placement))
    }

    /// Where a dragged divider stops: at the list's own thickness or nothing.
    /// The divider's position is the list's thickness only with the list
    /// before the image pane, on the left or the top; on the right or the
    /// bottom the list lies past the divider, so the position is turned into a
    /// thickness and back.
    func constrainedDividerPosition(_ proposedPosition: CGFloat, of splitView: NSSplitView) -> CGFloat {
        if viewer.horos_windowWillClose || splitView !== viewer.horos_splitView {
            return proposedPosition
        }

        let placement = self.placement
        let proposedThickness = SeriesListLayout.listThickness(forDividerPosition: proposedPosition, in: splitView, placement: placement)

        if isFloating {
            return SeriesListLayout.dividerPosition(forListThickness: 0, in: splitView, placement: placement)
        }

        let stripThickness = thickness()

        // A strip across the top or bottom snaps to its own thickness; the
        // scroller only matters down a side.
        let across = placement == .top || placement == .bottom
        var scrollerWidth: CGFloat = 0
        if !across, let scrollView = viewer.horos_previewMatrixScrollView {
            let scroller = scrollView.verticalScroller
            let overlay = BrowserController._scrollerStyle(scroller) == 1
            let shownWidth = !overlay && scrollView.hasVerticalScroller && scroller?.isHidden != true ? scroller?.frame.size.width ?? 0 : nil
            scrollerWidth = SeriesListDock.scrollerWidth(across: across, overlayScrollers: overlay, shownScrollerWidth: shownWidth)
        }

        let thickness = SeriesListDock.snappedThickness(proposedThickness, stripThickness: stripThickness, scrollerWidth: scrollerWidth, across: across)

        return SeriesListLayout.dividerPosition(forListThickness: thickness, in: splitView, placement: placement)
    }

    /// Lays the split view's panes out with the dock at the list's thickness,
    /// on any edge.
    func resizeSubviews(of splitView: NSSplitView) {
        if viewer.horos_windowWillClose || splitView !== viewer.horos_splitView {
            return
        }

        let placement = self.placement
        var thickness = isListVisible() ? self.thickness() : 0
        // The constraint works on the divider's position, which is measured
        // from the far end when the list is on the right or the bottom.
        let dividerPosition = viewer.splitView(splitView, constrainSplitPosition: SeriesListLayout.dividerPosition(forListThickness: thickness, in: splitView,
                                                                                                                   placement: placement),
                                               ofSubviewAt: 0)
        thickness = SeriesListLayout.listThickness(forDividerPosition: dividerPosition, in: splitView, placement: placement)

        let splitFrame = splitView.frame

        if splitFrame.size.height.isNaN || splitFrame.size.height < 0 || splitFrame.size.width.isNaN || splitFrame.size.width < 0 {
            NSLog("******* splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize - %f", splitFrame.size.height)
            return
        }

        SeriesListLayout.resizeSubviews(of: splitView, placement: placement, thickness: thickness)
    }

    /// The mouse moved over the window: the list hides or shows by itself.
    func mouseMoved() {
        if viewer.window?.isVisible != true && !viewer.fullScreenON() {
            return
        }

        if viewer.horos_windowWillClose { return }

        autoHide()
    }
}

// MARK: - The list's cells

extension SeriesListPresenter {

    /// The database window, which holds the patient's comparative studies,
    /// reached through the graph.
    var comparativeStudies: any ComparativeStudiesProviding {
        BrowserComparativeStudies(processGraph: processGraph)
    }

    /// Red.
    static let selectedItemColor = NSColor(calibratedRed: 252.0 / 255, green: 177.0 / 255, blue: 141.0 / 255, alpha: 1)

    /// Yellow.
    static let openItemColor = NSColor(calibratedRed: 249.0 / 255, green: 240.0 / 255, blue: 140.0 / 255, alpha: 1)

    /// The colour behind a cell.
    private static func color(of tint: SeriesListModel.Tint) -> NSColor? {
        switch tint {
        case .none: return nil
        case .otherStudy: return SeriesListColors.otherStudy
        case .shown: return SeriesListColors.shown
        case .fused: return SeriesListColors.fused
        }
    }

    /// The frame of a thumbnail cell: the colour of the study of the active
    /// window, when that window shows its series. A reused cell loses the
    /// number it had.
    private func setFrame(_ cell: NSCell?, _ color: NSColor?) {
        if let cell = cell as? ThumbnailCell {
            cell.frameColor = color
            cell.seriesNumber = 0
            cell.numberColor = nil
        }
    }

    /// The number of a series on its thumbnail: its place in its study, on the
    /// colour of the study while a window shows the series. The windows that
    /// show the series read the same number.
    private func setNumber(_ cell: NSCell?, of series: DicomSeries, atPlace place: Int, in build: Build) {
        let number = SeriesIdentity.number(atPlace: place)
        SeriesListIdentification.setNumber(number, of: series)
        if let cell = cell as? ThumbnailCell {
            cell.seriesNumber = number
            cell.numberColor = build.openColors?.object(forKey: series) as? NSColor
        }
    }

    /// The picture of a cell at the size the database font preference asks:
    /// set (as image and alternate image) or, for another preference, left.
    private func setSizedPicture(_ cell: NSButtonCell?, _ image: NSImage?) {
        switch SeriesListPictureSize.of(fontSize: preferences[ViewerPreferences.databaseFontSize]) {
        case .scaled(let factor):
            cell?.image = image?.imageByScalingProportionallyUsingNSImage(Float(factor))
            cell?.alternateImage = image?.imageByScalingProportionallyUsingNSImage(Float(factor))
        case .unscaled:
            cell?.image = image
            cell?.alternateImage = image
        case .none:
            break
        }
    }

    /// The picture of a series' cell, kept scaled. A series with no thumbnail
    /// yet shows an empty picture of the same size until SeriesListThumbnails
    /// has decoded one, which sets it on the cells that show the series.
    private func setSeriesPicture(_ cell: NSButtonCell?, of series: DicomSeries, image: DicomImage?, database: DicomDatabase?, inverted: Bool) {
        let size = SeriesListPictureSize.of(fontSize: preferences[ViewerPreferences.databaseFontSize])
        if size == .none { return }
        let thumbnails = SeriesListThumbnails.shared
        let picture = thumbnails.picture(of: series, size: size, inverted: inverted)
        if picture == nil { thumbnails.make(series: series, image: image, database: database, storing: preferences[DatabasePreferences.storeThumbnailsInDB]) }
        let shown = picture ?? thumbnails.emptyPicture(size: size)
        cell?.image = shown
        cell?.alternateImage = shown
    }

    /// Sets a thumbnail just made on the cells of this list that show `series`.
    func thumbnailMade(for series: DicomSeries) {
        guard isListVisible(), let cells = viewer.horos_previewMatrix?.cells else { return }
        let size = SeriesListPictureSize.of(fontSize: preferences[ViewerPreferences.databaseFontSize])
        guard let picture = SeriesListThumbnails.shared.picture(of: series, size: size, inverted: ViewerController.horos_DisplayUseInvertedPolarity()) else { return }
        for case let cell as NSButtonCell in cells
        where (cell.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as AnyObject? === series {
            cell.image = picture
            cell.alternateImage = picture
        }
        viewer.horos_previewMatrix?.needsDisplay = true
    }

    /// `attributes[key] = value`, raising as -[NSMutableDictionary setObject:forKey:]
    /// raised for a nil value, which the list's exception handlers log.
    private static func set(_ value: Any?, for key: NSAttributedString.Key, in attributes: inout [NSAttributedString.Key: Any]) {
        guard let value else {
            NSException(name: .invalidArgumentException, reason: "object cannot be nil (key: \(key.rawValue))", userInfo: nil).raise()
            return
        }
        attributes[key] = value
    }

    /// The UID of a study of the list, of the database or on a PACS.
    private static func studyUID(_ study: AnyObject) -> AnyObject? {
        if let local = study as? DicomStudy {
            return local.studyInstanceUID as NSString?
        }
        return viewerSendObject(study, "studyInstanceUID")
    }

    /// The cell at `index` of the list.
    private func cell(at index: Int) -> NSButtonCell? {
        viewer.horos_previewMatrix.flatMap { SeriesListLayout.cell(of: $0, at: index) } as? NSButtonCell
    }

    /// The object a cell of the list stands for.
    private static func represented(_ cell: NSCell?) -> Any? {
        (cell?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object
    }

    /// The index of the series shown in the current time point among the
    /// list's cells, NSNotFound when it is not there.
    func currentSeriesIndex() -> Int {
        let image = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: 0) as? DicomImage
        guard let series = image?.series else { return NSNotFound }
        let cells = viewer.horos_previewMatrix?.cells ?? []
        return cells.firstIndex { (Self.represented($0) as AnyObject?)?.isEqual(series) == true } ?? NSNotFound
    }

    /// Scrolls the list to the cell of the current series.
    func showCurrentThumbnail() {
        let index = currentSeriesIndex()

        if index != NSNotFound, let matrix = viewer.horos_previewMatrix {
            SeriesListLayout.scroll(matrix, toCellAt: index)
        }
    }

    /// Builds the list once it shows, if it was built while hidden.
    func checkBuilt() {
        if isListVisible() && viewer.horos_matrixPreviewBuilt == false {
            build(showSelected: viewer.window?.isKeyWindow == true)
        }
    }

    /// The study list rebuilds the list when a placeholder comes or goes.
    func excludedSeriesChanged() {
        if viewer.horos_windowWillClose || isListVisible() == false { return }
        build(showSelected: false)
    }

    /// A click on a series: it loads in this viewer.
    func seriesPressed(in matrix: NSMatrix?) {
        let cell = matrix?.selectedCell() as? ThumbnailCell

        cell?.lineBreakMode = .byWordWrapping
        cell?.font = NSFont.boldSystemFont(ofSize: comparativeStudies.fontSize("dbSmallMatrixFont"))

        cell?.imagePosition = .imageBelow
        cell?.isTransparent = false
        cell?.isEnabled = true

        cell?.setButtonType(.momentaryPushIn)
        cell?.bezelStyle = .shadowlessSquare
        cell?.highlightsBy = .contentsCellMask
        cell?.imageScaling = .scaleProportionallyDown
        cell?.isBordered = true

        viewer.loadSelectedSeries(Self.represented(matrix?.selectedCell()), rightClick: cell?.rightClick ?? false)
    }

    /// A click on a study: its series hide or show in every viewer of the
    /// patient (Command opens it in the browser); one on a PACS is retrieved.
    func studyPressed(in matrix: NSMatrix?) {
        let pressed = Self.represented(matrix?.selectedCell())

        if let study = pressed as? DicomStudy {
            if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
                comparativeStudies.openStudy(study)
            } else {
                study.setHidden(!study.isHidden())

                for other in Self.displayedViewers() {
                    other.buildMatrixPreview(!viewerSameString(other.studyInstanceUID(), viewer.studyInstanceUID()))
                }
            }
        } else if let node = pressed as? DCMTKStudyQueryNode {
            comparativeStudies.retrieveComparative(node)
        }
    }

    /// A click on a placeholder: the series the node's rule left out is retrieved.
    func excludedSeriesPressed(in matrix: NSMatrix?) {
        if let placeholder = Self.represented(matrix?.selectedCell()) as? ExcludedSeries {
            DCMTKQueryNode.retrieveExcludedSeries(placeholder)
        }
    }

    /// The other viewers of the study (of the patient, by the preference)
    /// scroll their lists to this one's position.
    func syncOtherLists() {
        Self.scrollingOtherLists = true

        for other in Self.displayedViewers() {
            let same: Bool
            if preferences[Self.syncsListsOfAllComparativeStudies] {
                same = viewerSameString(other.currentStudy()?.patientUID, viewer.currentStudy()?.patientUID)
            } else {
                same = viewerSameString(other.studyInstanceUID(), viewer.studyInstanceUID())
            }

            if other !== viewer && same {
                let clipView = other.previewMatrixScrollView()?.contentView
                var proposedBounds = clipView?.bounds ?? .zero
                proposedBounds.origin = viewer.horos_previewMatrix?.superview?.bounds.origin ?? .zero
                if let clipView {
                    clipView.scroll(to: clipView.constrainBoundsRect(proposedBounds).origin)
                }
                if let contentView = other.previewMatrixScrollView()?.contentView {
                    other.previewMatrixScrollView()?.reflectScrolledClipView(contentView)
                }
            }
        }

        Self.scrollingOtherLists = false
    }

    /// The other viewers' lists follow this one's, one tenth of a second after
    /// its last scroll, unless a viewer is scrolling them already.
    func listScrolled(_ note: Notification) {
        guard Self.scrollingOtherLists == false else { return }
        Self.scrollingOtherLists = true

        if (note.object as AnyObject?) === viewer.horos_previewMatrixScrollView?.contentView {
            let follows = SeriesListDock.syncsScrolling(preference: preferences[DatabasePreferences.syncPreviewList],
                                                        commandDown: NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true)
            if follows {
                viewer.horos_scrollSyncTimer?.invalidate()
                viewer.horos_scrollSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak viewer] _ in
                    MainActor.assumeIsolated {
                        viewer?.syncThumbnails()
                    }
                }
            }
        }

        Self.scrollingOtherLists = false
    }

    /// The pane of the list got its size: the list is built if it was not.
    func paneResized(_ note: Notification) {
        if viewer.horos_windowWillClose {
            return
        }

        if let subviews = viewer.horos_splitView?.subviews, subviews.count > 1, (note.object as AnyObject?) === subviews[1] {
            if isListVisible() && viewer.horos_matrixPreviewBuilt == false {
                viewer.buildMatrixPreview()
            }
        }
    }

    /// SyncSeriesListForAllComparativeStudies: the lists of the patient's
    /// other studies scroll together too. No pane sets it.
    private static let syncsListsOfAllComparativeStudies = PreferenceKey<Bool>("SyncSeriesListForAllComparativeStudies")
}

// MARK: - Building the list

extension SeriesListPresenter {

    /// What one build of the list reads once and every cell uses.
    private struct Build {
        let browser: any ComparativeStudiesProviding
        let database: DicomDatabase?
        let viewerStudy: DicomStudy
        let listed: SeriesListStudies
        /// The placeholders of each database study, by the study.
        let excluded: [ObjectIdentifier: [ExcludedSeries]]
        let model: SeriesListModel
        /// The series the active window shows, with the colour of its study,
        /// and every series a window shows, with the colour of its study.
        let windowColors: NSMapTable<AnyObject, AnyObject>?
        let openColors: NSMapTable<AnyObject, AnyObject>?
        /// The list shows: the thumbnails are drawn.
        let visible: Bool
        let inverted: Bool
    }

    /// What a build found, kept as it is found: the comparatives button shows
    /// it even when the build stops on an exception.
    private final class Outcome {
        var hasComparatives = false
        var newerThanLoaded = false
        /// The viewer shows no study: the list is emptied and nothing else follows.
        var noStudy = false
    }

    /// For the current study, always take the local images.
    private func shownStudy(_ listed: AnyObject, viewerStudy study: DicomStudy) -> AnyObject {
        listed is DCMTKStudyQueryNode && viewerSameString(Self.studyUID(listed), study.studyInstanceUID) ? study : listed
    }

    /// The patient's studies, read once into the list's model: the viewer's
    /// study from a PACS becomes its database copy, a study's placeholders are
    /// those found for its database copy.
    private func model(of listed: SeriesListStudies, viewerStudy study: DicomStudy, excluded: [ObjectIdentifier: [ExcludedSeries]],
                       countedCells: Int, openColors: NSMapTable<AnyObject, AnyObject>?) -> SeriesListModel {
        let viewerSeries = viewer.seriesListViewerSeries(checkingNil: false)
        let fused = viewer.blending()?.currentSeries()
        var studies: [SeriesListModel.Study] = []
        for index in 0..<listed.shown.count {
            let listedStudy = listed.shown.object(at: index) as AnyObject
            let shown = shownStudy(listedStudy, viewerStudy: study)
            let kind: SeriesListModel.StudyKind
            if shown is DicomStudy {
                kind = listedStudy is DCMTKStudyQueryNode ? .viewerStudyOnPACS : .local
            } else {
                kind = .distant
            }
            let series = (listed.shownSeries.object(at: index) as? [DicomSeries] ?? []).map { each in
                SeriesListModel.Series(isShown: viewerSeries.contains(each), isFused: fused === each,
                                       isInAWindow: openColors?.object(forKey: each) != nil)
            }
            studies.append(SeriesListModel.Study(kind: kind, isViewerStudy: viewerSameString(Self.studyUID(shown), study.studyInstanceUID),
                                                 seriesHidden: (shown as? DicomStudy)?.isHidden() ?? false, series: series,
                                                 excludedCount: excluded[ObjectIdentifier(shown)]?.count ?? 0))
        }
        return SeriesListModel(studies: studies, countedCells: countedCells)
    }

    /// Builds the series menu's first item and, when the list shows, the list:
    /// its cells from the model of the patient's studies, the comparatives
    /// button, then the views' colours and the series menu. While the window
    /// is not visible, checkBuilt() does it later: a faster opening.
    ///
    /// With `selectionOnly`, the cells of a list that shows the same series
    /// only take their new colours and frames.
    func build(showSelected: Bool, selectionOnly: Bool = false) {
        if viewer.window?.isVisible != true { return }
        if viewer.horos_windowWillClose { return }

        // The series menu builds all its items later, when needed.
        viewer.horos_needsToBuildSeriesPopupMenu = true
        viewer.horos_needsToBuildSeriesMatrix = true

        let inverted = ViewerController.horos_DisplayUseInvertedPolarity()

        viewer.horos_seriesPopupMenu?.menu?.removeAllItems()
        let menuItem = NSMenuItem(title: "", action: #selector(ViewerController.seriesPopupSelect(_:)), keyEquivalent: "")
        var img = (viewer.currentSeries()?.primitiveValue(forKey: "thumbnail") as? Data).flatMap { NSImage(data: $0) }

        if inverted {
            img = img?.imageInverted()
        }

        menuItem.image = img?.imageByScalingProportionallyToSizeUsingNSImage(NSSize(width: seriesPopupPictureSize, height: seriesPopupPictureSize))
        viewer.horos_seriesPopupMenu?.menu?.addItem(menuItem)
        viewer.horos_seriesPopupContextualMenu?.title = viewer.currentSeries()?.name ?? NSLocalizedString("Unnamed", comment: "")

        if isListVisible() == false {
            return
        }

        let outcome = Outcome()

        if let e = HorosObjCException.caught({
            fillCells(showSelected: showSelected, inverted: inverted, selectionOnly: selectionOnly, outcome: outcome)
        }) {
            _N2LogExceptionImpl(e, true, "-[ViewerController buildMatrixPreview:]")
        }

        setComparativesButton(hasComparatives: outcome.hasComparatives, newerThanLoaded: outcome.newerThanLoaded)

        // Whether the button would show: computed as before, not used.
        if preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes] && viewer.database?.isReadOnly == false && viewer.database?.isLocal() == true {
            _ = BrowserController.comparativeServers()
        }

        if outcome.noStudy { return }

        for view in imageViews() {
            view.computeColor()
        }

        viewer.buildSeriesPopup()

        viewer.horos_needsToBuildSeriesMatrix = false
    }

    /// The comparatives button under the list, as the list leaves it.
    private func setComparativesButton(hasComparatives: Bool, newerThanLoaded: Bool) {
        let button = viewer.horos_comparativesButton
        button?.isEnabled = hasComparatives

        let listsComparatives = viewer.flagListPODComparatives?.boolValue ?? false
        let state = SeriesListComparativesButton.state(hasComparatives: hasComparatives, newerThanLoaded: newerThanLoaded,
                                                       listsComparatives: listsComparatives)
        var color = NSColor.white
        var tip = ""

        if state.checked {
            button?.title = String(format: "✓ %@", NSLocalizedString("Comparatives", comment: ""))
        } else {
            button?.title = NSLocalizedString("Comparatives", comment: "")
        }
        switch state.tint {
        case .plain: break
        case .available: color = Self.openItemColor
        case .newer: color = Self.selectedItemColor
        }
        switch state.hint {
        case .available: tip = NSLocalizedString("There are PACS On-Demand comparatives", comment: "")
        case .newer: tip = NSLocalizedString("There are more recent PACS On-Demand comparatives", comment: "")
        case nil: break
        }

        if let clickHides = state.clickHides {
            if !tip.isEmpty {
                tip += ", "
            }

            if clickHides {
                tip += NSLocalizedString("Click here to hide them", comment: "")
            } else {
                tip += NSLocalizedString("Click here to show them", comment: "")
            }
        }
        if let button {
            var attributes = button.attributedTitle.attributes(at: 0, effectiveRange: nil)
            attributes[.foregroundColor] = color
            button.attributedTitle = NSAttributedString(string: button.title, attributes: attributes)
            button.toolTip = tip
        }
    }

    /// The list's cells for the patient's studies, then its scrolling.
    private func fillCells(showSelected: Bool, inverted: Bool, selectionOnly: Bool, outcome: Outcome) {
        let browser = comparativeStudies
        let curImage = viewer.horos_fileList(at: 0)?.object(at: 0) as? DicomImage
        let matrix = viewer.horos_previewMatrix
        let origin = matrix?.superview?.bounds.origin ?? .zero

        let visible = isListVisible()

        viewer.horos_matrixPreviewBuilt = visible

        viewer.horos_previewMatrixScrollView?.postsBoundsChangedNotifications = true

        guard let study = curImage?.series?.study else {
            matrix?.renewRows(0, columns: 0)
            matrix?.sizeToCells()
            viewer.horos_matrixPreviewBuilt = false
            outcome.noStudy = true
            return
        }

        let db = viewer.seriesMenuPresenter.database(of: study)
        let found = viewer.seriesListPatientStudies(of: study, database: db, selectingInBrowser: false)

        // The series may have changed places since the last list: the numbers
        // the windows read are given again, or found again by those that ask.
        if !selectionOnly { SeriesListIdentification.forgetNumbers() }

        seriesListMakeRetrieveImage(side: seriesPopupPictureSize)

        if let found, found.count != 0 {
            let windowColors = ViewerController.horosSeriesWindowColors()
            let openColors = ViewerController.horosSeriesOpenColors()
            var excluded: [ObjectIdentifier: [ExcludedSeries]] = [:]
            var countedCells = 0
            let listed = viewer.seriesListStudies(found, viewerStudy: study, database: db) { local, children in
                if local.isHidden() == false {
                    countedCells += children.count
                }

                // The series a DICOMweb node's rule left out, after them.
                let placeholders = BrowserController.horosExcludedSeries(ofLocalStudy: local, database: db?.dataBaseDirPath ?? "")
                excluded[ObjectIdentifier(local)] = placeholders
                if local.isHidden() == false {
                    countedCells += placeholders.count
                }
            }
            outcome.hasComparatives = listed.hasComparatives
            outcome.newerThanLoaded = listed.hasComparativesNewerThanLoaded

            let build = Build(browser: browser, database: db, viewerStudy: study, listed: listed, excluded: excluded,
                              model: model(of: listed, viewerStudy: study, excluded: excluded, countedCells: countedCells, openColors: openColors),
                              windowColors: windowColors, openColors: openColors, visible: visible, inverted: inverted)

            if selectionOnly, recolourCells(of: build) {
                return
            }

            matrix?.cellClass = ThumbnailCell.self

            // One column down a side strip or in the floating panel, one
            // row across a docked top or bottom strip; the cell size never
            // changes, so the thumbnails scroll instead of being squeezed.
            // The cells are filled by their position in the list, which is
            // the same in both.
            if let matrix {
                SeriesListLayout.layOut(matrix, count: build.model.cellCount, placement: placement, floating: isFloating)
            }

            for case let cell as NSButtonCell in matrix?.cells ?? [] {
                cell.lineBreakMode = .byWordWrapping
                cell.font = NSFont.boldSystemFont(ofSize: browser.fontSize("dbSmallMatrixFont"))
                cell.backgroundColor = nil
                setFrame(cell, nil)

                cell.representedObject = nil

                cell.imagePosition = .imageBelow
                cell.isTransparent = false
                cell.isEnabled = true

                cell.setButtonType(.momentaryPushIn)
                cell.bezelStyle = .shadowlessSquare
                cell.highlightsBy = .contentsCellMask
                cell.imageScaling = .scaleProportionallyDown
                cell.isBordered = true

                cell.title = ""

                cell.image = nil

                cell.target = viewer
            }

            var index = 0
            for studyIndex in build.model.studies.indices {
                index = fillStudy(studyIndex, of: build, from: index)
            }
        }

        matrix?.sizeToCells()

        if showSelected {
            showCurrentThumbnail()
        } else {
            viewer.horos_previewMatrixScrollView?.contentView.scroll(to: origin)
            if let contentView = viewer.horos_previewMatrixScrollView?.contentView {
                viewer.horos_previewMatrixScrollView?.reflectScrolledClipView(contentView)
            }
        }

        matrix?.needsDisplay = true
    }

    /// The series a cell stands for, or its study.
    private func listedObject(at index: Int) -> AnyObject? {
        (cell(at: index)?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as AnyObject?
    }

    /// Whether the cells stand, in order, for the studies and series of `build`.
    private func cellsMatch(_ build: Build) -> Bool {
        guard build.visible, viewer.horos_matrixPreviewBuilt, viewer.horos_previewMatrix?.cells.count == build.model.cellCount,
              build.excluded.values.allSatisfy(\.isEmpty) else { return false }
        var index = 0
        for studyIndex in build.model.studies.indices {
            guard listedObject(at: index) === build.listed.shown.object(at: studyIndex) as AnyObject else { return false }
            index += 1
            if build.model.studies[studyIndex].seriesHidden { continue }
            for series in build.listed.shownSeries.object(at: studyIndex) as? [DicomSeries] ?? [] {
                guard listedObject(at: index) === series else { return false }
                index += 1
            }
        }
        return index == build.model.cellCount
    }

    /// The colours and window frames of `build` on cells that already show its
    /// series, without reading the images of the studies. False, with nothing
    /// changed, when the cells stand for something else.
    private func recolourCells(of build: Build) -> Bool {
        guard cellsMatch(build) else { return false }
        let model = build.model
        var index = 0
        for studyIndex in model.studies.indices {
            let studyCell = cell(at: index)
            studyCell?.backgroundColor = Self.color(of: model.background(of: .study(studyIndex)))
            setFrame(studyCell, nil)
            index += 1
            let series = build.listed.shownSeries.object(at: studyIndex) as? [DicomSeries] ?? []
            if model.studies[studyIndex].seriesHidden {
                if let framing = model.framingSeries(ofStudy: studyIndex) {
                    setFrame(studyCell, build.windowColors?.object(forKey: series[framing]) as? NSColor)
                }
                if let colour = model.colour(of: .study(studyIndex)) {
                    studyCell?.backgroundColor = Self.color(of: colour)
                }
                continue
            }
            for (place, curSeries) in series.enumerated() {
                let position = SeriesListModel.Cell.series(study: studyIndex, series: place)
                let seriesCell = cell(at: index)
                seriesCell?.backgroundColor = Self.color(of: model.colour(of: position) ?? model.background(of: position))
                setFrame(seriesCell, build.windowColors?.object(forKey: curSeries) as? NSColor)
                setNumber(seriesCell, of: curSeries, atPlace: place, in: build)
                index += 1
            }
        }
        viewer.horos_previewMatrix?.needsDisplay = true
        return true
    }

    /// The cells of one shown study from `index` on: the study's, then its
    /// series and placeholders, or the study's colour and frame from its
    /// hidden series. Returns the index after them.
    private func fillStudy(_ studyIndex: Int, of build: Build, from start: Int) -> Int {
        var index = start
        let model = build.model
        let listedStudy = build.listed.shown.object(at: studyIndex) as AnyObject
        let cell = self.cell(at: index)

        let curStudyIndexAll = build.listed.all.index(of: listedStudy)

        cell?.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(listedStudy,
                                                                                    children: build.listed.shownSeries.object(at: studyIndex) as? NSArray)
        cell?.action = #selector(ViewerController.matrixPreviewSwitchHidden(_:))

        let curStudy = shownStudy(listedStudy, viewerStudy: build.viewerStudy)
        cell?.backgroundColor = Self.color(of: model.background(of: .study(studyIndex)))

        let series = build.listed.shownSeries.object(at: studyIndex) as? [DicomSeries] ?? []
        var images: [Any]? = nil

        if let localStudy = curStudy as? DicomStudy {
            if let e = HorosObjCException.caught({
                images = build.browser.images(of: localStudy)
                fillLocalStudyCell(cell, localStudy, studyIndex, of: build, seriesCount: series.count, imageCount: images?.count ?? 0,
                                   number: curStudyIndexAll)
            }) {
                _N2LogExceptionImpl(e, false, "-[ViewerController buildMatrixPreview:]")
            }
            index += 1
        }

        if let node = curStudy as? DCMTKQueryNode {
            // A study on a PACS.
            if let e = HorosObjCException.caught({
                let db = build.database
                let local = db?.objects(forEntity: db?.studyEntity(),
                                        predicate: viewerPredicate("studyInstanceUID = %@ AND patientID = %@", viewerSendObject(node, "studyInstanceUID"),
                                                                   viewerSendObject(node, "patientID")))
                if let copy = local?.first as? DicomStudy {
                    images = build.browser.images(of: copy)
                }
                fillDistantStudyCell(cell, node, viewerStudy: build.viewerStudy)
            }) {
                _N2LogExceptionImpl(e, false, "-[ViewerController buildMatrixPreview:]")
            }
            index += 1
        }

        if model.studies[studyIndex].seriesHidden == false {
            for (position, curSeries) in series.enumerated() {
                fillSeriesCell(self.cell(at: index), curSeries, .series(study: studyIndex, series: position), of: build, images: images)
                index += 1
            }

            for placeholder in build.excluded[ObjectIdentifier(curStudy)] ?? [] {
                fillExcludedCell(self.cell(at: index), placeholder, background: model.background(of: .excluded(study: studyIndex, placeholder: 0)),
                                 studyDate: (curStudy as? DicomStudy)?.date, visible: build.visible, browser: build.browser)
                index += 1
            }
        } else {
            // The series are hidden: the study's cell is framed by the first
            // of them in a window, and coloured when one is selected.
            if let framing = model.framingSeries(ofStudy: studyIndex) {
                setFrame(cell, build.windowColors?.object(forKey: series[framing]) as? NSColor)
            }
            if let colour = model.colour(of: .study(studyIndex)) {
                cell?.backgroundColor = Self.color(of: colour)
            }
        }
        return index
    }

    /// The cell of a study of the database: its number in its colour, the
    /// patient, name, date, modality and series, state and comment, and the
    /// action of a click (or the arrow of the viewer's study listed from a PACS).
    private func fillLocalStudyCell(_ cell: NSButtonCell?, _ localStudy: DicomStudy, _ studyIndex: Int, of build: Build,
                                    seriesCount: Int, imageCount: Int, number curStudyIndexAll: Int) {
        if seriesCount != imageCount {
            N2LogStackTraceMessage("[series count] != [images count] : You should not be here......")
        }

        let name = localStudy.studyName.map { ($0 as NSString).stringByTruncating(toLength: 34) as String }

        let states = BrowserController.statesArray() ?? []
        let stateIndex = SeriesListStudyNumbers.stateIndex(ViewerSender.intValue(localStudy.stateText), stateCount: states.count)
        let stateText = stateIndex.flatMap { states[$0] as? String } ?? ""
        let comment: String = (localStudy.comment.map { $0 as NSString } ?? "").withTruncatingToLength(32)

        let modality = localStudy.modality ?? "OT:"

        var action: String? = nil
        if build.model.studies[studyIndex].kind == .viewerStudyOnPACS {
            // This is an incomplete study.
            setSizedPicture(cell, seriesListRetrieveImage)

            cell?.imagePosition = .imageOverlaps
            cell?.imageScaling = .scaleProportionallyDown
        } else {
            switch build.model.action(ofStudy: studyIndex) {
            case .showSeries: action = NSLocalizedString("Show Series", comment: "")
            case .hideSeries: action = NSLocalizedString("Hide Series", comment: "")
            case nil: break
            }
        }

        let patName = seriesListPatientLine(localStudy.name, dateOfBirth: localStudy.dateOfBirth, separator: "\r", viewerStudy: build.viewerStudy)

        let seriesWord = seriesCount == 1 ? NSLocalizedString("series", comment: "one series, singular")
                                          : NSLocalizedString("series", comment: "zero or 2 or more series, plural")
        let components = SeriesListTitles.cellLines(
            number: String(format: " %d ", SeriesListStudyNumbers.number(studyIndex: curStudyIndexAll)), patient: patName, name: name,
            date: seriesListDateText(localStudy.date),
            modalityAndSeries: String(format: NSLocalizedString("%@: %@", comment: "semicolon separator for spacing"), modality,
                                      String(format: "%d %@", Int32(truncatingIfNeeded: seriesCount), seriesWord)),
            state: stateText, comment: comment, action: action)

        let finalString = NSMutableAttributedString(string: components.joined(separator: "\r"))

        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: build.browser.fontSize("viewerNumberFont"))]

        Self.set(seriesListStudyColor(studyIndex: curStudyIndexAll, inverted: build.inverted), for: .backgroundColor, in: &attributes)
        let numberLength = (components[0] as NSString).length
        finalString.setAttributes(attributes, range: NSRange(location: 0, length: numberLength))

        attributes[.font] = NSFont.boldSystemFont(ofSize: build.browser.fontSize("dbSmallMatrixFont"))
        attributes[.backgroundColor] = nil
        finalString.setAttributes(attributes, range: NSRange(location: numberLength, length: finalString.length - numberLength))

        finalString.setAlignment(.center, range: NSRange(location: 0, length: finalString.length))
        cell?.attributedTitle = finalString
    }

    /// The cell of a study on a PACS: patient, name, date and modality (no
    /// state nor comment), with the arrow of a study to retrieve.
    private func fillDistantStudyCell(_ cell: NSButtonCell?, _ node: DCMTKQueryNode, viewerStudy study: DicomStudy) {
        // The node's fields by key: the study node answers them, its base
        // class declares only some.
        let name = ((node as NSObject).value(forKey: "studyName") as? NSString)?.stringByTruncating(toLength: 34) as String? ?? ""
        let modality = (node as NSObject).value(forKey: "modality") as? String ?? "OT"

        let patName = seriesListPatientLine((node as NSObject).value(forKey: "name"), dateOfBirth: (node as NSObject).value(forKey: "dateOfBirth"),
                                            separator: "\r", viewerStudy: study)

        cell?.title = SeriesListTitles.comparativeCellLines(patient: patName, name: name, date: seriesListDateText(node.date() as Date?),
                                                            modality: modality).joined(separator: "\r")

        setSizedPicture(cell, seriesListRetrieveImage)

        cell?.imagePosition = .imageOverlaps
        cell?.imageScaling = .scaleProportionallyDown
    }

    /// The cell of a series: its name, date and count, its colour and the
    /// frame of the window that shows it, and its thumbnail when the list shows.
    private func fillSeriesCell(_ cell: NSButtonCell?, _ curSeries: DicomSeries, _ position: SeriesListModel.Cell, of build: Build, images: [Any]?) {
        guard case .series(_, let index) = position else { return }
        cell?.backgroundColor = Self.color(of: build.model.background(of: position))

        cell?.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(curSeries)
        cell?.font = NSFont.systemFont(ofSize: build.browser.fontSize("dbSmallMatrixFont"))
        cell?.action = #selector(ViewerController.matrixPreviewPressed(_:))
        cell?.lineBreakMode = .byCharWrapping

        var name = curSeries.name.map { $0 as NSString }

        if (name?.length ?? 0) > 18 {
            cell?.font = NSFont.boldSystemFont(ofSize: build.browser.fontSize("viewerSmallCellFont"))
            name = name?.stringByTruncating(toLength: 34)
        }

        let fileCount = ViewerSender.intValue(curSeries.noFiles())
        let frames = { () -> Int32 in
            ViewerSender.intValue(((curSeries.images as NSSet?)?.anyObject() as? DicomImage)?.numberOfFrames)
        }
        let counted = SeriesListImageCount.of(
            fileCount: fileCount,
            rawFileCount: { ViewerSender.intValue(curSeries.rawNoFiles()) },
            frames: {
                // One image: its frames, an exception logged.
                guard fileCount == 1 else { return frames() }
                var count: Int32 = 0
                if let e = HorosObjCException.caught({ count = frames() }) {
                    _N2LogExceptionImpl(e, true, "-[ViewerController buildMatrixPreview:]")
                }
                return count
            })
        func word(_ kind: SeriesListImageCount.Kind) -> String {
            switch kind {
            case .image: return NSLocalizedString("Image", comment: "")
            case .images: return NSLocalizedString("Images", comment: "")
            case .frames: return NSLocalizedString("Frames", comment: "Frames: for example, 50 Frames in a series")
            case .object: return NSLocalizedString("Object", comment: "")
            case .objects: return NSLocalizedString("Objects", comment: "")
            }
        }

        let seriesDateText = curSeries.displayDate.map { UserDefaults.formatDateTime($0) ?? "(null)" } ?? ""
        cell?.title = String(format: "%@\r%@\r%@", name ?? "", seriesDateText,
                             viewerSingularPluralCount(Int(counted.count), word(counted.singular), word(counted.plural)))

        if let colour = build.model.colour(of: position) {
            cell?.backgroundColor = Self.color(of: colour)
        }
        // Shown in the active window: framed in its study's colour. Numbered
        // by its place in its study, whether a window shows it or not.
        setFrame(cell, build.windowColors?.object(forKey: curSeries) as? NSColor)
        if case .series(_, let place) = position { setNumber(cell, of: curSeries, atPlace: place, in: build) }

        if build.visible {
            setSeriesPicture(cell, of: curSeries, image: index < (images?.count ?? 0) ? images?[index] as? DicomImage : nil, database: build.database,
                             inverted: build.inverted)
        }
    }

    /// The cell of a placeholder of a series a DICOMweb node left out, greyed.
    private func fillExcludedCell(_ cell: NSButtonCell?, _ placeholder: ExcludedSeries, background: SeriesListModel.Tint, studyDate: Date?,
                                  visible: Bool, browser: any ComparativeStudiesProviding) {
        cell?.backgroundColor = Self.color(of: background)
        cell?.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(placeholder)
        cell?.font = NSFont.systemFont(ofSize: browser.fontSize("dbSmallMatrixFont"))
        cell?.action = #selector(ViewerController.matrixPreviewRetrieveExcludedSeries(_:))
        cell?.lineBreakMode = .byCharWrapping
        let title = placeholder.title(studyDate: studyDate)
        var attributes: [NSAttributedString.Key: Any] = [:]
        Self.set(cell?.font, for: .font, in: &attributes)
        Self.set(NSColor.disabledControlTextColor, for: .foregroundColor, in: &attributes)
        cell?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        if visible {
            var img: NSImage? = placeholder.image(size: NSSize(width: 70, height: 70))
            switch preferences[ViewerPreferences.databaseFontSize] {
            case -1: img = img?.imageByScalingProportionallyUsingNSImage(0.6)
            case 1: img = img?.imageByScalingProportionallyUsingNSImage(1.3)
            default: break
            }
            cell?.image = img
            cell?.alternateImage = img
        }
    }
}
