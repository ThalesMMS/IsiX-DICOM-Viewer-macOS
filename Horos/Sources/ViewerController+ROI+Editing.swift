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

// The second half of the "ROI" block of ViewerController (from -roiVolume: to
// -sendToBackROI:: volume, set pixels, rename, propagation, selection, groups
// and ordering of the ROIs) is implemented in Swift since #832: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selectors. The instance variables it uses are read through
// ViewerController (SwiftIvars); roiList, pixList and their slices keep their
// Objective-C identity (NSMutableArray, never bridged to a Swift array), since
// callers mutate them and compare them by identity.
//
// A message to nil answered nil, 0 or NO: the optional chains below answer the
// same. An element taken out of an array is typed as the Objective-C typed it,
// without a runtime check (objcCast), so that messages go to it as before. An
// @try is HorosObjCException.perform (objcTry). -newPoint:: stays in
// Objective-C (a "new" method returning an object), and -newROI:, which returns
// an autoreleased ROI in spite of its name, is reached through
// -horos_unretainedNewROI:. The OSIRIX_LIGHT branches (not defined) are left out.

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

/// `(T*) object`: an `id` statically typed as the Objective-C typed it, without
/// a runtime check, as a C cast does; nil for nil.
fileprivate func objcCast<T: AnyObject>(_ object: Any?, _ type: T.Type) -> T? {
    guard let object else { return nil }
    return Unmanaged<T>.fromOpaque(Unmanaged.passUnretained(object as AnyObject).toOpaque()).takeUnretainedValue()
}

/// `(T*) [array objectAtIndex: index]`: nil for a nil array (a message to nil);
/// an index out of range raises, as it did.
fileprivate func objcObject<T: AnyObject>(_ array: NSArray?, _ index: Int, _ type: T.Type) -> T? {
    guard let array else { return nil }
    return objcCast(array.object(at: index), type)
}

/// `[sender tag]` on an `id`: 0 for nil (a message to nil), and the exception
/// Objective-C raised for an object without -tag.
fileprivate func objcTag(_ sender: Any?) -> Int {
    guard let object = sender as AnyObject? else { return 0 }
    let selector = NSSelectorFromString("tag")
    guard let targetClass: AnyClass = object_getClass(object),
          let implementation = class_getMethodImplementation(targetClass, selector) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector) -> Int
    return unsafeBitCast(implementation, to: Send.self)(object, selector)
}

/// `[a isEqualToString: b]`: NO when a is nil (a message to nil) or b is nil.
fileprivate func objcIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// The exception Foundation raises when nil is added to an array.
fileprivate func objcRaiseNilInsertion(_ selector: String) {
    NSException(name: .invalidArgumentException,
                reason: "*** -[__NSArrayM \(selector)]: object cannot be nil",
                userInfo: nil).raise()
}

/// `[array addObject: object]`: nothing for a nil array, and the exception
/// Foundation raised for a nil object.
fileprivate func objcAdd(_ array: NSMutableArray?, _ object: Any?) {
    guard let array else { return }
    guard let object else { objcRaiseNilInsertion("insertObject:atIndex:"); return }
    array.add(object)
}

/// `[array insertObject: object atIndex: index]`: nothing for a nil array, and
/// the exception Foundation raised for a nil object.
fileprivate func objcInsert(_ array: NSMutableArray?, _ object: Any?, _ index: Int) {
    guard let array else { return }
    guard let object else { objcRaiseNilInsertion("insertObject:atIndex:"); return }
    array.insert(object, at: index)
}

/// `[array removeObject: object]`: nothing for a nil array or a nil object.
fileprivate func objcRemove(_ array: NSMutableArray?, _ object: Any?) {
    guard let array, let object else { return }
    array.remove(object)
}

/// `[NSDictionary dictionaryWithObjectsAndKeys: object, key, …, nil]`: the
/// pairs up to the first nil object, which ended the list.
fileprivate func objcDictionary(_ objectsAndKeys: (Any?, String)...) -> NSDictionary {
    var objects: [Any] = []
    var keys: [NSCopying] = []
    for (object, key) in objectsAndKeys {
        guard let object else { break }
        objects.append(object)
        keys.append(key as NSString)
    }
    return NSDictionary(objects: objects, forKeys: keys)
}

/// C's float to int conversion on arm64: saturating, NaN to 0.
fileprivate func cInt32(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
fileprivate let ToolsMenuIconSize = NSMakeSize(28.0, 28.0)

fileprivate extension ViewerController {
    /// `[imageView curImage]`
    func roi2CurImage() -> Int {
        return Int(self.horos_imageView?.curImage ?? 0)
    }

    /// `[roiList[y] objectAtIndex: x]`, the ROIs of one image.
    func roi2Slice(_ y: Int, _ x: Int) -> NSMutableArray? {
        return objcObject(self.horos_roiList(at: y), x, NSMutableArray.self)
    }

    /// `[roiList[curMovieIndex] objectAtIndex: [imageView curImage]]`
    func roi2CurrentSlice() -> NSMutableArray? {
        return self.roi2Slice(Int(self.horos_curMovieIndex), self.roi2CurImage())
    }

    /// `[pixList[y] count]`
    func roi2PixCount(_ y: Int) -> Int {
        return self.horos_pixList(at: y)?.count ?? 0
    }

    /// `[pixList[y] objectAtIndex: x]`
    func roi2Pix(_ y: Int, _ x: Int) -> DCMPix? {
        return objcObject(self.horos_pixList(at: y), x, DCMPix.self)
    }

    /// `[NSApp beginSheet: sheet modalForWindow:[self window] modalDelegate:self didEndSelector:nil contextInfo:nil]`
    func roi2BeginSheet(_ sheet: NSWindow?) {
        guard let sheet, let window = self.window else { return }
        NSApp.beginSheet(sheet, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
    }

    /// `[NSApp endSheet: sheet returnCode: code]`
    func roi2EndSheet(_ sheet: NSWindow?, _ code: Int) {
        guard let sheet else { return }
        NSApp.endSheet(sheet, returnCode: code)
    }
}

/// The images `-roiPropagate:` copies the ROIs to, as a half-open range
/// `[start, upTo)` of indexes of the series: from `pos` (the current image)
/// through the image the panel names, both ends included, in either
/// direction, clamped to the `count` images of the series.
///
/// The panel asks for "up to image number:", the number the viewer shows as
/// "Im: N/count": counted from 1, and from the other end of the series when
/// the data is flipped. Image `imageNumber` is therefore index
/// `imageNumber - 1`, or `count - imageNumber` flipped. The Objective-C read
/// the number as an index counted from 0 and took `[min, max)`: image N was
/// reached after the current image but not before it, and flipped the range
/// went one image past N in one direction and stopped two short of it in the
/// other (#879). It also compared the bounds with the count as unsigned long
/// before clamping the negative ones, so a destination before the first image
/// became `count` and nothing was propagated; the bounds are compared as
/// signed values (#866).
fileprivate func roi2PropagationImages(_ pos: Int, _ imageNumber: Int, _ count: Int, flipped: Bool) -> (start: Int, upTo: Int) {
    if count <= 0 { return (0, 0) }

    let last = count - 1
    let destination = flipped ? count - imageNumber : imageNumber - 1
    let from = max(0, min(pos, last))
    let to = max(0, min(destination, last))

    return (min(from, to), max(from, to) + 1)
}

/// The images `-roiPropagateSlab:` copies the ROIs to, as a half-open range
/// `[start, upTo)` of indexes of the series: the thick slab the viewer shows
/// at `pos`, `stack` images from the current one towards its far end, which
/// is below it when the data is flipped, clamped to the `count` images of the
/// series. Empty when there is no slab.
///
/// With flipped data the range was `[pos - stack, pos)`, one image past the
/// slab DCMPix draws, `[pos - (stack - 1), pos]` (#882). The far end now comes
/// from HorosThickSlabRange, which -sync3DPosition sends the other viewers.
fileprivate func roi2SlabImages(_ pos: Int, _ stack: Int, _ count: Int, flipped: Bool) -> (start: Int, upTo: Int) {
    let far = ThickSlabRange.farEndIndex(currentIndex: pos, stack: stack, count: count, flippedData: flipped)
    if far < 0 { return (0, 0) }

    return (min(pos, far), max(pos, far) + 1)
}

/// The movie frame `i` clamped to `0 ..< maxMovieIndex`, and 0 when
/// `maxMovieIndex` is 0: roiList has MAX4D slots, of which slot 0 always
/// exists, where the Objective-C clamped to `maxMovieIndex - 1`, which is -1
/// with no frame (#879).
fileprivate func roi2MovieIndex(_ i: Int, _ maxMovieIndex: Int) -> Int {
    return max(0, min(i, maxMovieIndex - 1))
}

/// `mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing`
fileprivate func roi2IsSelected(_ mode: Int) -> Bool {
    return mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing
}

public extension ViewerController {
    // MARK: - ROI (second half)

    @objc(roiVolume:)
    func roiVolume(_ sender: Any!) {
        var preLocation: Float, interval: Float
        var selectedRoi: ROI? = nil

        _ = self.computeInterval()

        self.displayAWarningIfNonTrueVolumicData()

        var i = 0
        while i < Int(self.horos_maxMovieIndex) {
            self.saveROI(i)
            i += 1
        }

        selectedRoi = self.selectedROI()

        if selectedRoi == nil {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: NSLocalizedString("Select a ROI to compute volume of all ROIs with the same name.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // Check that sliceLocation is available and identical for all images
        preLocation = 0
        interval = 0

        if let curPixList = self.horos_pixList(at: Int(self.horos_curMovieIndex)) {
            for item in curPixList {
                let curPix = objcCast(item, DCMPix.self)
                if preLocation != 0 {
                    if interval != 0 {
                        // double - float - float, computed in double as C did.
                        if fabs((curPix?.sliceLocation ?? 0) - Double(preLocation) - Double(interval)) > 1.0 {
                            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: NSLocalizedString("Slice Interval is not constant!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                            return
                        }
                    }
                    interval = Float((curPix?.sliceLocation ?? 0) - Double(preLocation))
                }
                preLocation = Float(curPix?.sliceLocation ?? 0)
            }
        }

        NSLog("Slice Interval : %f", Double(interval))

        if objcTag(sender) == 0 { // Compute Volume
            if interval == 0 {
                HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: NSLocalizedString("Slice Locations not available to compute a volume.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        self.add(toUndoQueue: "roi")

        let splash = WaitRendering(NSLocalizedString("Preparing data...", comment: ""))
        splash?.showWindow(self)

        // Show Volume Window
        if objcTag(sender) == 0 {
            if let viewer = ROIVolumeController(roi: selectedRoi, viewer: self) {
                // [[ROIVolumeController alloc] initWithRoi:viewer:] was not
                // released: the controller releases itself when its window closes.
                _ = Unmanaged.passRetained(viewer)

                viewer.showWindow(self)
                viewer.window?.center()
            }
        } else if objcTag(sender) == 1 {
            _ = self.computeVolume(selectedRoi, points: nil, generateMissingROIs: true, generatedROIs: nil, computeData: nil, error: nil)

            let numberOfGeneratedROIafter = Int32(truncatingIfNeeded: self.rois(withComment: "morphing generated")?.count ?? 0)
            if numberOfGeneratedROIafter == 0 {
                HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: NSLocalizedString("The missing ROIs were not created : this feature does not work with ROIs that don't contain an area.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }

        splash?.close()
    }

    @objc(roiSetPixelsSetup:)
    func roiSetPixelsSetup(_ sender: Any!) {
        var selectedRoi: ROI? = nil

        selectedRoi = self.selectedROI()

        // The value is computed before the message, as Objective-C evaluated
        // the argument even for a nil outlet.
        let maxValueOfSeries = self.roi2Pix(0, 0)?.maxValueOfSeries ?? 0
        self.horos_maxValueText?.floatValue = maxValueOfSeries
        let minValueOfSeries = self.roi2Pix(0, 0)?.minValueOfSeries ?? 0
        self.horos_minValueText?.floatValue = minValueOfSeries
        let newValueOfSeries = self.roi2Pix(0, 0)?.minValueOfSeries ?? 0
        self.horos_newValueText?.floatValue = newValueOfSeries

        if selectedRoi == nil {
            self.horos_InOutROI?.isEnabled = false
            self.horos_InOutROI?.selectCell(withTag: 1)

            self.horos_AllROIsRadio?.cell(withTag: 1)?.isEnabled = false
            self.horos_AllROIsRadio?.cell(withTag: 0)?.isEnabled = false

            self.horos_AllROIsRadio?.selectCell(withTag: 2)
        } else {
            self.horos_InOutROI?.isEnabled = true

            self.horos_AllROIsRadio?.selectCell(withTag: 0)
            self.horos_AllROIsRadio?.cell(withTag: 1)?.isEnabled = true
            self.horos_AllROIsRadio?.cell(withTag: 0)?.isEnabled = true
        }

        if self.horos_maxMovieIndex != 1 { self.horos_setROI4DSeries?.isEnabled = true }
        else { self.horos_setROI4DSeries?.isEnabled = false }

        self.roiSetPixelsCheckButton(self)

        self.roi2BeginSheet(self.horos_roiSetPixWindow)
    }

    @objc(recomputeROI:)
    func recomputeROI(_ note: Notification!) {
        var i: Int, x: Int, y: Int

        if (note?.object as AnyObject?) === self {
            // Recompute all ROIs
            y = 0
            while y < Int(self.horos_maxMovieIndex) {
                x = 0
                while x < self.roi2PixCount(y) {
                    i = 0
                    while i < (self.roi2Slice(y, x)?.count ?? 0) {
                        objcObject(self.roi2Slice(y, x), i, ROI.self)?.recompute()
                        i += 1
                    }

                    //[[pixList[y] objectAtIndex: x] changeWLWW:iwl :iww];	//recompute image
                    x += 1
                }
                y += 1
            }
        }

        self.willChangeValue(forKey: "thicknessInMm")
        self.didChangeValue(forKey: "thicknessInMm")
    }

    @objc(roiSetPixelsCheckButton:)
    func roiSetPixelsCheckButton(_ sender: Any!) {
        var restoreAvailable = true

        if (self.horos_setROI4DSeries?.state.rawValue ?? 0) != 0 && self.horos_maxMovieIndex > 1 {
            restoreAvailable = false
        }

        if self.horos_postprocessed {
            restoreAvailable = false
        }

        if (self.horos_checkMaxValue?.state.rawValue ?? 0) != 0 || (self.horos_checkMinValue?.state.rawValue ?? 0) != 0 {
            restoreAvailable = false
        }

        if (self.horos_InOutROI?.selectedCell()?.tag ?? 0) != 0 {
            restoreAvailable = false
        }

        if (self.horos_AllROIsRadio?.selectedCell()?.tag ?? 0) == 2 { // All pixels
            restoreAvailable = false
        }

        if restoreAvailable == false {
            self.horos_newValueMatrix?.cell(withTag: 1)?.isEnabled = false
            self.horos_newValueMatrix?.selectCell(withTag: 0)
        } else {
            self.horos_newValueMatrix?.cell(withTag: 1)?.isEnabled = true
        }
    }

    @objc(roiSetPixels:)
    func roiSetPixels(_ sender: Any!) {
        var m = 0
        while m < Int(self.horos_maxMovieIndex) {
            self.saveROI(m)
            m += 1
        }

        // end sheet
        self.horos_roiSetPixWindow?.orderOut(sender)
        self.roi2EndSheet(self.horos_roiSetPixWindow, objcTag(sender))
        // do it only if OK button pressed
        if objcTag(sender) != 1 { return }

        // Find the first ROI selected
        var selectedROI: ROI? = nil
        var i: Int, y: Int, x: Int

        i = 0
        while i < (self.roi2CurrentSlice()?.count ?? 0) {
            let mode = objcObject(self.roi2CurrentSlice(), i, ROI.self)?.roImode ?? 0

            if roi2IsSelected(mode) {
                selectedROI = objcObject(self.roi2CurrentSlice(), i, ROI.self)
            }
            i += 1
        }

        // user's parameters
        let outside = (self.horos_InOutROI?.selectedCell()?.tag ?? 0) != 0
        let allRois = Int16(truncatingIfNeeded: self.horos_AllROIsRadio?.selectedCell()?.tag ?? 0)

        var minValue: Float = -Float.greatestFiniteMagnitude
        var maxValue: Float = Float.greatestFiniteMagnitude
        if self.horos_checkMaxValue?.state == .on { maxValue = self.horos_maxValueText?.floatValue ?? 0 }
        if self.horos_checkMinValue?.state == .on { minValue = self.horos_minValueText?.floatValue ?? 0 }

        let propagateIn4D = self.horos_setROI4DSeries?.state == .on

        let newValue = self.horos_newValueText?.floatValue ?? 0
        let revertToSaved = (self.horos_newValueMatrix?.selectedTag() ?? 0) != 0

        // proceed
        self.roiSetPixels(selectedROI, allRois, propagateIn4D, outside, minValue, maxValue, newValue, revertToSaved)

        // Recompute!!!! Apply WL/WW
        var iwl: Float = 0, iww: Float = 0

        self.horos_imageView?.getWLWW(&iwl, &iww)
        self.horos_imageView?.setWLWW(iwl, iww)

        // Recompute all ROIs
        y = 0
        while y < Int(self.horos_maxMovieIndex) {
            x = 0
            while x < self.roi2PixCount(y) {
                i = 0
                while i < (self.roi2Slice(y, x)?.count ?? 0) {
                    objcObject(self.roi2Slice(y, x), i, ROI.self)?.recompute()
                    i += 1
                }

                self.roi2Pix(y, x)?.changeWLWW(iwl, iww) //recompute WLWW
                x += 1
            }
            y += 1
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateVolumeData, object: self.horos_pixList(at: Int(self.horos_curMovieIndex)), userInfo: nil)
    }

    @objc(roiSetStartScheduler:)
    func roiSetStartScheduler(_ roiToProceed: NSMutableArray!) {
        if (roiToProceed?.count ?? 0) != 0 {
            self.horos_roiLock?.lock()

            if let exception = objcTry({
                let queue = OperationQueue()

                for loopItem in roiToProceed {
                    // ViewerControllerOperation is a class of ViewerController.m.
                    // The bridge never answers nil (an alloc/init of NSOperation).
                    if let op = self.horos_viewerControllerOperation(withDict: loopItem) {
                        queue.addOperation(op)
                    }
                }

                queue.waitUntilAllOperationsAreFinished()
            }) {
                _N2LogExceptionImpl(exception, false, "-[ViewerController roiSetStartScheduler:]")
            }

            self.horos_roiLock?.unlock()
        }
    }

    @objc(roiSetPixels::::::::)
    func roiSetPixels(_ aROI: ROI!, _ allRois: Int16, _ propagateIn4D: Bool, _ outside: Bool, _ minValue: Float, _ maxValue: Float, _ newValue: Float, _ revert: Bool) {
        var i: Int, x: Int, y: Int, z: Int
        var done: Bool, proceed: Bool
        let roiToProceed = NSMutableArray()
        let nsnewValue: NSNumber, nsminValue: NSNumber, nsmaxValue: NSNumber, nsoutside: NSNumber, nsrevert: NSNumber

        nsnewValue = NSNumber(value: newValue)
        nsminValue = NSNumber(value: minValue)
        nsmaxValue = NSNumber(value: maxValue)
        nsoutside = NSNumber(value: outside)
        nsrevert = NSNumber(value: revert)

        self.checkEverythingLoaded()

        let splash = WaitRendering(NSLocalizedString("Filtering...", comment: ""))
        splash?.showWindow(self)

        NSLog("startSetPixel")

        y = 0
        while y < Int(self.horos_maxMovieIndex) {
            if y == Int(self.horos_curMovieIndex) { proceed = true }
            else { proceed = false }

            if proceed {
                x = 0
                while x < self.roi2PixCount(y) {
                    done = false

                    if allRois == 2 {
                        let curPix = self.roi2Pix(y, x)
                        roiToProceed.add(objcDictionary((curPix, "curPix"), ("setPixel", "action"), (nsnewValue, "newValue"), (nsminValue, "minValue"), (nsmaxValue, "maxValue"), (nsoutside, "outside"), (nsrevert, "revert"), (NSNumber(value: Int32(truncatingIfNeeded: x)), "stackNo")))

                        done = true
                    } else {
                        i = 0
                        while i < (self.roi2Slice(y, x)?.count ?? 0) {
                            if objcIsEqualToString(objcObject(self.roi2Slice(y, x), i, ROI.self)?.name, aROI?.name) || allRois == 1 {
                                if propagateIn4D {
                                    z = 0
                                    while z < Int(self.horos_maxMovieIndex) {
                                        let curPix = self.roi2Pix(z, x)
                                        roiToProceed.add(objcDictionary((self.roi2Slice(y, x)?.object(at: i), "roi"), (curPix, "curPix"), ("setPixelRoi", "action"), (nsnewValue, "newValue"), (nsminValue, "minValue"), (nsmaxValue, "maxValue"), (nsoutside, "outside"), (nsrevert, "revert"), (NSNumber(value: Int32(truncatingIfNeeded: x)), "stackNo")))

                                        done = true
                                        z += 1
                                    }
                                } else {
                                    let curPix = self.roi2Pix(y, x)
                                    roiToProceed.add(objcDictionary((self.roi2Slice(y, x)?.object(at: i), "roi"), (curPix, "curPix"), ("setPixelRoi", "action"), (nsnewValue, "newValue"), (nsminValue, "minValue"), (nsmaxValue, "maxValue"), (nsoutside, "outside"), (nsrevert, "revert"), (NSNumber(value: Int32(truncatingIfNeeded: x)), "stackNo")))

                                    done = true
                                }
                            }
                            i += 1
                        }
                    }

                    if outside && done == false {
                        if propagateIn4D {
                            z = 0
                            while z < Int(self.horos_maxMovieIndex) {
                                let curPix = self.roi2Pix(z, x)
                                roiToProceed.add(objcDictionary((curPix, "curPix"), ("setPixel", "action"), (nsnewValue, "newValue"), (nsminValue, "minValue"), (nsmaxValue, "maxValue"), (nsoutside, "outside"), (nsrevert, "revert"), (NSNumber(value: Int32(truncatingIfNeeded: x)), "stackNo")))

                                z += 1
                            }
                        } else {
                            let curPix = self.roi2Pix(y, x)
                            roiToProceed.add(objcDictionary((curPix, "curPix"), ("setPixel", "action"), (nsnewValue, "newValue"), (nsminValue, "minValue"), (nsmaxValue, "maxValue"), (nsoutside, "outside"), (nsrevert, "revert"), (NSNumber(value: Int32(truncatingIfNeeded: x)), "stackNo")))
                        }
                    }
                    x += 1
                }
            }
            y += 1
        }

        var restoreReady = true

        if revert {
            restoreReady = self.roi2Pix(Int(self.horos_curMovieIndex), 0)?.prepareRestore() ?? false
        }

        if restoreReady {
            self.roiSetStartScheduler(roiToProceed)
        }

        if revert {
            self.roi2Pix(Int(self.horos_curMovieIndex), 0)?.freeRestore()
        }

        splash?.close()
        // [splash autorelease]: the reference Swift holds is released here.

        if restoreReady == false {
            NSLog("roiSetPixels: restore cache unavailable - pixels left unchanged")
            HorosAlertPanel.runCritical(title: NSLocalizedString("Restore Content", comment: ""), message: NSLocalizedString("The original pixel data of this series could not be reloaded from disk. The images were left unchanged.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        NSLog("endSetPixel")
    }

    @objc(roiSetPixels:::::::)
    func roiSetPixels(_ aROI: ROI!, _ allRois: Int16, _ propagateIn4D: Bool, _ outside: Bool, _ minValue: Float, _ maxValue: Float, _ newValue: Float) {
        return self.roiSetPixels(aROI, allRois, propagateIn4D, outside, minValue, maxValue, newValue, false)
    }

    @objc(endRoiRename:)
    func endRoiRename(_ sender: Any!) {
        self.horos_roiRenameWindow?.orderOut(sender)

        self.roi2EndSheet(self.horos_roiRenameWindow, objcTag(sender))

        if objcTag(sender) == 1 {
            var i: Int, x: Int, y: Int

            switch self.horos_roiRenameMatrix?.selectedCell()?.tag ?? 0 {
            case 0: // All ROIs of the image
                y = Int(self.horos_curMovieIndex)
                x = self.roi2CurImage()
                i = 0
                while i < (self.roi2Slice(y, x)?.count ?? 0) {
                    let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                    curROI?.name = self.horos_roiRenameName?.stringValue

                    NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: curROI, userInfo: nil)
                    i += 1
                }

            case 1: // All ROIs of the series
                y = 0
                while y < Int(self.horos_maxMovieIndex) {
                    x = 0
                    while x < self.roi2PixCount(y) {
                        i = 0
                        while i < (self.roi2Slice(y, x)?.count ?? 0) {
                            let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                            curROI?.name = self.horos_roiRenameName?.stringValue

                            NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: curROI, userInfo: nil)
                            i += 1
                        }
                        x += 1
                    }
                    y += 1
                }

            case 2: // All selected ROIs
                y = Int(self.horos_curMovieIndex)
                x = self.roi2CurImage()
                i = 0
                while i < (self.roi2Slice(y, x)?.count ?? 0) {
                    let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                    let mode = curROI?.roImode ?? 0

                    if roi2IsSelected(mode) {
                        curROI?.name = self.horos_roiRenameName?.stringValue

                        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: curROI, userInfo: nil)
                    }
                    i += 1
                }

            default:
                break
            }
        }
    }

    @objc(roiRename:)
    func roiRename(_ sender: Any!) {
        self.add(toUndoQueue: "roi")

        self.roi2BeginSheet(self.horos_roiRenameWindow)
    }

    @objc(closeModal:)
    func closeModal(_ sender: Any!) {
        if objcTag(sender) != 0 {
            NSApp.stopModal()
        } else {
            NSApp.abortModal()
        }
    }

    @objc(roiApplyWindow:)
    func roiApplyWindow(_ sender: Any!) -> NSArray! {
        self.roi2BeginSheet(self.horos_roiApplyWindow)

        let result: Int32 = self.horos_roiApplyWindow.map { Int32(truncatingIfNeeded: NSApp.runModal(for: $0).rawValue) } ?? 0

        self.roi2EndSheet(self.horos_roiApplyWindow, 0)

        self.horos_roiApplyWindow?.orderOut(sender)

        let applyToROIs = NSMutableArray()

        if result == Int32(truncatingIfNeeded: NSApplication.ModalResponse.stop.rawValue) {
            var i: Int, x: Int, y: Int

            switch self.horos_roiApplyMatrix?.selectedCell()?.tag ?? 0 {
            case 0: // All ROIs of the image
                y = Int(self.horos_curMovieIndex)
                x = self.roi2CurImage()
                i = 0
                while i < (self.roi2Slice(y, x)?.count ?? 0) {
                    let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                    objcAdd(applyToROIs, curROI)
                    i += 1
                }

            case 1: // All ROIs of the series
                y = 0
                while y < Int(self.horos_maxMovieIndex) {
                    x = 0
                    while x < self.roi2PixCount(y) {
                        i = 0
                        while i < (self.roi2Slice(y, x)?.count ?? 0) {
                            let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                            objcAdd(applyToROIs, curROI)
                            i += 1
                        }
                        x += 1
                    }
                    y += 1
                }

            case 2: // All selected ROIs
                y = Int(self.horos_curMovieIndex)
                x = self.roi2CurImage()
                i = 0
                while i < (self.roi2Slice(y, x)?.count ?? 0) {
                    let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                    let mode = curROI?.roImode ?? 0

                    if roi2IsSelected(mode) {
                        objcAdd(applyToROIs, curROI)
                    }
                    i += 1
                }

            case 3: // All ROIs with same name as selected
                y = Int(self.horos_curMovieIndex)
                x = self.roi2CurImage()
                var name: String? = nil

                i = 0
                while i < (self.roi2Slice(y, x)?.count ?? 0) {
                    let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                    let mode = curROI?.roImode ?? 0

                    if roi2IsSelected(mode) {
                        name = curROI?.name
                        break
                    }
                    i += 1
                }

                if name != nil {
                    y = 0
                    while y < Int(self.horos_maxMovieIndex) {
                        x = 0
                        while x < self.roi2PixCount(y) {
                            i = 0
                            while i < (self.roi2Slice(y, x)?.count ?? 0) {
                                let curROI = objcObject(self.roi2Slice(y, x), i, ROI.self)

                                if objcIsEqualToString(curROI?.name, name) {
                                    objcAdd(applyToROIs, curROI)
                                }
                                i += 1
                            }
                            x += 1
                        }
                        y += 1
                    }
                }

            default:
                break
            }
        }

        return applyToROIs
    }

    @objc(roiDeleteAll:)
    func roiDeleteAll(_ sender: Any!) {
        self.add(toUndoQueue: "roi")

        self.horos_imageView?.stopROIEditingForce(true)

        var y = 0
        while y < Int(self.horos_maxMovieIndex) {
            if let slices = self.horos_roiList(at: y) {
                for item in slices {
                    guard let x = objcCast(item, NSMutableArray.self) else { continue }

                    // [x retain] … [x autorelease]: kept alive until the pool drains, as before.
                    _ = Unmanaged.passUnretained(x).retain()

                    var i = Int32(truncatingIfNeeded: x.count) - 1
                    while i >= 0 {
                        let curROI = objcObject(x, Int(i), ROI.self)

                        if curROI?.locked == false {
                            NotificationCenter.default.post(name: NSNotification.Name.OsirixRemoveROI, object: curROI, userInfo: nil)
                            objcRemove(x, curROI)
                        }
                        i -= 1
                    }

                    _ = Unmanaged.passUnretained(x).autorelease()
                }
            }
            y += 1
        }

        if let imageView = self.horos_imageView {
            imageView.setIndex(imageView.curImage)
        }
    }

    @objc(roiPropagateSetup:)
    func roiPropagateSetup(_ sender: Any!) {
        var selectedRoi: ROI? = nil

        if self.roi2PixCount(Int(self.horos_curMovieIndex)) > 1 {
            self.add(toUndoQueue: "roi")

            selectedRoi = self.selectedROI()

            if selectedRoi == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("No ROI(s) selected to propagate on the series!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                if self.horos_maxMovieIndex <= 1 { self.horos_roiPropaDim?.cell(withTag: 1)?.isEnabled = false }

                self.roi2BeginSheet(self.horos_roiPropaWindow)
            }
        } else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("There is only one image in this series. Nothing to propagate!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(roiHistogram:)
    func roiHistogram(_ sender: Any!) {
        var i: Int32 = 0
        while Int(i) < (self.roi2CurrentSlice()?.count ?? 0) {
            let mode = objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)?.roImode ?? 0

            if roi2IsSelected(mode) {
                let theROI = objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)
                var found = false

                for loopItem1 in NSApp.windows {
                    if objcIsEqualToString(loopItem1.windowController?.windowNibName, "Histogram") && !horosWindowControllerIsClosing(loopItem1.windowController) {
                        if ((loopItem1.windowController as AnyObject?)?.curROI?() as AnyObject?) === theROI {
                            found = true
                            loopItem1.windowController?.window?.makeKeyAndOrderFront(self)
                        }
                    }
                }

                if found == false {
                    let roiWin = HistoWindow(roi: theROI)
                    // [[HistoWindow alloc] initWithROI:] was not released: the
                    // controller releases itself when its window closes.
                    _ = Unmanaged.passRetained(roiWin)
                    roiWin.showWindow(self)
                }
            }
            i += 1
        }
    }

    @objc(roiGetInfo:)
    func roiGetInfo(_ sender: Any!) {
        var i: Int

        // NSUInteger <= short: the comparison C made, in unsigned long.
        if UInt(self.horos_roiList(at: Int(self.horos_curMovieIndex))?.count ?? 0) <= UInt(bitPattern: self.roi2CurImage()) { return }

        i = 0
        while i < (self.roi2CurrentSlice()?.count ?? 0) {
            let mode = objcObject(self.roi2CurrentSlice(), i, ROI.self)?.roImode ?? 0

            if roi2IsSelected(mode) {
                let theROI = objcObject(self.roi2CurrentSlice(), i, ROI.self)
                let winList = NSApp.windows
                var found = false

                for loopItem1 in winList {
                    if objcIsEqualToString(loopItem1.windowController?.windowNibName, "ROI") && !horosWindowControllerIsClosing(loopItem1.windowController) {
                        if ((loopItem1.windowController as AnyObject?)?.curROI?() as AnyObject?) === theROI {
                            found = true
                            loopItem1.windowController?.window?.makeKeyAndOrderFront(self)
                        }
                    }
                }

                if found == false {
                    let roiWin = ROIWindow(roi: theROI, self)
                    // [[ROIWindow alloc] initWithROI::] was not released: the
                    // controller releases itself when its window closes.
                    _ = Unmanaged.passRetained(roiWin)
                    roiWin.showWindow(self)
                }
                break
            }
            i += 1
        }
    }

    @objc(roiDefaults:)
    func roiDefaults(_ sender: Any!) {
        for loopItem in NSApp.windows {
            if objcIsEqualToString(loopItem.windowController?.windowNibName, "ROIDefaults") && !horosWindowControllerIsClosing(loopItem.windowController) {
                loopItem.windowController?.window?.makeKeyAndOrderFront(self)
                return
            }
        }

        let roiDefaultsWin = ROIDefaultsWindow(controller: self)
        // [[ROIDefaultsWindow alloc] initWithController:] was not released: the
        // controller releases itself when its window closes.
        _ = Unmanaged.passRetained(roiDefaultsWin)
        roiDefaultsWin.showWindow(self)
    }

    @objc(roiPropagateSlab:)
    func roiPropagateSlab(_ sender: Any!) {
        let selectedROIs = NSMutableArray()
        let cur = Int(self.horos_curMovieIndex)

        if (self.roi2Pix(cur, self.roi2CurImage())?.stack ?? 0) < 2 {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("This function is only usefull if you use Thick Slab!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

            return
        }

        if self.roi2PixCount(cur) > 1 {
            self.add(toUndoQueue: "roi")

            var upToImage: Int, startImage: Int, i: Int, x: Int

            i = 0
            while i < (self.roi2CurrentSlice()?.count ?? 0) {
                let mode = objcObject(self.roi2CurrentSlice(), i, ROI.self)?.roImode ?? 0

                if roi2IsSelected(mode) {
                    objcAdd(selectedROIs, objcObject(self.roi2CurrentSlice(), i, ROI.self))
                }
                i += 1
            }

            (startImage, upToImage) = roi2SlabImages(self.roi2CurImage(), Int(self.roi2Pix(cur, self.roi2CurImage())?.stack ?? 0),
                                                     self.roi2PixCount(cur), flipped: self.horos_imageView?.flippedData ?? false)

            if selectedROIs.count > 0 {
                x = startImage
                while x < upToImage {
                    if x != self.roi2CurImage() {
                        i = 0
                        while i < selectedROIs.count {
                            // [[… copy] autorelease]: the copy Swift receives is released by Swift.
                            let newROI = objcCast(objcCast(selectedROIs.object(at: i), NSObject.self)?.copy(), ROI.self)

                            newROI?.isAliased = false

                            objcAdd(self.roi2Slice(cur, x), newROI)
                            i += 1
                        }
                    }
                    x += 1
                }

                if let imageView = self.horos_imageView {
                    imageView.setIndex(imageView.curImage)
                }
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("No ROI(s) selected to propagate on the series!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        } else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("There is only one image in this series. Nothing to propagate!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(roiList)
    func roiList() -> NSMutableArray! {
        return self.horos_roiList(at: Int(self.horos_curMovieIndex))
    }

    @objc(roiList:)
    func roiList(_ i: Int) -> NSMutableArray! {
        // Clamped to the frames of the series, and to the first slot of the C
        // array when there is no frame yet: maxMovieIndex - 1 was -1 (#879).
        let i = roi2MovieIndex(i, Int(self.horos_maxMovieIndex))

        return self.horos_roiList(at: i)
    }

    @objc(setRoiList:array:)
    func setRoiList(_ i: Int, array a: NSMutableArray!) {
        // Clamped to the frames of the series, and to the first slot of the C
        // array when there is no frame yet: maxMovieIndex - 1 was -1 (#879).
        let i = roi2MovieIndex(i, Int(self.horos_maxMovieIndex))

        // [a retain]; [roiList[ i] release]; roiList[ i] = a; the new array
        // is retained before the old one is released: releasing first freed
        // the array when it was the one already there (#866).
        self.horos_setRoiList(a, at: i)
    }

    @objc(roiPropagate:)
    func roiPropagate(_ sender: Any!) {
        var i: Int, x: Int
        let cur = Int(self.horos_curMovieIndex)

        self.horos_roiPropaWindow?.orderOut(sender)

        self.roi2EndSheet(self.horos_roiPropaWindow, objcTag(sender))

        if objcTag(sender) != 1 { return }

        let selectedROIs = NSMutableArray()

        switch self.horos_roiPropaDim?.selectedCell()?.tag ?? 0 {
        case 0:
            if self.roi2PixCount(cur) > 1 {
                var upToImage: Int, startImage: Int

                i = 0
                while i < (self.roi2CurrentSlice()?.count ?? 0) {
                    let mode = objcObject(self.roi2CurrentSlice(), i, ROI.self)?.roImode ?? 0

                    if roi2IsSelected(mode) {
                        objcAdd(selectedROIs, objcObject(self.roi2CurrentSlice(), i, ROI.self))
                    }
                    i += 1
                }

                if (self.horos_roiPropaMode?.selectedCell()?.tag ?? 0) == 1 {
                    // The image number typed in the panel, float converted to int as C did.
                    let imageNumber = cInt32(self.horos_roiPropaDest?.floatValue ?? 0)

                    (startImage, upToImage) = roi2PropagationImages(self.roi2CurImage(), Int(imageNumber), self.roi2PixCount(cur),
                                                                    flipped: self.horos_imageView?.flippedData ?? false)
                } else {
                    upToImage = self.roi2PixCount(cur)
                    startImage = 0
                }

                if selectedROIs.count > 0 {
                    x = startImage
                    while x < upToImage {
                        if x != self.roi2CurImage() {
                            if (self.horos_roiPropaCopy?.selectedCell()?.tag ?? 0) == 1 {
                                i = 0
                                while i < selectedROIs.count {
                                    // [[… copy] autorelease]: the copy Swift receives is released by Swift.
                                    let newROI = objcCast(objcCast(selectedROIs.object(at: i), NSObject.self)?.copy(), ROI.self)

                                    newROI?.isAliased = false
                                    objcAdd(self.roi2Slice(cur, x), newROI)
                                    i += 1
                                }
                            } else {
                                i = 0
                                while i < selectedROIs.count {
                                    objcAdd(self.roi2Slice(cur, x), selectedROIs.object(at: i))
                                    i += 1
                                }
                            }
                        }
                        x += 1
                    }

                    if let imageView = self.horos_imageView {
                        imageView.setIndex(imageView.curImage)
                    }
                } else {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("No ROI(s) selected to propagate on the series!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("There is only one image in this series. Nothing to propagate!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

        case 1: // 4D Dimension
            i = 0
            while i < (self.roi2CurrentSlice()?.count ?? 0) {
                let mode = objcObject(self.roi2CurrentSlice(), i, ROI.self)?.roImode ?? 0

                if roi2IsSelected(mode) {
                    objcAdd(selectedROIs, objcObject(self.roi2CurrentSlice(), i, ROI.self))
                }
                i += 1
            }

            if selectedROIs.count > 0 {
                x = 0
                while x < Int(self.horos_maxMovieIndex) {
                    if x != cur {
                        if (self.horos_roiPropaCopy?.selectedCell()?.tag ?? 0) == 1 {
                            i = 0
                            while i < selectedROIs.count {
                                // [[… copy] autorelease]: the copy Swift receives is released by Swift.
                                let newROI = objcCast(objcCast(selectedROIs.object(at: i), NSObject.self)?.copy(), ROI.self)

                                objcAdd(self.roi2Slice(x, self.roi2CurImage()), newROI)
                                i += 1
                            }
                        } else {
                            i = 0
                            while i < selectedROIs.count {
                                objcAdd(self.roi2Slice(x, self.roi2CurImage()), selectedROIs.object(at: i))
                                i += 1
                            }
                        }
                    }
                    x += 1
                }

                if let imageView = self.horos_imageView {
                    imageView.setIndex(imageView.curImage)
                }
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Propagate Error", comment: ""), message: NSLocalizedString("No ROI(s) selected to propagate on the series!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

        default:
            break
        }
    }

    @objc(setROIToolTag:)
    func setROIToolTag(_ roitype: ToolMode) {
        let cell = self.horos_toolsMatrix?.cell(atRow: 0, column: 5)
        cell?.tag = Int(roitype.rawValue)
        // The image is computed before the message, as Objective-C evaluated
        // the argument even for a nil cell.
        let image = self.image(forROI: roitype)
        cell?.image = image
        cell?.image?.size = ToolsMenuIconSize

        self.horos_toolsMatrix?.selectCell(atRow: 0, column: 5)

        self.setDefaultToolMenu(self.horos_toolsMatrix?.selectedCell())
        //change Image in contextual menu 4/22/04, removed on 2010-01-22 because menus are now regenerated when rightclick happens
        //	NSMenu *menu = [imageView menu];
        //	[[menu itemAtIndex:5] setImage: [self imageForROI: roitype]];
        //	[[menu itemAtIndex:5] setTag: -1];
    }

    @objc(setROITool:)
    func setROITool(_ sender: Any!) {
        self.setROIToolTag(ToolMode(rawValue: Int16(truncatingIfNeeded: objcTag(sender)))!)

        //change default Tool if sent from Menu
        if sender is NSMenuItem {
            self.setDefaultTool(sender)
        }
    }

    // returns the names of all the ROIs (one occurrence of each name)
    @objc(roiNames)
    func roiNames() -> NSArray! {
        var x: Int32, i: Int32, j: Int32
        var found: Bool
        let cur = Int(self.horos_curMovieIndex)

        let names = NSMutableArray()

        x = 0
        while Int(x) < self.roi2PixCount(cur) {
            i = 0
            while Int(i) < (self.roi2Slice(cur, Int(x))?.count ?? 0) {
                found = false
                let curROI = objcObject(self.roi2Slice(cur, Int(x)), Int(i), ROI.self)
                let name = curROI?.name
                j = 0
                while Int(j) < names.count && !found {
                    if objcIsEqualToString(name, objcCast(names.object(at: Int(j)), NSString.self) as String?) {
                        found = true
                    }
                    j += 1
                }
                if !found {
                    objcAdd(names, name)
                }
                i += 1
            }
            x += 1
        }
        return names
    }

    @objc(roisWithComment:)
    func rois(withComment comment: String!) -> NSArray! {
        var x: Int32, i: Int32
        let cur = Int(self.horos_curMovieIndex)

        let rois = NSMutableArray()

        x = 0
        while Int(x) < self.roi2PixCount(cur) {
            i = 0
            while Int(i) < (self.roi2Slice(cur, Int(x))?.count ?? 0) {
                let curROI = objcObject(self.roi2Slice(cur, Int(x)), Int(i), ROI.self)
                if objcIsEqualToString(curROI?.comments, comment) {
                    curROI?.pix = self.roi2Pix(cur, Int(x))
                    objcAdd(rois, curROI)
                }
                i += 1
            }
            x += 1
        }
        return rois
    }

    @objc(roisWithName:)
    func rois(withName name: String!) -> NSArray! {
        return self.rois(withName: name, in4D: false)
    }

    @objc(roisWithName:in4D:)
    func rois(withName name: String!, in4D: Bool) -> NSArray! {
        let rois = NSMutableArray()

        if in4D {
            var m: Int32 = 0
            while Int(m) < Int(self.horos_maxMovieIndex) {
                if let found = self.rois(withName: name, forMovieIndex: m) { rois.addObjects(from: found as! [Any]) }
                m += 1
            }
        } else {
            if let found = self.rois(withName: name, forMovieIndex: Int32(self.horos_curMovieIndex)) { rois.addObjects(from: found as! [Any]) }
        }

        return rois
    }

    @objc(roisWithName:forMovieIndex:)
    func rois(withName name: String!, forMovieIndex m: Int32) -> NSArray! {
        let rois = NSMutableArray()

        var x: Int32 = 0
        while Int(x) < self.roi2PixCount(Int(m)) {
            var i: Int32 = 0
            while Int(i) < (self.roi2Slice(Int(m), Int(x))?.count ?? 0) {
                let curROI = objcObject(self.roi2Slice(Int(m), Int(x)), Int(i), ROI.self)
                if objcIsEqualToString(curROI?.name, name) {
                    curROI?.pix = self.roi2Pix(Int(m), Int(x))
                    objcAdd(rois, curROI)
                }
                i += 1
            }
            x += 1
        }
        return rois
    }

    @objc(isoContourROI:numberOfPoints:)
    func isoContourROI(_ a: ROI!, numberOfPoints nof: Int32) -> ROI! {
        // The OSIRIX_LIGHT branch (return nil) is left out.
        var a: ROI? = a
        if a?.type == .tCPolygon || a?.type == .tOPolygon || a?.type == .tPencil {
            a?.points = ROI.resamplePoints(a?.splinePoints() as? [Any], number: nof)
            return a
        } else if a?.type == .tPlain {
            a = self.convertBrushROItoPolygon(a, numPoints: nof)
            a?.points = ROI.resamplePoints(a?.splinePoints() as? [Any], number: nof)
            return a
        } else { return nil }
    }

    @objc(roiMorphingBetween:and:ratio:)
    func roiMorphingBetween(_ a: ROI!, and b: ROI!, ratio: Float) -> ROI! {
        var a: ROI? = a
        var b: ROI? = b

        if a?.type == .tMesure && b?.type == .tMesure {
            let newMeasure = self.horos_unretainedNewROI(.tMesure)

            newMeasure?.addPoint(ROI.pointBetweenPoint(a?.point(at: 0) ?? .zero, and: b?.point(at: 0) ?? .zero, ratio: ratio))
            newMeasure?.addPoint(ROI.pointBetweenPoint(a?.point(at: 1) ?? .zero, and: b?.point(at: 1) ?? .zero, ratio: ratio))

            newMeasure?.rgbcolor = a?.rgbcolor ?? RGBColor()
            newMeasure?.opacity = a?.opacity ?? 0
            newMeasure?.thickness = a?.thickness ?? 0
            newMeasure?.name = a?.name

            return newMeasure
        }

        let inputROI = a

        // [[a copy] autorelease]: the copy Swift receives is released by Swift.
        // The ROIs are copied before they are turned into polygons: the
        // conversions below changed the caller's ROIs (an oval of the series
        // became a polygon when missing ROIs were generated) (#866).
        a = objcCast(a?.copy(), ROI.self)
        b = objcCast(b?.copy(), ROI.self)

        if a?.type == .tMesure {
            a?.points?.insert(MyPoint.point(ROI.pointBetweenPoint(a?.point(at: 0) ?? .zero, and: a?.point(at: 1) ?? .zero, ratio: 0.5)), at: 1)
            a?.type = .tOPolygon
        }

        if b?.type == .tMesure {
            b?.points?.insert(MyPoint.point(ROI.pointBetweenPoint(b?.point(at: 0) ?? .zero, and: b?.point(at: 1) ?? .zero, ratio: 0.5)), at: 1)
            b?.type = .tOPolygon
        }

        if a?.type == .tROI || a?.type == .tOval {
            let points = a?.points
            if a?.type == .tROI {
                a?.isSpline = false
            }

            a?.type = .tCPolygon
            a?.points = points
        }

        if b?.type == .tROI || b?.type == .tOval {
            let points = b?.points
            if b?.type == .tROI {
                b?.isSpline = false
            }

            b?.type = .tCPolygon
            b?.points = points
        }

        var aPts = a?.points
        var bPts = b?.points

        // MAX of two NSUInteger, stored in an int.
        var maxPoints = Int32(truncatingIfNeeded: max(aPts?.count ?? 0, bPts?.count ?? 0))
        maxPoints += maxPoints / 3

        a?.isAliased = false
        b?.isAliased = false

        // If the ROIs are brush ROIs, convert them into polygons, using a marching square isocontour
        // Otherwise update the points so they both have maxPoints number of points
        a = self.isoContourROI(a, numberOfPoints: maxPoints)
        b = self.isoContourROI(b, numberOfPoints: maxPoints)

        if a == nil { return nil }
        if b == nil { return nil }

        if (a?.points?.count ?? 0) != Int(maxPoints) || (b?.points?.count ?? 0) != Int(maxPoints) {
            NSLog("***** NoOfPoints !")
            return nil
        }

        aPts = a?.points
        bPts = b?.points

        var newROI: ROI? = nil
        if a?.type == .tOPolygon {
            newROI = self.horos_unretainedNewROI(.tOPolygon)
        } else {
            newROI = self.horos_unretainedNewROI(.tCPolygon)
        }

        let pts = newROI?.points
        var i: Int32 = 0

        while Int(i) < (aPts?.count ?? 0) {
            let aP = objcObject(aPts, Int(i), MyPoint.self)
            let bP = objcObject(bPts, Int(i), MyPoint.self)

            let newPt = ROI.pointBetweenPoint(aP?.point ?? .zero, and: bP?.point ?? .zero, ratio: ratio)

            objcAdd(pts, MyPoint.point(newPt))
            i += 1
        }

        if inputROI?.type == .tPlain {
            newROI = self.convertPolygonROItoBrush(newROI)
        }

        newROI?.rgbcolor = inputROI?.rgbcolor ?? RGBColor()
        newROI?.opacity = inputROI?.opacity ?? 0
        newROI?.thickness = inputROI?.thickness ?? 0
        newROI?.name = inputROI?.name

        return newROI
    }

    @objc(roiChange:)
    func roiChange(_ note: Notification!) {
        //	if( curvedController)
        //	{
        //		if( [note object] == [curvedController roi])
        //		{
        //			[curvedController recompute];
        //		}
        //	}
    }

    //- (IBAction)exportAsDICOMSR:(id)sender;
    //{
    //	SRAnnotationController *srController = [[SRAnnotationController alloc] initWithViewerController:self];
    //	[srController beginSheet];
    //}

    @objc(selectedROI)
    func selectedROI() -> ROI! {
        var selectedRoi: ROI? = nil
        var i: Int32

        i = 0
        while Int(i) < (self.roi2CurrentSlice()?.count ?? 0) {
            let mode = objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)?.roImode ?? 0

            if roi2IsSelected(mode) {
                selectedRoi = objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)
            }
            i += 1
        }

        if selectedRoi == nil {
            // If there is only one roi on the image, choose it !
            if (self.roi2CurrentSlice()?.count ?? 0) == 1 {
                selectedRoi = objcObject(self.roi2CurrentSlice(), 0, ROI.self)
                selectedRoi?.roImode = ROI_selected
                self.horos_imageView?.display()
            }
        }

        return selectedRoi
    }

    @objc(selectedROIs)
    func selectedROIs() -> NSMutableArray! {
        let selectedRois = NSMutableArray()
        var i: Int32

        i = 0
        while Int(i) < (self.roi2CurrentSlice()?.count ?? 0) {
            let mode = objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)?.roImode ?? 0

            if roi2IsSelected(mode) {
                objcAdd(selectedRois, objcObject(self.roi2CurrentSlice(), Int(i), ROI.self))
            }
            i += 1
        }

        return selectedRois
    }

    @objc(setMode:toROIGroupWithID:)
    func setMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval) {
        var mode = mode
        if groupID == 0.0 { return }
        if mode == ROI_selectedModify { mode = ROI_selected }
        // set the mode to all ROIs in the same group
        let curROIList = self.roi2CurrentSlice()
        for loopItem in curROIList ?? NSMutableArray() {
            if objcCast(loopItem, ROI.self)?.groupID == groupID {
                objcCast(loopItem, ROI.self)?.roImode = mode
            }
        }
    }

    @objc(selectROI:deselectingOther:)
    func select(_ roi: ROI!, deselectingOther deselectOther: Bool) {
        if deselectOther {
            var i: Int32 = 0
            while Int(i) < (self.roi2CurrentSlice()?.count ?? 0) {
                objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)?.roImode = ROI_sleep
                i += 1
            }
        }

        if let roi {
            // select the ROI
            roi.roImode = ROI_selected
            // select the othher grouped ROIs (if any)
            self.setMode(ROI_selected, toROIGroupWithID: roi.groupID)

            // bring it to front
            self.bring(toFrontROI: roi)
        }
    }

    @objc(deselectAllROIs)
    func deselectAllROIs() {
        var i: Int32 = 0
        while Int(i) < (self.roi2CurrentSlice()?.count ?? 0) {
            objcObject(self.roi2CurrentSlice(), Int(i), ROI.self)?.roImode = ROI_sleep
            i += 1
        }
    }

    @objc(setSelectedROIsGrouped:)
    func setSelectedROIsGrouped(_ grouped: Bool) {
        self.add(toUndoQueue: "roi")

        let curROIList = self.roi2CurrentSlice()
        var mode: Int

        let newGroupID: TimeInterval
        if grouped {
            newGroupID = Date.timeIntervalSinceReferenceDate
        } else {
            newGroupID = 0.0
        }

        for item in curROIList ?? NSMutableArray() {
            let roi = objcCast(item, ROI.self)
            mode = roi?.roImode ?? 0

            if roi2IsSelected(mode) {
                roi?.groupID = newGroupID
            }
        }
    }

    @objc(groupSelectedROIs)
    func groupSelectedROIs() {
        self.setSelectedROIsGrouped(true)
    }

    @objc(ungroupSelectedROIs)
    func ungroupSelectedROIs() {
        self.setSelectedROIsGrouped(false)
    }

    @objc(groupSelectedROIs:)
    func groupSelectedROIs(_ sender: Any!) {
        self.groupSelectedROIs()
    }

    @objc(ungroupSelectedROIs:)
    func ungroupSelectedROIs(_ sender: Any!) {
        self.ungroupSelectedROIs()
    }

    @objc(setSelectedROIsLocked:)
    func setSelectedROIsLocked(_ locked: Bool) {
        self.add(toUndoQueue: "roi")

        let curROIList = self.roi2CurrentSlice()

        for item in curROIList ?? NSMutableArray() {
            let roi = objcCast(item, ROI.self)
            if roi2IsSelected(roi?.roImode ?? 0) {
                roi?.locked = locked
            }
        }
    }

    @objc(lockSelectedROIs:)
    func lockSelectedROIs(_ sender: Any!) {
        self.setSelectedROIsLocked(true)
    }

    @objc(unlockSelectedROIs:)
    func unlockSelectedROIs(_ sender: Any!) {
        self.setSelectedROIsLocked(false)
    }

    @objc(makeSelectedROIsUnselectable:)
    func makeSelectedROIsUnselectable(_ sender: Any!) {
        self.add(toUndoQueue: "roi")

        let curROIList = self.roi2CurrentSlice()

        for item in curROIList ?? NSMutableArray() {
            let roi = objcCast(item, ROI.self)
            if roi2IsSelected(roi?.roImode ?? 0) {
                roi?.selectable = false
            }
        }
    }

    @objc(makeAllROIsSelectable:)
    func makeAllROIsSelectable(_ sender: Any!) {
        self.add(toUndoQueue: "roi")

        let curROIList = self.roi2CurrentSlice()

        for item in curROIList ?? NSMutableArray() {
            let roi = objcCast(item, ROI.self)
            roi?.selectable = true
        }
    }

    @objc(bringToFrontROI:)
    func bring(toFrontROI roi: ROI!) {
        if (roi?.groupID ?? 0) == 0.0 { // not grouped
            // [roi retain] … [roi release]: Swift holds roi meanwhile.
            objcRemove(self.roi2CurrentSlice(), roi)
            objcInsert(self.roi2CurrentSlice(), roi, 0)
        } else { // bring the whole group to front, without changing order inside the group
            let group = NSMutableArray()
            let ROIs = self.roi2CurrentSlice()
            var i: Int32 = 0
            while Int(i) < (ROIs?.count ?? 0) {
                if objcObject(ROIs, Int(i), ROI.self)?.groupID == roi?.groupID {
                    objcAdd(group, ROIs?.object(at: Int(i)))
                    objcRemove(ROIs, ROIs?.object(at: Int(i)))
                    i -= 1
                }
                i += 1
            }
            i = Int32(truncatingIfNeeded: group.count) - 1
            while i >= 0 {
                objcInsert(ROIs, group.object(at: Int(i)), 0)
                i -= 1
            }
        }
    }

    @objc(sendToBackROI:)
    func send(toBack roi: ROI!) {
        if (roi?.groupID ?? 0) == 0.0 { // not grouped
            // [roi retain] … [roi release]: Swift holds roi meanwhile. The
            // ROI is taken out before it goes back at the end: removing it
            // after the insertion took out both occurrences, and the ROI was
            // gone (#866).
            objcRemove(self.roi2CurrentSlice(), roi)
            objcInsert(self.roi2CurrentSlice(), roi, self.roi2CurrentSlice()?.count ?? 0)
        } else { // send the whole group to back, without changing order inside the group
            let group = NSMutableArray()
            let ROIs = self.roi2CurrentSlice()
            var i: Int32 = 0
            while Int(i) < (ROIs?.count ?? 0) {
                if objcObject(ROIs, Int(i), ROI.self)?.groupID == roi?.groupID {
                    objcAdd(group, ROIs?.object(at: Int(i)))
                    objcRemove(ROIs, ROIs?.object(at: Int(i)))
                    i -= 1
                }
                i += 1
            }
            // Appended in their order: appending them from the last one, as
            // the front insertion does, reversed the group (#866).
            for member in group {
                objcInsert(ROIs, member, ROIs?.count ?? 0)
            }
        }
    }
}
