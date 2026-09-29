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

// The "retrieve and view (#604)" block of ViewerController is implemented in
// Swift since #832: a Swift extension of ViewerController, which stays
// Objective-C, with the same selectors. It holds the progressive
// retrieve-and-view state, the change of the displayed series
// (-changeImageData::::), the load thread (-startLoadImageThread,
// -finishLoadImageData:) and the opening scale to fit. -dealloc (which sends
// [super dealloc]) and -copyViewerWindow (a copy-family method returning an
// object) stay in ViewerController.m.
//
// The instance variables are read through ViewerController (SwiftIvars). The
// volume data is read and stored as the NSData object itself (never a Data
// value): the DCMPix fImage pointers point into its bytes, and observers of
// the volume notifications see that same object. The ownership of the movie
// arrays (pixList, fileList, roiList, copyRoiList, volumeData) and of
// loadingThread repeats the manual retain/release of the former code: where
// it stored a value it had retained itself, the value is retained with
// Unmanaged and stored with the plain accessor; where it autoreleased the
// thread and cleared the ivar, the thread is autoreleased the same way.
//
// A message to nil answered nil, 0 or NO: the optional chains below answer the
// same. An @try is HorosObjCException.perform (objcTry), an @synchronized is
// objcSynchronized. A float turned into an int follows the arm64 conversion
// (NaN is 0, out of range saturates) instead of trapping. NSAssert, left
// enabled in every configuration, goes to the current NSAssertionHandler.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

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

/// `[object retain]` of a value the Objective-C stored in an ivar after
/// retaining it itself; the value is returned for the plain store.
@discardableResult
fileprivate func objcRetain<T: AnyObject>(_ object: T?) -> T? {
    if let object { _ = Unmanaged.passUnretained(object).retain() }
    return object
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

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[object valueForKeyPath: keyPath]`, nil for nil.
fileprivate func objcValue(_ object: Any?, _ keyPath: String) -> Any? {
    return (object as? NSObject)?.value(forKeyPath: keyPath)
}

/// `[string isEqualToString: other]`: NO when either is nil or not a string.
fileprivate func objcIsEqualToString(_ string: Any?, _ other: Any?) -> Bool {
    guard let string = string as? NSString, let other = other as? String else { return false }
    return string.isEqual(to: other)
}

/// `[string compare: other options: options]`, sent as Objective-C sent it: a
/// nil receiver answers NSOrderedSame (0), and a nil argument reaches the
/// method as nil.
fileprivate func objcCompare(_ string: Any?, _ other: Any?, _ options: NSString.CompareOptions) -> ComparisonResult {
    guard let string = string as? NSString else { return .orderedSame }
    let selector = #selector(NSString.compare(_:options:))
    typealias Compare = @convention(c) (NSString, Selector, NSString?, UInt) -> Int
    let compare = unsafeBitCast(string.method(for: selector), to: Compare.self)
    return ComparisonResult(rawValue: compare(string, selector, other as? NSString, options.rawValue)) ?? .orderedSame
}

/// `[object intValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// `[object floatValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcFloatValue(_ object: Any?) -> Float {
    if let number = object as? NSNumber { return number.floatValue }
    if let string = object as? NSString { return string.floatValue }
    return 0
}

/// `[object count]` of a collection (the to-many relationship of a series is
/// a set), 0 for nil.
fileprivate func objcCount(_ object: Any?) -> Int {
    if let set = object as? NSSet { return set.count }
    if let array = object as? NSArray { return array.count }
    if let ordered = object as? NSOrderedSet { return ordered.count }
    if let object = object as? NSObject, let count = object.value(forKey: "count") as? NSNumber { return count.intValue }
    return 0
}

/// `[array addObject: object]`: the exception Foundation raised for nil.
fileprivate func objcAdd(_ array: NSMutableArray, _ object: Any?) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.add(object)
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
/// Horos-Swift.h already exists.
fileprivate func dicomFileWriteCrop(_ source: NSString?, _ target: NSString?, column: Int32, row: Int32, width: Int32, height: Int32,
                                    seriesUID: NSString?, seriesNumber: Int32, error: inout NSError?) -> Bool {
    let selector = NSSelectorFromString("writeCropOfFile:toPath:column:row:width:height:seriesUID:seriesNumber:error:")
    guard let metaclass = object_getClass(DicomFile.self),
          let implementation = class_getMethodImplementation(metaclass, selector) else { return false }
    typealias Send = @convention(c) (AnyClass, Selector, NSString?, NSString?, Int32, Int32, Int32, Int32, NSString?, Int32,
                                     AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    let send = unsafeBitCast(implementation, to: Send.self)
    // The writer stores an autoreleased NSError (+0): the inout conversion to
    // an autoreleasing pointer retains what it reads back, as ARC would.
    var failure: NSError? = nil
    let written = send(DicomFile.self, selector, source, target, column, row, width, height, seriesUID, seriesNumber, &failure)
    error = failure
    return written
}

/// `[pix setArrayPix: array :i]` with the array object itself: the DCMPix keeps
/// the pointer without retaining it, and the [Any] Swift imports the parameter
/// as would hand it a temporary copy instead of the live pixel list.
fileprivate func dcmPixSetArrayPix(_ pix: DCMPix?, _ array: NSArray?, _ i: Int16) {
    guard let pix else { return }
    let selector = NSSelectorFromString("setArrayPix::")
    typealias Send = @convention(c) (AnyObject, Selector, NSArray?, Int16) -> Void
    unsafeBitCast(pix.method(for: selector), to: Send.self)(pix, selector, array, i)
}

/// `[view setPixels: pixels files: files rois: rois firstImage: … level: … reset: …]`
/// with the file list object itself: the [Any] Swift imports `files` as would
/// hand the view a copy instead of the viewer's live fileList.
fileprivate func dcmViewSetPixels(_ view: DCMView?, _ pixels: NSMutableArray?, files: NSArray?, rois: NSMutableArray?,
                                  firstImage: Int16, level: CChar, reset: Bool) {
    guard let view else { return }
    let selector = NSSelectorFromString("setPixels:files:rois:firstImage:level:reset:")
    typealias Send = @convention(c) (AnyObject, Selector, NSMutableArray?, NSArray?, NSMutableArray?, Int16, CChar, Bool) -> Void
    unsafeBitCast(view.method(for: selector), to: Send.self)(view, selector, pixels, files, rois, firstImage, level, reset)
}

/// The key of the associated coalescer. Only its address matters.
fileprivate var HorosRefreshCoalescerKey: UInt8 = 0

public extension ViewerController {

    // MARK: - retrieve and view (#604)

    @objc(horosRefreshCoalescer)
    func horosRefreshCoalescer() -> RefreshCoalescer! {
        if UserDefaults.standard.bool(forKey: "HorosProgressiveRetrieveViewing") == false {
            return nil
        }
        var coalescer = objc_getAssociatedObject(self, &HorosRefreshCoalescerKey) as? RefreshCoalescer
        if coalescer == nil {
            coalescer = RefreshCoalescer.standard()
            objc_setAssociatedObject(self, &HorosRefreshCoalescerKey, coalescer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return coalescer
    }

    // What the image view draws while this series is still being received, or
    // ended short or unverified. Empty for a series nobody is retrieving.
    @objc(retrieveStatusOverlay)
    func retrieveStatusOverlay() -> String! {
        let state = RetrieveViewing.shared.state(studyUID: self.currentStudy()?.studyInstanceUID ?? "",
                                                 seriesUID: self.currentSeries()?.seriesDICOMUID ?? "")
        return state != nil ? state!.overlayText : ""
    }

    @objc(isReceivingPartialSeries)
    func isReceivingPartialSeries() -> Bool {
        let state = RetrieveViewing.shared.state(studyUID: self.currentStudy()?.studyInstanceUID ?? "",
                                                 seriesUID: self.currentSeries()?.seriesDICOMUID ?? "")
        return state != nil ? state!.isPartial : false
    }

    @objc(retrieveViewingStateChanged:)
    func retrieveViewingStateChanged(_ note: Notification!) {
        if Thread.isMainThread == false {
            self.performSelector(onMainThread: #selector(ViewerController.retrieveViewingStateChanged(_:)), with: note, waitUntilDone: false)
            return
        }
        if ((note?.object as? NSObject)?.isEqual(self.currentStudy()?.studyInstanceUID) ?? false) {
            self.horos_imageView?.needsDisplay = true
        }
    }

    @objc(KeyImageCounter)
    func keyImageCounter() -> NSNumber! {
        var total: Int32 = 0

        for case let image as NSManagedObject in (self.horos_fileList(at: 0) ?? NSMutableArray()) {
            if (image.value(forKey: "isKeyImage") as? NSNumber)?.boolValue ?? false { total += 1 }
        }

        return NSNumber(value: total)
    }

    @objc(viewCinit:::)
    func viewCinit(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!) -> Any! {
        // [self initWithPix: f withFiles: d withVolume: v], sent as the former
        // code sent it: an init method cannot be called from a Swift method.
        // Its result is returned as the former code returned it.
        let selector = NSSelectorFromString("initWithPix:withFiles:withVolume:")
        typealias InitWithPix = @convention(c) (AnyObject, Selector, NSMutableArray?, NSMutableArray?, NSData?) -> Unmanaged<AnyObject>?
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
        objcSynchronized(self.horos_loadingThread) {
            self.horos_loadingThread?.cancel()
            if let thread = self.horos_loadingThread { _ = Unmanaged.passUnretained(thread).autorelease() }
            self.horos_assignLoading(nil)
        }

        if self.horos_resampleRatio != 1 {
            self.horos_resampleRatio = 1
        }

        var i = 0
        while i < Int(self.horos_maxMovieIndex) {
            if let e = objcTry({
                self.saveROI(i)
            }) {
                NSLog("***** saveROI exception : %@", e)
            }



            for case let a as NSArray in (self.horos_roiList(at: i) ?? NSMutableArray()) {
                // [a retain] … [a release]: the loop holds `a`.
                for case let r as ROI in a {
                    NotificationCenter.default.post(name: .OsirixRemoveROI, object: r, userInfo: nil)
                }
            }
            i += 1
        }

        self.applyStatusValue()

        i = 0
        while i < Int(self.horos_maxMovieIndex) {
            self.horos_setCopyRoiList(nil, at: i)
            self.horos_setRoiList(nil, at: i)
            self.horos_setPixList(nil, at: i)
            self.horos_setFileList(nil, at: i)

            self.horos_sendWillFreeVolumeDataNotification(forMovieIndex: i)
            self.horos_setVolumeData(nil, at: i)
            i += 1
        }

        self.horos_undoQueue?.removeAllObjects()
        self.horos_redoQueue?.removeAllObjects()
        self.horos_clearVolumeLengthState()

        if self.horos_thickSlab != nil {
            self.horos_thickSlab = nil
        }
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
        if angle < UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") {
            return true
        } else {
            return false
        }
    }

    @objc(copyVolumeData:andDCMPix:forMovieIndex:)
    func copyVolumeData(_ vD: AutoreleasingUnsafeMutablePointer<NSData?>!, andDCMPix newPixList: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!, forMovieIndex v: Int32) {
        vD.pointee = nil
        newPixList.pointee = nil

        // First calculate the amount of memory needed for the new serie
        let pL: NSArray? = self.pixList(Int(v))
        var curPix: DCMPix?
        var mem = 0

        var i = 0
        while i < (pL?.count ?? 0) {
            curPix = pL!.object(at: i) as? DCMPix
            mem = mem &+ (curPix?.pheight ?? 0) &* (curPix?.pwidth ?? 0) &* 4		// each pixel contains either a 32-bit float or a 32-bit ARGB value
            i += 1
        }

        let fVolumePtr = malloc(mem)?.assumingMemoryBound(to: UInt8.self)	// ALWAYS use malloc for allocating memory !
        if let fVolumePtr {
            // Copy the source series in the new one !
            if let source = self.volumePtr(Int(v)) {
                memcpy(fVolumePtr, source, mem)
            } else {
                // memcpy from NULL: the former code crashed here unless mem was 0.
                precondition(mem == 0, "copyVolumeData: the volume has no pixels to copy")
            }

            // Create a NSData object to control the new pointer
            vD.pointee = NSData(bytesNoCopy: fVolumePtr, length: mem, freeWhenDone: true)

            // Now copy the DCMPix with the new fVolumePtr
            let list = NSMutableArray()
            newPixList.pointee = list
            i = 0
            while i < (pL?.count ?? 0) {
                let copy = (pL!.object(at: i) as AnyObject).copy() as? DCMPix
                curPix = copy
                let offset = (copy?.pheight ?? 0) &* (copy?.pwidth ?? 0) &* 4 &* i
                copy?.fImage = UnsafeMutableRawPointer(fVolumePtr + offset).assumingMemoryBound(to: Float.self)
                objcAdd(list, copy)
                i += 1
            }
        }
    }

    // Cutting a rectangle out and leaving the geometry alone would put the crop where
    // the whole image was, so this writes a derived series: Rows and Columns become
    // the rectangle, Image Position (Patient) moves to the new first pixel, and the
    // original files are not touched.
    @IBAction
    @objc(exportCroppedSeries:)
    func exportCroppedSeries(_ sender: Any!) {
        var rectangle: ROI? = nil
        for case let roi as ROI in (self.selectedROIs() ?? NSMutableArray()) {
            if roi.type == .tROI { rectangle = roi; break }
        }

        guard let rectangle else {
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
        let images = self.horos_fileList(at: Int(self.horos_curMovieIndex))
        let seriesUID = dicomFileNewSeriesUID()
        var written = 0
        let trouble = NSMutableArray()

        let wait = Wait(string: NSLocalizedString("Export Cropped Series...", comment: ""), true)
        wait?.setCancel(true)
        wait?.showWindow(self)
        wait?.progress()?.maxValue = Double(images?.count ?? 0)

        for case let image as NSManagedObject in (images ?? NSMutableArray()) {
            if wait?.aborted() ?? false { break }
            autoreleasepool {
                let source = image.value(forKey: "completePath") as? NSString
                let target = (destination as NSString?)?.appendingPathComponent(String(format: "cropped-%04ld.dcm", written)) as NSString?
                var error: NSError? = nil
                if dicomFileWriteCrop(source, target,
                                      column: cInt32(Double(roundf(Float(NSMinX(area))))), row: cInt32(Double(roundf(Float(NSMinY(area))))),
                                      width: cInt32(Double(roundf(Float(NSWidth(area))))), height: cInt32(Double(roundf(Float(NSHeight(area))))),
                                      seriesUID: seriesUID, seriesNumber: 9120, error: &error) {
                    written += 1
                } else if trouble.count < 4 {
                    trouble.add(error?.localizedDescription ?? "unknown failure")
                }
            }
            wait?.progress()?.increment(by: 1)
        }

        wait?.close()

        NSLog("Export cropped series: %ld of %lu image(s) written to %@%@", written,
              UInt(images?.count ?? 0), objcFormatArgument(destination),
              (trouble.count != 0 ? String(format: "; %@", trouble.componentsJoined(by: "; ")) : "") as NSString)

        if written == 0 || trouble.count != 0 {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Export Cropped Series", comment: ""),
                                    message: String(format: NSLocalizedString("%ld of %lu images were written. %@", comment: ""),
                                                    written, UInt(images?.count ?? 0), trouble.componentsJoined(by: "; ")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        }
    }

    @objc(changeImageData::::)
    func changeImageData(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!, _ newViewerWindow: Bool) {
        var d = d
        if self.horos_windowWillClose { return }
        self.cancelOpeningScaleToFit()

        OSIEnvironment.shared()?.viewerControllerWillChangeData(self)

        if delayedTileWindows != 0 {
            delayedTileWindows = 0
            if let app = AppController.shared() {
                NSObject.cancelPreviousPerformRequests(withTarget: app, selector: #selector(AppController.tileWindows(_:)), object: nil)
            }
            AppController.shared()?.tileWindows(nil)
        }

        if self.horos_curMovieIndex != 0 {
            self.setMovieIndex(0)
        }

        var sameSeries = false
        var i = 0
        let previousColumns: Int = self.horos_imageView?.columns ?? 0, previousRows: Int = self.horos_imageView?.rows ?? 0
        let previousFusion = Int32(truncatingIfNeeded: self.horos_popFusion?.selectedTag() ?? 0),
            previousFusionActivated = Int32(truncatingIfNeeded: self.horos_activatedFusion?.state.rawValue ?? 0)

        let previousPatientUID = objcValue(self.horos_fileList(at: 0)?.object(at: 0), "series.study.patientUID")
        let previousStudyInstanceUID = objcValue(self.horos_fileList(at: 0)?.object(at: 0), "series.study.studyInstanceUID")
        let previousDicomImage = self.horos_imageView?.imageObj()
        var previousOrientation = [Float](repeating: 0, count: 9)
        var previousLocation: Float = 0
        let previousCurImage = Int32(self.horos_imageView?.curImage ?? 0)
        let wasFlipped = self.horos_imageView?.flippedData ?? false

        objcSynchronized(self) {
            NSDisableScreenUpdates()

            self.horos_statusValueToApply = -1

            if let e = objcTry({
                var equalVector = true
                var nonZeroVector = false

                self.horos_nonVolumicDataWarningDisplayed = true

                if previousColumns != 1 || previousRows != 1 {
                    self.horos_imageView = (self.horos_seriesView?.imageViews() as NSMutableArray?)?.object(at: 0) as? DCMView
                    _ = self.horos_imageView?.becomeFirstResponder()

                    self.setImageRows(1, columns: 1)
                }

                // [imageView mouseUp: [NSApp currentEvent]]: the current event may be nil.
                _ = self.horos_imageView?.perform(NSSelectorFromString("mouseUp:"), with: NSApplication.shared.currentEvent)

                if (self.horos_pixList(at: 0)?.count ?? 0) != 0 && (d?.count ?? 0) != 0 {
                    self.selectFirstTilingView()
                    self.horos_imageView?.updateTilingViews()

                    (self.horos_pixList(at: 0)?.object(at: 0) as? DCMPix)?.orientation(&previousOrientation)

                    var newOrientation = [Float](repeating: 0, count: 9)
                    (f?.object(at: 0) as? DCMPix)?.orientation(&newOrientation)

                    i = 0
                    while i < 9 {
                        if previousOrientation[i] != newOrientation[i] {
                            equalVector = false
                        }

                        if newOrientation[i] != 0 {
                            nonZeroVector = true
                        }
                        i += 1
                    }

                    var wasSyncButtonBehaviorIsBetweenStudies = false

                    if objcIsEqualToString(previousStudyInstanceUID, objcValue(d?.object(at: 0), "series.study.studyInstanceUID")) {
                        if SyncButtonBehaviorIsBetweenStudies.boolValue && ViewerController.horos_SYNCSERIES() {
                            wasSyncButtonBehaviorIsBetweenStudies = true
                        }
                    }

                    if wasSyncButtonBehaviorIsBetweenStudies == false {
                        self.turnOffSyncSeriesBetweenStudies(self)
                    }

                    previousLocation = self.horos_imageView?.imageObj()?.sliceLocation?.floatValue ?? 0
                }
                // Check if another post-processing viewer is open : we CANNOT release the fVolumePtr -> OsiriX WILL crash

                var minWindows = 1
                if self.fullScreenON() { minWindows += 1 }

                if newViewerWindow == false && (AppController.shared()?.FindRelatedViewers(self.horos_pixList(at: 0))?.count ?? 0) > minWindows {
                    NSSound.beep()
                    NSLog("changeImageData not possible with other post-processing windows opened")
                } else {
                    // *****************
                    self.horos_imageView?.drawing = false


                    NotificationCenter.default.post(name: .OsirixViewerWillChange, object: self, userInfo: nil)

                    self.activateBlending(nil)
                    self.clear8bitRepresentations()
                    self.horos_shutterOnOff?.state = .off

                    self.setFusionMode(0)

                    self.horos_imageView?.setIndex(0)

                    var newStudy: NSManagedObject? = nil

                    if (d?.count ?? 0) != 0 {
                        newStudy = objcValue(d!.object(at: 0), "series.study") as? NSManagedObject
                    }
                    var closeInfo: [AnyHashable: Any] = [:]
                    if let newStudyID = newStudy?.objectID { closeInfo["newStudyID"] = newStudyID }
                    NotificationCenter.default.post(name: .OsirixCloseViewer, object: self, userInfo: closeInfo)

                    self.horos_windowWillClose = true

                    self.setUpdateTilingViewsValue(true)

                    if (self.horos_subCtrlOnOff?.state.rawValue ?? 0) != 0 { self.horos_imageView?.setWLWW(0, 0) }
                    self.check(self.horos_subCtrlView, false)

                    if self.horos_currentOrientationTool != self.horos_originalOrientation && self.horos_originalOrientation != -1 {
                        self.horos_imageView?.xFlipped = false
                        self.horos_imageView?.yFlipped = false
                        self.horos_imageView?.rotation = 0
                    }

                    self.horos_orientationMatrix?.isEnabled = false

                    if (d?.count ?? 0) > 0 && (self.horos_fileList(at: 0)?.count ?? 0) > 0,
                       let previousSeriesID = (objcValue(self.horos_fileList(at: 0)!.object(at: 0), "series") as? NSManagedObject)?.objectID,
                       previousSeriesID.isEqual(to: (objcValue(d!.object(at: 0), "series") as? NSManagedObject)?.objectID) {
                        sameSeries = true
                    }

                    // Release previous data
                    self.finalizeSeriesViewing()

                    BrowserController.currentBrowser()?.database?.lock()

                    if let e = objcTry({
                        self.horos_orientationMatrix?.selectCell(withTag: 0)

                        // The former code stored these retained without releasing the
                        // previous values (a leak); the retain setters release them.
                        self.horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
                        self.horos_curConvMenu = NSLocalizedString("No Filter", comment: "")
                        self.horos_curWLWWMenu = NSLocalizedString("Default WL & WW", comment: "")

                        self.horos_curMovieIndex = 0
                        self.horos_maxMovieIndex = 1
                        self.horos_subCtrlMaskID = -2
                        self.horos_assignRegisteredViewer(nil)
                        self.horos_resampleRatio = 1.0

                        // volumeData[ 0] = v; [volumeData[ 0] retain];
                        self.horos_assignVolumeData(objcRetain(v), at: 0)
                        self.horos_sendDidAllocateVolumeDataNotification(forMovieIndex: 0)

                        self.horos_direction = 1

                        // [f retain]; pixList[ 0] = f;
                        self.horos_assignPixList(objcRetain(f), at: 0)

                        // Prepare pixList for image thick slab
                        i = 0
                        while i < (self.horos_pixList(at: 0)?.count ?? 0) {
                            dcmPixSetArrayPix(self.horos_pixList(at: 0)!.object(at: i) as? DCMPix, self.horos_pixList(at: 0), Int16(truncatingIfNeeded: i))
                            i += 1
                        }

                        if (d?.count ?? 0) == 0 { d = nil }
                        // [d retain]; fileList[ 0] = d;
                        self.horos_assignFileList(objcRetain(d), at: 0)

                        if let e = objcTry({
                            // Prepare roiList
                            self.horos_assignRoiList(objcRetain(NSMutableArray(capacity: 0)), at: 0)
                            self.horos_assignCopyRoiList(objcRetain(NSMutableArray(capacity: 0)), at: 0)
                            i = 0
                            while i < (self.horos_pixList(at: 0)?.count ?? 0) {
                                self.horos_roiList(at: 0)?.add(NSMutableArray())
                                self.horos_copyRoiList(at: 0)?.add(NSData())
                                i += 1
                            }
                            self.loadROI(0)

                            dcmViewSetPixels(self.horos_imageView, self.horos_pixList(at: 0), files: self.horos_fileList(at: 0), rois: self.horos_roiList(at: 0),
                                             firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: !sameSeries)

                            self.horos_imageView?.setIndexWithReset(0, true)
                        }) {
                            NSLog("Exception change image data: %@", e)
                        }

                        let pic = self.horos_imageView?.curDCM

                        self.setWindowTitle(self)

                        self.horos_slider?.maxValue = Double((self.horos_pixList(at: 0)?.count ?? 0) - 1)
                        self.horos_slider?.numberOfTickMarks = self.horos_pixList(at: 0)?.count ?? 0
                        self.adjustSlider()

                        if (self.horos_fileList(at: 0)?.count ?? 0) == 1 {
                            self.horos_speedSlider?.isEnabled = false
                            self.horos_slider?.isEnabled = false
                        } else {
                            if (pic?.cineRate() ?? 0) != 0 {
                                self.horos_speedSlider?.floatValue = pic?.cineRate() ?? 0
                            } else if UserDefaults.standard.float(forKey: "defaultFrameRate") != 0 {
                                self.horos_speedSlider?.floatValue = UserDefaults.standard.float(forKey: "defaultFrameRate")
                            }

                            self.horos_speedSlider?.isEnabled = true
                            self.horos_slider?.isEnabled = true
                        }

                        self.horos_subCtrlOnOff?.state = .off
                        self.horos_convPopup?.selectItem(at: 0)
                        self.horos_stacksFusion?.intValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "stackThickness"))
                        self.horos_sliderFusion?.intValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "stackThickness"))
                        self.horos_sliderFusion?.isEnabled = false
                        self.horos_activatedFusion?.state = .off

                        // maxMovieIndex was just reset to 1: this series has one
                        // time. A movie left running here kept firing behind a
                        // control switched off and still titled "Stop", so the
                        // images went on changing and the button that would stop
                        // them could not be pressed (#374, A224).
                        if FourDSeriesGuard.playControlApplies(timeCount: Int(self.horos_maxMovieIndex)) == false {
                            self.movieStop(self)
                        }

                        self.horos_movieRateSlider?.isEnabled = false
                        self.horos_moviePosSlider?.isEnabled = false
                        self.horos_moviePlayStop?.isEnabled = false

                        if UserDefaults.standard.float(forKey: "defaultMovieRate") != 0 {
                            self.horos_movieRateSlider?.floatValue = UserDefaults.standard.float(forKey: "defaultMovieRate")
                            self.horos_movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(self.movieRate()))
                        }

                        self.horos_speedText?.stringValue = String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"), Double(self.frameRate() * self.horos_direction))

                        self.horos_seriesView?.setPixels(self.horos_pixList(at: 0), files: self.horos_fileList(at: 0), rois: self.horos_roiList(at: 0),
                                                         firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: !sameSeries)

                        if ((self.horos_pixList(at: 0)?.object(at: 0) as? DCMPix)?.isRGB ?? false) == false {
                            if objcIsEqualToString(self.modality(), "PT") || (UserDefaults.standard.bool(forKey: "clutNM") == true && objcIsEqualToString(self.modality(), "NM")) {
                                if objcIsEqualToString(UserDefaults.standard.string(forKey: "PET Clut Mode"), "B/W Inverse") {
                                    self.applyCLUTString("B/W Inverse")
                                } else {
                                    self.applyCLUTString(UserDefaults.standard.string(forKey: "PET Default CLUT"))
                                }
                            } else { self.applyCLUTString(NSLocalizedString("No CLUT", comment: "")) }

                            if objcIsEqualToString(self.modality(), "PT") || (UserDefaults.standard.bool(forKey: "OpacityTableNM") == true && objcIsEqualToString(self.modality(), "NM")) {
                                if UserDefaults.standard.bool(forKey: "PETOpacityTable") {
                                    self.applyOpacityString(UserDefaults.standard.string(forKey: "PET Default Opacity Table"))
                                } else { self.applyOpacityString(NSLocalizedString("Linear Table", comment: "")) }
                            } else { self.applyOpacityString(NSLocalizedString("Linear Table", comment: "")) }

                            if (objcIsEqualToString(self.modality(), "CR") || objcIsEqualToString(self.modality(), "DR") || objcIsEqualToString(self.modality(), "DX") || objcIsEqualToString(self.modality(), "MG") || objcIsEqualToString(self.modality(), "XA") || objcIsEqualToString(self.modality(), "RF")) && UserDefaults.standard.bool(forKey: "automatic12BitTotoku") && AppController.canDisplay12Bit() {
                                self.horos_imageView?.setIsLUT12Bit(true)
                                self.horos_display12bitToolbarItemMatrix?.selectCell(withTag: 0)
                            }
                        } else {
                            self.applyCLUTString(NSLocalizedString("No CLUT", comment: ""))
                            self.applyOpacityString(NSLocalizedString("Linear Table", comment: ""))
                        }

                        var curImage = Int32(self.horos_imageView?.curImage ?? 0)
                        // int compared with an NSUInteger count: as the unsigned value.
                        if UInt(bitPattern: Int(curImage)) >= UInt(self.horos_fileList(at: Int(self.horos_curMovieIndex))?.count ?? 0) {
                            curImage = 0
                        }

                        let status = objcValue(self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: Int(curImage)), "series.study.stateText")

                        if status == nil { self.horos_StatusPopup?.selectItem(withTitle: NSLocalizedString("empty", comment: "")) }
                        else { _ = self.horos_StatusPopup?.selectItem(withTag: Int(objcIntValue(status))) }

                        var com = objcValue(self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: Int(curImage)), "series.comment") as? String

                        if com == nil || objcIsEqualToString(com, "") {
                            com = objcValue(self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: Int(curImage)), "series.study.comment") as? String
                        }

                        if com == nil || objcIsEqualToString(com, "") { self.horos_CommentsField?.title = NSLocalizedString("Add a comment", comment: "") }
                        else { self.horos_CommentsField?.title = com! }

                        if objcIsEqualToString(((objcValue(self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: 0), "completePath") as? NSString)?.lastPathComponent), "Empty.tif") == false {
                            _ = BrowserController.currentBrowser()?.findAndSelectFile(nil, image: self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: Int(curImage)) as? DicomImage, shouldExpand: false)
                        }

                        ////////

                        if objcCompare(previousPatientUID, objcValue(self.horos_fileList(at: 0)?.object(at: 0), "series.study.patientUID"), [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != .orderedSame {
                            self.buildMatrixPreview()
                            self.showCurrentThumbnail(self)
                        } else {
                            self.showCurrentThumbnail(self)
                        }


                        if UserDefaults.standard.bool(forKey: "onlyDisplayImagesOfSamePatient") {
                            let curPatientUID = objcValue(self.horos_fileList(at: 0)?.object(at: 0), "series.study.patientUID")
                            let curPatientID = objcValue(self.horos_fileList(at: 0)?.object(at: 0), "series.study.patientID")

                            for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()) {
                                let pUID = objcValue((v.fileList() as NSMutableArray?)?.object(at: 0), "series.study.patientUID")
                                let pID = objcValue((v.fileList() as NSMutableArray?)?.object(at: 0), "series.study.patientID")

                                if objcCompare(curPatientUID, pUID, [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != .orderedSame {
                                    if objcIsEqualToString(curPatientID, pID) == false {
                                        v.window?.close()
                                    }
                                }
                            }
                        }

                        // If same study, same patient and same orientation (but NOT same series), try to go the same position (mm) if available
                        if objcIsEqualToString(previousStudyInstanceUID, objcValue(self.horos_fileList(at: 0)?.object(at: 0), "series.study.studyInstanceUID")) {
                            if sameSeries {
                                // Can we find the same DicomImage?

                                var index = NSNotFound

                                if let previousDicomImage {
                                    index = self.horos_fileList(at: 0)?.index(of: previousDicomImage) ?? 0
                                }

                                if index != NSNotFound {
                                    if wasFlipped {
                                        index = (self.horos_fileList(at: 0)?.count ?? 0) &- 1 &- index
                                    }

                                    self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: index))
                                }
                            } else {
                                var keepFusion = false

                                if equalVector && nonZeroVector {
                                    var start = objcFloatValue(objcValue(self.horos_fileList(at: 0)?.object(at: 0), "sliceLocation"))
                                    var end = objcFloatValue(objcValue(self.horos_fileList(at: 0)?.lastObject, "sliceLocation"))

                                    if start == end {
                                        self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: previousCurImage))
                                        self.adjustSlider()
                                        keepFusion = true
                                    } else {
                                        if start > end {
                                            let temp = end

                                            end = start
                                            start = temp
                                        }

                                        if previousLocation >= start && previousLocation <= end {
                                            var index = 0
                                            var smallestdiff: Float = -1, fdiff: Float

                                            var i = 0
                                            while i < (self.horos_fileList(at: 0)?.count ?? 0) {
                                                let slicePosition = objcFloatValue(objcValue(self.horos_fileList(at: 0)!.object(at: i), "sliceLocation"))

                                                fdiff = abs(slicePosition - previousLocation)

                                                if fdiff < smallestdiff || smallestdiff == -1 {
                                                    smallestdiff = fdiff
                                                    index = i
                                                }
                                                i += 1
                                            }

                                            if index != 0 {
                                                if wasFlipped {
                                                    index = (self.horos_fileList(at: 0)?.count ?? 0) &- 1 &- index
                                                }
                                                self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: index))
                                                self.adjustSlider()
                                                keepFusion = true
                                            }
                                        }
                                    }
                                } else if nonZeroVector { // Try to find another viewer, of the same study, with same orientation
                                    for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()) {
                                        if v !== self && v.isDataVolumicIn4D(false,
                                                                            checkEverythingLoaded: SeriesReplaceLoadPolicy.peerVolumicProbeWaitsForLoad,
                                                                            tryToCorrect: SeriesReplaceLoadPolicy.peerVolumicProbeCorrectsPeer)
                                            && objcIsEqualToString(v.studyInstanceUID(), self.studyInstanceUID()) && self.parallel(toViewer: v) && (v.imageView()?.curImage ?? 0) != 0 {
                                            previousLocation = v.currentImage()?.sliceLocation?.floatValue ?? 0

                                            var start = objcFloatValue(objcValue(self.horos_fileList(at: 0)?.object(at: 0), "sliceLocation"))
                                            var end = objcFloatValue(objcValue(self.horos_fileList(at: 0)?.lastObject, "sliceLocation"))
                                            if start > end {
                                                let temp = end

                                                end = start
                                                start = temp
                                            }

                                            if previousLocation >= start && previousLocation <= end {
                                                var index = 0
                                                var smallestdiff: Float = -1, fdiff: Float

                                                var i = 0
                                                while i < (self.horos_fileList(at: 0)?.count ?? 0) {
                                                    let slicePosition = objcFloatValue(objcValue(self.horos_fileList(at: 0)!.object(at: i), "sliceLocation"))

                                                    fdiff = abs(slicePosition - previousLocation)

                                                    if fdiff < smallestdiff || smallestdiff == -1 {
                                                        smallestdiff = fdiff
                                                        index = i
                                                    }
                                                    i += 1
                                                }

                                                if index != 0 {
                                                    if wasFlipped {
                                                        index = (self.horos_fileList(at: 0)?.count ?? 0) &- 1 &- index
                                                    }
                                                    self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: index))
                                                    self.adjustSlider()
                                                    keepFusion = true

                                                    break
                                                }
                                            }
                                        }
                                    }
                                }

                                if keepFusion {
                                    if objcIsEqualToString(self.modality(), "CT") == false { keepFusion = false }
                                }

                                if keepFusion == false {
                                    if self.horos_blending != nil {
                                        self.activateBlending(nil)
                                    }
                                }
                            }
                        } else { //If study ID changed, cancel the fusion, if existing
                            if self.horos_blending != nil { self.activateBlending(nil) }
                        }

                        // [previousStudyInstanceUID release]; [previousPatientUID release]: Swift references.

                        // Is it only key images?
                        let images = self.horos_fileList(at: 0)
                        var onlyKeyImages = false

                        if (images?.count ?? 0) != objcCount(objcValue(images?.object(at: 0), "series.images")) && self.horos_postprocessed == false {
                            onlyKeyImages = true
                            for case let image as NSManagedObject in (images ?? NSMutableArray()) {
                                if ((image.value(forKey: "isKeyImage") as? NSNumber)?.boolValue ?? false) == false { onlyKeyImages = false }
                            }
                        }

                        self.horos_displayOnlyKeyImages = onlyKeyImages
                        self.horos_keyImagePopUpButton?.selectItem(at: self.horos_displayOnlyKeyImages ? 1 : 0)

                        self.horos_windowWillClose = false

                        self.setPostprocessed(false)

                        self.setSyncButtonBehavior(self)

                        if self.window?.isVisible ?? false {
                            self.horos_imageView?.becomeMainWindow()	// This will send the image sync order !
                        }

                        self.setUpdateTilingViewsValue(false)

                        self.selectFirstTilingView()
                        self.horos_imageView?.updateTilingViews()

                        if previousFusionActivated != 0 {
                            self.setFusionMode(Int(previousFusion))

                            _ = self.horos_popFusion?.selectItem(withTag: Int(previousFusion))

                            self.horos_imageView?.sendSyncMessage(0)
                        }

                        if UserDefaults.standard.bool(forKey: "AUTOMATIC FUSE") {
                            self.blendWindows(nil)
                        }

                        self.refreshMenus()

                        let userInfo: [AnyHashable: Any] = ["curImage": NSNumber(value: Int32(self.horos_imageView?.curImage ?? 0))]
                        NotificationCenter.default.post(name: .OsirixDCMUpdateCurrentImage, object: self.horos_imageView, userInfo: userInfo)

                        if previousColumns != 1 || previousRows != 1 {
                            self.horos_imageView = (self.horos_seriesView?.imageViews() as NSMutableArray?)?.object(at: 0) as? DCMView
                            _ = self.horos_imageView?.becomeFirstResponder()
                        }

                        self.setCurWLWWMenu(DCMView.findWLWWPreset(self.horos_imageView?.curWL ?? 0, self.horos_imageView?.curWW ?? 0, self.horos_imageView?.curDCM))

                        self.horos_nonVolumicDataWarningDisplayed = false

                        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()) {
                            v.buildMatrixPreview(false)
                        }

                        let subtractionOffset = self.horos_imageView?.curDCM?.subPixOffset ?? NSPoint.zero
                        self.offsetMatrixSetting((self.threeTestsFivePosibilities(cInt32(Double(subtractionOffset.y))) &* 5) &+ self.threeTestsFivePosibilities(cInt32(Double(subtractionOffset.x))))

                        self.horos_subCtrlSum?.floatValue = 1
                        self.horos_subCtrlPercent?.floatValue = 1

                        self.horos_imageView?.drawing = true
                        self.horos_imageView?.needsDisplay = true

                        // **

                        // Apply saved images tiling or default protocol

                        let study = self.currentStudy()
                        let series = self.currentSeries()

                        var newColumns = Int32(truncatingIfNeeded: previousColumns)
                        var newRows = Int32(truncatingIfNeeded: previousRows)

                        // default protocol
                        WindowLayoutManager.shared()?.setCurrentHangingProtocolForModality(study?.value(forKey: "modality") as? String, description: study?.value(forKey: "studyName") as? String)

                        newColumns = WindowLayoutManager.shared()?.imagesColumns() ?? 0
                        newRows = WindowLayoutManager.shared()?.imagesRows() ?? 0

                        // is there a windows state?

                        if study?.value(forKey: "windowsState") != nil && UserDefaults.standard.bool(forKey: "automaticWorkspaceLoad") {
                            var viewers: Any? = nil
                            if let state = study?.value(forKey: "windowsState") as? Data {
                                viewers = PropertyListSerialization.propertyListFromData(state, mutabilityOption: [], format: nil, errorDescription: nil)
                            }

                            for case let dict as NSObject in ((viewers as? NSArray) ?? NSArray()) {
                                let studyUID = dict.value(forKey: "studyInstanceUID")
                                let seriesUID = dict.value(forKey: "seriesInstanceUID")

                                if objcIsEqualToString(studyUID, study?.value(forKey: "studyInstanceUID")) && objcIsEqualToString(seriesUID, series?.value(forKey: "seriesInstanceUID")) {
                                    newRows = objcIntValue(dict.value(forKey: "rows"))
                                    newColumns = objcIntValue(dict.value(forKey: "columns"))
                                }
                            }
                        }

                        let a = !DCMView.noPropagateSettingsInSeries(forModality: self.modality())

                        for case let view as DCMView in ((self.horos_seriesView?.imageViews() as NSMutableArray?) ?? NSMutableArray()) {
                            if view.copysettingsinseries != a {
                                view.copysettingsinseries = a
                            }
                        }

                        if newRows != 1 || newColumns != 1 {
                            self.setImageRows(newRows, columns: newColumns, rescale: true)
                        }

                        if !sameSeries {
                            self.requestOpeningScaleToFit()
                        }
                    }) {
                        NSLog("***** changeImageData exception : %@", e)
                        self.window?.close()
                    }

                    BrowserController.currentBrowser()?.database?.unlock()

                    self.horos_imageView?.computeColor()

                    self.redrawToolbar()
                }

                NotificationCenter.default.post(name: .OsirixViewerDidChange, object: self, userInfo: nil)

                self.willChangeValue(forKey: "KeyImageCounter")
                self.didChangeValue(forKey: "KeyImageCounter")

                self.horos_imageView?.computeColor()

                if self.horos_exportDCM != nil {
                    self.horos_exportDCM = nil //We want new UNIQUE seriesInstanceUID & studyInstanceUID
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[ViewerController changeImageData::::]")
            }
            NSEnableScreenUpdates()
        }

        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()) {
            if v !== self {
                v.propagateSettings()
            }
        }

        OSIEnvironment.shared()?.viewerControllerDidChangeData(self)
    }

    @objc(cancelOpeningScaleToFit)
    func cancelOpeningScaleToFit() {
        self.horos_openingScaleToFitRequested = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(ViewerController.finishOpeningScaleToFit), object: nil)
    }

    @objc(requestOpeningScaleToFit)
    func requestOpeningScaleToFit() {
        self.cancelOpeningScaleToFit()
        if !UserDefaults.standard.bool(forKey: "ScaleToFitOnOpen") {
            return
        }
        self.horos_openingScaleToFitRequested = true
        // Open safely before the worker finishes the series envelope. Only this
        // pending request authorizes its later application, never a load callback.
        self.perform(#selector(ViewerController.finishOpeningScaleToFit), with: nil, afterDelay: 0.1)
    }

    @objc(finishOpeningScaleToFit)
    func finishOpeningScaleToFit() {
        if !self.horos_openingScaleToFitRequested || self.horos_windowWillClose {
            return
        }
        if delayedTileWindows != 0 {
            // setImageRows and window tiling already have a deferred layout path.
            self.perform(#selector(ViewerController.finishOpeningScaleToFit), with: nil, afterDelay: 0.1)
            return
        }
        if !UserDefaults.standard.bool(forKey: "ScaleToFitOnOpen") {
            self.cancelOpeningScaleToFit(); return
        }
        let pendingContent = self.horos_loadingThread != nil
        if !pendingContent { self.horos_openingScaleToFitRequested = false }
        self.window?.contentView?.layoutSubtreeIfNeeded()
        let wasUpdating = self.updateTilingViewsValue()
        self.setUpdateTilingViewsValue(true)
        // @try … @finally: the setting is restored, then the exception goes on.
        let e = objcTry {
            for case let view as DCMView in ((self.horos_seriesView?.imageViews() as NSMutableArray?) ?? NSMutableArray()) {
                if (view.curDCM?.isLoaded() ?? false) && !NSIsEmptyRect(view.bounds) {
                    let value: NSValue? = pendingContent ? nil : (self.horos_openingContentBoundsByPixels as NSDictionary?)?.object(forKey: NSValue(nonretainedObject: view.dcmPixList)) as? NSValue
                    view.applyOpeningScale(toFit: value != nil ? value!.rectValue : NSRect.zero)
                }
            }
        }
        self.setUpdateTilingViewsValue(wasUpdating)
        if let e { e.raise() }
    }

    @objc(showWindowTransition)
    func showWindowTransition() {
        var screen: NSScreen? = nil

        switch UserDefaults.standard.integer(forKey: "MULTIPLESCREENS") {
        case 1:		// use second screen only
            if NSScreen.screens.count > 1 {
                screen = (NSScreen.screens as NSArray).object(at: 1) as? NSScreen
            } else {
                screen = (NSScreen.screens as NSArray).object(at: 0) as? NSScreen
            }

        case 2:		// use all screens
            screen = (NSScreen.screens as NSArray).object(at: 0) as? NSScreen

        default:	// case 0: use main screen only
            screen = (NSScreen.screens as NSArray).object(at: 0) as? NSScreen
        }

        let screenRect = AppController.usefullRect(for: screen)

        self.window?.setFrame(screenRect, display: true)

        switch UserDefaults.standard.integer(forKey: "WINDOWSIZEVIEWER") {
        case 0: self.setWindowFrame(screenRect, showWindow: false)
        case 1: self.horos_imageView?.resizeWindow(toScale: 1.0)
        case 2: self.horos_imageView?.resizeWindow(toScale: 1.5)
        case 3: self.horos_imageView?.resizeWindow(toScale: 2.0)
        default: break
        }

        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()) {
            if v !== self {
                let userInfo: [AnyHashable: Any] = ["toolIndex": NSNumber(value: Int32(truncatingIfNeeded: v.imageView()?.currentTool.rawValue ?? 0))]
                NotificationCenter.default.post(name: .OsirixDefaultToolModified, object: nil, userInfo: userInfo)

                break
            }
        }
    }

    @objc(openingContentBoundsForPixLists:loadThread:)
    class func openingContentBounds(forPixLists lists: NSArray!, load loadThread: Thread!) -> NSDictionary! {
        objcAssert(!Thread.isMainThread, "Opening content analysis requires a worker thread",
                   #selector(ViewerController.openingContentBounds(forPixLists:load:)), ViewerController.self)
        let results = NSMutableDictionary()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, min(4, ProcessInfo.processInfo.processorCount - 1))
        for case let pixels as NSArray in (lists ?? NSArray()) {
            if loadThread?.isCancelled ?? false { return nil }
            let first = pixels.firstObject as? DCMPix
            if !(first?.isLoaded() ?? false) { continue }
            let width = first?.pwidth ?? 0, height = first?.pheight ?? 0
            let ratio = first?.pixelRatio ?? 0
            var envelope = NSRect.zero
            var compatible = true
            let lock = NSObject()
            for case let pix as DCMPix in pixels {
                if loadThread?.isCancelled ?? false { break }
                queue.addOperation {
                    autoreleasepool {
                        if loadThread?.isCancelled ?? false { return }
                        if !pix.isLoaded() || pix.pwidth != width || pix.pheight != height ||
                            !pix.pixelRatio.isFinite || abs(pix.pixelRatio - ratio) > 1e-6 {
                            objcSynchronized(lock) { compatible = false }
                            return
                        }
                        let hu = objcIsEqualToString(pix.modalityString, "CT") && objcIsEqualToString(pix.rescaleType, "HU")
                        var bounds = HorosContentRect()
                        // Unknown/empty content contributes the full frame; it
                        // must not let a small positive slice over-zoom the stack.
                        var rect = NSMakeRect(0, 0, CGFloat(width), CGFloat(height))
                        if HorosFindContentBounds(pix.fImage, pix.isRGB, hu, width, height, &bounds) {
                            rect = NSMakeRect(bounds.x, bounds.y, bounds.width, bounds.height)
                        }
                        objcSynchronized(lock) { envelope = NSUnionRect(envelope, rect) }
                    }
                }
            }
            // Retained volume storage must outlive in-flight reads, including
            // close/replacement cancellation.
            queue.waitUntilAllOperationsAreFinished()
            if loadThread?.isCancelled ?? false { return nil }
            if compatible {
                results[NSValue(nonretainedObject: pixels)] = NSValue(rect: envelope)
            }
        }
        return results
    }

    @objc(startLoadImageThread)
    func startLoadImageThread() {
        objcAssert(Thread.isMainThread, "Viewer loading must start on the main thread", #selector(ViewerController.startLoadImageThread), self)
        if self.horos_windowWillClose { return }

        self.horos_originalOrientation = -1
        self.horos_openingContentBoundsByPixels = nil

        objcSynchronized(self.horos_loadingThread) {
            self.horos_loadingThread?.cancel()
            if let thread = self.horos_loadingThread { _ = Unmanaged.passUnretained(thread).autorelease() }
            self.horos_assignLoading(nil)
        }

        let d = NSMutableDictionary()

        let volumeDataArray = NSMutableArray()
        let pixListArray = NSMutableArray()
        var z = 0
        while z < Int(self.horos_maxMovieIndex) {
            objcAdd(volumeDataArray, self.horos_volumeData(at: z))
            objcAdd(pixListArray, self.horos_pixList(at: z))
            z += 1
        }

        d.setObject(volumeDataArray, forKey: "volumeDataArray" as NSString)
        d.setObject(pixListArray, forKey: "pixListArray" as NSString)
        d.setObject(self, forKey: "viewerController" as NSString)
        d["computeOpeningContentBounds"] = NSNumber(value: UserDefaults.standard.bool(forKey: "ScaleToFitOnOpen"))

        let tempThread = Thread(target: ViewerController.self, selector: NSSelectorFromString("loadImageData:"), object: d)
        objcSynchronized(tempThread) {
            // loadingThread = tempThread (the +1 of the allocation is the ivar's).
            self.horos_loadingThread = tempThread
            self.horos_loadingThread?.start()
        }

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

        let pixMask = (self.horos_imageView?.dcmPixList as NSMutableArray?)?.object(at: self.horos_subCtrlMaskID) as? DCMPix

        for case let pix as DCMPix in ((self.horos_imageView?.dcmPixList as NSMutableArray?) ?? NSMutableArray()) {
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
        if !objcIsEqualToString(firstPix?.modalityString, "XA") {
            return NSLocalizedString("Subtraction works only for XA modality.", comment: "")
        }
        for movieIndex in 0..<max(Int(self.horos_maxMovieIndex), 1) {
            let list = self.horos_pixList(at: movieIndex) ?? NSMutableArray()
            if list.count < 2 {
                return NSLocalizedString("Subtraction needs a series of at least two images.", comment: "")
            }
            let first = list.object(at: 0) as? DCMPix
            for case let pix as DCMPix in list where pix.pwidth != first?.pwidth || pix.pheight != first?.pheight {
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
            self.horos_subCtrlMaskText?.stringValue = String(format: "2")//changes tool text

            self.horos_subCtrlMinMaxComputed = false
        } else { self.horos_subCtrlOnOff?.isEnabled = false }
    }

    //-(void) loadThread:(DCMPix*) pix
    //{
    //	NSAutoreleasePool	*pool = [[NSAutoreleasePool alloc] init];
    //
    //	[pix CheckLoad];
    //
    //	[processorsLock lock];
    //	if( numberOfThreadsForRelisce >= 0) numberOfThreadsForRelisce--;
    //	[processorsLock unlockWithCondition: 1];
    //
    //	[pool release];
    //}

    @objc(resampleDataIfNeeded:)
    func resampleDataIfNeeded(_ sender: Any!) {
        autoreleasepool {
            if UserDefaults.standard.bool(forKey: "ResampleData") {
                let height = Int32(truncatingIfNeeded: (self.horos_pixList(at: 0)?.object(at: 0) as? DCMPix)?.pheight ?? 0)
                let width = Int32(truncatingIfNeeded: (self.horos_pixList(at: 0)?.object(at: 0) as? DCMPix)?.pwidth ?? 0)
                let minimumValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "ResampleDataIfSmallerOrEqualValue"))
                let destinationValue = UserDefaults.standard.float(forKey: "ResampleDataValue")

                if width <= minimumValue || height <= minimumValue {
                    var ratio: Float

                    if width < height { ratio = Float(width) / destinationValue }
                    else { ratio = Float(height) / destinationValue }

                    if ratio > 0 {
                        let s = self.horos_imageView?.scaleValue ?? 0
                        if self.resampleData(withXFactor: ratio, yFactor: ratio, zFactor: 1.0) {
                            self.horos_imageView?.scaleValue = s * ratio
                        }
                    }
                }
            }
        }
    }


    @objc(areLoadingViewers)
    class func areLoadingViewers() -> Bool {
        for case let v as ViewerController in (ViewerController.get2DViewers() ?? NSMutableArray()) {
            if v.isEverythingLoaded() == false {
                return true
            }
        }
        return false
    }

    @objc(finishLoadImageData:)
    func finishLoadImageData(_ dict: NSDictionary!) {
        objcAssert(Thread.isMainThread, "Viewer load delivery requires the main thread", #selector(ViewerController.finishLoadImageData(_:)), self)
        let completedThread = dict?.object(forKey: "loadThread") as? Thread
        let pixListArray = dict?.object(forKey: "pixListArray") as? NSArray
        // A queued completion belongs to the thread that produced it, including a
        // restart on the same pixels. It must never cancel or detach its successor.
        // (pixListArray.count != maxMovieIndex compares the short as an NSUInteger.)
        if self.horos_windowWillClose || self.horos_requestLoadingCancel || completedThread == nil ||
            completedThread !== self.horos_loadingThread || completedThread!.isCancelled ||
            UInt(pixListArray?.count ?? 0) != UInt(bitPattern: Int(self.horos_maxMovieIndex)) {
            return
        }
        var index = 0
        while index < (pixListArray?.count ?? 0) {
            if (pixListArray!.object(at: index) as AnyObject) !== self.horos_pixList(at: index) { return }
            index += 1
        }

        // [openingContentBoundsByPixels release]; openingContentBoundsByPixels = [[dict objectForKey:…] copy];
        let bounds = (dict?.object(forKey: "openingContentBounds") as? NSObject)?.copy() as? NSDictionary
        self.horos_openingContentBoundsByPixels = bounds as? [AnyHashable: Any]

        // Retire this request before notifying consumers: a plugin/observer may
        // synchronously start the next load from DidLoadImagesNotification.
        if let thread = self.horos_loadingThread { _ = Unmanaged.passUnretained(thread).autorelease() }
        self.horos_assignLoading(nil)
        _ = self.computeOriginalOrientation()

        let firstPix = (pixListArray?.object(at: 0) as? NSArray)?.object(at: 0) as? DCMPix

        // MARK: modality dependant code, once images are already displayed in 2D viewer

        for case let pList as NSArray in (pixListArray ?? NSArray()) {
            for case let p as DCMPix in pList {
                p.maxValueOfSeries = 0
                p.minValueOfSeries = 0
            }
        }

        // MARK: XA
        // pixListArray holds the viewer's own movie lists (checked above), which
        // subtractionUnavailableReason reads, every one of them.
        self.horos_subCtrlMinMaxComputed = false
        self.horos_enableSubtraction = self.subtractionUnavailableReason() == nil

        self.enableSubtraction()

        // MARK: PET

        var isPET = false

        if objcIsEqualToString(firstPix?.modalityString, "PT") {
            isPET = true
        }

        if isPET || (UserDefaults.standard.bool(forKey: "mouseWindowingNM") == true && objcIsEqualToString(firstPix?.modalityString, "NM")) {
            if UserDefaults.standard.integer(forKey: "DEFAULTPETWLWW") != 0 {
                self.horos_imageView?.updatePresentationStateFromSeries()
            }
        }

        if isPET {
            if UserDefaults.standard.bool(forKey: "ConvertPETtoSUVautomatically") {
                self.convertPETtoSUV()
                self.horos_imageView?.setStartWLWW()
            }
        }

        if firstPix?.shutterEnabled ?? false {
            self.setShutterOnOffButton(NSNumber(value: true))
        }

        self.setWindowTitle(self)

        self.horos_originalOrientation = -1
        self.computeIntervalAsync()

        // Complete only a request that survived interaction/workspace changes.
        if self.horos_openingScaleToFitRequested {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(ViewerController.finishOpeningScaleToFit), object: nil)
            self.perform(#selector(ViewerController.finishOpeningScaleToFit), with: nil, afterDelay: 0.1)
        }

        NotificationCenter.default.post(Notification(name: .OsirixViewerControllerDidLoadImages, object: self))

    }
}
