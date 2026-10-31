/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXPreferences

// MARK: - The plan

/// What a print of the 2D viewer takes, computed from the print sheet before
/// a page is captured: the images (from, to, step), the number of pages, the
/// grid and the enlargement of the window and of the annotations on a page.
/// Values only: the job reads the sheet and the viewer, the plan decides.
struct ViewerPrintPlan: Sendable, Equatable {

    /// The cells of the sheet's Selection matrix, by tag.
    enum Selection: Int, Sendable {
        case currentImage = 0
        case keyImages = 1
        case range = 2
    }

    /// The first image printed (0-based).
    var from: Int32
    /// The end of the images printed, excluded.
    var to: Int32
    /// One image every `interval`.
    var interval: Int32

    /// The images of a choice of the sheet: `currentImage` is the image shown,
    /// `count` the images of the series, `first`, `last` and `step` the
    /// 1-based values of the range's sliders. A tag the matrix does not have
    /// takes no image.
    init(selection tag: Int, currentImage: Int32, count: Int32, first: Int32, last: Int32, step: Int32) {
        switch Selection(rawValue: tag) {
        case .currentImage:
            from = currentImage
            to = currentImage &+ 1
            interval = 1
        case .keyImages:
            from = 0
            to = count
            interval = 1
        case .range:
            if first < last {
                from = first &- 1
                to = last
            } else {
                to = first
                from = last &- 1
            }
            if to == from { to = from &+ 1 }
            // An interval below 1 never moved the loop forward: it takes every image.
            interval = step < 1 ? 1 : step
        case nil:
            from = 0
            to = 0
            interval = 0
        }
    }

    /// The images walked, in order: from, from + interval, ... below to.
    var indices: [Int32] {
        interval > 0 ? Array(stride(from: from, to: to, by: Int(interval))) : []
    }

    /// The maximum of the preparation's progress bar: (to - from) / interval,
    /// 0 when nothing is printed.
    var progressMaximum: Double {
        interval > 0 ? Double((to &- from) / interval) : 0
    }

    /// The pages of `images` images, `perPage` to a page (at least one), the
    /// last one partly filled.
    static func pageCount(images: Int32, perPage: Int32) -> Int32 {
        let perPage = max(perPage, 1)
        return images % perPage == 0 ? images / perPage : images / perPage &+ 1
    }

    /// The layout "adjust the format" picks for `images` images, among the
    /// tags (images per page) of the layout menu in its order: the first that
    /// holds them all, or the last one.
    static func adjustedLayoutTag(images: Int, itemTags: [Int]) -> Int {
        var index = 0, tag = 0
        repeat {
            tag = index < itemTags.count ? itemTags[index] : 0
            index += 1
        } while images > tag && index < itemTags.count
        return tag
    }

    /// The grid of a layout title, "CxR ...", as the print always read it:
    /// the values of its first and third characters (0 for none).
    static func grid(layoutTitle title: String?) -> (columns: Int32, rows: Int32) {
        let text = (title ?? "") as NSString
        func digit(_ at: Int) -> Int32 { at < text.length ? (text.substring(with: NSMakeRange(at, 1)) as NSString).intValue : 0 }
        return (digit(0), digit(2))
    }

    /// The grid a layout title names before its localized description, "2x3 ...";
    /// nil for a title that names none.
    static func dimensions(ofLayoutTitle title: String) -> (columns: Int, rows: Int)? {
        let prefix = title.prefix { $0.isASCII && ($0.isNumber || $0 == "x") }
        let dimensions = prefix.split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let columns = Int(dimensions[0]), let rows = Int(dimensions[1]),
              columns > 0, rows > 0 else { return nil }
        return (columns, rows)
    }

    /// How much larger the annotations are drawn on a page of `columns`
    /// columns: 35 % more for each column after the first, at most twice.
    static func fontIncrement(columns: Int32) -> Float {
        min(Float(1 + (Double(columns &- 1) * 0.35)), 2)
    }

    /// The size of the annotations' font on a page: the user's size, made
    /// larger by the grid and by the window's enlargement.
    static func pageFontSize(base: Float, increment: Float, scale: Float) -> Double {
        Double(base * increment * scale) * 1.2
    }

    /// How much the window is enlarged so that an image shown below 100 % is
    /// captured at 100 % (`viewScale` is the view's zoom), at most to the
    /// maximum window size shared out over the cells of the grid (by half of
    /// them, between 1 and 6); 1 when it is not enlarged.
    static func windowScale(viewScale: Float, maximumWindowSize: Int32, columns: Int32, rows: Int32, frame: CGSize) -> Float {
        var scaleFactor = Float(1.0 / Double(viewScale))
        let shares = min(max((columns &* rows) / 2, 1), 6)
        let limit = CGFloat(maximumWindowSize / shares)
        if frame.width * CGFloat(scaleFactor) > limit { scaleFactor = Float(limit / frame.width) }
        if frame.height * CGFloat(scaleFactor) > limit { scaleFactor = Float(limit / frame.height) }
        return scaleFactor <= 1.0 ? 1.0 : scaleFactor
    }
}

/// The choices of the print sheet: what the pages are drawn with (printView)
/// and what the next print starts from, kept in previousPrintSettings with the
/// keys and kinds of value it always had.
struct ViewerPrintSettings: Sendable, Equatable {
    /// The title of the layout chosen.
    var layout: String?
    var columns: Int32 = 0
    var rows: Int32 = 0
    /// The comment of the page header; nil when the header has none.
    var comments: String?
    var patientInfo = false
    var studyInfo = false
    /// White pages instead of black ones.
    var whiteBackground = false
    /// The cell of the Format matrix: 0 the view as shown, 1 the image's own size.
    var format: Int32 = 0
    var interval: Int32 = 0

    init(layout: String?, columns: Int32, rows: Int32, comments: String?, patientInfo: Bool, studyInfo: Bool,
         whiteBackground: Bool, format: Int32, interval: Int32) {
        self.layout = layout
        self.columns = columns
        self.rows = rows
        self.comments = comments
        self.patientInfo = patientInfo
        self.studyInfo = studyInfo
        self.whiteBackground = whiteBackground
        self.format = format
        self.interval = interval
    }

    /// The settings a stored dictionary holds: a header part is on when its
    /// key is there, the background is white when its three components are 1.
    init(stored values: [String: PropertyListValue]) {
        func number(_ key: String) -> Int32 {
            guard let value = values[key], value.isNumber else { return 0 }
            return Int32(truncatingIfNeeded: value.intValue)
        }
        func component(_ key: String) -> Float {
            switch values[key] {
            case .real(let value)?: return Float(value)
            case .integer(let value)?: return Float(value)
            case .boolean(let flag)?: return flag ? 1 : 0
            case .string(let text)?: return (text as NSString).floatValue
            default: return 0
            }
        }
        layout = values["layout"]?.stringValue
        columns = number("columns")
        rows = number("rows")
        comments = values["comments"]?.text
        patientInfo = values["patientInfo"] != nil
        studyInfo = values["studyInfo"] != nil
        whiteBackground = values["backgroundColor"]?.boolValue == true
            && component("backgroundColorR") == 1 && component("backgroundColorG") == 1 && component("backgroundColorB") == 1
        format = Int32(truncatingIfNeeded: values["format"]?.intValue ?? 0)
        interval = Int32(truncatingIfNeeded: values["interval"]?.intValue ?? 0)
    }

    /// The dictionary kept in previousPrintSettings and read by printView.
    var propertyList: [String: PropertyListValue] {
        let shade: PropertyListValue = .real(whiteBackground ? 1 : 0)
        var values: [String: PropertyListValue] = [
            "columns": .integer(Int(columns)), "rows": .integer(Int(rows)),
            "backgroundColor": .string("YES"),
            "backgroundColorR": shade, "backgroundColorG": shade, "backgroundColorB": shade,
            "format": .integer(Int(format)), "interval": .integer(Int(interval)),
        ]
        if let layout { values["layout"] = .string(layout) }
        if let comments { values["comments"] = .string(comments) }
        if patientInfo { values["patientInfo"] = .string("YES") }
        if studyInfo { values["studyInfo"] = .string("YES") }
        return values
    }

    /// Selects in the layout popup the grid the settings name, whatever the
    /// language the titles were saved in (the tags count images per page and
    /// cannot tell a portrait grid from a landscape one); 1x1 otherwise.
    @MainActor static func selectLayout(in popup: NSPopUpButton?, for settings: ViewerPrintSettings?) {
        guard let popup else { return }
        let columns = Int(settings?.columns ?? 0), rows = Int(settings?.rows ?? 0)
        let saved = columns > 0 && rows > 0 ? (columns: columns, rows: rows)
            : ViewerPrintPlan.dimensions(ofLayoutTitle: settings?.layout ?? "")
        let items = popup.itemArray.filter { $0.tag > 0 && ViewerPrintPlan.dimensions(ofLayoutTitle: $0.title) != nil }
        let matching = items.first { item in
            guard let saved, let grid = ViewerPrintPlan.dimensions(ofLayoutTitle: item.title) else { return false }
            return grid.columns == saved.columns && grid.rows == saved.rows
        }
        let fallback = items.first {
            ViewerPrintPlan.dimensions(ofLayoutTitle: $0.title)?.columns == 1 && ViewerPrintPlan.dimensions(ofLayoutTitle: $0.title)?.rows == 1
        }
        popup.select(matching ?? fallback ?? items.first)
    }
}

// MARK: - The job

/// The tag of an action's sender: a control, a cell or a menu item; 0 for
/// anything else, as a message to nil answered.
@MainActor func viewerActionTag(_ sender: Any?) -> Int {
    switch sender {
    case let control as NSControl: return control.tag
    case let cell as NSCell: return cell.tag
    case let item as NSMenuItem: return item.tag
    default: return 0
    }
}

/// The print of a 2D viewer: its sheet (opened from the previous settings,
/// with its page count and its range sliders), the pages prepared in a
/// private spool, and the print operation that prints them. The viewer's
/// actions, whose selectors the nibs, the menus and the former plugins use,
/// make one for each call; what lasts from one action to the next (the spool
/// and the window frame to restore) stays the viewer's.
@MainActor final class ViewerPrintJob {

    private unowned let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let registry: ViewerRegistry

    init(viewer: ViewerController, preferences: any PreferenceStore, registry: ViewerRegistry) {
        self.viewer = viewer
        self.preferences = preferences
        self.registry = registry
    }

    // MARK: The sheet

    /// Opens the print sheet on the viewer's window, set to the previous
    /// settings and to the images of the series, with the other viewers out
    /// of the way and, when the preferences ask for it, a square window.
    func openSheet() {
        let previous = preferences[VolumeRenderingPreferences.previousPrintSettings].map(ViewerPrintSettings.init(stored:))

        ViewerPrintSettings.selectLayout(in: viewer.horos_printLayout, for: previous)

        if let previous {
            viewer.horos_printSettings?.cell(withTag: 2)?.state = previous.comments != nil ? .on : .off
            viewer.horos_printSettings?.cell(withTag: 0)?.state = previous.patientInfo ? .on : .off
            viewer.horos_printSettings?.cell(withTag: 1)?.state = previous.studyInfo ? .on : .off
            let white = (viewer.horos_imageView?.whiteBackground ?? false) || previous.whiteBackground
            viewer.horos_printSettings?.cell(withTag: 3)?.state = white ? .on : .off

            _ = viewer.horos_printFormat?.selectCell(withTag: Int(previous.format))
            viewer.horos_printInterval?.intValue = previous.interval

            if let comments = previous.comments { viewer.horos_printText?.stringValue = comments }
        }

        let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0

        viewer.horos_printFrom?.maxValue = Double(count)
        viewer.horos_printTo?.maxValue = Double(count)
        viewer.horos_printFrom?.numberOfTickMarks = count
        viewer.horos_printTo?.numberOfTickMarks = count
        viewer.horos_printFrom?.intValue = 1
        viewer.horos_printTo?.intValue = Int32(truncatingIfNeeded: count)

        viewer.horos_printToText?.intValue = viewer.horos_printTo?.intValue ?? 0
        viewer.horos_printFromText?.intValue = viewer.horos_printFrom?.intValue ?? 0
        viewer.horos_printIntervalText?.intValue = viewer.horos_printInterval?.intValue ?? 0

        viewer.setCurrentdcmExport(viewer.horos_printSelection)

        updatePageCount(viewer)

        let several = count != 1
        viewer.horos_printFrom?.isEnabled = several
        viewer.horos_printTo?.isEnabled = several
        viewer.horos_printInterval?.isEnabled = several

        viewer.horos_windowFrameToRestore = NSMakeRect(0, 0, 0, 0)
        viewer.horos_scaleFitToRestore = viewer.horos_imageView?.isScaledFit() ?? false

        if preferences[ViewerPreferences.squareWindowForPrinting] {
            withoutScaleToFit {
                viewer.horos_windowFrameToRestore = viewer.window?.frame ?? NSZeroRect
                var newFrame = AppController.usefullRect(for: viewer.window?.screen)
                if newFrame.size.width < newFrame.size.height { newFrame.size.height = newFrame.size.width }
                else { newFrame.size.width = newFrame.size.height }

                AppController.resizeWindow(withAnimation: viewer.window, newSize: newFrame)
                if viewer.horos_scaleFitToRestore { viewer.horos_imageView?.scaleToFit() }
            }
        }

        for other in registry.displayedViewers where other !== viewer {
            other.window?.orderOut(viewer)
        }

        if let printWindow = viewer.horos_printWindow, let window = viewer.window {
            window.beginSheet(printWindow, completionHandler: nil)
        }
    }

    /// Shows the number of pages the sheet's choice prints, after a slider or
    /// its field changed (`sender`), and picks the layout that fits them when
    /// the preferences ask for it.
    func updatePageCount(_ sender: Any?) {
        let sent = sender as AnyObject?
        if sent === viewer.horos_printTo { viewer.horos_printToText?.intValue = viewer.horos_printTo?.intValue ?? 0 }
        if sent === viewer.horos_printFrom { viewer.horos_printFromText?.intValue = viewer.horos_printFrom?.intValue ?? 0 }
        if sent === viewer.horos_printInterval { viewer.horos_printIntervalText?.intValue = viewer.horos_printInterval?.intValue ?? 0 }

        if sent === viewer.horos_printToText { viewer.horos_printTo?.intValue = viewer.horos_printToText?.intValue ?? 0 }
        if sent === viewer.horos_printFromText { viewer.horos_printFrom?.intValue = viewer.horos_printFromText?.intValue ?? 0 }
        if sent === viewer.horos_printIntervalText { viewer.horos_printInterval?.intValue = viewer.horos_printIntervalText?.intValue ?? 0 }

        var perPage = Int32(truncatingIfNeeded: viewer.horos_printLayout?.selectedItem?.tag ?? 0)

        let selection = viewer.horos_printSelection?.selectedCell()?.tag ?? 0
        let movieIndex = Int(viewer.horos_curMovieIndex)
        let plan = ViewerPrintPlan(selection: selection,
                                   currentImage: Int32(viewer.horos_imageView?.curImage ?? 0),
                                   count: Int32(truncatingIfNeeded: viewer.horos_pixList(at: movieIndex)?.count ?? 0),
                                   first: viewer.horos_printFrom?.intValue ?? 0, last: viewer.horos_printTo?.intValue ?? 0,
                                   step: viewer.horos_printInterval?.intValue ?? 0)

        var count: Int32 = 0
        for index in plan.indices {
            if selection == ViewerPrintPlan.Selection.keyImages.rawValue {
                let image = viewer.horos_fileList(at: movieIndex)?.object(at: Int(index))
                let rois = viewer.horos_roiList(at: movieIndex)?.object(at: Int(index)) as? [Any]
                if !isKeyImage(image) && (rois?.count ?? 0) == 0 { continue }
            }
            count &+= 1
        }

        if preferences[ViewerPreferences.autoAdjustPrintingFormat], let layout = viewer.horos_printLayout {
            let tags = (layout.menu?.items ?? []).map(\.tag)
            _ = layout.selectItem(withTag: ViewerPrintPlan.adjustedLayoutTag(images: Int(count), itemTags: tags))
            perPage = Int32(truncatingIfNeeded: layout.selectedItem?.tag ?? 0)
        }

        viewer.horos_printPagesToPrint?.stringValue = String(format: NSLocalizedString("%d pages", comment: ""),
                                                             ViewerPrintPlan.pageCount(images: count, perPage: perPage))
    }

    /// Follows a range slider of the sheet: the image shown is the one the
    /// slider points at, and the page count follows.
    func followSlider(_ sender: Any?) {
        if (viewer.horos_printSelection?.selectedCell()?.tag ?? 0) == ViewerPrintPlan.Selection.range.rawValue {
            viewer.horos_printFromText?.takeIntValueFrom(viewer.horos_printFrom)
            viewer.horos_printToText?.takeIntValueFrom(viewer.horos_printTo)

            let value = (sender as? NSControl)?.intValue ?? 0
            if viewer.horos_imageView?.flippedData ?? false {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) &- Int(value)))
            } else {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: value &- 1))
            }

            viewer.horos_imageView?.sendSyncMessage(0)
            viewer.adjustSlider()
        }

        updatePageCount(viewer)
    }

    /// Closes the sheet; OK (a sender whose tag is not 0) prints its choice.
    func endSheet(_ sender: Any?) {
        viewer.checkEverythingLoaded()

        let tag = viewerActionTag(sender)
        viewer.horos_printWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        guard tag != 0 else {
            restoreWindows()
            return
        }

        let layoutTitle = viewer.horos_printLayout?.selectedItem?.title
        let grid = ViewerPrintPlan.grid(layoutTitle: layoutTitle)
        let headerCell = { (tag: Int) in (self.viewer.horos_printSettings?.cell(withTag: tag)?.state ?? .off) != .off }
        let settings = ViewerPrintSettings(layout: layoutTitle, columns: grid.columns, rows: grid.rows,
                                           comments: headerCell(2) ? viewer.horos_printText?.stringValue : nil,
                                           patientInfo: headerCell(0), studyInfo: headerCell(1),
                                           whiteBackground: headerCell(3),
                                           format: Int32(truncatingIfNeeded: viewer.horos_printFormat?.selectedCell()?.tag ?? 0),
                                           interval: viewer.horos_printInterval?.intValue ?? 0)
        preferences.set(settings.propertyList, for: VolumeRenderingPreferences.previousPrintSettings)

        let selection = viewer.horos_printSelection?.selectedCell()?.tag ?? 0
        let count = Int32(truncatingIfNeeded: viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0)
        var current = Int32(viewer.horos_imageView?.curImage ?? 0)
        if viewer.horos_imageView?.flippedData ?? false { current = count &- current &- 1 }
        let plan = ViewerPrintPlan(selection: selection, currentImage: current, count: count,
                                   first: viewer.horos_printFrom?.intValue ?? 0, last: viewer.horos_printTo?.intValue ?? 0,
                                   step: viewer.horos_printInterval?.intValue ?? 0)

        guard prepareSpoolDirectory() else {
            restoreWindows()
            presentPreparationFailure()
            return
        }

        let splash = Wait(string: NSLocalizedString("Preparing printing...", comment: ""))!
        splash.setCancel(true)
        splash.showWindow(viewer)
        splash.progress()?.maxValue = plan.progressMaximum

        let (pages, failed) = capturePages(plan, settings: settings, keyImagesOnly: selection == ViewerPrintPlan.Selection.keyImages.rawValue,
                                           splash: splash)

        let cancelled = splash.aborted()
        splash.close()
        // [splash autorelease]: alive until the pool drains, as before.
        _ = Unmanaged.passUnretained(splash).retain().autorelease()

        finish(pages: pages, settings: settings, cancelled: cancelled, failed: failed)
    }

    // MARK: The pages

    /// Captures the images of the plan into the spool, one page file each, in
    /// order: the window is put at the size and the annotations at the font of
    /// a printed cell while it captures, then everything is put back. Stops at
    /// the first page that cannot be written or when the splash is cancelled.
    private func capturePages(_ plan: ViewerPrintPlan, settings: ViewerPrintSettings, keyImagesOnly: Bool,
                              splash: Wait) -> (pages: [String], failed: Bool) {
        var pages: [String] = []
        var failed = false

        let currentImageIndex = viewer.imageIndex()
        let fontSize = preferences[ViewerPreferences.fontSize]
        let frame = viewer.window?.frame ?? NSZeroRect
        let magnetic = viewer.magnetic()
        let matrixVisible = viewer.checkFrameSize()
        let dontConstrainWindow = OSIWindow.dontConstrainWindow()
        OSIWindow.setDontConstrain(true)
        viewer.setMagnetic(false)
        viewer.setMatrixVisible(false)

        let increment = ViewerPrintPlan.fontIncrement(columns: settings.columns)

        preferences.set(false, for: ViewerPreferences.allowSmartCropping)

        var origin = viewer.window?.screen?.visibleFrame.origin ?? NSZeroPoint
        origin.y += viewer.window?.screen?.visibleFrame.size.height ?? 0

        OSIWindowController.setDontEnterMagneticFunctions(true)
        OSIWindowController.setDontEnterWindowDidChangeScreen(true)

        let previousRows = viewer.horos_seriesView?.imageRows() ?? 0, previousColumns = viewer.horos_seriesView?.imageColumns() ?? 0
        if previousRows != 1 || previousColumns != 1 {
            viewer.setImageRows(1, columns: 1)
        }

        let whiteBackground = viewer.horos_imageView?.whiteBackground ?? false
        if settings.whiteBackground {
            viewer.horos_imageView?.whiteBackground = true
        }

        for index in plan.indices {
            autoreleasepool {
                if keyImagesOnly {
                    let files = viewer.fileList()
                    let position = (viewer.horos_imageView?.flippedData ?? false) ? (files?.count ?? 0) &- 1 &- Int(index) : Int(index)
                    let rois = viewer.roiList()?.object(at: position) as? [Any]
                    if !isKeyImage(files?.object(at: position)) && (rois?.count ?? 0) == 0 {
                        splash.increment(by: 1)
                        return
                    }
                }

                viewer.setImageIndex(Int(index))

                var scale: Float = 1.0
                if preferences[ViewerPreferences.printsAt100PercentMinimum] && viewer.scaleValue() < 1.0 {
                    scale = ViewerPrintPlan.windowScale(viewScale: viewer.scaleValue(),
                                                        maximumWindowSize: Int32(truncatingIfNeeded: preferences[ViewerPreferences.maximumWindowSize]),
                                                        columns: settings.columns, rows: settings.rows, frame: frame.size)
                }
                let windowSizeChanged = scale > 1.0
                if windowSizeChanged {
                    viewer.window?.setFrame(NSMakeRect(origin.x, origin.y, frame.size.width * CGFloat(scale), frame.size.height * CGFloat(scale)), display: true)
                }

                let pageFontSize = ViewerPrintPlan.pageFontSize(base: fontSize, increment: increment, scale: scale)
                if pageFontSize != Double(preferences[ViewerPreferences.fontSize]) {
                    setFontSize(Float(pageFontSize))
                }

                var image = viewer.horos_imageView?.nsimage((viewer.horos_printFormat?.selectedCell()?.tag ?? 0) != 0)

                if windowSizeChanged {
                    setFontSize(fontSize)
                    viewer.window?.setFrame(NSMakeRect(origin.x, origin.y, frame.size.width, frame.size.height), display: true)
                }

                if settings.columns &* settings.rows > 4 {
                    image = DCMPix.resizeIfNecessary(image, dcmPix: viewer.horos_imageView?.curDCM)
                }

                if let page = writePage(image, index: index) {
                    pages.append(page)
                } else {
                    failed = true
                }

                splash.increment(by: 1)
            }

            if failed || splash.aborted() {
                break
            }
        }

        viewer.horos_imageView?.whiteBackground = whiteBackground

        preferences.set(true, for: ViewerPreferences.allowSmartCropping)

        if fontSize != preferences[ViewerPreferences.fontSize] {
            setFontSize(fontSize)
        }

        viewer.setMagnetic(magnetic)
        viewer.window?.setFrame(frame, display: true)
        // Left on, it kept every window of the app free of the screen's bounds.
        OSIWindow.setDontConstrain(dontConstrainWindow)
        viewer.setMatrixVisible(matrixVisible)

        viewer.setImageIndex(currentImageIndex)

        if previousRows != 1 || previousColumns != 1 {
            viewer.setImageRows(previousRows, columns: previousColumns)
        }

        OSIWindowController.setDontEnterMagneticFunctions(false)
        OSIWindowController.setDontEnterWindowDidChangeScreen(false)

        // Go back to initial frame
        viewer.setImageIndex(currentImageIndex)
        viewer.window?.update()
        viewer.horos_imageView?.sendSyncMessage(0)

        viewer.adjustSlider()

        return (pages, failed)
    }

    /// Prints the pages prepared, under a job title that is not the window's.
    /// A cancelled or failed preparation, or one that made no page, prints
    /// nothing, not even the pages already captured: the spool goes, the
    /// windows come back, and a failure is said.
    func finish(pages: [String], settings: ViewerPrintSettings, cancelled: Bool, failed: Bool) {
        if !cancelled && !failed && !pages.isEmpty {
            let pageView = printView(viewer: viewer, settings: settings.propertyList.mapValues(\.object) as NSDictionary,
                                     files: pages as NSArray, printInfo: NSPrintInfo.shared)

            let printOperation = NSPrintOperation(view: pageView)

            // Pagination and drawing belong to the main-actor NSView. Keep
            // AppKit's PDF rendering on that actor as well as its preview.
            printOperation.canSpawnSeparateThread = false
            // Never the window title: it carries the patient's name into the
            // printer queue and into the proposed name of a saved PDF.
            printOperation.jobTitle = "IsiX DICOM Viewer"

            if let window = viewer.window {
                printOperation.runModal(for: window,
                                        delegate: viewer,
                                        didRun: #selector(ViewerController.printOperationDidRun(_:success:contextInfo:)),
                                        contextInfo: nil)
            }
        } else {
            discardSpoolDirectory()
            restoreWindows()

            if failed {
                presentPreparationFailure()
            }
        }
    }

    /// The end of the print operation: its pages go, the windows come back.
    func operationDidRun(success: Bool) {
        if !success {
            NSLog("--- print operation ended without printing: cancelled or failed, not a success")
        }

        discardSpoolDirectory()
        restoreWindows()
    }

    /// Puts the viewer's window back to the frame it had before a square
    /// print window, and the other viewers in front again.
    func restoreWindows() {
        if preferences[ViewerPreferences.squareWindowForPrinting] && !NSIsEmptyRect(viewer.horos_windowFrameToRestore) {
            withoutScaleToFit {
                AppController.resizeWindow(withAnimation: viewer.window, newSize: viewer.horos_windowFrameToRestore)
                if viewer.horos_scaleFitToRestore { viewer.horos_imageView?.scaleToFit() }
            }
        }

        for other in registry.viewers ?? [] {
            other.window?.orderFront(viewer)
        }

        viewer.window?.makeKeyAndOrderFront(viewer)
    }

    func presentPreparationFailure() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Printing Failed", comment: "")
        alert.informativeText = NSLocalizedString("The images could not be prepared for printing. Nothing was printed.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    /// Runs `body` with AlwaysScaleToFit off, then puts back the value it had,
    /// as an integer, as it was read.
    private func withoutScaleToFit(_ body: () -> Void) {
        let key = ViewerPreferences.alwaysScaleToFit.name
        let alwaysScaleToFit = Int.reading(preferences.object(forKey: key))
        preferences.set(0, forKey: key)
        body()
        preferences.set(alwaysScaleToFit, forKey: key)
    }

    /// Changes the annotations' font, and tells the image views.
    private func setFontSize(_ size: Float) {
        preferences.set(size, for: ViewerPreferences.fontSize)
        NotificationCenter.default.post(name: .OsirixGLFontChange, object: viewer)
    }

    /// Whether a file of the viewer is a key image.
    private func isKeyImage(_ file: Any?) -> Bool {
        (file as? DicomImage)?.isKeyImage()?.boolValue ?? false
    }

    // MARK: The spool

    // The pages prepared for printing are the rendered images: the patient's
    // picture, and their name when the header option is on. They used to be
    // written to a fixed /tmp/print, a path every user of the machine can read and
    // pre-create, and the same path for every viewer and every job. The database
    // browser already prints through a private per-job spool; this is the
    // same one.

    /// Makes the job's private spool (0700), discarding the previous one.
    func prepareSpoolDirectory() -> Bool {
        discardSpoolDirectory()

        let directory = PrintSelection.newSpoolDirectory()
        do {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: false,
                                                    attributes: [FileAttributeKey.posixPermissions: NSNumber(value: 0o700)])
        } catch {
            NSLog("--- print spool directory could not be created: %@", error as NSError)
            return false
        }

        viewer.horos_printSpoolDirectory = directory
        return true
    }

    /// Removes the spool and its pages; nothing when there is none.
    func discardSpoolDirectory() {
        viewer.horos_printSpoolDirectory = Self.discardingSpool(viewer.horos_printSpoolDirectory)
    }

    /// Removes a spool and answers nil, what the viewer then keeps. Static: the
    /// viewer's teardown calls it from its deinit, where no job may be made, since
    /// forming the job's unowned reference to a deallocating viewer traps.
    static func discardingSpool(_ directory: String?) -> String? {
        if let directory {
            _ = PrintSelection.discardSpoolDirectory(directory)
        }
        return nil
    }

    // A page that could not be written must not become a path in the job: printView
    // draws nothing for a missing file, so the job would print a blank cell instead
    // of the image, without a word. The name is the frame index, never a name or an
    // identifier.

    /// Writes a page into the spool; its path, or nil when it was not written.
    func writePage(_ image: NSImage?, index: Int32) -> String? {
        guard let bitmapData = image?.tiffRepresentation, !bitmapData.isEmpty,
              let printSpoolDirectory = viewer.horos_printSpoolDirectory else {
            return nil
        }

        let path = (printSpoolDirectory as NSString).appendingPathComponent(
            PrintSelection.viewerPageTemporaryName(index: Int(index)))

        guard (bitmapData as NSData).write(toFile: path, atomically: true) else {
            return nil
        }
        return path
    }
}
