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
import IsiXImaging

// Opening 2D and 4D viewers from the browser: the commands of the menus and
// toolbar, which images of the selection go to which viewer, the cut of one
// series into the sub-series of a 3D/4D acquisition, and the tiling of the
// windows afterwards. Loading the images is ViewerSeriesLoader's; the rules
// are in IsiXImaging (ViewerOpeningRules.swift).

/// `[value floatValue]` of a number or a string; 0 for nil and the rest.
nonisolated func openingFloatValue(_ value: Any?) -> Float {
    if let number = value as? NSNumber { return number.floatValue }
    if let string = value as? NSString { return string.floatValue }
    return 0
}

extension BrowserController {

    // MARK: Loading

    @objc(computeEnoughMemory::)
    nonisolated func computeEnoughMemory(_ toOpenArray: [Any]!, _ requiredMem: UnsafeMutablePointer<UInt>!) -> Bool {
        return ViewerSeriesLoader.enoughMemory(for: (toOpenArray ?? []).map { ($0 as? NSArray) as? [Any] ?? [] }, requiredMegabytes: requiredMem)
    }

    @objc(openViewerFromImages:movie:viewer:keyImagesOnly:)
    @discardableResult
    func openViewer(fromImages toOpenArray: [Any]!, movie movieViewer: Bool, viewer: ViewerController!, keyImagesOnly keyImages: Bool) -> ViewerController! {
        return openViewer(fromImages: toOpenArray, movie: movieViewer, viewer: viewer, keyImagesOnly: keyImages, tryToFlipData: false)
    }

    @objc(openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:)
    @discardableResult
    func openViewer(fromImages toOpenArray: [Any]!, movie movieViewer: Bool, viewer: ViewerController!, keyImagesOnly keyImages: Bool,
                    tryToFlipData: Bool) -> ViewerController! {
        let lists = (toOpenArray ?? []).map { ($0 as? NSArray) as? [Any] ?? [] }
        return ViewerSeriesLoader(browser: self).open(lists, movie: movieViewer, viewer: viewer, keyImagesOnly: keyImages, tryToFlipData: tryToFlipData)
    }

    // MARK: Selection

    /// The lists of images to open, as the selection gives them: the 4D
    /// player checks them (cutting one series into its times); a single
    /// series opened with Option or as "Reparsed Series" may be cut into
    /// sub-series, chosen in a sheet.
    @objc(processOpenViewerDICOMFromArray:movie:viewer:)
    func processOpenViewerDICOM(from toOpenArrayIn: [Any]!, movie movieViewerIn: Bool, viewer: ViewerController!) {
        var toOpenArray: [[Any]]? = (toOpenArrayIn ?? []).map { ($0 as? NSArray) as? [Any] ?? [] }
        var movieViewer = movieViewerIn
        var movieError = false, tryToFlipData = false

        if (toOpenArray?.count ?? 0) > 2 {
            displayWaitWindowIfNecessary()
        }

        if movieViewer {
            // First check if all series contain the same number of images.
            if toOpenArray?.count == 1, let singleSeries = toOpenArray?[0] {
                // Just one thumbnail is selected: its times.
                let groups = SeriesSplitting.movieGroups(sliceLocations: singleSeries.map { openingFloatValue(($0 as AnyObject).value(forKey: "sliceLocation")) })
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
               (NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false) || horos_openReparsedSeriesFlag {
                // Just one thumbnail is selected.
                let singleSeries = ((selected as NSArray).sortedArray(using: [NSSortDescriptor(key: "instanceNumber", ascending: true),
                                                                             NSSortDescriptor(key: "frameID", ascending: true)]))
                let groups = SeriesSplitting.reparseGroups(
                    sliceLocations: singleSeries.map { openingFloatValue(($0 as AnyObject).value(forKey: "sliceLocation")) },
                    comments: singleSeries.map { openingFloatValue(($0 as AnyObject).value(forKey: "comment")) })
                let splittedSeries = groups.map { $0.map { singleSeries[$0] } }

                if splittedSeries.count > 1 {
                    closeWaitWindowIfNecessary()
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
            _ = openViewer(fromImages: toOpenArray, movie: movieViewer, viewer: viewer, keyImagesOnly: false, tryToFlipData: tryToFlipData)
        }
    }

    @objc(viewerDICOMInt:dcmFile:viewer:)
    func viewerDICOMInt(_ movieViewer: Bool, dcmFile selectedLines: [Any]!, viewer: ViewerController!) {
        viewerDICOMInt(movieViewer, dcmFile: selectedLines, viewer: viewer, tileWindows: true, protocol: nil)
    }

    @objc(viewerDICOMInt:dcmFile:viewer:tileWindows:)
    func viewerDICOMInt(_ movieViewer: Bool, dcmFile selectedLines: [Any]!, viewer: ViewerController!, tileWindows: Bool) {
        viewerDICOMInt(movieViewer, dcmFile: selectedLines, viewer: viewer, tileWindows: tileWindows, protocol: nil)
    }

    /// Opens the selected lines of the database: the images selected among
    /// the thumbnails of a series, or a list per series (a study opens its
    /// first image series); then tiles the windows, or brings them into view.
    @objc(viewerDICOMInt:dcmFile:viewer:tileWindows:protocol:)
    func viewerDICOMInt(_ movieViewer: Bool, dcmFile selectedLines: [Any]!, viewer: ViewerController!, tileWindows: Bool,
                        protocol hangingProtocol: [AnyHashable: Any]!) {
        guard let selectedLines, !selectedLines.isEmpty else { return }

        N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
            if let e = BrowserObjC.attempt({
                let selectedLine = selectedLines[0] as AnyObject
                let matrix = self.horos_oMatrix
                var cells: [NSCell] = matrix?.selectedCells ?? []
                if cells.isEmpty, let first = matrix?.cells.first {
                    cells = [first]
                }

                if BrowserObjC.literallyEqual(selectedLine.value(forKey: "type") as? String, "Series") {
                    AppController.shared()?.addStudyToRecentStudiesMenu((selectedLine.value(forKey: "study") as? NSManagedObject)?.objectID)
                } else {
                    AppController.shared()?.addStudyToRecentStudiesMenu((selectedLine as? NSManagedObject)?.objectID)
                }

                if cells.count > 1 && BrowserObjC.literallyEqual(selectedLine.value(forKey: "type") as? String, "Series") {
                    // Open selected images only!
                    let curList = self.childrenArray(selectedLine) ?? []
                    let selectedFilesList = cells.filter { $0.tag < curList.count }.map { curList[$0.tag] }
                    _ = self.openViewer(fromImages: [selectedFilesList], movie: movieViewer, viewer: viewer, keyImagesOnly: false)
                } else {
                    // Open series: an array of the images of each series.
                    var toOpenArray: [Any] = []
                    if cells.count == 1 && selectedLines.count > 1 {
                        // Just one thumbnail is selected, but multiple lines are selected.
                        for line in selectedLines {
                            var curFile = line as AnyObject
                            var loadList: [Any]?
                            if BrowserObjC.literallyEqual(curFile.value(forKey: "type") as? String, "Study") {
                                // Find the first series of images! Not a ROI series!
                                if let imageSeries = curFile.value(forKey: "imageSeries") as? NSArray, imageSeries.count > 0 {
                                    curFile = imageSeries[0] as AnyObject
                                    loadList = self.childrenArray(curFile)
                                }
                            }
                            if BrowserObjC.literallyEqual(curFile.value(forKey: "type") as? String, "Series") {
                                loadList = self.childrenArray(curFile)
                            }
                            if let loadList { toOpenArray.append(loadList) }
                        }
                    } else {
                        let matrixViewArray = self.horos_matrixViewArray ?? []
                        for cell in cells where matrixViewArray.count > cell.tag {
                            let curFile = matrixViewArray[cell.tag] as AnyObject
                            var loadList: [Any]?
                            if BrowserObjC.literallyEqual(curFile.value(forKey: "type") as? String, "Image") {
                                loadList = self.childrenArray(selectedLine, onlyImages: true)
                            }
                            if BrowserObjC.literallyEqual(curFile.value(forKey: "type") as? String, "Series") {
                                loadList = self.childrenArray(curFile, onlyImages: true)
                            }
                            if let loadList { toOpenArray.append(loadList) }
                        }
                    }
                    self.processOpenViewerDICOM(from: toOpenArray, movie: movieViewer, viewer: viewer)
                }

                if tileWindows {
                    let viewers = ViewerController.getDisplayed2DViewers() ?? []
                    if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                        AppController.shared()?.tileWindows(hangingProtocol.map { NSDictionary(dictionary: $0) })
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
                        AppController.shared()?.checkAllWindowsAreVisible(self, makeKey: true)
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

    // MARK: Commands

    @objc(viewerSubSeriesDICOM:)
    func viewerSubSeriesDICOM(_ sender: Any!) {
        horos_openSubSeriesFlag = true
        viewerDICOM(sender)
        horos_openSubSeriesFlag = false
    }

    @objc(viewerReparsedSeries:)
    func viewerReparsedSeries(_ sender: Any!) {
        horos_openReparsedSeriesFlag = true
        viewerDICOM(sender)
        horos_openReparsedSeriesFlag = false
    }

    /// "Open Images": with Shift the selection merged in one viewer.
    @objc(viewerDICOM:)
    func viewerDICOM(_ sender: Any!) {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
            viewerDICOMMergeSelection(sender)
        } else if window?.firstResponder === horos_databaseOutline {
            newViewerDICOM(nil)
        } else {
            newViewerDICOM(sender)
        }
    }

    /// Opens the selection: each selected study by its hanging protocol when
    /// the database list asks (no sender) with a study line and one
    /// thumbnail; otherwise the selected series, unless an external viewer
    /// opens them.
    @objc(newViewerDICOM:)
    func newViewerDICOM(_ sender: Any!) {
        var item: AnyObject?
        N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
            let outline = self.horos_databaseOutline
            item = outline.flatMap { $0.item(atRow: $0.selectedRow) as AnyObject? }
            if let e = BrowserObjC.attempt({
                if sender == nil && (self.horos_oMatrix?.selectedCells.count ?? 0) == 1
                    && BrowserObjC.literallyEqual(item?.value(forKey: "type") as? String, "Study") {
                    let array = self.databaseSelection() ?? []
                    let defaults = UserDefaults.standard
                    let savedValue = defaults.bool(forKey: "automaticWorkspaceLoad")
                    if array.count > 1 && savedValue { defaults.set(false, forKey: "automaticWorkspaceLoad") }
                    for obj in array {
                        if let outline { OutlineSelectionRestore.select(obj, in: outline, extending: false) }
                        self.databaseOpenStudy(obj as? NSManagedObject)
                    }
                    if array.count > 1 && savedValue { defaults.set(true, forKey: "automaticWorkspaceLoad") }
                } else {
                    let matrixViewArray = self.horos_matrixViewArray ?? []
                    let tag = self.horos_oMatrix?.selectedCell()?.tag ?? 0
                    if matrixViewArray.count > tag && !self.`is`(usingExternalViewer: matrixViewArray[tag] as? NSManagedObject) {
                        // To avoid loading the DCMPix in previewSliderAction
                        self.horos_dontUpdatePreviewPane = true
                        self.viewerDICOMInt(false, dcmFile: self.databaseSelection(), viewer: nil)
                        self.horos_dontUpdatePreviewPane = false
                        self.previewSliderAction(nil)
                    }
                }
            }) {
                BrowserObjC.log(e, stack: true, "-[BrowserController newViewerDICOM:]")
            }
        }

        NotificationCenter.default.post(name: .OsirixDidLoadNewObject, object: item, userInfo: nil)
        closeWaitWindowIfNecessary()
    }

    /// The selected images, all in one viewer.
    @objc(viewerDICOMMergeSelection:)
    func viewerDICOMMergeSelection(_ sender: Any!) {
        let images = NSMutableArray()
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            _ = files(forDatabaseMatrixSelection: images)
        } else {
            _ = files(forDatabaseOutlineSelection: images)
        }
        _ = openViewer(fromImages: [images], movie: false, viewer: nil, keyImagesOnly: false)
        tileOrShowViewers()
    }

    /// The images of the selection that have ROIs; with Esc down, exported
    /// and closed.
    @objc(viewerDICOMROIsImages:)
    func viewerDICOMROIsImages(_ sender: Any!) {
        let roisImagesArray = roiImages(sender) ?? []
        if !roisImagesArray.isEmpty {
            BrowserController.horos_dontShowOpenSubSeries = true
            _ = openViewer(fromImages: [roisImagesArray], movie: false, viewer: nil, keyImagesOnly: false)
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
    @objc(viewerDICOMKeyImages:)
    func viewerDICOMKeyImages(_ sender: Any!) {
        let selectedItems = NSMutableArray()
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            _ = files(forDatabaseMatrixSelection: selectedItems)
        } else {
            _ = files(forDatabaseOutlineSelection: selectedItems)
        }
        BrowserController.horos_dontShowOpenSubSeries = true
        _ = openViewer(fromImages: [selectedItems], movie: false, viewer: nil, keyImagesOnly: true)
        BrowserController.horos_dontShowOpenSubSeries = false
        tileOrShowViewers()
        #if !OSIRIX_LIGHT
        exportFirstViewerIfEscapeIsDown("Key images")
        #endif
    }

    /// The selected database lines in the 4D player.
    @objc(MovieViewerDICOM:)
    func movieViewerDICOM(_ sender: Any!) {
        let selectedItems = NSMutableArray()
        if let outline = horos_databaseOutline {
            for index in outline.selectedRowIndexes {
                if let item = outline.item(atRow: index) { selectedItems.add(item) }
            }
        }
        viewerDICOMInt(true, dcmFile: selectedItems as? [Any], viewer: nil)
    }

    /// Tiles the windows when "AUTOTILING" is on; otherwise brings them into view.
    private func tileOrShowViewers() {
        if UserDefaults.standard.bool(forKey: "AUTOTILING") {
            NSApp.sendAction(NSSelectorFromString("tileWindows:"), to: nil, from: self)
        } else {
            AppController.shared()?.checkAllWindowsAreVisible(self, makeKey: true)
        }
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
}
