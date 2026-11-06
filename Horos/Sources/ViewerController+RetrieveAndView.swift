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
import CoreData
import IsiXPreferences

// The selectors of ViewerController's retrieve-and-view and series load, kept
// for the nibs, the bindings, the other viewers and the former plugins. The
// work is the viewer's ViewerSeriesLoad (the load, on its SeriesImageLoader,
// the change of the series shown, its release, the fit at opening and the
// window's placement) and ProgressiveRetrieveState (the status of a series
// still arriving). The tiling views, the mask subtraction of an XA series and
// the export of a cropped series stay here.

/// NSAssert: the current NSAssertionHandler gets the failure and, by default,
/// raises NSInternalInconsistencyException.
fileprivate func objcAssert(_ condition: Bool, _ description: String, _ selector: Selector, _ object: AnyObject, line: Int = #line) {
    if condition { return }
    let handler = NSAssertionHandler.current
    let handleFailure = NSSelectorFromString("handleFailureInMethod:object:file:lineNumber:description:")
    typealias HandleFailure = @convention(c) (AnyObject, Selector, Selector, AnyObject, NSString, Int, NSString) -> Void
    let function = unsafeBitCast(handler.method(for: handleFailure), to: HandleFailure.self)
    function(handler, handleFailure, selector, object, "ViewerController+RetrieveAndView.swift", line, description as NSString)
}

/// `(int) x` of a double or float on arm64: NaN is 0, out of range saturates.
fileprivate func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// `(long) x` of a double on arm64: NaN is 0, out of range saturates.
fileprivate func cLong(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// `[DicomFile newSeriesUID]`. Despite its name the method returns an
/// autoreleased string, so it is sent without the new-family ownership Swift
/// would assume (which would release the string once more).
fileprivate func dicomFileNewSeriesUID() -> NSString? {
    let selector = NSSelectorFromString("newSeriesUID")
    guard let metaclass = object_getClass(DicomFile.self),
          let implementation = class_getMethodImplementation(metaclass, selector) else { return nil }
    typealias Send = @convention(c) (AnyClass, Selector) -> Unmanaged<NSString>?
    return unsafeBitCast(implementation, to: Send.self)(DicomFile.self, selector)?.takeUnretainedValue()
}

/// `[DicomFile writeCropOfFile:toPath:column:row:width:height:seriesUID:seriesNumber:error:]`,
/// sent through the runtime: its declaration is only visible where
/// Horos-Swift.h already exists. Throws the writer's error.
fileprivate func dicomFileWriteCrop(_ source: NSString?, _ target: NSString?, column: Int32, row: Int32, width: Int32, height: Int32,
                                    seriesUID: NSString?, seriesNumber: Int32) throws {
    let unknownFailure = NSError(domain: "HorosCrop", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown failure"])
    let selector = NSSelectorFromString("writeCropOfFile:toPath:column:row:width:height:seriesUID:seriesNumber:error:")
    guard let metaclass = object_getClass(DicomFile.self),
          let implementation = class_getMethodImplementation(metaclass, selector) else { throw unknownFailure }
    typealias Send = @convention(c) (AnyClass, Selector, NSString?, NSString?, Int32, Int32, Int32, Int32, NSString?, Int32,
                                     AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    let send = unsafeBitCast(implementation, to: Send.self)
    // The writer stores an autoreleased NSError (+0): the inout conversion to
    // an autoreleasing pointer retains what it reads back, as ARC would.
    var failure: NSError? = nil
    if !send(DicomFile.self, selector, source, target, column, row, width, height, seriesUID, seriesNumber, &failure) {
        throw failure ?? unknownFailure
    }
}

/// Posts `name` from `object`: the notifications of the series a viewer
/// shows, loads and leaves, which other viewers and plugins observe by name.
func postViewerNotification(_ name: Notification.Name, _ object: Any?, _ userInfo: [AnyHashable: Any]? = nil) {
    NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
}

public extension ViewerController {

    // MARK: - retrieve and view

    @objc(horosRefreshCoalescer)
    func horosRefreshCoalescer() -> RefreshCoalescer! {
        ProgressiveRetrieveState.of(self).refreshCoalescer()
    }

    // What the image view draws while this series is still being received, or
    // ended short or unverified. Empty for a series nobody is retrieving.
    @objc(retrieveStatusOverlay)
    func retrieveStatusOverlay() -> String! {
        ProgressiveRetrieveState.of(self).statusOverlay(of: self)
    }

    @objc(isReceivingPartialSeries)
    func isReceivingPartialSeries() -> Bool {
        ProgressiveRetrieveState.of(self).isReceivingPartialSeries(self)
    }

    @objc(retrieveViewingStateChanged:)
    func retrieveViewingStateChanged(_ note: Notification!) {
        if Thread.isMainThread == false {
            self.performSelector(onMainThread: #selector(ViewerController.retrieveViewingStateChanged(_:)), with: note, waitUntilDone: false)
            return
        }
        ProgressiveRetrieveState.of(self).retrieveStateChanged(note, viewer: self)
    }

    @objc(KeyImageCounter)
    func keyImageCounter() -> NSNumber! {
        NSNumber(value: Int32((horos_fileList(at: 0) ?? []).count { (($0 as? DicomImage)?.isKeyImage()?.boolValue) ?? false }))
    }

    @objc(viewCinit:::)
    func viewCinit(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!) -> Any! {
        // [self initWithPix: f withFiles: d withVolume: v], sent as the former
        // code sent it: an init method cannot be called from a Swift method.
        // Its result is returned as the former code returned it.
        let selector = NSSelectorFromString("initWithPix:withFiles:withVolume:")
        typealias InitWithPix = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, NSData?) -> Unmanaged<AnyObject>?
        let send = unsafeBitCast(self.method(for: selector), to: InitWithPix.self)
        return send(self, selector, f, d, v)?.takeUnretainedValue()
    }

    @objc(updateTilingViewsValue)
    func updateTilingViewsValue() -> Bool {
        return self.horos_updateTilingViews
    }

    @objc(setUpdateTilingViewsValue:)
    func setUpdateTilingViewsValue(_ v: Bool) {
        self.horos_updateTilingViews = v
    }

    @objc(finalizeSeriesViewing)
    func finalizeSeriesViewing() {
        horosSeriesLoad.finalize(viewerStays: false)
    }

    @objc(selectFirstTilingView)
    func selectFirstTilingView() {
        self.horos_seriesView?.selectFirstTilingView()
    }

    @objc(parallelToViewer:)
    func parallel(toViewer v: ViewerController!) -> Bool {
        var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)

        self.horos_imageView?.curDCM?.orientation(&orientA)
        v?.imageView()?.curDCM?.orientation(&orientB)

        let angle = orientA.withUnsafeMutableBufferPointer { a in
            orientB.withUnsafeMutableBufferPointer { b in
                DCMView.angleBetweenVector(a.baseAddress! + 6, andVector: b.baseAddress! + 6)
            }
        }
        return angle < sessionGraph.preferences[ViewerPreferences.parallelPlaneTolerance]
    }

    /// A copy of movie frame `v`: its volume in a buffer of its own and a copy
    /// of each slice pointing into it; nil and nil when it cannot be made.
    @objc(copyVolumeData:andDCMPix:forMovieIndex:)
    func copyVolumeData(_ vD: AutoreleasingUnsafeMutablePointer<NSData?>!, andDCMPix newPixList: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!, forMovieIndex v: Int32) {
        let copied = ViewerVolumeData.copy(movieIndex: Int(v), of: self)
        vD.pointee = copied?.volume
        newPixList.pointee = copied?.pixels
    }

    // Cutting a rectangle out and leaving the geometry alone would put the crop where
    // the whole image was, so this writes a derived series: Rows and Columns become
    // the rectangle, Image Position (Patient) moves to the new first pixel, and the
    // original files are not touched.
    @IBAction
    @objc(exportCroppedSeries:)
    func exportCroppedSeries(_ sender: Any!) {
        guard let rectangle = (self.selectedROIs() ?? []).lazy.compactMap({ $0 as? ROI }).first(where: { $0.type == .tROI }) else {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Export Cropped Series", comment: ""),
                                    message: NSLocalizedString("Select a rectangular ROI first: it says what to keep.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let area = rectangle.rect
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Export", comment: "")
        panel.message = String(format: NSLocalizedString("Choose where to write the cropped series (%d x %d).", comment: ""),
                               cInt32(Double(roundf(Float(area.size.width)))), cInt32(Double(roundf(Float(area.size.height)))))
        if panel.runModal() != .OK { return }

        let destination = panel.url?.path
        let images = (self.horos_fileList(at: Int(self.horos_curMovieIndex)) ?? []).compactMap { $0 as? DicomImage }
        let seriesUID = dicomFileNewSeriesUID()
        var written = 0
        var trouble: [String] = []

        let wait = Wait(string: NSLocalizedString("Export Cropped Series...", comment: ""), true)
        wait?.setCancel(true)
        wait?.showWindow(self)
        wait?.progress()?.maxValue = Double(images.count)

        for image in images {
            if wait?.aborted() ?? false { break }
            autoreleasepool {
                let source = image.completePath() as NSString?
                let target = (destination as NSString?)?.appendingPathComponent(String(format: "cropped-%04ld.dcm", written)) as NSString?
                do {
                    try dicomFileWriteCrop(source, target,
                                           column: cInt32(Double(roundf(Float(NSMinX(area))))), row: cInt32(Double(roundf(Float(NSMinY(area))))),
                                           width: cInt32(Double(roundf(Float(NSWidth(area))))), height: cInt32(Double(roundf(Float(NSHeight(area))))),
                                           seriesUID: seriesUID, seriesNumber: 9120)
                    written += 1
                } catch {
                    if trouble.count < 4 { trouble.append(error.localizedDescription) }
                }
            }
            wait?.progress()?.increment(by: 1)
        }

        wait?.close()

        NSLog("Export cropped series: %ld of %lu image(s) written to %@%@", written,
              UInt(images.count), (destination ?? "(null)") as NSString,
              (trouble.isEmpty ? "" : "; " + trouble.joined(separator: "; ")) as NSString)

        if written == 0 || !trouble.isEmpty {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Export Cropped Series", comment: ""),
                                    message: String(format: NSLocalizedString("%ld of %lu images were written. %@", comment: ""),
                                                    written, UInt(images.count), trouble.joined(separator: "; ")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        }
    }

    @objc(changeImageData::::)
    func changeImageData(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!, _ newViewerWindow: Bool) {
        horosSeriesLoad.show(GivenSeries(pixels: f, files: d, volume: v), newViewerWindow: newViewerWindow)
    }

    /// Records that this window shows `series`, and answers whether it had
    /// shown it before.
    @objc(horosRecordSeriesShown:)
    func horosRecordSeriesShown(_ series: NSManagedObjectID?) -> Bool {
        horosSeriesLoad.recordSeriesShown(series)
    }

    @objc(cancelOpeningScaleToFit)
    func cancelOpeningScaleToFit() {
        horosSeriesLoad.cancelOpeningScaleToFit()
    }

    @objc(requestOpeningScaleToFit)
    func requestOpeningScaleToFit() {
        horosSeriesLoad.requestOpeningScaleToFit()
    }

    @objc(finishOpeningScaleToFit)
    func finishOpeningScaleToFit() {
        horosSeriesLoad.finishOpeningScaleToFit()
    }

    @objc(showWindowTransition)
    func showWindowTransition() {
        horosSeriesLoad.showWindowTransition()
    }

    @objc(openingContentBoundsForPixLists:loadThread:)
    nonisolated class func openingContentBounds(forPixLists lists: NSArray!, load loadThread: Thread!) -> NSDictionary! {
        objcAssert(!Thread.isMainThread, "Opening content analysis requires a worker thread",
                   #selector(ViewerController.openingContentBounds(forPixLists:load:)), ViewerController.self)
        return SeriesImageLoader.openingContentBounds(of: (lists as? [AnyObject]) ?? [], thread: loadThread) as NSDictionary?
    }

    /// Starts decoding the series: the viewer's series load replaces the pending one.
    @objc(startLoadImageThread)
    func startLoadImageThread() {
        if self.horos_windowWillClose { return }

        self.horos_originalOrientation = -1
        self.horos_openingContentBoundsByPixels = nil
        horosSeriesLoad.start()
        self.setWindowTitle(self)
    }

    @objc(subtractionActivated)
    func subtractionActivated() -> Bool {
        return (self.horos_subCtrlOnOff?.state.rawValue ?? 0) != 0
    }

    @objc(computeSubCtrlMinMax)
    func computeSubCtrlMinMax() {
        if self.horos_subCtrlMinMaxComputed { return }

        self.horos_subCtrlMinMaxComputed = true

        //define min and max value of the subtraction
        var subCtrlMin = 1024
        var subCtrlMax = 0

        let slices = (self.horos_imageView?.dcmPixList ?? []).compactMap { $0 as? DCMPix }
        let pixMask = slices.indices.contains(self.horos_subCtrlMaskID) ? slices[self.horos_subCtrlMaskID] : nil

        for pix in slices {
            // subMinMax reads the mask with this image's width and height. An
            // image of another size than the mask is not subtracted
            // (subCtrlOnOff:) and does not count in the range.
            guard let mask = pixMask, mask.fImage != nil, pix.pwidth == mask.pwidth, pix.pheight == mask.pheight else { continue }

            self.horos_subCtrlMinMax = pix.subMinMax(pix.fImage, mask.fImage)

            if Double(self.horos_subCtrlMinMax.x) < Double(subCtrlMin) { subCtrlMin = cLong(Double(self.horos_subCtrlMinMax.x)) }
            if Double(self.horos_subCtrlMinMax.y) > Double(subCtrlMax) { subCtrlMax = cLong(Double(self.horos_subCtrlMinMax.y)) }
        }
        var minMax = self.horos_subCtrlMinMax
        minMax.x = CGFloat(subCtrlMin)
        minMax.y = CGFloat(subCtrlMax)
        self.horos_subCtrlMinMax = minMax
    }

    /// Why the XA mask subtraction cannot run on this series, or nil when it
    /// can. The subtraction works on the list of curMovieIndex, which may be
    /// any of the movie lists, so every one of them must hold at least two
    /// images (the default mask is the second one), all of one size.
    @objc(subtractionUnavailableReason)
    func subtractionUnavailableReason() -> String? {
        let firstPix = self.horos_pixList(at: 0)?.firstObject as? DCMPix
        if firstPix?.modalityString != "XA" {
            return NSLocalizedString("Subtraction works only for XA modality.", comment: "")
        }
        for movieIndex in 0..<max(Int(self.horos_maxMovieIndex), 1) {
            let list = (self.horos_pixList(at: movieIndex) ?? []).compactMap { $0 as? DCMPix }
            if list.count < 2 {
                return NSLocalizedString("Subtraction needs a series of at least two images.", comment: "")
            }
            if list.contains(where: { $0.pwidth != list[0].pwidth || $0.pheight != list[0].pheight }) {
                return NSLocalizedString("Subtraction needs all the images of the series to have the same size.", comment: "")
            }
        }
        return nil
    }

    @objc(enableSubtraction)
    func enableSubtraction() {
        if self.horos_enableSubtraction {
            self.horos_subCtrlOnOff?.isEnabled = true

            self.horos_subCtrlMaskID = 1
            self.horos_subCtrlMaskText?.stringValue = "2" //changes tool text

            self.horos_subCtrlMinMaxComputed = false
        } else { self.horos_subCtrlOnOff?.isEnabled = false }
    }

    @objc(resampleDataIfNeeded:)
    func resampleDataIfNeeded(_ sender: Any!) {
        horosSeriesLoad.resampleIfNeeded()
    }

    @objc(areLoadingViewers)
    nonisolated class func areLoadingViewers() -> Bool {
        (viewerRegistry.viewers ?? []).contains { !$0.isEverythingLoaded() }
    }
}
