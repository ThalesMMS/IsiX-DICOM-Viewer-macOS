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
import IsiXDICOMFile
import IsiXImaging
import IsiXPreferences

// The database preview beside the study list: the thumbnails of the selected
// row in the browser's matrix, the image view showing one of their frames with
// the window the preview policy chose, the animation slider, the scroll wheel
// and the animation that move it. BrowserController keeps the selectors the
// nib, the timers, the delegates and the tools send, and hands their work to
// this pane. The decisions that need neither AppKit nor the database are
// IsiXImaging's PreviewWindowing and IsiXDatabase's PreviewAnimation and
// PreviewReuse; the thumbnails are made by ThumbnailLoader.

/// `[cell tag] < [array count]` of a signed tag: the tag compared as the
/// NSUInteger it was converted to.
private func isIndex(_ index: Int, below count: Int) -> Bool {
    UInt(bitPattern: index) < UInt(bitPattern: count)
}

/// `[object intValue]` of an NSNumber or an NSString, 0 for nil.
private func intValue(_ object: Any?) -> Int32 {
    BrowserObjC.intValue(object)
}

/// `[sender selectedCell]` of an `id` sender: nil for nil, and the same
/// unrecognized-selector exception as before for a sender without cells.
private func selectedCell(of sender: Any?) -> NSCell? {
    guard let sender = sender as AnyObject? else { return nil }
    return sender.perform(NSSelectorFromString("selectedCell"))?.takeUnretainedValue() as? NSCell
}

/// The images of a row of the study list, from its `images` set.
@MainActor private func rowImages(_ item: Any?) -> [Any] {
    (rowValue(item, "images") as? NSSet)?.allObjects ?? []
}

/// The database preview of one browser window, on the main actor with the
/// window's views. The browser makes it once and keeps it.
@MainActor final class BrowserPreviewPane {
    private unowned let browser: BrowserController
    private let processGraph: ProcessGraph
    private let preferences: any PreferenceStore
    private let loader = ThumbnailLoader()

    init(browser: BrowserController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.browser = browser
        self.processGraph = processGraph
        self.preferences = preferences
    }

    /// Whether the browser's database is not a local one: frames are then
    /// decoded as Bonjour frames.
    private var isRemote: Bool {
        !(browser.database?.isLocal() ?? false)
    }

    // MARK: - The window of the preview

    /// Records a window the preview view reports. True when it asks for the
    /// automatic window, which the caller applies once the view is done
    /// applying the one it reported.
    func needsAutomaticWindow(afterRequest level: Float, width: Float) -> Bool {
        if browser.horos_previewWindowPolicy?.recordRequested(level: level, width: width) == true {
            return false
        }
        return !PreviewWindowing.isWindowOnScreen(level: level, width: width)
    }

    /// The frame a series' defaults are read from (PreviewWindowing's middle
    /// image), decoded; the frame shown when it is that one, or when that one
    /// cannot be read.
    private func referencePix(for image: DicomImage?, shown pix: DCMPix) -> DCMPix {
        guard let image else { return pix }
        var reference: DCMPix? = nil
        if HorosObjCException.caught({
            guard let series = image.series, let images = series.sortedImages() as? [DicomImage], !images.isEmpty else { return }
            let seriesID = Int(intValue(series.id))
            let remote = isRemote
            let frame = PreviewWindowing.referenceFrame(imageCount: images.count, fileFrames: Int(image.numberOfFrames?.intValue ?? 1),
                                                        shownFrame: pix.frameNo) { index in
                (images[index] == image, Int(images[index].frameID?.intValue ?? 0))
            }
            switch frame {
            case .shown:
                return
            case .fileFrame(let middle, let frames):
                reference = DCMPix(path: image.completePath(), middle, frames, nil, middle, seriesID, isBonjour: remote, imageObj: image)
            case .seriesImage(let index, let count, let middleFrame):
                reference = DCMPix(path: images[index].completePath(), index, count, nil, middleFrame, seriesID, isBonjour: remote, imageObj: images[index])
            }
        }) != nil { reference = nil }
        guard let reference else { return pix }
        reference.checkLoad()
        return reference.notAbleToLoadImage ? pix : reference
    }

    /// Applies to the preview the window `pix` (the frame on screen when nil)
    /// should be shown with, which the policy chooses: the series' defaults
    /// when the frame starts a series or a new revision of its file, the
    /// window on screen, or the one a person chose, otherwise.
    func applyWindow(for image: DicomImage?, pix: DCMPix?) {
        guard let policy = browser.horos_previewWindowPolicy, let imageView = browser.horos_imageView,
              let shownPix = pix ?? imageView.curDCM else {
            return
        }

        // Every entry point reaches this, including the first display, which sets
        // the pixel list rather than moving the slider. When the caller has no row
        // to hand over, the frame on screen knows which one it came from.
        var image = image
        if image == nil, HorosObjCException.caught({ image = shownPix.imageObj() }) != nil {
            image = nil
        }

        var seriesKey: String? = nil
        var path: String? = nil
        var refused = false
        if HorosObjCException.caught({
            // A Structured Report or a Segmentation has no frame to window; the
            // preview keeps its icon and the policy is not consulted.
            if let frame = BrowserController.horos_previewFrame(for: image, frame: Int32(truncatingIfNeeded: shownPix.frameNo)),
               PreviewIdentity.refusalForPreviewing(frame) != nil {
                refused = true
                return
            }
            seriesKey = image?.series?.seriesDICOMUID
            path = image?.completePath()
            if (seriesKey ?? "").isEmpty {
                seriesKey = "series.id " + (image?.series?.id.map { $0.description } ?? "(null)")
            }
        }) != nil { seriesKey = nil }
        if refused { return }

        if (path ?? "").isEmpty {
            path = shownPix.srcFile
        }

        let needsDefaults = policy.beginFrame(seriesKey: seriesKey, path: path, revisionKey: shownPix.parsedFileCacheKey())
        let window: PreviewWindow?
        if needsDefaults {
            // The defaults belong to the series, so they come from its middle
            // image; the frame shown keeps its own identity above.
            let reference = referencePix(for: image, shown: shownPix)
            let isColor = reference.isColorPreviewFrame()
            let modality = reference.modalityString
            let storedRange = reference.storedRangePreviewWindow() as? PreviewWindow
            var dicomWindow = reference.dicomPreviewWindow() as? PreviewWindow
            // A window that only restates the stored bit range says nothing
            // about this picture; the ladder treats it as absent.
            if PreviewWindowPolicy.isStoredRange(dicomWindow, storedRange: storedRange, slope: reference.slope, intercept: reference.offset) {
                dicomWindow = nil
            }
            // Sampling the frame costs a pass over the pixels. Only pay for it when
            // the ladder can actually reach the computed window.
            var automatic: PreviewWindow? = nil
            if PreviewWindowPolicy.needsAutomaticWindow(modality: modality, dicom: dicomWindow, isColor: isColor) {
                automatic = reference.automaticPreviewWindow() as? PreviewWindow
            }
            var frameRange: PreviewWindow? = nil
            if PreviewWindowing.needsFrameRange(hasAutomaticWindow: automatic != nil, isColor: isColor,
                                                hasValidFileWindow: dicomWindow?.isValid == true) {
                frameRange = reference.frameRangePreviewWindow() as? PreviewWindow
            }
            window = policy.window(modality: modality, dicom: dicomWindow, automatic: automatic,
                                   frameRange: frameRange, storedRange: storedRange, isColor: isColor)
        } else {
            // Same series, same revision: whatever is on screen stays, and an
            // adjustment a person made outlives the scroll and the late batch.
            window = policy.manualWindow ?? policy.appliedWindow
        }

        guard let window, window.isValid else { return }

        var pixelsLevel: Float = 0, pixelsWidth: Float = 0
        imageView.getWLWW(&pixelsLevel, &pixelsWidth)
        let shown = PreviewWindowing(pixels: WindowLevelState(level: pixelsLevel, width: pixelsWidth), view: imageView.windowLevelState)
        if shown.isShowing(level: window.level, width: window.width) { return }

        imageView.apply(window)
    }

    // MARK: - The slider

    /// Shows the frame the animation slider is on: of the selected multiframe
    /// image, of the selected series, or of the selected thumbnail's series.
    func showSliderFrame(sender: Any?) {
        guard let cell = browser.horos_oMatrix?.selectedCell(), !browser.horos_dontUpdatePreviewPane, cell.isEnabled else { return }
        let rows = browser.horos_matrixViewArray ?? []
        if !isIndex(cell.tag, below: rows.count) { return }

        let outline = browser.horos_databaseOutline
        let item = outline.flatMap { $0.item(atRow: $0.selectedRow) }
        let slider = browser.horos_animationSlider
        let position = Int(slider?.intValue ?? 0)
        let images = rowImages(item)

        if isRowType(item, "Series") && images.count == 1 && intValue((images[0] as? DicomImage)?.numberOfFrames) > 1 {
            // A multiframe image that is directly selected.
            let image = images[0] as? DicomImage
            let frames = Int(intValue(image?.numberOfFrames))
            // Already on a 2D viewer? Its frame is lent.
            let pix: DCMPix? = Self.lentFrame(path: image?.completePath(), frame: Int32(truncatingIfNeeded: position),
                                              expected: BrowserController.horos_previewFrame(for: image, frame: Int32(truncatingIfNeeded: position)))
                ?? DCMPix(path: image?.completePath(), position, frames, nil, position, Int(intValue(image?.series?.id)), isBonjour: isRemote, imageObj: image)
            if let pix {
                HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
                    browser.horos_previewPix?.replaceObject(at: cell.tag, with: pix)
                }
                browser.horos_imageView?.setIndex(cell.tag)
                // The window this frame is shown with, and why.
                applyWindow(for: image, pix: pix)
            }
        } else if isRowType(item, "Study") || (isRowType(item, "Series") && images.count > 1) {
            let list: [Any]
            if isRowType(item, "Study") {
                list = browser.imagesArray(rows[cell.tag]) ?? []
            } else {
                list = browser.imagesArray(item) ?? []
                if sender != nil {
                    browser.horos_oMatrix?.selectCell(withTag: position)
                }
            }
            guard !list.isEmpty else { return }
            let frames = list.count > 1 ? list.count : Int(intValue((list[0] as? DicomImage)?.numberOfFrames))
            let curDCM = browser.horos_imageView?.curDCM

            if list.count > 1 || frames == 1 {
                if !isIndex(position, below: list.count) { return }
                let image = list[position] as? DicomImage
                let frameID = intValue(image?.frameID)
                guard !BrowserObjC.literallyEqual(curDCM?.srcFile, image?.completePath()) || Int(frameID) != (curDCM?.frameNo ?? 0) else { return }
                let pix: DCMPix? = Self.lentFrame(path: image?.completePath(), frame: frameID,
                                                  expected: BrowserController.horos_previewFrame(for: image, frame: frameID))
                    ?? DCMPix(path: image?.completePath(), position, list.count, nil, Int(frameID), Int(intValue(image?.series?.id)), isBonjour: isRemote, imageObj: image)
                if let pix { show(pix, of: image, at: cell.tag) }
            } else if frames > 1 {
                // A single multiframe image.
                let first = list[0] as? DicomImage
                let seriesID = Int(intValue(first?.series?.id))
                guard !BrowserObjC.literallyEqual(curDCM?.srcFile, first?.completePath())
                        || (curDCM?.frameNo ?? 0) != position || (curDCM?.serieNo ?? 0) != seriesID else { return }
                let pix: DCMPix? = Self.lentFrame(path: first?.completePath(), frame: Int32(truncatingIfNeeded: position),
                                                  expected: BrowserController.horos_previewFrame(for: first, frame: Int32(truncatingIfNeeded: position)))
                    ?? DCMPix(path: first?.completePath(), position, frames, nil, position, seriesID, isBonjour: isRemote, imageObj: first)
                if let pix { show(pix, of: first, at: cell.tag) }
            }
        }
    }

    /// Puts `pix` in the preview list at `tag`, shows it with its window, and
    /// frees the pixels of the other frames. The frame it replaces is kept
    /// until then, so that DCMPix's cache does not reload it; the frame the
    /// view draws, which setIndex: clamps, is not freed under it.
    private func show(_ pix: DCMPix, of image: DicomImage?, at tag: Int) {
        HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
            let previous = browser.horos_previewPix?.object(at: tag)
            browser.horos_previewPix?.replaceObject(at: tag, with: pix)

            if BrowserController.horos_withReset {
                browser.horos_imageView?.setIndexWithReset(tag, true)
            } else {
                browser.horos_imageView?.setIndex(tag)
            }

            applyWindow(for: image, pix: pix)

            _ = HorosObjCException.caught {
                let drawn = browser.horos_imageView?.curDCM
                for case let other as DCMPix in browser.horos_previewPix ?? [] where other !== pix && other !== drawn {
                    other.kill8bitsImage()
                    other.revert(false)
                }
            }
            withExtendedLifetime(previous) {}
        }
    }

    /// One step of the animation, every 0.15 s while the animation box is
    /// checked and the window is the key one.
    func performAnimation() {
        if processGraph.isSessionInactive || BrowserController.horos_waitForRunningProcess { return }
        // Wait loading all images.
        if browser.database == nil { return }
        if (browser.horos_animationCheck?.state ?? .off) == .off { return }
        if (browser.window?.isKeyWindow ?? false) == false { return }
        guard let slider = browser.horos_animationSlider, slider.isEnabled else { return }

        slider.intValue = PreviewWindowing.nextAnimationPosition(from: slider.intValue, maxValue: slider.maxValue)
        showSliderFrame(sender: nil)
    }

    /// Moves the slider one image for a wheel event over the preview. A wheel
    /// delivers one notch at a time and each one used to decode a frame before
    /// the next arrived: only the newest position is kept - the slider already
    /// holds it - so one burst costs one decode and the frame finally drawn is
    /// the one asked for.
    func scroll(with event: NSEvent) {
        let slider = browser.horos_animationSlider
        guard let position = PreviewWindowing.wheelPosition(from: slider?.intValue ?? 0, deltaY: Double(event.deltaY),
                                                            reversed: preferences[ViewerPreferences.scrollWheelReversed],
                                                            maxValue: slider?.maxValue ?? 0) else { return }
        slider?.intValue = position

        if let coalescer = browser.horos_previewRedrawCoalescer {
            coalescer.request { [unowned browser = self.browser] in browser.previewSliderAction(slider) }
            if event.phase == .ended || event.momentumPhase == .ended {
                coalescer.flush()
            }
        } else {
            browser.previewSliderAction(slider)
        }
    }

    /// The slider for the selected thumbnail: one step per image of its
    /// series, or disabled; and the preview back on its first frame.
    func initAnimationSlider() {
        let slider = browser.horos_animationSlider

        guard var cell = browser.horos_oMatrix?.selectedCell() as? NSButtonCell else {
            disableAnimation(slider)
            resetPreviewToSlider(slider)
            return
        }
        // A cell that names no row (a placeholder of a series left out, with
        // its negative tag) falls back to the first row's thumbnail.
        if ThumbnailCellTag.rowIndex(tag: cell.tag, count: (browser.horos_matrixViewArray ?? []).count) == nil {
            browser.horos_oMatrix?.selectCell(withTag: 0)
            guard let first = browser.horos_oMatrix?.selectedCell() as? NSButtonCell else {
                // [nil tag] is 0: the thumbnail of the first row.
                return animate(slider, tag: 0)
            }
            cell = first
        }
        animate(slider, tag: cell.tag)
    }

    private func animate(_ slider: NSSlider?, tag: Int) {
        let outline = browser.horos_databaseOutline
        let file = outline?.item(atRow: outline?.selectedRow ?? -1)
        let images = { rowImages(file) }

        let frames = PreviewAnimation.frames(
            type: rowValue(file, "type"),
            seriesImageCount: { images().count },
            firstImageFrames: { rowValue(images().first, "numberOfFrames") },
            studyImages: {
                let rows = self.browser.horos_matrixViewArray ?? []
                guard !rows.isEmpty else { return nil }
                guard rows.indices.contains(tag) else { raiseOutOfRange(tag, rows.count); return nil }
                guard let images = self.browser.imagesArray(rows[tag]) else { return nil }
                return (images.count, { images.isEmpty ? nil : rowValue(images[0], "numberOfFrames") })
            })

        switch frames {
        case .refresh:
            browser.outlineViewRefresh()
            browser.refreshMatrix(browser)
            return
        case .slider(let animate, let count):
            switch PreviewAnimation.sliderChange(animate: animate, sliderEnabled: slider?.isEnabled ?? false, images: count) {
            case .disable:
                disableAnimation(slider)
            case .enable(let images):
                slider?.isEnabled = true
                slider?.maxValue = Double(images - 1)
                slider?.numberOfTickMarks = images
                slider?.intValue = 0
            case .keep:
                break
            }
        }
        resetPreviewToSlider(slider)
    }

    func disableAnimation(_ slider: NSSlider?) {
        slider?.isEnabled = false
        slider?.maxValue = 0
        slider?.numberOfTickMarks = 1
        slider?.intValue = 0
    }

    /// The preview shows the slider's image, from its first frame.
    private func resetPreviewToSlider(_ slider: NSSlider?) {
        BrowserController.horos_withReset = true
        browser.previewSliderAction(slider)
        BrowserController.horos_withReset = false
    }

    // MARK: - The thumbnails

    /// The thumbnail pressed: the slider on it for a series of several
    /// images, the preview on it otherwise.
    func matrixPressed(_ sender: Any?) {
        let cell = selectedCell(of: sender)
        let tag = cell?.tag ?? 0
        let slider = browser.horos_animationSlider
        browser.window?.makeFirstResponder(browser.horos_oMatrix)

        let outline = browser.horos_databaseOutline
        let selectedRow = { outline.flatMap { $0.item(atRow: $0.selectedRow) } }
        if tag >= 0 {
            let row = selectedRow()
            if isRowType(row, "Series") && rowImages(row).count > 1 {
                slider?.intValue = Int32(truncatingIfNeeded: tag)
                browser.previewSliderAction(nil)
                return
            }
        }

        disableAnimation(slider)

        if tag >= 0 {
            if !isRowType(selectedRow(), "Study") {
                browser.horos_imageView?.setIndex(Int(Int32(truncatingIfNeeded: tag)))
            }
            initAnimationSlider()
        }

        browser.resetROIsAndKeysButton()
    }

    /// The thumbnails' cells for `count` rows, empty and "loading...", with a
    /// new preview list: what a load still running made for the previous one
    /// is discarded by the generation.
    func matrixInit(_ count: Int) {
        HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
            browser.horos_previewPix = NSMutableArray()
            // A load that started before this point is now publishing into a
            // list nobody is showing. Pointer identity alone cannot say so: the
            // allocator may hand the same address back.
            browser.horos_incrementPreviewPixGeneration()
            browser.horos_previewPixThumbnails?.removeAllObjects()
        }

        HorosObjCException.synchronized(browser) {
            browser.horos_setDCMDone = false
            browser.horos_loadPreviewIndex = 0

            matrixFrameDidChange()

            let matrix = browser.horos_oMatrix
            var rows = 0, columns = 0
            matrix?.getNumberOfRows(&rows, columns: &columns)
            if columns < 1 { columns = 1 }
            let font = NSFont.systemFont(ofSize: CGFloat(browser.fontSize("dbMatrixFont")))
            for i in 0..<max(rows * columns, 0) {
                let cell = matrix?.cell(atRow: i / columns, column: i % columns) as? NSButtonCell
                cell?.tag = i
                cell?.isTransparent = i >= count
                cell?.isEnabled = false
                cell?.font = font
                cell?.imagePosition = .imageBelow
                cell?.title = NSLocalizedString("loading...", comment: "")
                cell?.image = nil
                cell?.bezelStyle = .shadowlessSquare
            }

            browser.horos_imageView?.setPixels(nil, files: nil, rois: nil, firstImage: 0, level: 0, reset: true)
            browser.horosLayOutExcludedSeriesCells()
        }
    }

    /// The cell of thumbnail `index` of the matrix.
    private func matrixCell(_ index: Int) -> NSButtonCell? {
        let matrix = browser.horos_oMatrix
        var rows = 0, columns = 0
        matrix?.getNumberOfRows(&rows, columns: &columns)
        if columns < 1 { columns = 1 }
        return matrix?.cell(atRow: index / columns, column: index % columns) as? NSButtonCell
    }

    /// Shows the thumbnail `index` made for `file`, a series or an image of
    /// the thumbnails: its icon, its title and its menu; the first one shown
    /// also puts the preview list on the image view.
    func showIcon(_ index: Int, of file: NSManagedObject?) {
        guard let file else {
            browser.horos_oMatrix?.needsDisplay = true
            return
        }

        var icon: NSImage? = nil
        let available: Bool = HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
            guard isIndex(index, below: browser.horos_previewPix?.count ?? 0),
                  isIndex(index, below: browser.horos_previewPixThumbnails?.count ?? 0) else { return false }
            icon = browser.horos_previewPixThumbnails?.object(at: index) as? NSImage
            if icon == nil { NSLog("Error: [previewPixThumbnails objectAtIndex: i] == nil") }
            return true
        }
        if !available { return }

        if let raised = HorosObjCException.caught({ self.describeIcon(index, of: file, icon: icon) }) {
            if raised.name != .objectInaccessibleException {
                BrowserObjC.log(raised, stack: true, "-[BrowserController matrixNewIcon::]")
            }
        }
        browser.horos_oMatrix?.needsDisplay = true
    }

    private func describeIcon(_ index: Int, of file: NSManagedObject, icon: NSImage?) {
        var icon = icon
        let image = file as? DicomImage
        let series = image == nil ? file as? DicomSeries : nil
        let anyImage = series?.images?.first as? DicomImage
        let modality = image?.modality ?? anyImage?.modality
        let sopClassUID = image?.series?.seriesSOPClassUID ?? series?.seriesSOPClassUID
        let fileType = image?.fileType() ?? anyImage?.fileType()

        if let series, icon !== browser.horos_notFoundImage, series.thumbnail == nil,
           preferences[DatabasePreferences.storeThumbnailsInDB] {
            series.thumbnail = BrowserController.produceJPEGThumbnail(icon)
        }

        let isRT = modality?.hasPrefix("RT") == true
        guard icon != nil || isRT else {
            showUnreadable(index)
            return
        }

        let cell = matrixCell(index)
        cell?.lineBreakMode = .byCharWrapping
        cell?.font = NSFont.systemFont(ofSize: CGFloat(browser.fontSize("dbMatrixFont")))
        cell?.representedObject = file.objectID
        cell?.imagePosition = .imageBelow
        cell?.isTransparent = false
        cell?.isEnabled = true
        cell?.setButtonType(.pushOnPushOff)
        cell?.bezelStyle = .shadowlessSquare
        cell?.imageScaling = .scaleProportionallyDown
        cell?.isBordered = true
        cell?.action = #selector(BrowserController.matrixPressed(_:))

        if modality == "RTSTRUCT" {
            BrowserController.horos_contextualRTMenu?.item(at: 0)?.action = #selector(BrowserController.createROIsFromRTSTRUCT(_:))
            cell?.menu = BrowserController.horos_contextualRTMenu
        } else {
            cell?.menu = BrowserController.horos_contextualMenu
        }

        var name = (rowValue(file, "name") as? String) ?? ""
        if (name as NSString).length > 18 {
            cell?.font = NSFont.systemFont(ofSize: CGFloat(browser.fontSize("dbSmallMatrixFont")))
            name = (name as NSString).stringByTruncating(toLength: 36) as String // 2 lines
        }
        if (name as NSString).length == 0, let modality {
            name = modality
        }
        let shownName = (name.isEmpty && modality == nil) ? "(null)" : name

        let isDocument = DICOMSOPClass.isStructuredReport(sopClassUID) || DICOMSOPClass.isPDF(sopClassUID)
        if isRT {
            cell?.title = shownName + "\r" + (modality ?? "(null)")
        } else if fileType == "DICOMMPEG2" {
            let count = intValue(rowValue(file, "noFiles"))
            cell?.title = String(format: NSLocalizedString("MPEG-2 Series\r%@\r%d Images", comment: ""), shownName, count)
            icon = Bundle.main.pathForImageResource("mpeg2").flatMap { NSImage(contentsOfFile: $0) }
        } else if let series {
            cell?.title = shownName + "\r" + seriesCount(series, isDocument: isDocument)
        } else if image != nil {
            if isDocument {
                cell?.title = String(format: NSLocalizedString("Page %d", comment: ""), Int32(truncatingIfNeeded: index + 1))
            } else if let location = image?.sliceLocation?.floatValue, location != 0 {
                cell?.title = String(format: NSLocalizedString("Image %d\r%.2f", comment: ""), Int32(truncatingIfNeeded: index + 1), Double(location))
            } else {
                cell?.title = String(format: NSLocalizedString("Image %d", comment: ""), Int32(truncatingIfNeeded: index + 1))
            }
        }

        cell?.setButtonType(.pushOnPushOff)

        if Self.displayUsesInvertedPolarity {
            icon = icon?.imageInverted()
        }

        cell?.highlightsBy = [] // don't show highlight
        switch preferences[ViewerPreferences.databaseFontSize] {
        case -1: cell?.image = icon?.imageByScalingProportionallyUsingNSImage(0.6)
        case 0: cell?.image = icon
        case 1: cell?.image = icon?.imageByScalingProportionallyUsingNSImage(1.3)
        default: break
        }

        if !browser.horos_setDCMDone {
            let outline = browser.horos_databaseOutline
            if let first = outline?.selectedRowIndexes.first {
                let row = outline?.item(atRow: first)

                // Before the pixels: a view not yet named the preview compares
                // the first and last images' slice locations, which decodes both -
                // two whole radiographs of a study of single-image series, on
                // the main thread.
                browser.horos_imageView?.stringID = "previewDatabase"

                HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
                    let files = browser.imagesArray(row, preferredObject: SelectionImages.any) as NSArray?
                    browser.horos_imageView?.setPixels(browser.horos_previewPix, files: files, rois: nil,
                                                       firstImage: browser.horos_oMatrix?.selectedCell()?.tag ?? 0,
                                                       level: CChar(UInt8(ascii: "i")), reset: true)
                }

                // The first frame of a new selection: choose its window here
                // too, not only when the slider moves.
                applyWindow(for: nil, pix: nil)

                browser.horos_setDCMDone = true
            }
        }
    }

    /// "1 Image", "3 Frames", "2 Pages", "4 Objects": what a series' thumbnail counts.
    private func seriesCount(_ series: DicomSeries, isDocument: Bool) -> String {
        var count = intValue(series.noFiles())
        let firstImageFrames = { intValue((series.images?.first as? DicomImage)?.numberOfFrames) }
        let singular: String, plural: String
        if isDocument {
            if count <= 1 && firstImageFrames() >= 1 { count = firstImageFrames() }
            singular = NSLocalizedString("Page", comment: "")
            plural = NSLocalizedString("Pages", comment: "")
        } else if count == 1 && firstImageFrames() > 1 {
            count = firstImageFrames()
            singular = NSLocalizedString("Frame", comment: "")
            plural = NSLocalizedString("Frames", comment: "")
        } else if count == 0 {
            count = intValue(series.rawNoFiles())
            if count <= 1 && firstImageFrames() >= 1 { count = firstImageFrames() }
            singular = NSLocalizedString("Object", comment: "")
            plural = NSLocalizedString("Objects", comment: "")
        } else {
            singular = NSLocalizedString("Image", comment: "")
            plural = NSLocalizedString("Images", comment: "")
        }
        return BrowserObjC.singularPlural(Int(count), singular, plural)
    }

    /// The cell of a thumbnail whose file cannot be read.
    private func showUnreadable(_ index: Int) {
        guard let cell = matrixCell(index) else { return }
        cell.lineBreakMode = .byCharWrapping
        cell.font = NSFont.systemFont(ofSize: CGFloat(browser.fontSize("dbMatrixFont")))
        cell.representedObject = nil
        cell.imagePosition = .imageBelow
        cell.isTransparent = false
        cell.isEnabled = false
        cell.setButtonType(.pushOnPushOff)
        cell.bezelStyle = .shadowlessSquare
        cell.imageScaling = .scaleProportionallyDown
        cell.isBordered = true
        browser.horos_oMatrix?.setToolTip(NSLocalizedString("File not readable", comment: ""), for: cell)
        cell.title = NSLocalizedString("File not readable", comment: "")
        cell.image = nil
        cell.tag = index
    }

    /// Whether the display shows inverted colours (Accessibility), which the
    /// thumbnails follow: the system's own preference.
    private static var displayUsesInvertedPolarity: Bool {
        let value = CFPreferencesCopyValue("DisplayUseInvertedPolarity" as CFString, "com.apple.CoreGraphics" as CFString,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }

    /// Shows the thumbnails made so far whose cells are still waiting.
    func displayIcons() {
        if browser.database == nil { return }
        if processGraph.isSessionInactive || BrowserController.horos_waitForRunningProcess { return }

        if let raised = HorosObjCException.caught({
            HorosObjCException.synchronized(self.browser.horos_previewPixThumbnails) {
                let count = self.browser.horos_previewPix?.count ?? 0
                guard count > 0 && isIndex(self.browser.horos_loadPreviewIndex, below: count) else { return }
                var i = 0
                while isIndex(i, below: self.browser.horos_previewPix?.count ?? 0) {
                    if self.matrixCell(i)?.isEnabled != true {
                        let rows = self.browser.horos_matrixViewArray ?? []
                        if isIndex(i, below: rows.count) {
                            self.showIcon(i, of: rows[i] as? NSManagedObject)
                        }
                    }
                    i += 1
                }

                if self.browser.horos_oMatrix?.selectedCell() == nil && !(self.browser.horos_matrixViewArray ?? []).isEmpty {
                    self.browser.horos_oMatrix?.selectCell(withTag: 0)
                }
                if self.browser.horos_loadPreviewIndex == 0 {
                    self.initAnimationSlider()
                }
                self.browser.horos_loadPreviewIndex = i
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController matrixDisplayIcons:]")
        }
    }

    /// Lays the matrix out for its width: as many columns as fit, the rows
    /// the series and the placeholders of those a node's rule left out need.
    func matrixFrameDidChange() {
        let cellCount = (browser.horos_matrixViewArray?.count ?? 0) + browser.horosExcludedSeries.count
        if cellCount == 0 { return }

        guard let matrix = browser.horos_oMatrix else { return }
        let selectedTag = matrix.selectedCell()?.tag ?? 0
        let cellWidth = matrix.cellSize.width + matrix.intercellSpacing.width
        let width = (browser.horos_thumbnailsScrollView?.bounds.size.width ?? 0) + matrix.intercellSpacing.width
        guard cellWidth > 0 else { return }

        let columns = Self.int(roundf(Float(width / cellWidth)))
        guard columns > 0 else { return }
        let rows = max(Self.int(ceilf(Float(1.0 * Double(cellCount) / Double(columns)))), 1)

        matrix.renewRows(rows, columns: columns)
        HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
            var i = browser.horos_previewPix?.count ?? 0
            while i < columns * rows {
                let cell = matrix.cell(atRow: i / columns, column: i % columns) as? NSButtonCell
                cell?.isTransparent = true
                cell?.isEnabled = false
                i += 1
            }
        }
        browser.horosLayOutExcludedSeriesCells()
        matrix.sizeToCells()
        matrix.selectCell(withTag: selectedTag)
    }

    /// A float converted to an int as arm64 converts it: NaN is 0, and a
    /// value out of range saturates, where Swift would trap.
    private static func int(_ value: Float) -> Int {
        if value.isNaN { return 0 }
        if value >= Float(Int.max) { return Int.max }
        if value <= Float(Int.min) { return Int.min }
        return Int(value)
    }

    /// Forgets the thumbnails stored for the selected studies and series, and
    /// shows the matrix again, which makes them anew.
    func rebuildThumbnails() {
        if let raised = HorosObjCException.caught({
            let outline = self.browser.horos_databaseOutline
            if (outline?.selectedRow ?? 0) >= 0 {
                for row in outline?.selectedRowIndexes ?? [] {
                    let item = outline?.item(atRow: row)
                    if isRowType(item, "Study") {
                        for case let series as DicomSeries in self.browser.childrenArray(item) ?? [] { series.thumbnail = nil }
                    }
                    if isRowType(item, "Series") {
                        (item as? DicomSeries)?.thumbnail = nil
                    }
                }
            }
            _ = self.browser.database?.save(nil)
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController rebuildThumbnails:]")
        }
        browser.refreshMatrix(browser)
    }

    // MARK: - Showing a row's thumbnails

    /// The thumbnails of the selected row, keeping the selected ones when the
    /// row is the same, and the load of those still to make: on the main
    /// actor for the few thumbnails of a series, by the loader otherwise.
    func showThumbnails(of item: Any, sameRow: Bool) {
        var files: [Any] = []
        var selectedCells: [(id: Any, row: Int, column: Int)] = []
        var imageLevel = false
        let matrix = browser.horos_oMatrix

        N2ManagedObjectContextPerformAndWait(browser.database?.managedObjectContext) {
            if let raised = HorosObjCException.caught({
                self.disableAnimation(self.browser.horos_animationSlider)

                if OutlineSelection.showsFrames(type: rowValue(item, "type"),
                                                imageCount: { rowImages(item).count },
                                                frames: { rowValue(rowImages(item).first, "numberOfFrames") }) {
                    self.browser.horos_matrixViewArray = [item]
                } else {
                    self.browser.horos_matrixViewArray = self.browser.childrenArray(item)
                }
                self.browser.horosPrepareExcludedSeries(of: item)

                if sameRow {
                    for case let cell as NSButtonCell in matrix?.cells ?? [] {
                        var row = 0, column = 0
                        if cell.state == .on && !cell.isTransparent && (matrix?.getRow(&row, column: &column, of: cell) ?? false),
                           let represented = cell.representedObject {
                            selectedCells.append((represented, row, column))
                        }
                    }
                } else {
                    matrix?.selectCell(withTag: 0)
                }

                self.matrixInit(self.browser.horos_matrixViewArray?.count ?? 0)

                files = self.browser.imagesArray(item, preferredObject: SelectionImages.firstForFirst) ?? []
                imageLevel = item is DicomSeries

                if let thumbnails = self.browser.horos_previewPixThumbnails {
                    HorosObjCException.synchronized(thumbnails) {
                        for _ in files { thumbnails.add(self.browser.horos_notFoundImage ?? NSImage()) }
                    }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewSelectionDidChange:]")
            }
        }

        // If series level, and less than 5 thumbnails to compute: do it on the
        // main actor: faster, and no blinking icons.
        let onLoader = OutlineSelection.iconsOnSeparateThread(imageLevel: imageLevel, missingThumbnails: {
            files.filter { (rowValue($0, "series") as? NSManagedObject)?.primitiveValue(forKey: "thumbnail") == nil }.count
        })

        HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
            browser.horos_matrixLoadIconsThread?.cancel()
            browser.horos_matrixLoadIconsThread = nil

            let request = ThumbnailRequest(objectIDs: files.compactMap { ($0 as? NSManagedObject)?.objectID },
                                           imageLevel: imageLevel, database: browser.horos_databaseIvar,
                                           list: browser.horos_previewPix, generation: browser.horos_previewPixGeneration,
                                           notFound: browser.horos_notFoundImage ?? NSImage(), state: browser.previewState)
            if onLoader {
                // The task keeps the pane until the load ends; the browser keeps
                // the pane for its whole life anyway.
                let loader = self.loader
                browser.horos_matrixLoadIconsThread = ThumbnailLoad(task: Task {
                    await loader.load(request) { batch, final in self.accept(batch, final: final) }
                })

                if sameRow {
                    for cell in matrix?.cells ?? [] {
                        cell.state = .off
                        cell.isHighlighted = false
                    }
                    for selected in selectedCells {
                        let cell = matrix?.cell(atRow: selected.row, column: selected.column)
                        cell?.state = .on
                        cell?.isHighlighted = true
                    }
                }
            } else {
                if let batch = ThumbnailLoader.make(request, database: request.database, isCancelled: { false }, progress: nil) {
                    publish(batch)
                }
                displayIcons()
                if sameRow {
                    matrix?.deselectAllCells()
                    var first = true
                    for cell in matrix?.cells ?? [] {
                        guard let represented = cell.representedObject as? NSObject,
                              selectedCells.contains(where: { ($0.id as? NSObject)?.isEqual(represented) == true }) else { continue }
                        if first {
                            matrix?.selectCell(cell)
                            first = false
                        } else {
                            cell.isHighlighted = true
                            cell.state = .on
                        }
                    }
                    browser.matrixPressed(matrix)
                }
            }
        }
    }

    /// A batch the loader made, on the main actor: published unless the load
    /// was cancelled, and the thumbnails shown at the end of the load.
    private func accept(_ batch: ThumbnailBatch, final: Bool) {
        if !batch.cancelled {
            publish(batch)
        }
        displayIcons()
        _ = final
    }

    /// Puts the thumbnails and frames of `batch` in the preview lists, when
    /// they are still the lists the load was asked for.
    private func publish(_ batch: ThumbnailBatch) {
        HorosObjCException.synchronized(browser.horos_previewPixThumbnails) {
            guard browser.horos_previewPix === batch.list && browser.horos_previewPixGeneration == batch.generation else { return }
            browser.horos_previewPixThumbnails?.setArray(batch.thumbnails)
            browser.horos_previewPix?.setArray(batch.frames)
        }
    }

    // MARK: - A frame a viewer has loaded

    /// A copy of a frame a 2D viewer has loaded, when it is the frame asked
    /// for: the same file and frame, and, given the frame expected, the same
    /// instance, series and size. Frame 0 used to match on the path alone; a
    /// multiframe file is one row per frame in a viewer's file list, so that
    /// returned whichever frame of the file the viewer happened to hold. A file
    /// rewritten, replaced or removed since the viewer decoded it is not lent.
    /// Main thread only: elsewhere, nil.
    nonisolated static func lentFrame(path: String?, frame: Int32, expected: PreviewFrame?) -> DCMPix? {
        guard Thread.isMainThread else { return nil }
        let expected = LentExpectation(frame: expected)
        return MainActor.assumeIsolated {
            LentPreviewFrame(pix: lentFrameOnMainActor(path: path, frame: frame, expected: expected.frame))
        }.pix
    }

    private static func lentFrameOnMainActor(path pathToFind: String?, frame frameNumber: Int32, expected: PreviewFrame?) -> DCMPix? {
        var lent: DCMPix? = nil
        for case let viewer as ViewerController in (ViewerController.get2DViewers() as? [Any]) ?? [] where !viewer.windowWillClose() {
            // The lists are copied: the viewer may change them meanwhile.
            var fileList: [Any] = [], pixList: [Any] = []
            if let raised = HorosObjCException.caught({
                fileList = (viewer.fileList() as? [Any]) ?? []
                pixList = (viewer.pixList() as? [Any]) ?? []
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame:]")
            }
            let volumeData = viewer.volumeData()

            if let raised = HorosObjCException.caught({
                var index = PreviewReuse.index(count: fileList.count,
                                               path: { rowValue(fileList[$0], "completePath") },
                                               frame: { rowValue(fileList[$0], "frameID") },
                                               pathToFind: pathToFind, frameNumber: frameNumber)

                if let found = index, let expected, let image = fileList[found] as? NSObject {
                    // The identity of what is loaded elsewhere, against what
                    // was asked for: same file, same frame, same series, same size.
                    let loaded = BrowserController.viewerRowFrame(image, frame: intValue(rowValue(image, "frameID")))
                    if let refusal = PreviewIdentity.refusalForReusing(loaded, asRequested: expected) {
                        NSLog("Preview: not reusing a loaded frame: %@", refusal)
                        index = nil
                    }
                }

                guard let found = index else { return }
                guard found < pixList.count else { raiseOutOfRange(found, pixList.count); return }
                guard let dcmPix = pixList[found] as? DCMPix else { return }
                dcmPix.checking?.lock()
                dcmPix.checkLoad()

                if dcmPix.isLoaded() && !dcmPix.loadedFileMatchesDisk() {
                    let refusal = FileRevision.refusalForReusingFile(loaded: dcmPix.loadedFileRevision() as? FileRevision,
                                                                     current: FileRevision(path: pathToFind ?? ""))
                    NSLog("Preview: not reusing a loaded frame: %@", refusal ?? "the file changed on disk")
                } else if dcmPix.isLoaded() {
                    if let copy = dcmPix.copy() as? DCMPix {
                        let count = Int(dcmPix.pheight * dcmPix.pwidth)
                        if let pixels = malloc(count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) {
                            if let source = dcmPix.fImage { pixels.update(from: source, count: count) }
                            copy.fImage = pixels
                            copy.freefImage(whenDone: true)
                            lent = copy
                        }
                    }
                }
                dcmPix.checking?.unlock()
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame:]")
            }
            withExtendedLifetime(volumeData) {}
        }
        return lent
    }
}

/// The frame a lent frame must be, carried onto the main actor.
private struct LentExpectation: @unchecked Sendable {
    let frame: PreviewFrame?
}

/// The NSRangeException -objectAtIndex: raised for an index past the end.
private func raiseOutOfRange(_ index: Int, _ count: Int) {
    NSException(name: .rangeException,
                reason: "*** -[__NSArrayI objectAtIndex:]: index \(index) beyond bounds [0 .. \(count - 1)]", userInfo: nil).raise()
}
