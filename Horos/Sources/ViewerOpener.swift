/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXImaging
import IsiXPreferences
import Synchronization

// Opening viewers from the database window: the selection's series and
// images, a study by its hanging protocol or by the workspace saved with it,
// the comparative studies a protocol asks for, the series an external
// application opens (MPEG-2, PDF and SR reports, RTSTRUCT), the 3D/4D and
// sub-series sheets, the presentation states and the placeholders of the
// series a node left out. BrowserController keeps the selectors the nib, the
// menus, the delegates and the plugins send, and hands their work here.
// Loading the images is ViewerSeriesLoader's; the windows are arranged by the
// process's ViewerWindowArranger; the rules that need neither AppKit nor the
// database are in IsiXImaging (ViewerOpeningRules.swift) and IsiXDatabase.

/// `[value boolValue]` of a number or a string read from a hanging protocol
/// or a saved workspace; NO for nil and the rest.
nonisolated private func plistBool(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// `[value intValue]`, 0 for nil and the rest.
nonisolated private func plistInt(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// `[value integerValue]`, 0 for nil and the rest.
nonisolated private func plistInteger(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? NSString { return string.integerValue }
    return 0
}

/// `[value floatValue]`, 0 for nil and the rest.
nonisolated private func plistFloat(_ value: Any?) -> Float {
    if let number = value as? NSNumber { return number.floatValue }
    if let string = value as? NSString { return string.floatValue }
    return 0
}

/// `[a isEqualToString: b]` of two values read as strings: never for nil
/// or for anything but a string.
nonisolated private func sameString(_ a: Any?, _ b: Any?) -> Bool {
    BrowserObjC.literallyEqual(a as? String, b as? String)
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
nonisolated private func formatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[object autorelease]`: the wait windows closed stay alive until the
/// current pool drains, as they did.
nonisolated private func autoreleaseLater(_ object: AnyObject?) {
    if let object {
        _ = Unmanaged.passUnretained(object).retain().autorelease()
    }
}

/// `[array objectAtIndex: index]`: NSRangeException past the end, as the
/// former code raised (and caught).
nonisolated private func element(_ array: [Any], _ index: Int) -> Any {
    (array as AnyObject).object(at: index) as Any
}

/// `[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: component]`.
nonisolated private func resourcePath(_ component: String) -> String? {
    (Bundle.main.resourcePath as NSString?)?.appendingPathComponent(component)
}

/// What the 3D/4D sheet chose.
enum SubSeriesChoice {
    /// Nothing is opened.
    case cancel
    /// The whole series, as selected.
    case entire
    /// These lists, in 2D viewers or the 4D player.
    case open([[Any]], movie: Bool)
    /// The sheet opened the viewers itself.
    case opened
}

/// The opening of viewers from one database window, on the main actor with
/// the window's views and sheets. The browser makes it once and keeps it.
private final class ComparativeOpening: Sendable {
    private let studies = Mutex<[Int: NSManagedObjectID]>([:])
    @MainActor var work: Task<Void, Never>?
    @MainActor var deadline: Task<Void, Never>?

    func record(_ study: NSManagedObjectID, at index: Int) {
        studies.withLock { $0[index] = study }
    }

    func orderedIDs() -> [NSManagedObjectID] {
        studies.withLock { $0.sorted { $0.key < $1.key }.map(\.value) }
    }
}

private struct ComparativeOpeningRules: Sendable {
    let limit: UInt
    let sameModality: Bool
    let sameDescription: Bool
    let defaultProtocol: Bool
    let description: String

    init(_ options: [AnyHashable: Any]) {
        limit = UInt(bitPattern: Int(plistInt(options["NumberOfComparativeToDisplay"])))
        sameModality = plistBool(options["PreviousStudySameModality"])
        sameDescription = plistBool(options["PreviousStudySameDescription"])
        defaultProtocol = plistBool(options["isDefaultProtocolForModality"])
        description = options["Study Description"] as? String ?? ""
    }

    func includes(modality: String?, name: String?, beside current: DicomStudy) -> Bool {
        if sameModality && !sameString(modality, current.modality) { return false }
        if !sameDescription { return true }
        if defaultProtocol { return sameString(name, current.studyName) }
        return (name as NSString?)?.range(of: description, options: [.caseInsensitive, .literal]).location != NSNotFound
    }
}

@MainActor final class ViewerOpener {

    let browser: BrowserController
    let processGraph: ProcessGraph
    let preferences: any PreferenceStore

    /// The lists the sub-series sheet keeps open: the sub-series of the
    /// series being opened.
    private var subSeriesLists: [Any]?
    private var comparativeOpening: ComparativeOpening?

    /// What the thumbnails show after the series of the selected study.
    var excludedSeries: [ExcludedSeries] = []
    private var excludedSeriesObserver: NSObjectProtocol?

    /// The tag of the first placeholder cell; the next ones count down.
    static let firstExcludedSeriesTag = -1000

    init(browser: BrowserController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.browser = browser
        self.processGraph = processGraph
        self.preferences = preferences
    }

    /// The database the browser shows now.
    var database: DicomDatabase? {
        browser.database
    }

    var arranger: ViewerWindowArranger {
        processGraph.windowArranger
    }

    // MARK: - Wait window

    /// "Opening...", shown while several viewers open.
    func showWaitWindow() {
        if browser.horos_waitOpeningWindow == nil { browser.horos_waitOpeningWindow = WaitRendering(NSLocalizedString("Opening...", comment: "")) }
        browser.horos_waitOpeningWindow?.showWindow(browser)
    }

    func closeWaitWindow() {
        browser.horos_waitOpeningWindow?.close()
        autoreleaseLater(browser.horos_waitOpeningWindow)
        browser.horos_waitOpeningWindow = nil
    }

    // MARK: - Windows

    /// Brings the 2D viewers to the front, unless the application holds that
    /// off while it places them.
    private func showViewers(makeKey: Bool) {
        guard let appController = processGraph.appController, !appController.checkAllWindowsAreVisibleIsOff else { return }
        arranger.bringViewersToFront(makeKey: makeKey)
    }

    /// Tiles the windows when "AUTOTILING" is on, through the responder chain
    /// as the toolbar does; otherwise brings them into view.
    private func tileOrShowViewers() {
        if preferences[ViewerPreferences.autoTiling] {
            NSApp.sendAction(NSSelectorFromString("tileWindows:"), to: nil, from: browser)
        } else {
            showViewers(makeKey: true)
        }
    }

    // MARK: - Loading

    /// Each list of images in a viewer of its own, or in `viewer`; the lists
    /// together in the 4D player for a movie.
    @discardableResult
    func openViewer(_ lists: [[Any]], movie: Bool, viewer: ViewerController?, keyImagesOnly: Bool, tryToFlipData: Bool = false) -> ViewerController? {
        ViewerSeriesLoader(browser: browser).open(lists, movie: movie, viewer: viewer, keyImagesOnly: keyImagesOnly, tryToFlipData: tryToFlipData)
    }

    // MARK: - Selection

    /// The lists of images to open, as the selection gives them: the 4D
    /// player checks them (cutting one series into its times); a single
    /// series opened with Option or as "Reparsed Series" may be cut into
    /// sub-series, chosen in a sheet.
    func open(lists toOpenArrayIn: [[Any]], movie movieViewerIn: Bool, viewer: ViewerController?) {
        var toOpenArray: [[Any]]? = toOpenArrayIn
        var movieViewer = movieViewerIn
        var movieError = false, tryToFlipData = false

        if (toOpenArray?.count ?? 0) > 2 {
            showWaitWindow()
        }

        if movieViewer {
            // First check if all series contain the same number of images.
            if toOpenArray?.count == 1, let singleSeries = toOpenArray?[0] {
                // Just one thumbnail is selected: its times.
                let groups = SeriesSplitting.movieGroups(sliceLocations: singleSeries.map { ($0 as? DicomImage)?.sliceLocation?.floatValue ?? 0 })
                toOpenArray = groups.map { $0.map { singleSeries[$0] } }
            }
            switch MoviePlayerSelection.check(imageCounts: toOpenArray?.map(\.count) ?? [], maximum: Int(MAX4D)) {
            case .singleSeries:
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("4D Player", comment: "4D Player"),
                                                message: NSLocalizedString("To see an animated series, you have to select multiple series of the same area at different times: e.g. a cardiac CT", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                movieError = true
            case .tooManySeries:
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("4D Player", comment: "4D Player"),
                                                message: String(format: NSLocalizedString("4D Player is limited to a maximum number of %d series.", comment: ""), Int32(MAX4D)),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                movieError = true
            case .differentImageCounts:
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("4D Player", comment: "4D Player"),
                                                message: NSLocalizedString("In the current version, all series must contain the same number of images.", comment: "In the current version, all series must contain the same number of images."),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                movieError = true
            case .accepted:
                break
            }
        } else {
            tryToFlipData = true

            if toOpenArray?.count == 1, let selected = toOpenArray?[0],
               (NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false) || browser.horos_openReparsedSeriesFlag {
                // Just one thumbnail is selected.
                let singleSeries = StudyListItem.sorted(selected, by: [NSSortDescriptor(key: "instanceNumber", ascending: true),
                                                                       NSSortDescriptor(key: "frameID", ascending: true)])
                let groups = SeriesSplitting.reparseGroups(
                    sliceLocations: singleSeries.map { ($0 as? DicomImage)?.sliceLocation?.floatValue ?? 0 },
                    comments: singleSeries.map { (($0 as? DicomImage)?.comment as NSString?)?.floatValue ?? 0 })
                let splittedSeries = groups.map { $0.map { singleSeries[$0] } }

                if splittedSeries.count > 1 {
                    closeWaitWindow()
                    switch chooseSubSeries(splittedSeries, movie: movieViewer, viewer: viewer) {
                    case .cancel:
                        movieError = true
                    case .entire:
                        break
                    case .open(let lists, let movie):
                        toOpenArray = lists
                        movieViewer = movie
                    case .opened:
                        toOpenArray = nil
                    }
                }
            }
        }

        if !movieError, let toOpenArray {
            openViewer(toOpenArray, movie: movieViewer, viewer: viewer, keyImagesOnly: false, tryToFlipData: tryToFlipData)
        }
    }

    /// Opens the selected lines of the database: the images selected among
    /// the thumbnails of a series, or a list per series (a study opens its
    /// first image series); then tiles the windows, or brings them into view.
    func open(_ selectedLines: [Any]?, movie movieViewer: Bool, viewer: ViewerController?, tileWindows: Bool = true,
              protocol hangingProtocol: [AnyHashable: Any]? = nil) {
        guard let selectedLines, !selectedLines.isEmpty else { return }

        N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
            if let e = HorosObjCException.caught({
                let selectedLine = selectedLines[0]
                let matrix = self.browser.horos_oMatrix
                var cells: [NSCell] = matrix?.selectedCells ?? []
                if cells.isEmpty, let first = matrix?.cells.first {
                    cells = [first]
                }

                let study = isRowType(selectedLine, "Series") ? rowValue(selectedLine, "study") : selectedLine as Any?
                if let studyID = (study as? NSManagedObject)?.objectID {
                    self.processGraph.applicationMenus.addRecentStudy(studyID)
                }

                if cells.count > 1 && isRowType(selectedLine, "Series") {
                    // Open selected images only!
                    let curList = self.browser.childrenArray(selectedLine) ?? []
                    let selectedFilesList = ThumbnailCellTag.rows(tags: cells.map(\.tag), of: curList)
                    self.openViewer([selectedFilesList], movie: movieViewer, viewer: viewer, keyImagesOnly: false)
                } else {
                    // Open series: an array of the images of each series.
                    var toOpenArray: [[Any]] = []
                    if cells.count == 1 && selectedLines.count > 1 {
                        // Just one thumbnail is selected, but multiple lines are selected.
                        for line in selectedLines {
                            var curFile = line
                            var loadList: [Any]?
                            if isRowType(curFile, "Study") {
                                // Find the first series of images! Not a ROI series!
                                if let imageSeries = rowValue(curFile, "imageSeries") as? [Any], let first = imageSeries.first {
                                    curFile = first
                                    loadList = self.browser.childrenArray(curFile)
                                }
                            }
                            if isRowType(curFile, "Series") {
                                loadList = self.browser.childrenArray(curFile)
                            }
                            if let loadList { toOpenArray.append(loadList) }
                        }
                    } else {
                        // A placeholder of a series left out names no row.
                        let matrixViewArray = self.browser.horos_matrixViewArray ?? []
                        for curFile in ThumbnailCellTag.rows(tags: cells.map(\.tag), of: matrixViewArray) {
                            var loadList: [Any]?
                            if isRowType(curFile, "Image") {
                                loadList = self.browser.childrenArray(selectedLine, onlyImages: true)
                            }
                            if isRowType(curFile, "Series") {
                                loadList = self.browser.childrenArray(curFile, onlyImages: true)
                            }
                            if let loadList { toOpenArray.append(loadList) }
                        }
                    }
                    self.open(lists: toOpenArray, movie: movieViewer, viewer: viewer)
                }

                if tileWindows {
                    let viewers = ViewerController.getDisplayed2DViewers() ?? []
                    if self.preferences[ViewerPreferences.autoTiling] {
                        self.arranger.tileWindows(hangingProtocol.flatMap { ViewerWindowArranger.request(from: $0) })
                        if viewers.count > 1 {
                            var keyViewer: ViewerController?
                            for case let v as ViewerController in viewers {
                                v.imageView()?.scaleToFit()
                                v.imageView()?.setOriginX(0, y: 0)
                                if v.window?.isKeyWindow ?? false { keyViewer = v }
                            }
                            keyViewer?.propagateSettings()
                        }
                    } else {
                        self.showViewers(makeKey: true)
                    }
                }
            }) {
                BrowserObjC.log(e, stack: true, "-[BrowserController viewerDICOMInt:dcmFile:viewer:tileWindows:protocol:]")
                _ = HorosAlertPanel.run(title: NSLocalizedString("Opening Error", comment: ""),
                                        message: String(format: NSLocalizedString("Opening Error : %@\r\r%@", comment: ""), e, e.printStackTrace() ?? ""),
                                        defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        }
    }

    // MARK: - Commands

    /// "Open Images": with Shift the selection merged in one viewer.
    func openImages(sender: Any?) {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
            openMergedSelection(sender: sender)
        } else if browser.window?.firstResponder === browser.horos_databaseOutline {
            browser.newViewerDICOM(nil)
        } else {
            browser.newViewerDICOM(sender)
        }
    }

    /// Opens the selection: each selected study by its hanging protocol when
    /// the database list asks (no sender) with a study line and one
    /// thumbnail; otherwise the selected series, unless an external viewer
    /// opens them. Answers the line selected in the list.
    func openSelection(sender: Any?) -> AnyObject? {
        var item: AnyObject?
        N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
            let outline = self.browser.horos_databaseOutline
            item = outline.flatMap { $0.item(atRow: $0.selectedRow) as AnyObject? }
            if let e = HorosObjCException.caught({
                if sender == nil && (self.browser.horos_oMatrix?.selectedCells.count ?? 0) == 1 && isRowType(item, "Study") {
                    let array = self.browser.databaseSelection() ?? []
                    let savedValue = self.preferences[ViewerPreferences.automaticWorkspaceLoad]
                    if array.count > 1 && savedValue { self.preferences.set(false, for: ViewerPreferences.automaticWorkspaceLoad) }
                    for obj in array {
                        if let outline { OutlineSelectionRestore.select(obj, in: outline, extending: false) }
                        self.openStudy(obj as? NSManagedObject)
                    }
                    if array.count > 1 && savedValue { self.preferences.set(true, for: ViewerPreferences.automaticWorkspaceLoad) }
                } else {
                    // A selected placeholder of a series left out names no
                    // row: nothing opens, as for a tag past the rows.
                    let matrixViewArray = self.browser.horos_matrixViewArray ?? []
                    let tag = self.browser.horos_oMatrix?.selectedCell()?.tag ?? 0
                    if let row = ThumbnailCellTag.rowIndex(tag: tag, count: matrixViewArray.count),
                       !self.isUsingExternalViewer(matrixViewArray[row] as? NSManagedObject) {
                        // To avoid loading the DCMPix in previewSliderAction
                        self.browser.horos_dontUpdatePreviewPane = true
                        self.open(self.browser.databaseSelection(), movie: false, viewer: nil)
                        self.browser.horos_dontUpdatePreviewPane = false
                        self.browser.previewSliderAction(nil)
                    }
                }
            }) {
                BrowserObjC.log(e, stack: true, "-[BrowserController newViewerDICOM:]")
            }
        }
        return item
    }

    /// The images of the selection, of the thumbnails or of the list. The
    /// browser's readers of the selection fill an NSMutableArray.
    private func selectedImages(sender: Any?) -> [Any] {
        let images = NSMutableArray()
        if browser.isThumbnailMenuItem(sender) || browser.window?.firstResponder === browser.horos_oMatrix {
            _ = browser.files(forDatabaseMatrixSelection: images)
        } else {
            _ = browser.files(forDatabaseOutlineSelection: images)
        }
        return images as? [Any] ?? []
    }

    /// The selected images, all in one viewer.
    func openMergedSelection(sender: Any?) {
        openViewer([selectedImages(sender: sender)], movie: false, viewer: nil, keyImagesOnly: false)
        tileOrShowViewers()
    }

    /// The images of the selection that have ROIs; with Esc down, exported
    /// and closed.
    func openROIImages(sender: Any?) {
        let roisImagesArray = browser.roiImages(sender) ?? []
        if !roisImagesArray.isEmpty {
            BrowserController.horos_dontShowOpenSubSeries = true
            openViewer([roisImagesArray], movie: false, viewer: nil, keyImagesOnly: false)
            BrowserController.horos_dontShowOpenSubSeries = false
            tileOrShowViewers()
        } else {
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("ROIs Images", comment: ""),
                                                 message: NSLocalizedString("No images containing ROIs are found in this selection.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        #if !OSIRIX_LIGHT
        exportFirstViewerIfEscapeIsDown("ROIs images")
        #endif
    }

    /// The key images of the selection; with Esc down, exported and closed.
    func openKeyImages(sender: Any?) {
        let selectedItems = selectedImages(sender: sender)
        BrowserController.horos_dontShowOpenSubSeries = true
        openViewer([selectedItems], movie: false, viewer: nil, keyImagesOnly: true)
        BrowserController.horos_dontShowOpenSubSeries = false
        tileOrShowViewers()
        #if !OSIRIX_LIGHT
        exportFirstViewerIfEscapeIsDown("Key images")
        #endif
    }

    /// The selected database lines in the 4D player.
    func openSelectionIn4D() {
        var selectedItems: [Any] = []
        if let outline = browser.horos_databaseOutline {
            for index in outline.selectedRowIndexes {
                if let item = outline.item(atRow: index) { selectedItems.append(item) }
            }
        }
        open(selectedItems, movie: true, viewer: nil)
    }

    #if !OSIRIX_LIGHT
    /// With Esc held down, the images just opened are exported and their
    /// viewer closed.
    private func exportFirstViewerIfEscapeIsDown(_ seriesName: String) {
        guard CGEventSource.keyState(.combinedSessionState, key: 53) else { return }
        if let v = ViewerController.getDisplayed2DViewers()?.first as? ViewerController {
            v.exportAllImages(seriesName)
            v.window?.close()
        }
    }
    #endif

    // MARK: - Studies

    /// Opens a row of the study list: a series in a viewer, unless an
    /// external application opens it; a study by the workspace saved with it,
    /// then by its hanging protocol; a study of a node is retrieved first.
    func openStudy(_ item: NSManagedObject?) {
        cancelComparativeOpening()
        // #ifndef  OSIRIX_LIGHT
        if let node = (item as AnyObject?) as? DCMTKStudyQueryNode {
            // Check to see if already in retrieving mode, if not download it
            browser.retrieveComparativeStudy(node, select: true, open: true)
            return
        }
        // #endif

        let cells = browser.horos_oMatrix?.selectedCells ?? []
        if cells.count > 1 {
            for c in browser.horos_oMatrix?.cells ?? [] {
                c.isHighlighted = false
            }

            browser.horos_oMatrix?.selectCell(cells[0])
        }

        if isRowType(item, "Series") {
            if !isUsingExternalViewer(item) {
                // DICOM & others
                open(item.map { [$0] } ?? [], movie: false, viewer: nil)
            }
        } else { // STUDY - Hanging Protocols - Windows State
            let currentStudy = item as? DicomStudy

            browser.checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: currentStudy.map { [$0] } ?? [])

            if let studyID = currentStudy?.objectID {
                processGraph.applicationMenus.addRecentStudy(studyID)
            }

            if currentStudy?.windowsState != nil && preferences[ViewerPreferences.automaticWorkspaceLoad] {
                restoreWorkspace(of: currentStudy)
            }

            // The hanging protocol prevails over the workspace when a study opens.
            WindowLayoutManager.shared()?.setCurrentHangingProtocolForModality(currentStudy?.modality, description: currentStudy?.studyName)

            let currentHangingProtocol = WindowLayoutManager.shared()?.currentHangingProtocol

            open(currentStudy, withProtocol: currentHangingProtocol as? [AnyHashable: Any])
        }
    }

    /// The series of a study, opened by a hanging protocol: their order, the
    /// comparative studies, the number of windows, the synchronization, the
    /// propagation and the window of each viewer.
    func open(_ currentStudy: DicomStudy?, withProtocol currentHangingProtocol: [AnyHashable: Any]?) {
        cancelComparativeOpening()
        if let currentStudy, let currentHangingProtocol, let database,
           plistBool(currentHangingProtocol["Comparative"]),
           !hasDisplayedSeries(from: browser.childrenArray(currentStudy) ?? []) {
            prepareComparativeOpening(currentStudy, in: database, options: currentHangingProtocol)
        } else {
            openPrepared(currentStudy, withProtocol: currentHangingProtocol, comparatives: [])
        }
    }

    private func openPrepared(_ currentStudy: DicomStudy?, withProtocol currentHangingProtocol: [AnyHashable: Any]?,
                              comparatives studies: [DicomStudy]) {
        var restoreNoAutotiling = false
        var viewerWindowSize: Int32 = 0
        if preferences[ViewerPreferences.autoTiling] != true {
            restoreNoAutotiling = true
            viewerWindowSize = Int32(truncatingIfNeeded: preferences[ViewerPreferences.viewerWindowSize])
            preferences.set(true, for: ViewerPreferences.autoTiling)
        }

        let children = browser.childrenArray(currentStudy) ?? []

        if !hasDisplayedSeries(from: children) {
            if let sync = currentHangingProtocol?["Sync"] {
                DCMView.setSyncro(Int16(plistBool(sync) ? syncroLOC : syncroOFF))
            }

            if let propagate = currentHangingProtocol?["Propagate"] {
                preferences.set(plistBool(propagate), for: ViewerPreferences.copySettings)
            }

            var seriesArray: [Any]
            if (currentStudy?.imageSeriesContainingPixels(true)?.count ?? 0) > 0 {
                seriesArray = currentStudy?.imageSeriesContainingPixels(true) as? [Any] ?? []
            } else {
                seriesArray = currentStudy?.imageSeries() as? [Any] ?? []
            }

            // Sort series according to SeriesOrder, if available
            seriesArray = Self.ordered(seriesArray, by: currentHangingProtocol)

            var comparatives = Self.comparativeSeries(of: studies, by: currentHangingProtocol)

            // Prepare the series
            let total = Int(Int32(truncatingIfNeeded: Int(WindowLayoutManager.windowsRows(forHangingProtocol: currentHangingProtocol))
                * Int(WindowLayoutManager.windowsColumns(forHangingProtocol: currentHangingProtocol)) * arranger.viewerScreens().count))

            if seriesArray.count > total {
                seriesArray.removeSubrange(max(total, 0)...)
            }

            if seriesArray.count + comparatives.count > total {
                while seriesArray.count + comparatives.count > total && seriesArray.count > 1 {
                    seriesArray.removeLast()
                }

                while seriesArray.count + comparatives.count > total && !comparatives.isEmpty {
                    comparatives.removeLast()
                }
            }

            if plistBool(currentHangingProtocol?["RepeatSeriesIfNotEnoughSeries"]) {
                if seriesArray.count + comparatives.count < total {
                    var i = 0
                    while seriesArray.count + comparatives.count < total && !seriesArray.isEmpty {
                        seriesArray.append(seriesArray[i])
                        i += 1
                    }
                }
            }

            seriesArray += comparatives

            open(Self.seriesLevel(seriesArray), movie: false, viewer: nil, tileWindows: true, protocol: currentHangingProtocol)
        } else {
            for case let v as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
                v.window?.makeKeyAndOrderFront(browser)
            }
        }

        // Apply WL/WW
        for case let v as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
            guard let p = WindowLayoutManager.hangingProtocol(forModality: v.modality(), description: v.currentStudy()?.studyName) else { continue }
            if plistInt(p["WL"]) == 0 && plistInt(p["WW"]) == 0 { // Default
            } else if plistInt(p["WL"]) == 1 && plistInt(p["WW"]) == 1 { // Full
                v.imageView()?.setWLWW(0, 0)
            } else if p["WL"] != nil && p["WW"] != nil {
                v.imageView()?.setWLWW(plistFloat(p["WL"]), plistFloat(p["WW"]))
            }
        }

        if restoreNoAutotiling {
            preferences.set(false, for: ViewerPreferences.autoTiling)
            preferences.set(Int(viewerWindowSize), for: ViewerPreferences.viewerWindowSize)
        }
    }

    private func hasDisplayedSeries(from children: [Any]) -> Bool {
        (ViewerController.getDisplayedSeries() ?? []).contains { series in
            children.contains { sameString((series as? DicomSeries)?.seriesInstanceUID, ($0 as? DicomSeries)?.seriesInstanceUID) }
        }
    }

    /// The series in the order of the protocol's SeriesOrder: for each term,
    /// the last series whose name holds it, then the series no term took.
    nonisolated static func ordered(_ series: [Any], by hangingProtocol: [AnyHashable: Any]?) -> [Any] {
        guard hangingProtocol?["SeriesOrder"] != nil else { return series }
        let ignoreCase = plistBool(hangingProtocol?["SeriesOrderIgnoreCase"])
        var remaining = series
        var ordered: [Any] = []
        for term in (hangingProtocol?["SeriesOrder"] as? NSString)?.components(separatedBy: ",") ?? [] {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)

            var index = -1
            for (i, s) in remaining.enumerated() {
                let name = (s as? DicomSeries)?.name as NSString?
                if ignoreCase {
                    if (name?.range(of: term, options: .caseInsensitive).length ?? 0) > 0 {
                        index = i
                    }
                } else if name?.n2Contains(term as NSString) ?? false {
                    index = i
                }
            }

            if index != -1 {
                ordered.append(remaining.remove(at: index))
            }
        }
        return ordered + remaining
    }

    /// The first NumberOfSeriesPerComparative image series of each
    /// comparative study (one when the protocol says none), in the protocol's
    /// order.
    nonisolated static func comparativeSeries(of studies: [Any], by hangingProtocol: [AnyHashable: Any]?) -> [Any] {
        // Even one series must honor SeriesOrder; missing legacy counts mean one.
        let n = max(1, plistInteger(hangingProtocol?["NumberOfSeriesPerComparative"]))
        var series: [Any] = []
        for study in studies {
            let study = study as? DicomStudy
            var available = study?.imageSeriesContainingPixels(true) as? [Any] ?? []
            if available.isEmpty { available = study?.imageSeries() as? [Any] ?? [] }
            series += ordered(available, by: hangingProtocol).prefix(n)
        }
        return series
    }

    /// A study among the series to open stands for its first image series.
    nonisolated static func seriesLevel(_ items: [Any]) -> [Any] {
        items.map { item in
            guard let study = item as? DicomStudy else { return item }
            if let first = (study.imageSeriesContainingPixels(true) as? [Any])?.first {
                return first
            } else if let first = (study.imageSeries() as? [Any])?.first {
                return first
            }
            NSLog("---- no imageSeries in this study?: %@", study)
            return item
        }
    }

    private var selectedOpeningRowID: NSManagedObjectID? {
        guard let outline = browser.horos_databaseOutline, outline.selectedRow >= 0 else { return nil }
        return (outline.item(atRow: outline.selectedRow) as? NSManagedObject)?.objectID
    }

    private func cancelComparativeOpening() {
        comparativeOpening?.deadline?.cancel()
        comparativeOpening?.work?.cancel()
        comparativeOpening = nil
    }

    private func prepareComparativeOpening(_ study: DicomStudy, in database: DicomDatabase, options: [AnyHashable: Any]) {
        let opening = ComparativeOpening()
        comparativeOpening = opening
        let selected = selectedOpeningRowID
        let studyID = study.objectID
        let destination = Handed(value: database)
        let rules = ComparativeOpeningRules(options)
        let browser = self.browser
        let graph = processGraph

        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.comparativeOpening === opening else { return }
            self.cancelComparativeOpening()
            guard self.database === database, self.selectedOpeningRowID == selected,
                  let current = database.object(withID: studyID) as? DicomStudy, !current.isDeleted else { return }
            let comparisons = opening.orderedIDs().compactMap { database.object(withID: $0) as? DicomStudy }
            self.openPrepared(current, withProtocol: options, comparatives: comparisons)
        }

        opening.work = Task { [weak self] in
            let completed = await ActivityThread.run(name: NSLocalizedString("Retrieving images...", comment: "")) {
                let thread = Handed(value: Thread.current)
                guard !thread.value.isCancelled else { return false }
                guard let worker = destination.value.privateQueueIndependentDatabase() as? DicomDatabase else { return true }
                var remote: [(Int, DCMTKStudyQueryNode)] = []
                worker.performBlockAndWait {
                    guard let current = worker.object(withID: studyID) as? DicomStudy else { return }
                    let history = PatientHistoryList.historyNow(of: studyID, in: worker, browser: browser,
                        search: graph.pacsOnDemand, preferences: graph.preferences, updatesTable: false) ?? []
                    var position = 0
                    for candidate in history {
                        if thread.value.isCancelled { break }
                        if let local = candidate as? DicomStudy,
                           !sameString(local.studyInstanceUID, current.studyInstanceUID),
                           rules.includes(modality: local.modality, name: local.studyName, beside: current) {
                            opening.record(local.objectID, at: position)
                        } else if let node = candidate as? DCMTKStudyQueryNode,
                                  !sameString(node.studyInstanceUID(), current.studyInstanceUID),
                                  rules.includes(modality: node.modality(), name: node.studyName(), beside: current) {
                            remote.append((position, node))
                        } else {
                            continue
                        }
                        position += 1
                        if UInt(position) >= rules.limit { break }
                    }
                }
                if !remote.isEmpty && !thread.value.isCancelled {
                    Task { @MainActor in
                        guard opening.work?.isCancelled == false else { return }
                        opening.deadline = Task {
                            do { try await Task.sleep(for: .seconds(30)) } catch { return }
                            if !thread.value.isCancelled { finish() }
                        }
                    }
                    for (position, node) in remote {
                        guard !thread.value.isCancelled, graph.activeLocalDatabase === destination.value else { break }
                        browser.comparativeState.retrieves.retrieveNow(node, in: destination.value)
                        worker.performBlockAndWait {
                            guard !thread.value.isCancelled, let uid = node.studyInstanceUID() else { return }
                            let request = NSFetchRequest<DicomStudy>(entityName: "Study")
                            request.predicate = NSPredicate(format: "studyInstanceUID == %@", uid)
                            let matches = (try? worker.managedObjectContext.fetch(request))?.filter { local in
                                guard (local.imageSeriesContainingPixels(true)?.count ?? 0) > 0 else { return false }
                                if let expected = node.comparativeIdentity,
                                   let actual = PatientHistoryList.comparativeIdentity(of: local, in: worker) {
                                    if expected.hasDifferentIssuer(from: actual) { return false }
                                    if expected.corroborates(actual) { return true }
                                }
                                guard let key = node.patientUID(), let localKey = local.patientUID, !key.isEmpty, !localKey.isEmpty else { return false }
                                return key.caseInsensitiveCompare(localKey) == .orderedSame
                            } ?? []
                            if matches.count == 1 { opening.record(matches[0].objectID, at: position) }
                        }
                    }
                }
                return !thread.value.isCancelled
            }
            if completed && !Task.isCancelled {
                finish()
            } else if self?.comparativeOpening === opening {
                self?.cancelComparativeOpening()
            }
        }
    }

    // MARK: - Workspaces

    /// The viewers of the workspace saved with the study, when it holds the
    /// study: their series fetched (from a node when they are missing and the
    /// comparative search asks the nodes), opened, placed at their saved
    /// frames or tiled, with their window, zoom, pan, rotation and flips.
    private func restoreWorkspace(of currentStudy: DicomStudy?) {
        let saved = currentStudy?.windowsState.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [Any] ?? []
        // Each viewer saved is a dictionary of its settings.
        let viewers: [[String: Any]] = saved.map { $0 as? [String: Any] ?? [:] }

        // Check if this windowsState contains at least this study...
        guard viewers.contains(where: { sameString(currentStudy?.studyInstanceUID, $0["studyInstanceUID"]) }) else { return }

        var seriesToOpen: [[Any]] = []
        var viewersToLoad: [[String: Any]] = []

        ViewerController.closeAllWindows()

        var propagateSettings: Any? = nil
        var syncSettings: Any? = nil
        var SYNCSERIES: Any? = nil
        var syncButtonBehaviorIsBetweenStudies: Any? = nil

        if preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes] {
            showWaitWindow()

            // Check if all studies are available, available on PACS-On-Demand ?
            for dict in viewers {
                retrieveIfMissing(studyUID: dict["studyInstanceUID"])
            }

            closeWaitWindow()
        }

        for dict in viewers {
            let studyUID = dict["studyInstanceUID"]
            let seriesUID = dict["seriesInstanceUID"] as? String
            let seriesDICOMUID = dict["seriesDICOMUID"] as? String

            propagateSettings = dict["propagateSettings"]
            syncSettings = dict["syncSettings"]
            SYNCSERIES = dict["SYNCSERIES"]
            syncButtonBehaviorIsBetweenStudies = dict["SyncButtonBehaviorIsBetweenStudies"]

            let series4D = seriesUID?.components(separatedBy: "\\**\\")
            // Find the corresponding study & 4D series

            if let e = HorosObjCException.caught({
                let context = self.database?.managedObjectContext

                N2ManagedObjectContextPerformAndWait(context) {
                    var seriesForThisViewer: Int? = nil

                    if let e = HorosObjCException.caught({
                        for curSeriesUID in series4D ?? [] {
                            var request = NSFetchRequest<NSFetchRequestResult>(entityName: "Series")
                            request.predicate = NSPredicate(format: "study.studyInstanceUID == %@ AND seriesInstanceUID == %@", argumentArray: [studyUID ?? NSNull(), curSeriesUID])

                            var seriesArray = try? context?.fetch(request)

                            //Try the DICOMSeriesUID
                            if (seriesArray?.count ?? 0) == 0 && ((seriesDICOMUID as NSString?)?.length ?? 0) > 0 {
                                request = NSFetchRequest<NSFetchRequestResult>(entityName: "Series")
                                request.predicate = NSPredicate(format: "study.studyInstanceUID == %@ AND seriesDICOMUID == %@", argumentArray: [studyUID ?? NSNull(), seriesDICOMUID ?? NSNull()])
                                seriesArray = try? context?.fetch(request)
                            }

                            if let seriesArray, seriesArray.count == 1 {
                                // [nil compare:] answered NSOrderedSame.
                                let patientUID = (seriesArray[0] as? DicomSeries)?.study?.patientUID as NSString?
                                if (patientUID.map { $0.compare(currentStudy?.patientUID ?? "", options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) } ?? .orderedSame) == .orderedSame {
                                    if seriesForThisViewer == nil {
                                        seriesForThisViewer = seriesToOpen.count
                                        seriesToOpen.append([])
                                        viewersToLoad.append(dict)
                                    }

                                    if let viewerIndex = seriesForThisViewer { seriesToOpen[viewerIndex].append(seriesArray[0]) }
                                } else {
                                    NSLog("%@ versus %@", formatArgument((seriesArray[0] as? DicomSeries)?.study?.patientUID), formatArgument(currentStudy?.patientUID))
                                }
                            } else if (seriesArray?.count ?? 0) > 1 {
                                NSLog("****** number of series corresponding to these UID (%@) is not unique?: %d", curSeriesUID as NSString, Int32(truncatingIfNeeded: seriesArray?.count ?? 0))
                            }
                        }
                    }) {
                        BrowserObjC.log(e, stack: true, "-[BrowserController databaseOpenStudy:]")
                    }
                }
            }) {
                BrowserObjC.log(e, stack: true, "-[BrowserController databaseOpenStudy:]")
            }
        }

        guard !seriesToOpen.isEmpty && viewersToLoad.count == seriesToOpen.count else { return }

        if let syncSettings {
            DCMView.setSyncro(Int16(plistBool(syncSettings) ? syncroLOC : syncroOFF))
        }

        if let propagateSettings {
            preferences.set(plistBool(propagateSettings), for: ViewerPreferences.copySettings)
        }

        showWaitWindow()

        processGraph.appController?.checkAllWindowsAreVisibleIsOff = true

        for (i, series) in seriesToOpen.enumerated() {
            let toOpenArray: [[Any]] = series.compactMap { browser.childrenArray($0) }
            open(lists: toOpenArray, movie: plistBool(viewersToLoad[i]["4DData"]), viewer: nil)
        }

        let displayedViewers = ViewerController.getDisplayed2DViewers() as? [Any] ?? []
        // A workspace saved with viewers of another patient, or of series
        // no longer here, opens only part of its viewers: their saved
        // frames and tiling describe the whole layout, and a lone viewer
        // kept the half of the screen its column had. Those viewers are
        // tiled anew instead. A study saved with part of a layout (only its
        // patient's viewers) has no frames to apply either.
        let partialWorkspace = viewersToLoad.count != viewers.count ||
            viewersToLoad.contains { $0["window position"] == nil }
        var validWindowsPosition = !partialWorkspace
        for (i, dict) in viewersToLoad.enumerated() where i < displayedViewers.count {
            let v = displayedViewers[i] as? ViewerController

            var r = NSRect.zero
            let s = Scanner(string: (dict["window position"] as? String) ?? "")

            // -scanFloat: left the value as it was when nothing could be read.
            var scaleRatio: Float = 1, a: Float = 0
            if let f = s.scanFloat() { a = f };  r.origin.x = CGFloat(a);       if let f = s.scanFloat() { a = f };  r.origin.y = CGFloat(a)
            if let f = s.scanFloat() { a = f };  r.size.width = CGFloat(a);    if let f = s.scanFloat() { a = f };  r.size.height = CGFloat(a)

            let screenIndex = (dict["screenIndex"] as? NSNumber)?.uintValue ?? 0
            let savedScreenRect = NSRectFromString((dict["screen"] as? String) ?? "")
            if savedScreenRect.size.width > 0 && savedScreenRect.size.height > 0 {
                if screenIndex < UInt(NSScreen.screens.count) {
                    var widthRatio: Float = 1, heightRatio: Float = 1
                    let curScreenVisibleRect = ViewerWindowArranger.usefulRect(for: NSScreen.screens[Int(screenIndex)], showFloatingWindows: true)

                    widthRatio = Float(curScreenVisibleRect.size.width / savedScreenRect.size.width)
                    heightRatio = Float(curScreenVisibleRect.size.height / savedScreenRect.size.height)

                    r.size.width *= CGFloat(widthRatio)
                    r.size.height *= CGFloat(heightRatio)

                    r.origin.x = ((r.origin.x - savedScreenRect.origin.x) * CGFloat(widthRatio)) + curScreenVisibleRect.origin.x
                    r.origin.y = ((r.origin.y - savedScreenRect.origin.y) * CGFloat(heightRatio)) + curScreenVisibleRect.origin.y

                    if widthRatio < 1 || heightRatio < 1 {
                        scaleRatio = widthRatio < heightRatio ? widthRatio : heightRatio
                    }

                    if widthRatio > 1 || heightRatio > 1 {
                        scaleRatio = widthRatio > heightRatio ? widthRatio : heightRatio
                    }

                    // Test if the window is completely contained in the screen, otherwise, we will TileWindows.
                    if NSEqualRects(NSIntersectionRect(curScreenVisibleRect, r), r) == false {
                        r = NSIntersectionRect(curScreenVisibleRect, r)
                        validWindowsPosition = false
                    }
                } else {
                    validWindowsPosition = false
                }
            } else {
                validWindowsPosition = false
            }

            let index = plistInt(dict["index"])
            let rows = plistInt(dict["rows"])
            let columns = plistInt(dict["columns"])
            var wl = plistFloat(dict["wl"])
            let ww = plistFloat(dict["ww"])
            let x = plistFloat(dict["x"])
            let y = plistFloat(dict["y"])
            let rotation = plistFloat(dict["rotation"])
            let scale = plistFloat(dict["scale"]) * scaleRatio*scaleRatio

            if validWindowsPosition {
                v?.setWindowFrame(r, showWindow: false)
            }

            v?.setImageRows(rows, columns: columns)

            // A workspace explicitly owns its saved zoom/pan.
            v?.cancelOpeningScaleToFit()
            for view in v?.seriesView()?.imageViews() ?? [] {
                (view as? DCMView)?.prepareForWorkspacePresentation()
            }

            v?.setImageIndex(Int(index))
            wl = v?.imageView()?.curDCM?.calibratedWindowLevel(forStoredLevel: wl) ?? 0

            if v?.imageView()?.curDCM?.suvConverted ?? false {
                v?.setWL(wl * (v?.factorPET2SUV() ?? 0), ww: ww * (v?.factorPET2SUV() ?? 0))
            } else {
                v?.setWL(wl, ww: ww)
            }

            v?.setScaleValue(scale)
            v?.setRotation(rotation)
            v?.setOrigin(NSMakePoint(CGFloat(x), CGFloat(y)))

            // Each flip axis is restored from its own key. A workspace saved
            // before the keys existed leaves the flips as the series stored them.
            if dict["xFlipped"] != nil {
                v?.setXFlipped(plistBool(dict["xFlipped"]))
            }
            if dict["yFlipped"] != nil {
                v?.setYFlipped(plistBool(dict["yFlipped"]))
            }

            if plistBool(dict["SyncButtonBehaviorIsBetweenStudies"]) {
                v?.imageView()?.syncRelativeDiff = plistFloat(dict["syncRelativeDiff"])
            }

            if let tiling = dict["LastWindowsTilingRowsColumns"], !partialWorkspace {
                preferences.set(tiling, forKey: ViewerPreferences.lastWindowsTilingRowsColumns.name)
            }
        }

        processGraph.appController?.checkAllWindowsAreVisibleIsOff = false
        showViewers(makeKey: false)

        if validWindowsPosition {
            for i in viewersToLoad.indices where i < displayedViewers.count {
                let v = displayedViewers[i] as? ViewerController

                if let window = v?.window, let screen = window.screen {
                    // Test if the window is completely contained in the screen, otherwise, we will TileWindows.
                    if NSEqualRects(NSIntersectionRect(screen.visibleFrame, window.frame), window.frame) == false {
                        validWindowsPosition = false
                    }
                } else {
                    validWindowsPosition = false
                }
            }
        }

        if validWindowsPosition == false {
            var request: ViewerWindowArranger.Request? = nil
            let rw = partialWorkspace ? nil : preferences[ViewerPreferences.lastWindowsTilingRowsColumns] as NSString?
            if let rw, rw.length == 2 {
                request = ViewerWindowArranger.Request(rows: (rw.substring(with: NSMakeRange(0, 1)) as NSString).intValue,
                                                       columns: (rw.substring(with: NSMakeRange(1, 1)) as NSString).intValue)
            }
            arranger.tileWindows(request)
        }
        (displayedViewers.first as? ViewerController)?.window?.makeKeyAndOrderFront(browser)

        closeWaitWindow()

        //windowsStateApplied = YES; // Hanging Protocol has to prevail over window state when opening studies

        for v in displayedViewers.reversed() {
            (v as? ViewerController)?.buildMatrixPreview(true)
        }

        if plistBool(syncButtonBehaviorIsBetweenStudies) && plistBool(SYNCSERIES) {
            ViewerController.activateSYNCSERIESBetweenStudies()
        }

        ToolbarPanelController.checkForValidToolbar()

        (displayedViewers.last as? ViewerController)?.redrawToolbar()
    }

    /// A study of the workspace missing from the database, asked of the
    /// comparative nodes (PACS On-Demand) and retrieved: waited for until its
    /// image count stops changing, 20 seconds at most.
    private func retrieveIfMissing(studyUID: Any?) {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
        request.predicate = NSPredicate(format: "studyInstanceUID == %@", argumentArray: [studyUID ?? NSNull()])

        let context = database?.managedObjectContext
        var studiesArray = try? context?.fetch(request)

        guard (studiesArray?.count ?? 0) == 0 else { return }
        // #ifndef OSIRIX_LIGHT
        let servers = processGraph.pacsOnDemand.nodes.comparativeServers()

        let distantStudy = QueryController.queryStudies(forFilters: ["StudyInstanceUID" as AnyHashable: studyUID ?? NSNull()], servers: servers, showErrors: false)?.lastObject as? DCMTKStudyQueryNode

        guard let distantStudy else { return }
        // No time for decompression; the setting is shared with the comparative
        // retrievals that may be running.
        ListenerCompressionSuspension.shared.begin()

        QueryController.retrieveStudies([distantStudy], showErrors: false, checkForPreviousAutoRetrieve: true)

        var lastNumberOfImages = 0, currentNumberOfImages = 0
        let dateStart = Date.timeIntervalSinceReferenceDate

        repeat {
            Thread.sleep(forTimeInterval: 0.1)

            lastNumberOfImages = (studiesArray?.last as? DicomStudy)?.images()?.count ?? 0

            _ = processGraph.databaseIngest.importQueueNow()

            // And find the study locally
            let r = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
            r.predicate = NSPredicate(format: "studyInstanceUID == %@", argumentArray: [studyUID ?? NSNull()])

            if let e = HorosObjCException.caught({
                studiesArray = try? context?.fetch(r)
            }) { BrowserObjC.log(e, stack: true, "-[BrowserController databaseOpenStudy:]") }

            currentNumberOfImages = (studiesArray?.last as? DicomStudy)?.images()?.count ?? 0
        }
        while ((studiesArray?.count ?? 0) == 0 || lastNumberOfImages != currentNumberOfImages) && Date.timeIntervalSinceReferenceDate - dateStart < 20

        ListenerCompressionSuspension.shared.end()
        // #endif
    }

    // MARK: - External viewer

    /// Whether the series is opened by another application, not in a
    /// viewer: an MPEG-2 file by VLC, a PDF or SR report by the default PDF
    /// viewer (when "openPDFwithPreview" asks), and an RTSTRUCT, whose ROIs
    /// are made on the images instead.
    func isUsingExternalViewer(_ item: NSManagedObject?) -> Bool {
        var r = false

        N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
            guard isRowType(item, "Series") else { return }
            // Preserve the existing exception propagation after the queue work.
            let raised = HorosObjCException.caught {
                r = self.openExternally(item)
            }
            if let raised { raised.raise() }
        }

        return r
    }

    private func openExternally(_ item: NSManagedObject?) -> Bool {
        var r = false
        let images = browser.childrenArray(item, onlyImages: false) ?? []

        var im: DicomImage? = nil

        // An NSUInteger against an int: a negative slider value compares as a huge one.
        let sliderValue = Int(browser.horos_animationSlider?.intValue ?? 0)
        if UInt(images.count) > UInt(bitPattern: sliderValue) {
            im = images[sliderValue] as? DicomImage
        } else {
            im = (item as? DicomSeries)?.images?.first as? DicomImage
        }

        if sameString(im?.fileType(), "DICOMMPEG2") {
            let filePath = im?.completePath()

            let reportFailure: @Sendable (Bool) -> Void = { opened in
                guard !opened else { return }
                onMainRunLoop {
                    HorosAlertPanel.run(title: NSLocalizedString("MPEG-2 File", comment: ""), message: NSLocalizedString("MPEG-2 DICOM files require the VLC application. Available for free here: http://www.videolan.org/vlc/", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
                }
            }
            if let filePath {
                NSWorkspace.shared.openDocument(atPath: filePath, applicationIdentifiers: ["org.videolan.vlc"], completion: reportFailure)
            } else { reportFailure(false) }
            Thread.sleep(forTimeInterval: 1)

            r = true
        }

        // #ifndef OSIRIX_LIGHT

        let sopClassUID = im?.series?.seriesSOPClassUID
        if (sameString(im?.modality?.lowercased(), "pdf") || DICOMSOPClass.isPDF(sopClassUID) || DICOMSOPClass.isStructuredReport(sopClassUID)) && preferences[ViewerPreferences.openPDFwithPreview] {
            var path: String? = nil

            if DICOMSOPClass.isPDF(sopClassUID) {
                let dcmObject = im?.completePath().flatMap { DCMObject.object(contentsOfFile: $0) }

                if sameString(dcmObject?.attributeValue(withName: "SOPClassUID"), DICOMSOPClass.pdfStorageClassUID()) {
                    let pdfData = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data

                    var filename = dcmObject?.attributeValue(withName: "DocumentTitle") as? String
                    if ((filename as NSString?)?.length ?? 0) <= 0 {
                        filename = "PDFFile.pdf"
                    }

                    if sameString(((filename as NSString?)?.pathExtension as NSString?)?.lowercased, "pdf") == false {
                        filename = (filename as NSString?)?.appendingPathExtension("pdf")
                    }

                    path = (database?.tempDirPath() as NSString?)?.appendingPathComponent(filename ?? "")
                    if let path {
                        try? FileManager.default.removeItem(atPath: path)
                        (pdfData as NSData?)?.write(toFile: path, atomically: true)
                    }
                }
            } else if DICOMSOPClass.isStructuredReport(sopClassUID) {
                FileManager.default.confirmDirectory(atPath: (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix"))

                let htmlpath = ((((FileManager.default.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix") as NSString).appendingPathComponent((im?.completePath() as NSString?)?.lastPathComponent ?? "")) as NSString).appendingPathExtension("xml")

                if (htmlpath.map { FileManager.default.fileExists(atPath: $0) } ?? false) == false {
                    let aTask = Process()
                    aTask.environment = resourcePath("/dicom.dic").map { ["DCMDICTPATH": $0] }
                    aTask.launchPath = resourcePath("/dsr2html")
                    // The arguments end at the first one missing, as a nil ended them.
                    var arguments = ["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items"]
                    if let resolved = im?.completePathResolved() {
                        arguments.append(resolved)
                        if let htmlpath { arguments.append(htmlpath) }
                    }
                    aTask.arguments = arguments

                    // The wait had no deadline and the launch could raise. Both
                    // ran on the main thread. A missing conversion leaves no
                    // file, which the PDF path below already has to survive.
                    var taskError: NSError? = nil
                    if HorosRunTaskUntilExit(aTask, 60, &taskError) == false {
                        NSLog("****** dsr2html failed: %@", formatArgument(taskError?.localizedDescription))
                    }
                }

                if (htmlpath.flatMap { ($0 as NSString).appendingPathExtension("pdf") }.map { FileManager.default.fileExists(atPath: $0) } ?? false) == false {
                    if let htmlpath, let service = DecompressService.shared,
                       case .failure(let error) = service.updateReportPDF(atPath: htmlpath, timeout: 10) {
                        NSLog("****** Decompress pdfFromURL failed: %@", "\(error)")
                    }
                }

                path = htmlpath.flatMap { ($0 as NSString).appendingPathExtension("pdf") }
            } else {
                path = im?.completePath()
            }

            if let path, NSWorkspace.shared.open(URL(fileURLWithPath: path)) == false {
                r = false
            } else {
                r = true
            }

            Thread.sleep(forTimeInterval: 1)
        }

        // RTSTRUCT
        if sameString(im?.modality?.lowercased(), "rtstruct") {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("RTSTRUCT", comment: ""),
                                                message: NSLocalizedString("This series contains RTSTRUCT ROIs. Should I generate the corresponding ROIs on the images series?", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""),
                                                alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                otherButton: nil) == HorosAlertPanel.defaultResponse {
                let dcmObj = im?.completePathResolved().flatMap { DCMObject.object(contentsOfFile: $0) }

                let pix = HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
                    browser.horos_previewPix?.object(at: 0) as? DCMPix  // Should only be one DCMPix associated w/ an RTSTRUCT
                }

                pix?.createROIs(fromRTSTRUCT: dcmObj)

                r = true
            }
        }

        // #endif
        return r
    }

    // MARK: - 3D/4D sheet

    /// The 3D/4D sheet for the sub-series of one series: a thumbnail per
    /// sub-series (3D) and, when they all have as many images, per time
    /// (4D).
    func chooseSubSeries(_ splittedSeries: [[Any]], movie movieViewer: Bool, viewer: ViewerController?) -> SubSeriesChoice {
        guard let subOpenWindow = browser.horos_subOpenWindow, let matrix3D = browser.horos_subOpenMatrix3D, let matrix4D = browser.horos_subOpenMatrix4D,
              let supOpenButtons = browser.horos_supOpenButtons else { return .cancel }

        matrix3D.renewRows(1, columns: splittedSeries.count)
        matrix3D.sizeToCells()
        matrix3D.target = browser
        matrix3D.action = #selector(BrowserController.selectSubSeriesAndOpen(_:))

        matrix4D.renewRows(1, columns: splittedSeries[0].count)
        matrix4D.sizeToCells()
        matrix4D.target = browser
        matrix4D.action = #selector(BrowserController.selectSubSeriesAndOpen(_:))

        supOpenButtons.cell(withTag: 3)?.isEnabled = true
        let areData4D = SeriesSplitting.isFourD(groupSizes: splittedSeries.map(\.count))
        if !areData4D {
            supOpenButtons.cell(withTag: 3)?.isEnabled = false
        }

        func thumbnail(_ image: Any, title: String, in cell: NSCell?) {
            let image = image as? DicomImage
            // The image's own database says whether its file is a shared
            // database's: the images opened need not be the browser's rows.
            guard let dcmPix = DCMPix(path: image?.completePath(), 0, 1, nil, Int(image?.frameID?.int32Value ?? 0),
                                      Int(image?.series?.id?.int32Value ?? 0), isBonjour: RemoteDicomDatabase.database(of: image) != nil,
                                      imageObj: image) else { return }
            let img = dcmPix.generateThumbnailImage(withWW: image?.series?.windowWidth?.floatValue ?? 0,
                                                    wl: dcmPix.calibratedWindowLevel(forStoredLevel: image?.series?.windowLevel?.floatValue ?? 0))
            guard let cell = cell as? NSButtonCell else { return }
            cell.isTransparent = false
            cell.isEnabled = true
            cell.font = NSFont.systemFont(ofSize: 10)
            cell.imagePosition = .imageBelow
            cell.title = title
            cell.image = img
            cell.alternateImage = img
        }

        for (i, series) in splittedSeries.enumerated() {
            thumbnail(element(series, series.count / 2),
                      title: String(format: NSLocalizedString("%d/%d Images", comment: ""), Int32(i + 1), Int32(series.count)),
                      in: matrix3D.cell(atRow: 0, column: i))
        }
        if areData4D {
            for i in 0..<splittedSeries[0].count {
                thumbnail(splittedSeries[0][i], title: String(format: NSLocalizedString("%d/%d Images", comment: ""), Int32(i + 1), Int32(splittedSeries.count)),
                          in: matrix4D.cell(atRow: 0, column: i))
            }
        } else {
            matrix4D.renewRows(0, columns: 0)
            matrix4D.sizeToCells()
            matrix4D.isEnabled = false
        }

        NSApp.mainWindow?.beginSheet(subOpenWindow, completionHandler: nil)
        var result = NSApp.runModal(for: subOpenWindow).rawValue
        subOpenWindow.makeFirstResponder(nil)

        if result == 2 {
            supOpenButtons.selectCell(withTag: 2)
            if matrix3D.selectedColumn < 0 {
                result = matrix4D.selectedColumn < 0 ? 0 : 5
            }
        } else if result == 6 {
            NSLog("Open all 3D")
        } else if result == 7 {
            NSLog("Open all 4D")
        } else if result == 10 {
            NSLog("Reparse in 3D")
            reparse(groupCount: splittedSeries.count, from: splittedSeries) { splittedSeries[$0] }
            browser.refreshDatabase(browser)
            browser.refreshMatrix(browser)
            result = 0
        } else if result == 11 {
            NSLog("Reparse in 4D")
            reparse(groupCount: splittedSeries[0].count, from: splittedSeries) { i in splittedSeries.map { element($0, i) } }
            browser.refreshDatabase(browser)
            browser.refreshMatrix(browser)
            result = 0
        } else {
            result = supOpenButtons.selectedTag()
        }

        subOpenWindow.sheetParent?.endSheet(subOpenWindow)
        subOpenWindow.orderOut(browser)

        switch result {
        case 0: // Cancel
            return .cancel
        case 2: // selected 3D
            return .open([splittedSeries[matrix3D.selectedColumn]], movie: movieViewer)
        case 3: // 4D Viewer
            return .open(splittedSeries, movie: true)
        case 5: // selected 4D
            return .open([splittedSeries.map { element($0, matrix4D.selectedColumn) }], movie: movieViewer)
        case 6:
            showWaitWindow()
            for array in splittedSeries {
                openViewer([array], movie: movieViewer, viewer: viewer, keyImagesOnly: false)
            }
            return .opened
        case 7:
            var openAllWindows = true
            if splittedSeries[0].count > 25 {
                openAllWindows = HorosAlertPanel.runInformational(
                    title: NSLocalizedString("Series Opening", comment: ""),
                    message: String(format: NSLocalizedString("Are you sure you want to open %d windows? It's a lot of windows for this screen...", comment: ""), Int32(splittedSeries[0].count)),
                    defaultButton: NSLocalizedString("Yes", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                    otherButton: nil) == HorosAlertPanel.defaultResponse
            }
            if openAllWindows {
                showWaitWindow()
                for i in 0..<splittedSeries[0].count {
                    openViewer([splittedSeries.map { element($0, i) }], movie: movieViewer, viewer: viewer, keyImagesOnly: false)
                }
            }
            return .opened
        default: // 1: Entire
            return .entire
        }
    }

    /// "Reparse in 3D" / "Reparse in 4D": a new series of the study for each
    /// group, the images moved into it and the original series deleted, as
    /// IsiXDatabase's SeriesReparse writes it; then the database is saved.
    private func reparse(groupCount: Int, from splittedSeries: [[Any]], group: @escaping (Int) -> [Any]) {
        guard let database, let context = database.managedObjectContext else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            if let e = HorosObjCException.caught({
                let groups = (0..<groupCount).map { group($0).compactMap { $0 as? NSManagedObject } }
                SeriesReparse.write(groups: groups, seriesOf: splittedSeries.last?.last as? NSManagedObject, in: context)
                _ = database.save(nil)
            }) {
                BrowserObjC.log(e, stack: true, "-[BrowserController processOpenViewerDICOMFromArray:movie:viewer:]")
            }
        }
    }

    // MARK: - Sub-series sheet

    /// The images of each list the sub-series sheet keeps, sorted as their
    /// series sorts its images.
    func keptImages(of toOpenArray: [Any]?) -> [Any] {
        var newArray: [Any] = []
        for loadList in toOpenArray ?? [] {
            let list = loadList as? [Any] ?? []
            let kept = SubSeriesSelection.indices(imageCount: list.count, from: browser.horos_subFrom, to: browser.horos_subTo, interval: browser.horos_subInterval)
            guard !kept.isEmpty else { continue }
            var imagesArray = kept.map { list[$0] }
            if let descriptors = ((imagesArray.last as? DicomImage)?.series as? DicomSeries)?.sortDescriptorsForImages() as? [NSSortDescriptor] {
                imagesArray = StudyListItem.sorted(imagesArray, by: descriptors)
            }
            newArray.append(imagesArray)
        }
        return newArray
    }

    /// Whether the images the sheet keeps fit in memory: smiles and OK, or
    /// errors and what to do.
    func checkMemory() {
        var mem: UInt = 0
        let selection = keptImages(of: subSeriesLists)
        if selection.isEmpty {
            browser.horos_subSeriesOKButton?.isEnabled = false
            browser.horos_memoryMessage?.stringValue = NSLocalizedString("Select at least one image.", comment: "")
            return
        }
        if ViewerSeriesLoader.enoughMemory(for: selection.map { $0 as? [Any] ?? [] }, requiredMegabytes: &mem) {
            browser.horos_leftIcon?.image = NSImage(named: "smile")
            browser.horos_rightIcon?.image = NSImage(named: "smile")
            browser.horos_subSeriesOKButton?.isEnabled = true
            browser.horos_memoryMessage?.stringValue = NSLocalizedString("OK !", comment: "")
        } else {
            browser.horos_leftIcon?.image = NSImage(named: "error")
            browser.horos_rightIcon?.image = NSImage(named: "error")
            browser.horos_subSeriesOKButton?.isEnabled = false
            browser.horos_memoryMessage?.stringValue = NSLocalizedString("Not enough memory. Select fewer images and try again.", comment: "")
        }
    }

    /// `[sender intValue]`: a number from the bindings, or the control the
    /// sheet sends.
    private func senderIntValue(_ sender: Any?) -> Int32 {
        if let number = sender as? NSNumber { return number.int32Value }
        if let control = sender as? NSControl { return control.intValue }
        if let cell = sender as? NSCell { return cell.intValue }
        if let string = sender as? NSString { return string.intValue }
        return 0
    }

    func setSubInterval(_ sender: Any?) {
        browser.horos_subInterval = senderIntValue(sender)
        checkMemory()
    }

    func setSubFrom(_ sender: Any?) {
        browser.horos_subFrom = senderIntValue(sender)
        if database == nil { return }
        browser.horos_animationSlider?.intValue = browser.horos_subFrom - 1
        showSubSeriesBoundInPreview()
    }

    func setSubTo(_ sender: Any?) {
        browser.horos_subTo = senderIntValue(sender)
        if database == nil { return }
        browser.horos_animationSlider?.intValue = browser.horos_subTo - 1
        showSubSeriesBoundInPreview()
    }

    /// The preview shows the image a bound of the range was moved to.
    private func showSubSeriesBoundInPreview() {
        let copyDontUpdatePreviewPane = browser.horos_dontUpdatePreviewPane
        browser.horos_dontUpdatePreviewPane = false
        browser.previewSliderAction(nil)
        browser.horos_dontUpdatePreviewPane = copyDontUpdatePreviewPane
        checkMemory()
    }

    /// The sub-series sheet: the images kept of each list, or nil when it is
    /// cancelled or cannot be shown (another sheet, a full-screen window).
    func chooseSubSeriesRange(_ toOpenArray: [Any]?) -> [Any]? {
        browser.horos_waitOpeningWindow?.window?.orderOut(browser)
        let copySortSeriesBySliceLocation = preferences[DatabasePreferences.sortSeriesBySliceLocation]

        subSeriesLists = toOpenArray

        // To avoid the problem of displaying this sheet when the user is in fullscreen mode
        if (NSApp.mainWindow?.level.rawValue ?? 0) > NSWindow.Level.modalPanel.rawValue { NSSound.beep(); return nil }
        if (NSApp.keyWindow?.level.rawValue ?? 0) > NSWindow.Level.modalPanel.rawValue { NSSound.beep(); return nil }

        // The sheet's fields are bound to these keys of the browser: setting
        // them by key runs their setters, -setSubTo: and -setSubFrom:, and tells
        // the bindings.
        let count = NSNumber(value: Int32((toOpenArray?.first as? [Any])?.count ?? 0))
        browser.setValue(count, forKey: "subTo")
        browser.setValue(count, forKey: "subMax")
        browser.setValue(NSNumber(value: Int32(1)), forKey: "subFrom")
        browser.setValue(NSNumber(value: Int32(1)), forKey: "subInterval")

        guard !browser.horos_subSeriesWindowIsOn, let subSeriesWindow = browser.horos_subSeriesWindow else { return nil }
        browser.horos_subSeriesWindowIsOn = true
        // The legacy nib puts this status inside a hidden memory-information
        // section. Keep selection feedback visible independently of that section.
        if let content = subSeriesWindow.contentView, let memoryMessage = browser.horos_memoryMessage, memoryMessage.superview !== content {
            memoryMessage.removeFromSuperview()
            content.addSubview(memoryMessage)
            memoryMessage.translatesAutoresizingMaskIntoConstraints = false
            memoryMessage.isHidden = false
            memoryMessage.textColor = .labelColor
            memoryMessage.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            memoryMessage.alignment = .left
            memoryMessage.cell?.wraps = true
            memoryMessage.cell?.isScrollable = false
            NSLayoutConstraint.activate([
                memoryMessage.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                memoryMessage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                memoryMessage.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            ])
        }
        NSApp.mainWindow?.beginSheet(subSeriesWindow, completionHandler: nil)
        checkMemory()

        let result = NSApp.runModal(for: subSeriesWindow)
        subSeriesWindow.makeFirstResponder(nil)
        subSeriesWindow.sheetParent?.endSheet(subSeriesWindow)
        subSeriesWindow.orderOut(browser)
        browser.horos_waitOpeningWindow?.window?.orderBack(browser)
        browser.horos_subSeriesWindowIsOn = false

        let returnedArray = result == .stop ? keptImages(of: toOpenArray) : nil
        subSeriesLists = nil
        preferences.set(copySortSeriesBySliceLocation, for: DatabasePreferences.sortSeriesBySliceLocation)
        return returnedArray
    }

    // MARK: - Presentation states

    /// The missing references and the features the presentation state does
    /// not apply, logged and shown.
    func presentGSPSFlags(_ document: GSPSDocument?, missing: [GSPSImageReference]) {
        var lines: [String] = []
        for reference in missing {
            lines.append(String(format: NSLocalizedString("Missing referenced SOP Instance UID %@", comment: ""), reference.sopInstanceUID))
        }
        for flag in document?.unsupportedFeatures ?? [] {
            lines.append(flag)
        }
        if lines.count == 0 {
            return
        }
        for line in lines {
            NSLog("GSPS: %@", line)
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Grayscale Presentation State", comment: "")
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }

    /// If `series` is a Softcopy Presentation State, opens the referenced images
    /// (when they are in the same study) and applies the documented GSPS subset.
    /// `handled` when the series was handled as a presentation state, even if
    /// every reference is missing — in that case no empty viewer is opened.
    func openPresentationState(_ series: DicomSeries?, viewer: ViewerController?, keyImagesOnly keyImages: Bool) -> (handled: Bool, viewer: ViewerController?) {
        guard let series else {
            return (false, nil)
        }

        let sopClass = series.seriesSOPClassUID
        if GSPSDocument.isSoftcopyPresentationStateSOPClass(sopClass) == false
            && DICOMSOPClass.isPresentationState(sopClass) == false {
            return (false, nil)
        }

        let gspsImage = (series.sortedImages()?.first as? DicomImage) ?? (series.images?.first as? DicomImage)
        let path = gspsImage?.completePath()
        guard let document = GSPSDocument.document(contentsOfFile: path) else {
            NSLog("GSPS: series %@ looks like a presentation state but the file could not be read", formatArgument(series.name))
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("Grayscale Presentation State", comment: "")
            alert.informativeText = NSLocalizedString("That series is a presentation state, but the file could not be read. The original images were not opened or changed.", comment: "")
            alert.runModal()
            return (true, nil)
        }

        var found: [DicomImage] = []
        for case let image as DicomImage in (series.study?.images() as NSSet?) ?? NSSet() {
            if GSPSDocument.isSoftcopyPresentationStateSOPClass(image.series?.seriesSOPClassUID)
                || DICOMSOPClass.isPresentationState(image.series?.seriesSOPClassUID) {
                continue
            }

            var matches = document.references(sopInstanceUID: image.sopInstanceUID() ?? "", frame: Int(max(1, image.frameID?.int32Value ?? 0)))
            if matches == false && (image.numberOfFrames?.int32Value ?? 0) > 1 {
                var frame: Int32 = 1
                while frame <= (image.numberOfFrames?.int32Value ?? 0) {
                    if document.references(sopInstanceUID: image.sopInstanceUID() ?? "", frame: Int(frame)) {
                        matches = true
                        break
                    }
                    frame += 1
                }
            }
            if matches {
                found.append(image)
            }
        }

        found = StudyListItem.sorted(found, by: [
            NSSortDescriptor(key: "instanceNumber", ascending: true),
            NSSortDescriptor(key: "frameID", ascending: true),
        ]).compactMap { $0 as? DicomImage }

        var missing: [GSPSImageReference] = []
        for reference in document.referencedImages {
            var present = false
            for image in found {
                if document.references(sopInstanceUID: image.sopInstanceUID() ?? "", frame: Int(max(1, image.frameID?.int32Value ?? 0)))
                    || ((image.numberOfFrames?.int32Value ?? 0) > 1 && (image.sopInstanceUID() as NSString?)?.isEqual(to: reference.sopInstanceUID) == true) {
                    present = true
                    break
                }
            }
            if present == false {
                missing.append(reference)
            }
        }

        if found.isEmpty {
            presentGSPSFlags(document, missing: missing.count > 0 ? missing : document.referencedImages)
            return (true, nil)
        }

        let opened = openViewer([found], movie: false, viewer: viewer, keyImagesOnly: keyImages, tryToFlipData: true)
        if let opened {
            // The viewer's method is reached through the runtime by selector,
            // as the former file sent it; its result is not read.
            _ = opened.perform(NSSelectorFromString("applyGrayscaleSoftcopyPresentationStateFromPath:"), with: path)
        } else {
            presentGSPSFlags(document, missing: missing)
        }
        return (true, opened)
    }

    // MARK: - Series left out

    // The placeholders of the series a DICOMweb node's rule left out of the
    // selected study, in the cells after its series' thumbnails. Their cells
    // are outside `matrixViewArray`, with negative tags: every use of the
    // thumbnails that takes a series by its cell's tag (open, merge, export,
    // print, drag, the context menu) checks the tag against that array with
    // IsiXDatabase's ThumbnailCellTag, or as an unsigned index, and passes
    // them by; the preview's slider falls back to the first thumbnail. A
    // click retrieves the series.

    /// The row of `rows` (the browser's `matrixViewArray`) a thumbnail's cell
    /// names, nil for a cell that names none, as a placeholder.
    static func thumbnailRow(_ cell: NSCell, of rows: [Any]?) -> Any? {
        let rows = rows ?? []
        return ThumbnailCellTag.rowIndex(tag: cell.tag, count: rows.count).map { rows[$0] }
    }

    /// The placeholders of `item` when it is a study, none otherwise.
    func prepareExcludedSeries(of item: Any?) {
        if excludedSeriesObserver == nil {
            excludedSeriesObserver = NotificationCenter.default.addObserver(forName: ExcludedSeries.didChangeNotification,
                                                                            object: nil, queue: .main) { [weak self] note in
                let uid = note.object as? String
                MainActor.assumeIsolated {
                    guard let self, let outline = self.browser.horos_databaseOutline,
                          let study = outline.item(atRow: outline.selectedRow) as? DicomStudy,
                          study.studyInstanceUID == uid else { return }
                    self.prepareExcludedSeries(of: study)
                    self.browser.previewMatrixScrollViewFrameDidChange(nil)
                }
            }
        }
        guard let study = item as? DicomStudy, let uid = study.studyInstanceUID,
              let database = database?.dataBaseDirPath, !database.isEmpty else {
            excludedSeries = []
            return
        }
        excludedSeries = Self.excludedSeries(ofLocalStudy: study, studyUID: uid, database: database)
    }

    /// The placeholders of a local study: neither their series nor their middle
    /// instance in the database.
    static func excludedSeries(ofLocalStudy study: DicomStudy, studyUID uid: String, database: String) -> [ExcludedSeries] {
        let local = Set(((study.series as NSSet?)?.allObjects ?? []).compactMap { ($0 as? DicomSeries)?.seriesDICOMUID })
        let pending = ExcludedSeries.placeholders(study: uid, database: database, localSeries: local)
        return ExcludedSeries.withoutLocalInstances(pending) { middles in
            guard let context = study.managedObjectContext else { return [] }
            var encoded: [Data] = []
            for middle in middles {
                guard let data = DicomImage.sopInstanceUIDEncode(middle) else { continue }
                encoded.append(data)
                // A stored SOP Instance UID may keep a trailing zero byte.
                var padded = data
                padded.append(0)
                encoded.append(padded)
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
            request.predicate = NSPredicate(format: "series.study == %@ AND compressedSopInstanceUID IN %@", study, encoded)
            return Set(((try? context.fetch(request)) ?? []).compactMap { ($0 as? DicomImage)?.sopInstanceUID() })
        }
    }

    /// Fills the cells after the series' with the placeholders.
    func layOutExcludedSeriesCells() {
        guard let matrix = browser.horos_oMatrix else { return }
        let placeholders = excludedSeries
        guard !placeholders.isEmpty else { return }
        let first = browser.horos_matrixViewArray?.count ?? 0
        var rows = 0, columns = 0
        matrix.getNumberOfRows(&rows, columns: &columns)
        if columns < 1 { columns = 1 }
        let font = NSFont.systemFont(ofSize: CGFloat(browser.fontSize("dbMatrixFont")))
        let studyDate = browser.horos_databaseOutline.flatMap { ($0.item(atRow: $0.selectedRow) as? DicomStudy)?.date }
        var side = min(matrix.cellSize.width, matrix.cellSize.height) * 0.6
        if side < 16 { side = 64 }
        for (k, placeholder) in placeholders.enumerated() {
            let i = first + k
            guard i < rows * columns, let cell = matrix.cell(atRow: i / columns, column: i % columns) as? NSButtonCell else { break }
            cell.tag = Self.firstExcludedSeriesTag - k
            cell.representedObject = placeholder
            cell.isTransparent = false
            cell.isEnabled = true
            cell.setButtonType(.momentaryPushIn)
            cell.bezelStyle = .shadowlessSquare
            cell.isBordered = true
            cell.imagePosition = .imageBelow
            cell.imageScaling = .scaleProportionallyDown
            cell.lineBreakMode = .byCharWrapping
            cell.font = font
            cell.menu = nil
            cell.attributedTitle = NSAttributedString(string: placeholder.title(studyDate: studyDate),
                                                      attributes: [.font: font, .foregroundColor: NSColor.disabledControlTextColor])
            cell.image = placeholder.image(size: NSSize(width: side, height: side))
            cell.target = browser
            cell.action = #selector(BrowserController.horosRetrieveExcludedSeries(_:))
        }
    }

    /// A click on a placeholder retrieves its series.
    static func retrieveExcludedSeries(_ sender: Any?) {
        let cell = (sender as? NSMatrix)?.selectedCell() ?? (sender as? NSCell)
        guard let placeholder = cell?.representedObject as? ExcludedSeries else { return }
        DCMTKQueryNode.retrieveExcludedSeries(placeholder)
    }
}
