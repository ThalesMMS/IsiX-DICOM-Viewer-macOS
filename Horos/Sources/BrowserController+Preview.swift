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

// The "Preview window policy (#608)" block of BrowserController is implemented
// in Swift since #831: a Swift extension of BrowserController, which stays
// Objective-C, with the same selectors. The instance variables it used are read
// through BrowserController (SwiftIvars) and the file-scope statics of
// BrowserController.m (contextual, contextualRT, withReset,
// waitForRunningProcess, HorosPreviewFrameForImage) through
// BrowserController (SwiftStatics).
//
// An @synchronized is objcSynchronized, the same recursive lock on the same
// object; an @try is HorosObjCException.perform. The pairs of retain/release
// on the DCMPix and NSImage objects are Swift references; the previous frame
// -previewSliderAction: held "to allow the cached system in DCMPix to avoid
// reloading" is kept alive until the end of the same @synchronized block.
// A signed index compared with an NSUInteger count is compared as the unsigned
// value Objective-C converted it to. A float turned into an int follows the
// arm64 conversion (NaN is 0, out of range saturates) instead of trapping.

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

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
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

/// `[object boolValue]` of an NSNumber or an NSString, NO for nil.
fileprivate func objcBoolValue(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
}

/// `[string isEqualToString: other]`: NO when either is nil or not a string.
fileprivate func objcIsEqualToString(_ string: Any?, _ other: Any?) -> Bool {
    guard let string = string as? NSString, let other = other as? String else { return false }
    return string.isEqual(to: other)
}

/// `[[object valueForKey:@"images"] allObjects]`, nil when there is no set.
fileprivate func objcAllImages(_ object: NSObject?) -> NSArray? {
    return (object?.value(forKey: "images") as? NSSet)?.allObjects as NSArray?
}

/// `[sender selectedCell]` of an `id` sender: nil for nil, and the same
/// unrecognized-selector exception as before for a sender without cells.
fileprivate func objcSelectedCell(_ sender: Any?) -> NSCell? {
    guard let sender = sender as AnyObject? else { return nil }
    return sender.perform(NSSelectorFromString("selectedCell"))?.takeUnretainedValue() as? NSCell
}

/// `[array replaceObjectAtIndex:index withObject:object]`: nothing for a nil
/// array, and the exception Foundation raised for a nil object.
fileprivate func objcReplace(_ array: NSMutableArray?, _ index: Int, _ object: Any?) {
    guard let array else { return }
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM replaceObjectAtIndex:withObject:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.replaceObject(at: index, with: object)
}

/// `[array addObject:object]`: nothing for a nil array, and the exception
/// Foundation raised for a nil object.
fileprivate func objcAdd(_ array: NSMutableArray?, _ object: Any?) {
    guard let array else { return }
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.add(object)
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

/// The same for an NSInteger.
fileprivate func objcInt(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    if value >= Float(Int.max) { return Int.max }
    if value <= Float(Int.min) { return Int.min }
    return Int(value)
}

/// The same for a double assigned to an int.
fileprivate func objcInt32(_ value: Double) -> Int32 {
    if value.isNaN { return 0 }
    if value >= Double(Int32.max) { return Int32.max }
    if value <= Double(Int32.min) { return Int32.min }
    return Int32(value)
}

/// `i < [array count]` of a signed index: the index compared as the
/// NSUInteger it was converted to.
@inline(__always)
fileprivate func objcUnsignedLess(_ index: Int, _ count: Int) -> Bool {
    return UInt(bitPattern: index) < UInt(bitPattern: count)
}

/// N2LocalizedSingularPluralCount of N2Stuff.h.
fileprivate func previewSingularPluralCount(_ c: Int32, _ s: String?, _ p: String?) -> String {
    return String(format: "%@ %@",
                  NumberFormatter.localizedString(from: NSNumber(value: Int(c)), number: .decimal),
                  objcFormatArgument(c == 1 ? s : p))
}

/// What a pass of the loop of -matrixLoadIcons: did inside its @try.
fileprivate enum LoadIconsStep {
    case next       // continue
    case stop       // break
    case notFound   // fell out of the @try: the "not found" icon
}

extension BrowserController: PreviewViewWindowDelegate {}

public extension BrowserController {

    // MARK: Preview window policy (#608)

    @objc(previewView:didRequestWindowLevel:width:)
    func previewView(_ view: PreviewView!, didRequestWindowLevel wl: Float, width ww: Float) {
        if view !== horos_imageView {
            return
        }

        if horos_previewWindowPolicy?.recordRequested(level: wl, width: ww) == true {
            return
        }

        if ww > 0 && ww.isFinite && wl.isFinite {
            return // the window already on screen, re-asserted by a redraw
        }

        // A width of zero asks for automatic selection, so the preview computes its
        // window again rather than showing an image two units wide. Not from inside
        // this call: the view is in the middle of applying one (#608).
        perform(#selector(applyPreviewWindowForCurrentFrame), with: nil, afterDelay: 0)
    }

    @objc(applyPreviewWindowForCurrentFrame)
    func applyPreviewWindowForCurrentFrame() {
        applyPreviewWindow(for: nil, pix: nil)
    }

    // The window this frame should be shown with, and the reason it is that window.
    // Separates the three sources the preview used to conflate: what the file says,
    // what the pixels say, and what a person chose (#608).
    @objc(applyPreviewWindowForImage:pix:)
    func applyPreviewWindow(for imageObj: DicomImage!, pix dcmPix: DCMPix!) {
        guard let previewWindowPolicy = horos_previewWindowPolicy, let imageView = horos_imageView else {
            return
        }

        var dcmPix: DCMPix? = dcmPix
        if dcmPix == nil {
            dcmPix = imageView.curDCM
        }

        guard let dcmPix else {
            return
        }

        // Every entry point reaches this, including the first display, which sets
        // the pixel list rather than moving the slider. When the caller has no row
        // to hand over, the frame on screen knows which one it came from.
        var imageObj: DicomImage? = imageObj
        if imageObj == nil {
            if objcTry({ imageObj = dcmPix.imageObj() }) != nil { imageObj = nil }
        }

        var seriesKey: String? = nil
        var path: String? = nil
        var refused = false

        if objcTry({
            // A Structured Report or a Segmentation has no frame to window; the
            // preview keeps its icon and the policy is not consulted (#380 D).
            let frame = BrowserController.horos_previewFrame(for: imageObj, frame: Int32(truncatingIfNeeded: dcmPix.frameNo))
            if let frame, PreviewIdentity.refusalForPreviewing(frame) != nil {
                refused = true
                return
            }

            seriesKey = imageObj?.value(forKeyPath: "series.seriesDICOMUID") as? String
            path = imageObj?.value(forKey: "completePath") as? String

            if ((seriesKey as NSString?)?.length ?? 0) == 0 {
                seriesKey = String(format: "series.id %@", objcFormatArgument(imageObj?.value(forKeyPath: "series.id")))
            }
        }) != nil { seriesKey = nil }
        if refused {
            return
        }

        if ((path as NSString?)?.length ?? 0) == 0 {
            path = dcmPix.srcFile
        }

        let needsDefaults = previewWindowPolicy.beginFrame(seriesKey: seriesKey,
                                                           path: path,
                                                           revisionKey: dcmPix.parsedFileCacheKey())

        var window: PreviewWindow? = nil

        if needsDefaults {
            let isColor = dcmPix.isColorPreviewFrame()
            let modality = dcmPix.modalityString
            let dicomWindow = dcmPix.dicomPreviewWindow() as? PreviewWindow

            // Sampling the frame costs a pass over the pixels. Only pay for it when
            // the ladder can actually reach the computed window.
            var automatic: PreviewWindow? = nil
            if PreviewWindowPolicy.needsAutomaticWindow(modality: modality, dicom: dicomWindow, isColor: isColor) {
                automatic = dcmPix.automaticPreviewWindow() as? PreviewWindow
            }

            // The frame's own minimum and maximum, only when there was nothing to
            // sample: a uniform frame has no percentiles worth taking, and the
            // stored bit range would show it as flat grey (#610).
            var frameRange: PreviewWindow? = nil
            if automatic == nil && isColor == false && (dicomWindow == nil || dicomWindow?.isValid == false || objcIsEqualToString((modality as NSString?)?.uppercased, "MR")) {
                frameRange = dcmPix.frameRangePreviewWindow() as? PreviewWindow
            }

            window = previewWindowPolicy.window(modality: modality,
                                                dicom: dicomWindow,
                                                automatic: automatic,
                                                frameRange: frameRange,
                                                storedRange: dcmPix.storedRangePreviewWindow() as? PreviewWindow,
                                                isColor: isColor)
        } else {
            // Same series, same revision: whatever is on screen stays, and an
            // adjustment a person made outlives the scroll and the late batch.
            window = previewWindowPolicy.manualWindow
            if window == nil {
                window = previewWindowPolicy.appliedWindow
            }
        }

        guard let window, window.isValid else {
            return
        }

        var currentWL: Float = 0, currentWW: Float = 0
        imageView.getWLWW(&currentWL, &currentWW)

        // Re-applying the same numbers would reload the textures for nothing.
        if currentWW == window.width && currentWL == window.level {
            return
        }

        imageView.apply(window)
    }

    @objc(previewSliderAction:)
    @IBAction func previewSliderAction(_ sender: Any!) {
        var animate = false
        var noOfImages = 0

        let cell = horos_oMatrix?.selectedCell()
        if let cell, horos_dontUpdatePreviewPane == false {
            if cell.isEnabled {
                if !objcUnsignedLess(cell.tag, horos_matrixViewArray?.count ?? 0) { return }

                let outline = horos_databaseOutline
                let aFile = outline.flatMap { $0.item(atRow: $0.selectedRow) } as? NSObject
                let type = aFile?.value(forKey: "type")
                if objcIsEqualToString(type, "Series") &&
                    (objcAllImages(aFile)?.count ?? 0) == 1 &&
                    objcIntValue((objcAllImages(aFile)?.object(at: 0) as? NSObject)?.value(forKey: "numberOfFrames")) > 1 { // multi frame image that is directly selected
                    let image = objcAllImages(aFile)?.object(at: 0) as? NSManagedObject

                    noOfImages = Int(objcIntValue(image?.value(forKey: "numberOfFrames")))
                    animate = true

                    var dcmPix: DCMPix? = nil

                    //Is this image already displayed on the front most 2D viewers? -> take the dcmpix from there
                    let sliderValue = horos_animationSlider?.intValue ?? 0
                    dcmPix = getDCMPix(fromViewerIfAvailable: image?.value(forKey: "completePath") as? String, frameNumber: sliderValue, expectedFrame: BrowserController.horos_previewFrame(for: image as? DicomImage, frame: sliderValue))

                    if dcmPix == nil {
                        dcmPix = DCMPix(path: image?.value(forKey: "completePath") as? String, Int(horos_animationSlider?.intValue ?? 0), noOfImages, nil, Int(horos_animationSlider?.intValue ?? 0), Int(objcIntValue(image?.value(forKeyPath: "series.id"))), isBonjour: !(self.database?.isLocal() ?? false), imageObj: image)
                    }

                    if let dcmPix {
                        objcSynchronized(horos_previewPixThumbnails) {
                            horos_previewPix?.replaceObject(at: cell.tag, with: dcmPix)
                        }

                        horos_imageView?.setIndex(Int16(truncatingIfNeeded: cell.tag))

                        // The window this frame is shown with, and why (#608). The
                        // pair read here used to be dropped on the floor.
                        applyPreviewWindow(for: image as? DicomImage, pix: dcmPix)
                    }
                } else if objcIsEqualToString(type, "Study") || (objcIsEqualToString(type, "Series") && (objcAllImages(aFile)?.count ?? 0) > 1) {
                    let images: NSArray?

                    if objcIsEqualToString(type, "Study") {
                        images = imagesArray((horos_matrixViewArray as NSArray?)?.object(at: cell.tag)) as NSArray?
                    } else {
                        images = imagesArray(aFile) as NSArray?
                        if sender != nil {
                            horos_oMatrix?.selectCell(withTag: Int(horos_animationSlider?.intValue ?? 0))
                        }
                    }

                    if let images, images.count > 0 {
                        if images.count > 1 { noOfImages = images.count }
                        else { noOfImages = Int(objcIntValue((images.object(at: 0) as? NSObject)?.value(forKey: "numberOfFrames"))) }

                        if images.count > 1 || noOfImages == 1 {
                            animate = true

                            if !objcUnsignedLess(Int(horos_animationSlider?.intValue ?? 0), images.count) { return }

                            let imageObj = images.object(at: Int(horos_animationSlider?.intValue ?? 0)) as? NSManagedObject

                            if objcIsEqualToString(horos_imageView?.curDCM?.srcFile, (images.object(at: Int(horos_animationSlider?.intValue ?? 0)) as? NSObject)?.value(forKey: "completePath")) == false || Int(objcIntValue(imageObj?.value(forKey: "frameID"))) != (horos_imageView?.curDCM?.frameNo ?? 0) {
                                var dcmPix: DCMPix? = nil

                                dcmPix = getDCMPix(fromViewerIfAvailable: imageObj?.value(forKey: "completePath") as? String, frameNumber: objcIntValue(imageObj?.value(forKey: "frameID")), expectedFrame: BrowserController.horos_previewFrame(for: imageObj as? DicomImage, frame: objcIntValue(imageObj?.value(forKey: "frameID"))))

                                if dcmPix == nil {
                                    dcmPix = DCMPix(path: imageObj?.value(forKey: "completePath") as? String, Int(horos_animationSlider?.intValue ?? 0), images.count, nil, Int(objcIntValue(imageObj?.value(forKey: "frameID"))), Int(objcIntValue(imageObj?.value(forKeyPath: "series.id"))), isBonjour: !(self.database?.isLocal() ?? false), imageObj: imageObj)
                                }

                                if let dcmPix {
                                    objcSynchronized(horos_previewPixThumbnails) {
                                        let previousDcmPix = horos_previewPix?.object(at: cell.tag) // To allow the cached system in DCMPix to avoid reloading

                                        horos_previewPix?.replaceObject(at: cell.tag, with: dcmPix)

                                        if BrowserController.horos_withReset { horos_imageView?.setIndexWithReset(Int16(truncatingIfNeeded: cell.tag), true) }
                                        else { horos_imageView?.setIndex(Int16(truncatingIfNeeded: cell.tag)) }

                                        applyPreviewWindow(for: imageObj as? DicomImage, pix: dcmPix)

                                        _ = objcTry {
                                            // setIndex: clamps its index, so the frame
                                            // being drawn is not always the one just
                                            // inserted. Freeing the pixels of whatever
                                            // the view is holding is how the preview
                                            // drew released memory (#608).
                                            let drawn = horos_imageView?.curDCM

                                            for case let p as DCMPix in horos_previewPix ?? NSMutableArray() {
                                                if p !== dcmPix && p !== drawn {
                                                    p.kill8bitsImage()
                                                    p.revert(false)
                                                }
                                            }
                                        }

                                        withExtendedLifetime(previousDcmPix) {}
                                    }
                                }
                            }
                        } else if noOfImages > 1 { // It's a multi-frame single image
                            animate = true

                            let first = images.object(at: 0) as? NSManagedObject

                            if objcIsEqualToString(horos_imageView?.curDCM?.srcFile, first?.value(forKey: "completePath")) == false
                                || (horos_imageView?.curDCM?.frameNo ?? 0) != Int(horos_animationSlider?.intValue ?? 0)
                                || (horos_imageView?.curDCM?.serieNo ?? 0) != Int(objcIntValue(first?.value(forKeyPath: "series.id"))) {
                                var dcmPix: DCMPix? = nil

                                dcmPix = getDCMPix(fromViewerIfAvailable: first?.value(forKey: "completePath") as? String, frameNumber: horos_animationSlider?.intValue ?? 0, expectedFrame: BrowserController.horos_previewFrame(for: first as? DicomImage, frame: horos_animationSlider?.intValue ?? 0))

                                if dcmPix == nil {
                                    dcmPix = DCMPix(path: first?.value(forKey: "completePath") as? String, Int(horos_animationSlider?.intValue ?? 0), noOfImages, nil, Int(horos_animationSlider?.intValue ?? 0), Int(objcIntValue(first?.value(forKeyPath: "series.id"))), isBonjour: !(self.database?.isLocal() ?? false), imageObj: first)
                                }

                                if let dcmPix {
                                    objcSynchronized(horos_previewPixThumbnails) {
                                        let previousDcmPix = horos_previewPix?.object(at: cell.tag) // To allow the cached system in DCMPix to avoid reloading

                                        horos_previewPix?.replaceObject(at: cell.tag, with: dcmPix)

                                        if BrowserController.horos_withReset { horos_imageView?.setIndexWithReset(Int16(truncatingIfNeeded: cell.tag), true) }
                                        else { horos_imageView?.setIndex(Int16(truncatingIfNeeded: cell.tag)) }

                                        applyPreviewWindow(for: first as? DicomImage, pix: dcmPix)

                                        _ = objcTry {
                                            let drawn = horos_imageView?.curDCM

                                            for case let p as DCMPix in horos_previewPix ?? NSMutableArray() {
                                                if p !== dcmPix && p !== drawn {
                                                    p.kill8bitsImage()
                                                    p.revert(false)
                                                }
                                            }
                                        }

                                        withExtendedLifetime(previousDcmPix) {}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        _ = animate // set, never read, as before
    }


    @objc(previewPerformAnimation:)
    func previewPerformAnimation(_ sender: Any!) {
        //[NSThread detachNewThreadSelector: @selector( createThread) toTarget: self withObject: nil];

        //[self outlineViewRefresh];

        if (AppController.shared()?.isSessionInactive ?? false) || BrowserController.horos_waitForRunningProcess {
            return
        }

        // Wait loading all images !!!
        if self.database == nil { return }
        // if( bonjourDownloading) return;
        if (horos_animationCheck?.state ?? .off) == .off { return }

        if (self.window?.isKeyWindow ?? false) == false { return }
        guard let animationSlider = horos_animationSlider, animationSlider.isEnabled else { return }

        var pos = animationSlider.intValue
        pos &+= 1
        if Double(pos) > animationSlider.maxValue { pos = 0 }

        animationSlider.intValue = pos
        previewSliderAction(nil)
    }

    @objc(scrollWheel:)
    override func scrollWheel(with theEvent: NSEvent) {
        var reverseScrollWheel: Float

        if UserDefaults.standard.bool(forKey: "Scroll Wheel Reversed") {
            reverseScrollWheel = -1.0
        } else {
            reverseScrollWheel = 1.0
        }

        var change = reverseScrollWheel * Float(theEvent.deltaY)

        if theEvent.deltaY == 0 {
            return
        }

        var pos = horos_animationSlider?.intValue ?? 0

        if change > 0 {
            change = 1
            pos &+= Int32(change)
        } else {
            change = -1
            pos &+= Int32(change)
        }

        if Double(pos) > (horos_animationSlider?.maxValue ?? 0) { pos = 0 }
        if pos < 0 { pos = objcInt32(horos_animationSlider?.maxValue ?? 0) }

        horos_animationSlider?.intValue = pos

        // A wheel delivers one notch at a time and each one used to decode a frame
        // before the next arrived. Keep only the newest position - the slider
        // already holds it - so one burst costs one decode and the frame finally
        // drawn is the one asked for (#608).
        if let previewRedrawCoalescer = horos_previewRedrawCoalescer {
            unowned(unsafe) let browser = self
            let slider = horos_animationSlider
            previewRedrawCoalescer.request { browser.previewSliderAction(slider) }

            if theEvent.phase == .ended || theEvent.momentumPhase == .ended {
                previewRedrawCoalescer.flush()
            }
        } else {
            previewSliderAction(horos_animationSlider)
        }
    }

    @objc(matrixPressed:)
    @IBAction func matrixPressed(_ sender: Any!) {
        let theCell = objcSelectedCell(sender)
        var index: Int32

        self.window?.makeFirstResponder(horos_oMatrix)

        if (theCell?.tag ?? 0) >= 0 {
            let dcmFile = horos_databaseOutline.flatMap { $0.item(atRow: $0.selectedRow) } as? NSObject

//            if (dcmFile)
//            {
//                [theCell setLineBreakMode: NSLineBreakByCharWrapping];
//                [theCell setFont:[NSFont systemFontOfSize: [self fontSize: @"dbMatrixFont"]]];
//
////                [theCell setRepresentedObject: [dcmFile objectID]];
//
//                [theCell setImagePosition: NSImageBelow];
//                [theCell setTransparent:NO];
//                [theCell setEnabled:YES];
//
//                [theCell setButtonType:NSPushOnPushOffButton];
//                [theCell setBezelStyle:NSShadowlessSquareBezelStyle];
//                //[theCell setShowsStateBy:NSPushInCellMask];
//                [theCell setHighlightsBy:NSContentsCellMask];
//                [theCell setImageScaling:NSImageScaleProportionallyDown];
//                [theCell setBordered:YES];
//            }


            if objcIsEqualToString(dcmFile?.value(forKey: "type"), "Series") && (objcAllImages(dcmFile)?.count ?? 0) > 1 {
                horos_animationSlider?.intValue = Int32(truncatingIfNeeded: theCell?.tag ?? 0)
                previewSliderAction(nil)

                // ******************************

                return
            }
        }


        horos_animationSlider?.isEnabled = false
        horos_animationSlider?.maxValue = 0
        horos_animationSlider?.numberOfTickMarks = 1
        horos_animationSlider?.intValue = 0

        if (theCell?.tag ?? 0) >= 0 {
            let dcmFile = horos_databaseOutline.flatMap { $0.item(atRow: $0.selectedRow) } as? NSObject

            if dcmFile != nil {
//                [theCell setLineBreakMode: NSLineBreakByCharWrapping];
//                [theCell setFont:[NSFont systemFontOfSize: [self fontSize: @"dbMatrixFont"]]];
//
//                [theCell setRepresentedObject: [dcmFile objectID]];
//
//                [theCell setImagePosition: NSImageBelow];
//                [theCell setTransparent:NO];
//                [theCell setEnabled:YES];
//
//                [theCell setButtonType:NSPushOnPushOffButton];
//                [theCell setBezelStyle:NSShadowlessSquareBezelStyle];
//                [theCell setShowsStateBy:NSPushInCellMask];
//                [theCell setHighlightsBy:NSContentsCellMask];
//                [theCell setImageScaling:NSImageScaleProportionallyDown];
//                [theCell setBordered:YES];
            }

            if objcIsEqualToString(dcmFile?.value(forKey: "type"), "Study") == false {
                index = Int32(truncatingIfNeeded: theCell?.tag ?? 0)
                horos_imageView?.setIndex(Int16(truncatingIfNeeded: index))
            }

            initAnimationSlider()
        }

        resetROIsAndKeysButton()
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
        objcSynchronized(horos_previewPixThumbnails) {
            self.horos_previewPix = NSMutableArray()

            // A thumbnail thread that started before this point is now publishing
            // into a list nobody is showing. Pointer identity alone cannot say so:
            // the allocator may hand the same address back (#608).
            horos_incrementPreviewPixGeneration() // previewPixGeneration++

            horos_previewPixThumbnails?.removeAllObjects()
        }

        objcSynchronized(self) {
            horos_setDCMDone = false
            horos_loadPreviewIndex = 0

            previewMatrixScrollViewFrameDidChange(nil)

            var rows = 0, columns = 0
            horos_oMatrix?.getNumberOfRows(&rows, columns: &columns); if columns < 1 { columns = 1 }

            var i = 0
            while i < rows * columns {
                let cell = horos_oMatrix?.cell(atRow: i / columns, column: i % columns) as? NSButtonCell
                cell?.tag = i
                cell?.isTransparent = (i >= noOfImages)
                cell?.isEnabled = false
                cell?.font = NSFont.systemFont(ofSize: CGFloat(fontSize("dbMatrixFont")))
                cell?.imagePosition = .imageBelow
                cell?.title = NSLocalizedString("loading...", comment: "")
                cell?.image = nil
                cell?.bezelStyle = .shadowlessSquare
                i += 1
            }

            horos_imageView?.setPixels(nil, files: nil, rois: nil, firstImage: 0, level: 0, reset: true)
        }
    }

    @objc(matrixNewIcon::)
    func matrixNewIcon(_ index: Int, _ curFile: NSManagedObject!) {
        do {
            let i = index
            var img: NSImage? = nil

            guard let curFile else {
                horos_oMatrix?.needsDisplay = true
                return
            }

            var bail = false
            objcSynchronized(horos_previewPixThumbnails) {
                if !objcUnsignedLess(i, horos_previewPix?.count ?? 0) { bail = true; return }
                if !objcUnsignedLess(i, horos_previewPixThumbnails?.count ?? 0) { bail = true; return }

                img = horos_previewPixThumbnails?.object(at: i) as? NSImage
                if img == nil { NSLog("Error: [previewPixThumbnails objectAtIndex: i] == nil") }
            }
            if bail { return }

            //        [_database lock];
            if let ne = objcTry({
                var modality: String?, seriesSOPClassUID: String?, fileType: String?

                if objcIsEqualToString(curFile.value(forKey: "type"), "Image") {
                    modality = curFile.value(forKey: "modality") as? String
                    seriesSOPClassUID = curFile.value(forKeyPath: "series.seriesSOPClassUID") as? String
                    fileType = curFile.value(forKey: "fileType") as? String
                } else { // Series
                    seriesSOPClassUID = curFile.value(forKey: "seriesSOPClassUID") as? String

                    let im = (curFile.value(forKey: "images") as? NSSet)?.anyObject() as? NSObject
                    modality = im?.value(forKey: "modality") as? String
                    fileType = im?.value(forKey: "fileType") as? String

                    if img !== horos_notFoundImage {
                        if curFile.value(forKey: "thumbnail") == nil {
                            if UserDefaults.standard.bool(forKey: "StoreThumbnailsInDB") {
                                let data = BrowserController.produceJPEGThumbnail(img)
                                curFile.setValue(data, forKey: "thumbnail")
                            }
                        }
                    }
                }

                if img != nil || (modality as NSString?)?.hasPrefix("RT") == true {
                    var rows = 0, cols = 0; horos_oMatrix?.getNumberOfRows(&rows, columns: &cols); if cols < 1 { cols = 1 }
                    let cell = horos_oMatrix?.cell(atRow: i / cols, column: i % cols) as? NSButtonCell

                    cell?.lineBreakMode = .byCharWrapping
                    cell?.font = NSFont.systemFont(ofSize: CGFloat(fontSize("dbMatrixFont")))

                    cell?.representedObject = curFile.objectID

                    cell?.imagePosition = .imageBelow
                    cell?.isTransparent = false
                    cell?.isEnabled = true

                    cell?.setButtonType(.pushOnPushOff)
                    cell?.bezelStyle = .shadowlessSquare
                    cell?.imageScaling = .scaleProportionallyDown
                    cell?.isBordered = true

                    cell?.action = #selector(matrixPressed(_:))

                    if objcIsEqualToString(modality, "RTSTRUCT") {
                        BrowserController.horos_contextualRTMenu?.item(at: 0)?.action = #selector(createROIsFromRTSTRUCT(_:))
                        cell?.menu = BrowserController.horos_contextualRTMenu
                    } else {
                        cell?.menu = BrowserController.horos_contextualMenu
                    }

                    var name = curFile.value(forKey: "name") as? NSString

                    if name == nil {
                        name = ""
                    }

                    if (name?.length ?? 0) > 18 {
                        cell?.font = NSFont.systemFont(ofSize: CGFloat(fontSize("dbSmallMatrixFont")))
                        name = name?.stringByTruncating(toLength: 36) // 2 lines
                    }

                    if (name?.length ?? 0) == 0 {
                        name = modality as NSString?
                    }

                    if (modality as NSString?)?.hasPrefix("RT") == true {
                        cell?.title = String(format: "%@\r%@", objcFormatArgument(name), objcFormatArgument(modality))
                    } else if objcIsEqualToString(fileType, "DICOMMPEG2") {
                        let count = Int(objcIntValue(curFile.value(forKey: "noFiles")))
                        cell?.title = String(format: NSLocalizedString("MPEG-2 Series\r%@\r%d Images", comment: ""), objcFormatArgument(name), Int32(truncatingIfNeeded: count))
                        img = Bundle.main.pathForImageResource("mpeg2").flatMap { NSImage(contentsOfFile: $0) }
                    } else if objcIsEqualToString(curFile.value(forKey: "type"), "Series") {
                        var count = objcIntValue(curFile.value(forKey: "noFiles"))
                        var singleType: String? = nil, pluralType: String? = nil
                        let firstImageFrames = { objcIntValue(((curFile.value(forKey: "images") as? NSSet)?.anyObject() as? NSObject)?.value(forKey: "numberOfFrames")) }

                        if DCMAbstractSyntaxUID.isStructuredReport(seriesSOPClassUID) || DCMAbstractSyntaxUID.isPDF(seriesSOPClassUID) {
                            if count <= 1 && firstImageFrames() >= 1 {
                                count = firstImageFrames()
                            }

                            singleType = NSLocalizedString("Page", comment: "")
                            pluralType = NSLocalizedString("Pages", comment: "")
                        } else if count == 1 && firstImageFrames() > 1 {
                            count = firstImageFrames()
                            singleType = NSLocalizedString("Frame", comment: "")
                            pluralType = NSLocalizedString("Frames", comment: "")
                        } else if count == 0 {
                            count = objcIntValue(curFile.value(forKey: "rawNoFiles"))
                            if count <= 1 && firstImageFrames() >= 1 {
                                count = firstImageFrames()
                            }

                            singleType = NSLocalizedString("Object", comment: "")
                            pluralType = NSLocalizedString("Objects", comment: "")
                        } else {
                            singleType = NSLocalizedString("Image", comment: "")
                            pluralType = NSLocalizedString("Images", comment: "")
                        }

                        cell?.title = String(format: "%@\r%@", objcFormatArgument(name), previewSingularPluralCount(count, singleType, pluralType))
                    } else if objcIsEqualToString(curFile.value(forKey: "type"), "Image") {
                        if DCMAbstractSyntaxUID.isStructuredReport(seriesSOPClassUID) || DCMAbstractSyntaxUID.isPDF(seriesSOPClassUID) {
                            cell?.title = String(format: NSLocalizedString("Page %d", comment: ""), Int32(truncatingIfNeeded: i + 1))
                        } else if objcFloatValue(curFile.value(forKey: "sliceLocation")) != 0 {
                            cell?.title = String(format: NSLocalizedString("Image %d\r%.2f", comment: ""), Int32(truncatingIfNeeded: i + 1), Double(objcFloatValue(curFile.value(forKey: "sliceLocation"))))
                        } else {
                            cell?.title = String(format: NSLocalizedString("Image %d", comment: ""), Int32(truncatingIfNeeded: i + 1))
                        }
                    }

                    cell?.setButtonType(.pushOnPushOff)

                    if objcBoolValue((UserDefaults.standard.persistentDomain(forName: "com.apple.CoreGraphics") as NSDictionary?)?.object(forKey: "DisplayUseInvertedPolarity")) {
                        let ii = img?.imageInverted()

                        img = ii
                    }

                    cell?.highlightsBy = [] // don't show highlight
                    switch UserDefaults.standard.integer(forKey: "dbFontSize") {
                    case -1:
                        cell?.image = img?.imageByScalingProportionallyUsingNSImage(0.6)
                    case 0:
                        cell?.image = img
                    case 1:
                        cell?.image = img?.imageByScalingProportionallyUsingNSImage(1.3)
                    default:
                        break
                    }

                    if horos_setDCMDone == false {
                        let index = horos_databaseOutline?.selectedRowIndexes
                        if (index?.count ?? 0) >= 1 {
                            let aFile = horos_databaseOutline?.item(atRow: index?.first ?? NSNotFound)

                            objcSynchronized(horos_previewPixThumbnails) {
                                horos_imageView?.setPixels(horos_previewPix, files: imagesArray(aFile, preferredObject: Int32(bitPattern: oAny.rawValue)), rois: nil, firstImage: Int16(truncatingIfNeeded: horos_oMatrix?.selectedCell()?.tag ?? 0), level: CChar(UInt8(ascii: "i")), reset: true)
                            }

                            horos_imageView?.stringID = "previewDatabase"

                            // The first frame of a new selection: choose its window
                            // here too, not only when the slider moves (#608).
                            applyPreviewWindow(for: nil, pix: nil)

                            horos_setDCMDone = true
                        }
                    }
                } else { // Show Error Button
                    var rows = 0, cols = 0; horos_oMatrix?.getNumberOfRows(&rows, columns: &cols); if cols < 1 { cols = 1 }
                    let cell = horos_oMatrix?.cell(atRow: i / cols, column: i % cols) as? NSButtonCell

                    cell?.lineBreakMode = .byCharWrapping
                    cell?.font = NSFont.systemFont(ofSize: CGFloat(fontSize("dbMatrixFont")))

                    cell?.representedObject = nil

                    cell?.imagePosition = .imageBelow
                    cell?.isTransparent = false
                    cell?.isEnabled = false

                    cell?.setButtonType(.pushOnPushOff)
                    cell?.bezelStyle = .shadowlessSquare
                    cell?.imageScaling = .scaleProportionallyDown
                    cell?.isBordered = true

                    if let cell { horos_oMatrix?.setToolTip(NSLocalizedString("File not readable", comment: ""), for: cell) }
                    cell?.title = NSLocalizedString("File not readable", comment: "")
                    cell?.image = nil
                    cell?.tag = i
                }
            }) {
                if ne.name != .objectInaccessibleException {
                    _N2LogExceptionImpl(ne, true, "-[BrowserController matrixNewIcon::]")
                }
            }
            //            [_database unlock];

            _ = img
        }
        horos_oMatrix?.needsDisplay = true
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

            if let e = objcTry({
                if objcIsEqualToString(curObj?.value(forKey: "type"), "Series") {
                    curObj = (childrenArray(curObj) as NSArray?)?.object(at: 0) as? NSObject
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[BrowserController pdfPreview:]")
            }

            //	[_database unlock];

            NSLog("%@", objcFormatArgument(curObj?.value(forKey: "completePath")))

            let dcmObject = (curObj?.value(forKey: "completePath") as? String).flatMap { HorosDCMTKObject(contentsOfFile: $0) }
            let encapsulatedPDF = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data
            let fileManager = FileManager.default
            if let pathToPDF, fileManager.createFile(atPath: pathToPDF, contents: encapsulatedPDF, attributes: nil) { NSWorkspace.shared.openFile(pathToPDF, withApplication: nil, andDeactivate: true) }
            else { NSLog("couldn't open pdf") }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    @objc(matrixDisplayIcons:)
    func matrixDisplayIcons(_ sender: Any!) {
        //	if( bonjourDownloading) return;
        if self.database == nil { return }
        if (AppController.shared()?.isSessionInactive ?? false) || BrowserController.horos_waitForRunningProcess { return }

        if let ne = objcTry({
            objcSynchronized(horos_previewPixThumbnails) {
                let count = horos_previewPix?.count ?? 0
                if count > 0 && objcUnsignedLess(horos_loadPreviewIndex, count) {
                    var i = 0
                    while objcUnsignedLess(i, horos_previewPix?.count ?? 0) {
                        var rows = 0, cols = 0; horos_oMatrix?.getNumberOfRows(&rows, columns: &cols); if cols < 1 { cols = 1 }
                        let cell = horos_oMatrix?.cell(atRow: i / cols, column: i % cols) as? NSButtonCell

                        if (cell?.isEnabled ?? false) == false {
                            if objcUnsignedLess(i, horos_previewPix?.count ?? 0) {
                                if horos_previewPix?.object(at: i) != nil {
                                    if objcUnsignedLess(i, horos_matrixViewArray?.count ?? 0) {
                                        matrixNewIcon(i, (horos_matrixViewArray as NSArray?)?.object(at: i) as? NSManagedObject)
                                    }
                                }
                            }
                        }
                        i += 1
                    }

                    if horos_oMatrix?.selectedCell() == nil {
                        if (horos_matrixViewArray?.count ?? 0) > 0 {
                            horos_oMatrix?.selectCell(withTag: 0)
                        }
                    }

                    if horos_loadPreviewIndex == 0 {
                        initAnimationSlider()
                    }

                    horos_loadPreviewIndex = i
                }
            }
        }) {
            _N2LogExceptionImpl(ne, true, "-[BrowserController matrixDisplayIcons:]")
        }
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

    @objc(buildAllThumbnails:)
    @IBAction func buildAllThumbnails(_ sender: Any!) {
        if DCMPix.isRunOsiriXInProtectedModeActivated() { return }
        if UserDefaults.standard.bool(forKey: "StoreThumbnailsInDB") == false { return }

        let context = self.database?.managedObjectContext
        let model = self.database?.managedObjectModel

        let recoveryPath = (BrowserController.currentBrowser()?.database?.baseDirPath as NSString?)?.appendingPathComponent("ThumbnailPath")
        if let recoveryPath, FileManager.default.fileExists(atPath: recoveryPath) {
            outlineViewRefresh()
            refreshMatrix(self)
            var usedEncoding = String.Encoding.utf8
            let uri = try? String(contentsOfFile: recoveryPath, usedEncoding: &usedEncoding)

            try? FileManager.default.removeItem(atPath: recoveryPath)

            var studyObject: NSManagedObject? = nil

            if let ne = objcTry({
                if let uri, let url = URL(string: uri), let objectID = context?.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url) {
                    studyObject = try? context?.existingObject(with: objectID)
                }
            }) {
                _N2LogExceptionImpl(ne, true, "-[BrowserController buildAllThumbnails:]")
            }

            if let studyObject {
                var r: Int

                if UserDefaults.standard.bool(forKey: "hideListenerError") {
                    r = NSAlertDefaultReturn
                } else {
                    r = HorosAlertPanel.run(title: NSLocalizedString("Corrupted files", comment: ""),
                                            message: String(format: NSLocalizedString("A corrupted study crashed OsiriX:\r\r%@ / %@\r\rThis file will be deleted.\r\rYou can run OsiriX in Protected Mode (shift + option keys at startup) if you have more crashes.\r\rShould I delete this corrupted study? (Highly recommended)", comment: ""), objcFormatArgument(studyObject.value(forKey: "name")), objcFormatArgument(studyObject.value(forKey: "studyName"))),
                                            defaultButton: NSLocalizedString("OK", comment: ""),
                                            alternateButton: NSLocalizedString("Cancel", comment: ""),
                                            otherButton: nil)
                }

                if r == NSAlertDefaultReturn {
                    context?.lock()

                    if let ne = objcTry({
                        context?.delete(studyObject)
                        _ = self.database?.save(nil)
                    }) {
                        _N2LogExceptionImpl(ne, true, "-[BrowserController buildAllThumbnails:]")
                    }

                    context?.unlock()

                    outlineViewRefresh()
                    refreshMatrix(self)
                }
            }

        }

        if UserDefaults.standard.bool(forKey: "hideListenerError") == false {
            if self.database?.tryLock() == true {
                if context?.tryLock() == true {
                    horos_DatabaseIsEdited = true

                    if let ne = objcTry({
                        let dbRequest = NSFetchRequest<NSFetchRequestResult>()
                        dbRequest.entity = model?.entitiesByName["Series"]
                        dbRequest.predicate = NSPredicate(format: "thumbnail == NIL")
                        dbRequest.fetchLimit = 60

                        let seriesArray = (try? context?.fetch(dbRequest)) as NSArray?

                        var maxSeries = seriesArray?.count ?? 0

                        if maxSeries > 60 { maxSeries = 60 } // We will continue next time...

                        var i = 0
                        while i < maxSeries {
                            buildThumbnail(seriesArray?.object(at: i) as? DicomSeries)
                            i += 1
                        }

                        _ = self.database?.save(nil)
                    }) {
                        _N2LogExceptionImpl(ne, true, "-[BrowserController buildAllThumbnails:]")
                    }

                    context?.unlock()
                }
                self.database?.unlock()
            }
        }

        horos_DatabaseIsEdited = false
    }

    @objc(resetWindowsState:)
    @IBAction func resetWindowsState(_ sender: Any!) {
        var x = 0, row = 0
        let context = self.database?.managedObjectContext

        context?.lock()

        if let e = objcTry({
            let selectedRows = horos_databaseOutline?.selectedRowIndexes as NSIndexSet?

            if (horos_databaseOutline?.selectedRow ?? 0) >= 0 {
                x = 0
                while x < (selectedRows?.count ?? 0) {
                    if x == 0 { row = selectedRows?.firstIndex ?? 0 }
                    else { row = selectedRows?.indexGreaterThanIndex(row) ?? 0 }

                    let object = horos_databaseOutline?.item(atRow: row) as? NSObject

                    if objcIsEqualToString(object?.value(forKey: "type"), "Study") {
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "rotationAngle")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "scale")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "windowLevel")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "windowWidth")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "xFlipped")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "yFlipped")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "xOffset")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "yOffset")
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "displayStyle")

                        object?.setValue(nil, forKey: "windowsState")
                    } else if objcIsEqualToString(object?.value(forKey: "type"), "Series") {
                        object?.setValue(nil, forKey: "rotationAngle")
                        object?.setValue(nil, forKey: "scale")
                        object?.setValue(nil, forKey: "windowLevel")
                        object?.setValue(nil, forKey: "windowWidth")
                        object?.setValue(nil, forKey: "xFlipped")
                        object?.setValue(nil, forKey: "yFlipped")
                        object?.setValue(nil, forKey: "xOffset")
                        object?.setValue(nil, forKey: "yOffset")
                        object?.setValue(nil, forKey: "displayStyle")

                        object?.setValue(nil, forKeyPath: "study.windowsState")
                    }
                    x += 1
                }
            }

            _ = self.database?.save(nil)
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController resetWindowsState:]")
        }

        context?.unlock()
    }

    @objc(retrieveSelectedPODStudies:)
    @IBAction func retrieveSelectedPODStudies(_ sender: Any!) {
        if let e = objcTry({
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
        //	[_database lock];
        if let e = objcTry({
            let selectedRows = horos_databaseOutline?.selectedRowIndexes as NSIndexSet?
            var row = 0

            if (horos_databaseOutline?.selectedRow ?? 0) >= 0 {
                var x = 0
                while x < (selectedRows?.count ?? 0) {
                    if x == 0 { row = selectedRows?.firstIndex ?? 0 }
                    else { row = selectedRows?.indexGreaterThanIndex(row) ?? 0 }

                    let object = horos_databaseOutline?.item(atRow: row) as? NSObject

                    if objcIsEqualToString(object?.value(forKey: "type"), "Study") {
                        (childrenArray(object) as NSArray?)?.setValue(nil, forKey: "thumbnail")
                    }
                    if objcIsEqualToString(object?.value(forKey: "type"), "Series") {
                        object?.setValue(nil, forKey: "thumbnail")
                    }
                    x += 1
                }
            }

            _ = self.database?.save(nil)
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController rebuildThumbnails:]")
        }
        //		[_database unlock];

        refreshMatrix(self)
    }

    @objc(matrixLoadIcons:)
    func matrixLoadIcons(_ dict: [AnyHashable: Any]!) {
        autoreleasepool {
            if Thread.isMainThread == false {
                Thread.current.name = "matrixLoadIcons"
            }

            if let e = objcTry({
                let dict = dict as NSDictionary?
                let objectIDs = dict?.value(forKey: "objectIDs") as? NSArray
                let imageLevel = objcBoolValue(dict?.value(forKey: "imageLevel"))
                var idatabase = dict?.value(forKey: "DicomDatabase") as? DicomDatabase
                let context = dict?.value(forKey: "Context") as AnyObject?
                let generation = (dict?.value(forKey: "Generation") as? NSNumber)?.uintValue ?? 0

                if Thread.isMainThread == false {
                    idatabase = idatabase?.independentDatabase() as? DicomDatabase // INDEPENDANT CONTEXT !
                }

                var tempPreviewPixThumbnails: NSMutableArray? = nil
                var tempPreviewPix: NSMutableArray? = nil

                var cancelled = false
                objcSynchronized(horos_previewPixThumbnails) {
                    if Thread.current.isCancelled {
                        cancelled = true
                        return
                    }

                    tempPreviewPixThumbnails = horos_previewPixThumbnails?.mutableCopy() as? NSMutableArray
                    tempPreviewPix = horos_previewPix?.mutableCopy() as? NSMutableArray
                }
                if cancelled {
                    return
                }

                var i = 0
                while i < (objectIDs?.count ?? 0) {
                    var step = LoadIconsStep.notFound
                    if let e = objcTry({
                        if Thread.current.isCancelled {
                            step = .stop
                            return
                        }

                        if i != 0 {
                            // only do it on a delayed basis
                            let now = Date.timeIntervalSinceReferenceDate
                            if now - horos_timeIntervalOfLastLoadIconsDisplayIcons > 0.5 {
                                horos_timeIntervalOfLastLoadIconsDisplayIcons = now
                                objcSynchronized(horos_previewPixThumbnails) {
                                    if Thread.current.isCancelled == false {
                                        if horos_previewPix === context && horos_previewPixGeneration == generation {
                                            horos_previewPixThumbnails?.removeAllObjects()
                                            horos_previewPixThumbnails?.addObjects(from: (tempPreviewPixThumbnails as? [Any]) ?? [])

                                            horos_previewPix?.removeAllObjects()
                                            horos_previewPix?.addObjects(from: (tempPreviewPix as? [Any]) ?? [])
                                        }
                                    }
                                }

                                if Thread.isMainThread == false && Thread.current.isCancelled == false {
                                    self.performSelector(onMainThread: #selector(matrixDisplayIcons(_:)), with: nil, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
                                }
                            }
                        }

                        guard let image = idatabase?.object(withID: objectIDs?.object(at: i)) as? DicomImage else {
                            step = .stop // the objects don't exist anymore, the selection has very likely changed after this call
                            return
                        }

                        var frame: Int32 = 0
                        if (image.numberOfFrames?.int32Value ?? 0) > 1 {
                            frame = (image.numberOfFrames?.int32Value ?? 0) / 2
                        }
                        if let frameID = image.frameID { frame = frameID.int32Value }

                        var dcmPix = getDCMPix(fromViewerIfAvailable: image.completePath(), frameNumber: frame, expectedFrame: BrowserController.horos_previewFrame(for: image, frame: frame))
                        if dcmPix == nil {
                            dcmPix = DCMPix(path: image.completePath(), 0, 1, nil, Int(frame), 0, isBonjour: !(idatabase?.isLocal() ?? false), imageObj: image)
                        }

                        if !imageLevel {
                            if let dbThmb = image.series?.thumbnail {
                                let rep = NSBitmapImageRep(data: dbThmb)
                                let dbIma = NSImage(size: rep?.size ?? .zero)
                                if let rep { dbIma.addRepresentation(rep) }

                                let pix = (dcmPix != nil ? dcmPix : BrowserController.horos_emptyPreviewPix())

                                objcReplace(tempPreviewPixThumbnails, i, dbIma)
                                objcAdd(tempPreviewPix, pix)
                                step = .next
                                return
                            }
                        }

                        if let dcmPix {
                            if DCMAbstractSyntaxUID.isStructuredReport(image.series?.seriesSOPClassUID) || DCMAbstractSyntaxUID.isPDF(image.series?.seriesSOPClassUID) {
                                let icon = NSWorkspace.shared.icon(forFileType: "txt")

                                let thumbnail = NSImage(size: NSMakeSize(CGFloat(THUMBNAILSIZE), CGFloat(THUMBNAILSIZE)))

                                thumbnail.lockFocus()
                                icon.draw(in: NSMakeRect(0, 0, CGFloat(THUMBNAILSIZE), CGFloat(THUMBNAILSIZE)), from: icon.alignmentRect, operation: .copy, fraction: 1.0)
                                thumbnail.unlockFocus()

                                objcReplace(tempPreviewPixThumbnails, i, thumbnail)
                                objcAdd(tempPreviewPix, dcmPix)
                            } else {
                                var thumbnail = dcmPix.generateThumbnailImage(withWW: image.series?.windowWidth?.floatValue ?? 0, wl: dcmPix.calibratedWindowLevel(forStoredLevel: image.series?.windowLevel?.floatValue ?? 0))
                                dcmPix.revert(false) // <- Kill the raw data
                                if thumbnail == nil || dcmPix.notAbleToLoadImage == true { thumbnail = horos_notFoundImage }

                                objcReplace(tempPreviewPixThumbnails, i, thumbnail)
                                objcAdd(tempPreviewPix, dcmPix)
                            }
                            step = .next
                            return
                        }
                    }) {
                        _N2LogExceptionImpl(e, true, "-[BrowserController matrixLoadIcons:]")
                    }
                    if step == .stop { break }
                    if step == .next { i += 1; continue }
                    // successful iterations don't execute this (they continue to the next iteration), this is in case no image has been provided by this iteration (exception, no file, ...)

                    objcReplace(tempPreviewPixThumbnails, i, horos_notFoundImage)
                    objcAdd(tempPreviewPix, BrowserController.horos_emptyPreviewPix())
                    i += 1
                }


                objcSynchronized(horos_previewPixThumbnails) {
                    if Thread.current.isCancelled == false {
                        if horos_previewPix === context && horos_previewPixGeneration == generation {
                            horos_previewPixThumbnails?.removeAllObjects()
                            horos_previewPixThumbnails?.addObjects(from: (tempPreviewPixThumbnails as? [Any]) ?? [])

                            horos_previewPix?.removeAllObjects()
                            horos_previewPix?.addObjects(from: (tempPreviewPix as? [Any]) ?? [])
                        }
                    }

                    if Thread.isMainThread == false {
                        self.performSelector(onMainThread: #selector(matrixDisplayIcons(_:)), with: nil, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
                    } else {
                        matrixDisplayIcons(nil)
                    }
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[BrowserController matrixLoadIcons:]")
            }
        }
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
            if let exception = objcTry({
                DatabaseWindowPlacement.restore(window, savedFrame: window.frame)
            }) {
                _N2LogExceptionImpl(exception, false, "-[BrowserController recoverWindowsAfterScreenChange]")
            }
        }
        ToolbarPanelController.checkForValidToolbar()
        for screen in NSScreen.screens {
            if let exception = objcTry({
                ViewerController.frontMostDisplayed2DViewer(for: screen)?.redrawToolbar()
            }) {
                _N2LogExceptionImpl(exception, false, "-[BrowserController recoverWindowsAfterScreenChange]")
            }
        }
    }

    @objc(previewMatrixScrollViewFrameDidChange:)
    func previewMatrixScrollViewFrameDidChange(_ note: Notification!) {
        if (horos_matrixViewArray?.count ?? 0) == 0 {
            return
        }

        let oMatrix = horos_oMatrix
        let selectedCellTag = oMatrix?.selectedCell()?.tag ?? 0

        let rcs = (oMatrix?.cellSize.width ?? 0) + (oMatrix?.intercellSpacing.width ?? 0)

        var size = horos_thumbnailsScrollView?.bounds.size ?? .zero
        size.width += (oMatrix?.intercellSpacing.width ?? 0)

        if rcs > 0 {
            let hcells = objcInt(roundf(Float(size.width / rcs)))

            if hcells > 0 {
                var vcells = objcInt(ceilf(Float(1.0 * Double(horos_matrixViewArray?.count ?? 0) / Double(hcells)))) //MAX(1, (NSInteger)ceilf(1.0*matrixViewArray.count/hcells));

                if vcells < 1 {
                    vcells = 1
                }

                if vcells > 0 && hcells > 0 {
                    oMatrix?.renewRows(vcells, columns: hcells)

                    objcSynchronized(horos_previewPixThumbnails) {
                        var i = Int32(truncatingIfNeeded: horos_previewPix?.count ?? 0)
                        while Int(i) < hcells * vcells {
                            let cell = oMatrix?.cell(atRow: Int(i) / hcells, column: Int(i) % hcells) as? NSButtonCell
                            cell?.isTransparent = true
                            cell?.isEnabled = false
                            i += 1
                        }
                    }

                    oMatrix?.sizeToCells()
                    oMatrix?.selectCell(withTag: selectedCellTag)
                }
            }
        }
    }
}
