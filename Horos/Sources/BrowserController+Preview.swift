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
import IsiXDICOMDataset
import IsiXDICOMFile

// The "Preview window policy" block of BrowserController: the selectors the
// nib, the timers, the preview view's delegate, the matrix and the tools send
// for the database preview, which BrowserPreviewPane answers, and the window's
// own actions and split views kept beside them. The state it uses is read
// through the class's accessors (BrowserController+StateAccess.swift) and its
// statics (BrowserController+ClassState.swift).
//
// An @try is HorosObjCException.perform. A float turned into an int follows
// the arm64 conversion (NaN is 0, out of range saturates) instead of trapping.

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[string isEqualToString: other]`: NO when either is nil or not a string.
fileprivate func objcIsEqualToString(_ string: Any?, _ other: Any?) -> Bool {
    guard let string = string as? NSString, let other = other as? String else { return false }
    return string.isEqual(to: other)
}

/// `[sender selectedCell]` of an `id` sender: nil for nil, and the same
/// unrecognized-selector exception as before for a sender without cells.
fileprivate func objcSelectedCell(_ sender: Any?) -> NSCell? {
    guard let sender = sender as AnyObject? else { return nil }
    return sender.perform(NSSelectorFromString("selectedCell"))?.takeUnretainedValue() as? NSCell
}

/// MIN() of Foundation: `a < b ? a : b`, which keeps b when a is NaN.
@inline(__always)
fileprivate func objcMIN(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? a : b }

/// MAX() of Foundation: `a < b ? b : a`, which keeps a when a is NaN.
@inline(__always)
fileprivate func objcMAX(_ a: Float, _ b: Float) -> Float { return a < b ? b : a }
@inline(__always)
fileprivate func objcMAX(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? b : a }

/// A float converted to an int as arm64 converts it: NaN is 0, and a value out
/// of range saturates, where Swift would trap.
fileprivate func objcInt32(_ value: Float) -> Int32 {
    if value.isNaN { return 0 }
    if value >= Float(Int32.max) { return Int32.max }
    if value <= Float(Int32.min) { return Int32.min }
    return Int32(value)
}

/// Forgets the rotation, zoom, window, flips, offset and display style a
/// series was last shown with.
fileprivate func forgetPresentation(of series: DicomSeries) {
    series.rotationAngle = nil
    series.scale = nil
    series.windowLevel = nil
    series.windowWidth = nil
    series.xFlipped = nil
    series.yFlipped = nil
    series.xOffset = nil
    series.yOffset = nil
    series.displayStyle = nil
}

extension BrowserController: @MainActor PreviewViewWindowDelegate {}

public extension BrowserController {

    // MARK: Preview window policy

    @objc(previewView:didRequestWindowLevel:width:)
    func previewView(_ view: PreviewView!, didRequestWindowLevel wl: Float, width ww: Float) {
        guard view === horos_imageView, previewPane.needsAutomaticWindow(afterRequest: wl, width: ww) else { return }

        // A width of zero asks for automatic selection, so the preview computes its
        // window again rather than showing an image two units wide. Not from inside
        // this call: the view is in the middle of applying one.
        perform(#selector(applyPreviewWindowForCurrentFrame), with: nil, afterDelay: 0)
    }

    @objc(applyPreviewWindowForCurrentFrame)
    func applyPreviewWindowForCurrentFrame() {
        applyPreviewWindow(for: nil, pix: nil)
    }

    /// The window the frame is shown with, and why (BrowserPreviewPane).
    @objc(applyPreviewWindowForImage:pix:)
    func applyPreviewWindow(for imageObj: DicomImage!, pix dcmPix: DCMPix!) {
        previewPane.applyWindow(for: imageObj, pix: dcmPix)
    }

    @objc(previewSliderAction:)
    @IBAction func previewSliderAction(_ sender: Any!) {
        previewPane.showSliderFrame(sender: sender)
    }

    @objc(previewPerformAnimation:)
    func previewPerformAnimation(_ sender: Any!) {
        previewPane.performAnimation()
    }

    override func scrollWheel(with theEvent: NSEvent) {
        previewPane.scroll(with: theEvent)
    }

    @objc(matrixPressed:)
    @IBAction func matrixPressed(_ sender: Any!) {
        previewPane.matrixPressed(sender)
    }

    @objc(matrixDoublePressed:)
    @IBAction func matrixDoublePressed(_ sender: Any!) {
        let theCell = horos_oMatrix?.selectedCell()

        if (theCell?.tag ?? 0) >= 0 {
            viewerDICOM(horos_oMatrix?.menu?.item(at: 0))
        }
    }

    @objc(matrixInit:)
    func matrixInit(_ noOfImages: Int) {
        previewPane.matrixInit(noOfImages)
    }

    @objc(matrixNewIcon::)
    func matrixNewIcon(_ index: Int, _ curFile: NSManagedObject!) {
        previewPane.showIcon(index, of: curFile)
    }

    @objc(pdfPreview:)
    func pdfPreview(_ sender: Any!) {
        matrixPressed(sender)

        autoreleasepool {
            NSLog("open pdf with Preview")
            //check if the folder PDF exists in OsiriX document folder
            var pathToPDF = (self.database?.baseDirPath as NSString?)?.appendingPathComponent("PDF")
            if !FileManager.default.fileExists(atPath: pathToPDF ?? "") {
                if let pathToPDF { try? FileManager.default.createDirectory(atPath: pathToPDF, withIntermediateDirectories: true, attributes: nil) }
            }

            //pathToPDF = /PDF/yyyymmdd.hhmmss.pdf
            let datetimeFormatter = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d.%H%M%S", allowNaturalLanguage: false)
            pathToPDF = (pathToPDF as NSString?)?.appendingPathComponent(datetimeFormatter?.string(from: Date()) ?? "")
            pathToPDF = (pathToPDF as NSString?)?.appendingPathExtension("pdf")
            NSLog("%@", objcFormatArgument(pathToPDF))

            //creating file and opening it with preview
            var curObj = (horos_matrixViewArray as NSArray?)?.object(at: objcSelectedCell(sender)?.tag ?? 0) as? NSObject
            NSLog("%@", objcFormatArgument(curObj?.value(forKey: "type")))

            //	[_database lock];

            if let e = HorosObjCException.caught({
                if objcIsEqualToString(curObj?.value(forKey: "type"), "Series") {
                    curObj = (childrenArray(curObj) as NSArray?)?.object(at: 0) as? NSObject
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[BrowserController pdfPreview:]")
            }

            //	[_database unlock];

            NSLog("%@", objcFormatArgument(curObj?.value(forKey: "completePath")))

            let dcmObject = (curObj?.value(forKey: "completePath") as? String).flatMap { DCMObject.object(contentsOfFile: $0) }
            let encapsulatedPDF = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data
            let fileManager = FileManager.default
            if let pathToPDF, fileManager.createFile(atPath: pathToPDF, contents: encapsulatedPDF, attributes: nil) { NSWorkspace.shared.open(URL(fileURLWithPath: pathToPDF)) }
            else { NSLog("couldn't open pdf") }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    @objc(matrixDisplayIcons:)
    func matrixDisplayIcons(_ sender: Any!) {
        previewPane.displayIcons()
    }

    @objc(produceJPEGThumbnail:)
    class func produceJPEGThumbnail(_ image: NSImage!) -> Data! {
        return image?.jpegRepresentation(withQuality: 0.3)
    }

    @objc(buildThumbnail:)
    func buildThumbnail(_ series: DicomSeries!) {
        autoreleasepool {
            _ = series?.thumbnail
        }
    }

    @objc(resetWindowsState:)
    @IBAction func resetWindowsState(_ sender: Any!) {
        var x = 0, row = 0
        let context = self.database?.managedObjectContext

        N2ManagedObjectContextPerformAndWait(context) {

        if let e = HorosObjCException.caught({
            let selectedRows = horos_databaseOutline?.selectedRowIndexes as NSIndexSet?

            if (horos_databaseOutline?.selectedRow ?? 0) >= 0 {
                x = 0
                while x < (selectedRows?.count ?? 0) {
                    if x == 0 { row = selectedRows?.firstIndex ?? 0 }
                    else { row = selectedRows?.indexGreaterThanIndex(row) ?? 0 }

                    let object = horos_databaseOutline?.item(atRow: row) as? NSObject

                    if let study = object as? DicomStudy {
                        for case let series as DicomSeries in childrenArray(study) ?? [] {
                            forgetPresentation(of: series)
                        }
                        study.windowsState = nil
                    } else if let series = object as? DicomSeries {
                        forgetPresentation(of: series)
                        series.study?.windowsState = nil
                    }
                    x += 1
                }
            }

            _ = self.database?.save(nil)
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController resetWindowsState:]")
        }

        }
    }

    @objc(retrieveSelectedPODStudies:)
    @IBAction func retrieveSelectedPODStudies(_ sender: Any!) {
        if let e = HorosObjCException.caught({
            let selectedRows = horos_databaseOutline?.selectedRowIndexes as NSIndexSet?
            var row = 0

            if (horos_databaseOutline?.selectedRow ?? 0) >= 0 {
                var x = 0
                while x < (selectedRows?.count ?? 0) {
                    if x == 0 { row = selectedRows?.firstIndex ?? 0 }
                    else { row = selectedRows?.indexGreaterThanIndex(row) ?? 0 }

                    let object = horos_databaseOutline?.item(atRow: row) as AnyObject?

                    if object?.isDistant?() == true {
                        // Check to see if already in retrieving mode, if not download it
                        retrieveComparativeStudy(object as? DCMTKStudyQueryNode, select: false, open: false, showGUI: false)
                    }
                    x += 1
                }
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController retrieveSelectedPODStudies:]")
        }
    }

    @objc(rebuildThumbnails:)
    @IBAction func rebuildThumbnails(_ sender: Any!) {
        previewPane.rebuildThumbnails()
    }

    @objc(_scrollerStyle:)
    class func _scrollerStyle(_ scroller: NSScroller!) -> Int {
        if scroller?.responds(to: #selector(getter: NSScroller.scrollerStyle)) == true {
            // The former code sent it through an NSInvocation.
            return scroller.scrollerStyle.rawValue
        }

        return 0 // NSScrollerStyleLegacy is 0
    }

    @objc(splitView:constrainSplitPosition:ofSubviewAt:)
    func splitView(_ sender: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        var proposedPosition = proposedPosition

        if sender === horos_splitViewVert {
            horos_splitViewVertDividerRatio = proposedPosition / sender.bounds.size.width

            let oMatrix = horos_oMatrix
            let rcs = (oMatrix?.cellSize.width ?? 0) + (oMatrix?.intercellSpacing.width ?? 0)

            var scrollbarWidth: CGFloat = 0
            if let thumbnailsScrollView = horos_thumbnailsScrollView, thumbnailsScrollView.isKind(of: NSScrollView.self) {
                let scroller = thumbnailsScrollView.verticalScroller
                if type(of: self)._scrollerStyle(scroller) != 1 {
                    if thumbnailsScrollView.hasVerticalScroller && !(scroller?.isHidden ?? false) {
                        scrollbarWidth = scroller?.frame.size.width ?? 0
                    }
                }
            }

            proposedPosition -= scrollbarWidth

            let hcells = objcInt32(objcMAX(roundf(Float((proposedPosition + (oMatrix?.intercellSpacing.width ?? 0)) / rcs)), 1))
            proposedPosition = rcs * CGFloat(hcells) - (oMatrix?.intercellSpacing.width ?? 0)
            proposedPosition = objcMIN(proposedPosition, sender.maxPossiblePositionOfDivider(at: offset))

            proposedPosition += (scrollbarWidth != 0 ? scrollbarWidth + 3 : 2)

            return proposedPosition
        }

        if sender === horos_splitDrawer {
            proposedPosition = objcMAX(proposedPosition, sender.minPossiblePositionOfDivider(at: offset))
            proposedPosition = objcMIN(proposedPosition, sender.maxPossiblePositionOfDivider(at: offset))
        }

        if sender === horos_splitComparative {
            proposedPosition = objcMAX(proposedPosition, sender.minPossiblePositionOfDivider(at: offset))
            proposedPosition = objcMIN(proposedPosition, sender.maxPossiblePositionOfDivider(at: offset))
        }

        if sender.isEqual(horos_bannerSplit) {
            return sender.frame.size.height - ((horos_banner?.image?.size.height ?? 0) + 3)
        }

        if sender.isEqual(horos_splitAlbums) {
            proposedPosition = objcMAX(proposedPosition, sender.minPossiblePositionOfDivider(at: offset))
            proposedPosition = objcMIN(proposedPosition, sender.maxPossiblePositionOfDivider(at: offset))
        }

        return proposedPosition
    }

    @objc(observeScrollerStyleDidChangeNotification:)
    func observeScrollerStyleDidChange(_ n: Notification!) {
        let thumbnailsScrollView = horos_thumbnailsScrollView
        var frame = thumbnailsScrollView?.superview?.bounds ?? .zero
        if type(of: self)._scrollerStyle(thumbnailsScrollView?.verticalScroller) == 1 { // overlay
            frame.origin.x += 2; frame.size.width -= 2
            thumbnailsScrollView?.frame = frame
        } else {
            frame.origin.x += 2; frame.size.width -= 3
            thumbnailsScrollView?.frame = frame
        }
        horos_splitViewVert?.resizeSubviews(withOldSize: horos_splitViewVert?.bounds.size ?? .zero)
    }

    @objc(windowDidChangeScreen:)
    func windowDidChangeScreen(_ notification: Notification!) {
        // The application compares complete screen snapshots. Merely moving focus or
        // moving a window between unchanged screens must not rescale every viewer.
        AppController.shared()?.updateScreenParameters()
    }

    @objc(recoverWindowsAfterScreenChange)
    func recoverWindowsAfterScreenChange() {
        // Preserve every controller, pixel list and ROI object. Only constrain windows
        // that no longer fit; valid placements on other displays remain untouched.
        for window in NSApp.windows {
            // Update alerts are panels (sometimes borderless), but their active modal
            // window must remain reachable after a display disappears.
            let activeModal = window === NSApp.modalWindow
            if !activeModal && (window.isKind(of: NSPanel.self) || !window.styleMask.contains(.titled)) { continue }
            if !window.isVisible && !window.isMiniaturized && window !== self.window { continue }
            if let exception = HorosObjCException.caught({
                DatabaseWindowPlacement.restore(window, savedFrame: window.frame)
            }) {
                _N2LogExceptionImpl(exception, false, "-[BrowserController recoverWindowsAfterScreenChange]")
            }
        }
        ToolbarPanelController.checkForValidToolbar()
        for screen in NSScreen.screens {
            if let exception = HorosObjCException.caught({
                ViewerController.frontMostDisplayed2DViewer(for: screen)?.redrawToolbar()
            }) {
                _N2LogExceptionImpl(exception, false, "-[BrowserController recoverWindowsAfterScreenChange]")
            }
        }
    }

    @objc(previewMatrixScrollViewFrameDidChange:)
    func previewMatrixScrollViewFrameDidChange(_ note: Notification!) {
        previewPane.matrixFrameDidChange()
    }
}
