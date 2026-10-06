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
import Accelerate

// The "blending" block of ViewerController is implemented in Swift:
// a Swift extension of ViewerController, which stays Objective-C, with
// the same selectors. The instance variables it uses are read through
// ViewerController (SwiftIvars); _blendingType, an ivar of OSIWindowController,
// through its accessor there. -blendedWindow, the getter of the declared
// property, stays in Objective-C.
//
// blendingController is assigned without retain, as before (the assign store
// of the accessor); blendedWindow is released and cleared through the retain
// setter. The reentry counter of -ActivateBlending: was a static of the method,
// shared by all viewers: it is the fileprivate counter below. A message to nil
// answered nil, 0 or NO: the optional chains below answer the same. An @try is
// HorosObjCException.perform (objcTry), and the code of its @finally runs after
// it. Messages the former code sent to an `id` sender (tag, selectedSegment,
// floatValue) are sent as Objective-C sent them (objcSend…). The C conversions
// from float to long saturate and take NaN to 0, as on arm64 (cLong).

/// `static int noActivateBlendingReentry` of -ActivateBlending:.
@MainActor fileprivate var noActivateBlendingReentry: Int32 = 0

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

/// `[a isEqualToString: b]`, NO when either is nil.
fileprivate func objcIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// The implementation of `selectorName` for `target`, as objc_msgSend finds it:
/// a target that does not implement the method raises when it is called
/// (through the forwarding machinery).
fileprivate func objcImplementation(_ target: AnyObject, _ selectorName: String) -> (IMP, Selector)? {
    let selector = NSSelectorFromString(selectorName)
    guard let targetClass: AnyClass = object_getClass(target),
          let implementation = class_getMethodImplementation(targetClass, selector) else { return nil }
    return (implementation, selector)
}

/// `[target selector]` of a method returning `long`/`NSInteger`; 0 for nil.
fileprivate func objcSendInteger(_ target: Any?, _ selectorName: String) -> Int {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector) -> Int
    return unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector)
}

/// `[target selector]` of a method returning `float`; 0 for nil.
fileprivate func objcSendFloat(_ target: Any?, _ selectorName: String) -> Float {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector) -> Float
    return unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector)
}

/// `[views makeObjectsPerformSelector: @selector(display)]`, which Swift does
/// not offer.
@MainActor fileprivate func makeViewsDisplay(_ views: NSArray?) {
    for case let view as NSView in views ?? NSArray() {
        view.display()
    }
}

/// C conversion of a float to `long`, as arm64 does it: saturating, NaN to 0.
fileprivate func cLong(_ x: Float) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// `[DCMView angleBetweenVector: a+6 andVector: b+6]` of two orientations.
@MainActor fileprivate func normalsAngle(_ orientA: inout [Float], _ orientB: inout [Float]) -> Float {
    return orientA.withUnsafeMutableBufferPointer { a in
        orientB.withUnsafeMutableBufferPointer { b in
            DCMView.angleBetweenVector(a.baseAddress! + 6, andVector: b.baseAddress! + 6)
        }
    }
}

/// `[NSString stringWithFormat:@"%0.0f%%", (float) (value + 256.) / 5.12]`.
fileprivate func blendingPercentageString(_ value: Float) -> String {
    return String(format: "%0.0f%%", Double(Float(Double(value) + 256.0)) / 5.12)
}

public extension ViewerController {

    // MARK: - blending

    @objc(blendWindows:)
    func blendWindows(_ sender: Any!) {
        let viewersCT = ViewerController.getDisplayed2DViewers()
        let viewersPET = ViewerController.getDisplayed2DViewers()
        var fused = false

        if sender != nil && self.horos_blending != nil {
            self.activateBlending(nil)
            return
        }

        if sender != nil {
            // The secondary viewer does not own the link. Find its existing owner
            // before trying to create a new pair or reporting incompatibility.
            for case let owner as ViewerController in viewersCT ?? NSMutableArray() {
                if owner.blending() === self {
                    owner.activateBlending(nil)
                    return
                }
            }
        }

        for case let vCT as ViewerController in viewersCT ?? NSMutableArray() {
            if objcIsEqualToString(vCT.modality(), "CT") {
                for case let vPET as ViewerController in viewersPET ?? NSMutableArray() {
                    if sender != nil && vCT !== self && vPET !== self { continue }
                    if vPET !== vCT {
                        if (objcIsEqualToString(vPET.modality(), "PT") || objcIsEqualToString(vPET.modality(), "NM")) && objcIsEqualToString(vPET.studyInstanceUID(), vCT.studyInstanceUID()) {
                            let a: ViewerController = vCT

                            if a.blending() == nil {
                                let b: ViewerController = vPET

                                var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)

                                a.imageView()?.curDCM?.orientation(&orientA)
                                b.imageView()?.curDCM?.orientation(&orientB)

                                if normalsAngle(&orientA, &orientB) < UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") {
                                    if a.isGantryTitled() == false && b.isGantryTitled() == false {
                                        a.imageView()?.sendSyncMessage(0)
                                        a.activateBlending(b)

                                        fused = true
                                        if sender != nil { return }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if fused == false && sender != nil {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("PET-CT Fusion", comment: ""),
                                            message: NSLocalizedString("This function requires two parallel series: a PT/NM series and a CT series in the same study.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(ActivateBlending:)
    func activateBlending(_ bC: ViewerController!) {
        if noActivateBlendingReentry > 0 {
            return
        }

        noActivateBlendingReentry += 1

        self.activateBlendingInside(bC)

        // @finally
        noActivateBlendingReentry -= 1
    }

    /// The body of -ActivateBlending:, under its reentry guard. The guard
    /// turns away a -ActivateBlending: that the body causes indirectly (an
    /// alert's event loop, a notification); the body's own calls, which undo
    /// this viewer's previous fusion and the other viewer's fusion with this
    /// one, come here directly: through the guard they did nothing, and two
    /// viewers could be fused with each other.
    private func activateBlendingInside(_ bC: ViewerController!) {
        if let e = objcTry({
            if bC === self { return }
            if self.horos_blending === bC { return }

            if let bC {
                if let reason = self.fourDFusionRefusalReason(forOverlay: bC) {
                    _ = HorosAlertPanel.run(title: NSLocalizedString("PET-CT Fusion", comment: ""), message: reason,
                                            defaultButton: nil, alternateButton: nil, otherButton: nil)
                    return
                }
            }

            if self.horos_blending != nil && bC != nil {
                self.activateBlendingInside(nil)
            }

            self.horos_imageView?.sendSyncMessage(0)

            // blendingController = bC; (not retained)
            self.horos_assignBlendingController(bC)

            if self.horos_blending != nil {
                NSLog("Blending Activated!")

                if self.horos_blending?.blending() === self {	// NO cross blending !
                    self.horos_blending?.activateBlendingInside(nil)
                }

                if objcIsEqualToString((self.fileList()?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String,
                                       (self.horos_blending?.fileList()?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String) {
                    // By default, re-activate 'propagate settings'

                    UserDefaults.standard.set(true, forKey: "COPYSETTINGS")
                }

                var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)

                var proceed = false

                self.imageView()?.curDCM?.orientation(&orientA)
                self.horos_blending?.imageView()?.curDCM?.orientation(&orientB)

                if orientB[6] == 0 && orientB[7] == 0 && orientB[8] == 0 { proceed = true }
                if orientA[6] == 0 && orientA[7] == 0 && orientA[8] == 0 { proceed = true }

                if normalsAngle(&orientA, &orientB) > UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") {  // Planes are not paralel!
                    // FROM SAME STUDY

                    if objcIsEqualToString((self.fileList()?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String,
                                           (self.horos_blending?.fileList()?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String) {
                        let result = HorosAlertPanel.runCritical(title: NSLocalizedString("2D Planes", comment: ""),
                                                                 message: NSLocalizedString("These 2D planes are not parallel. If you continue the result will be distorted. You can instead 'Reorient' the series to have the same origin/orientation.", comment: ""),
                                                                 defaultButton: NSLocalizedString("Reorient & Fusion", comment: ""),
                                                                 alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                                 otherButton: NSLocalizedString("Fusion", comment: ""))

                        switch result {
                        case HorosAlertPanel.alternateResponse:
                            proceed = false

                        case HorosAlertPanel.defaultResponse:		// Resample
                            // blendingController = [self resampleSeries: blendingController rescale: NO]; (not retained)
                            self.horos_assignBlendingController(self.resampleSeries(self.horos_blending, rescale: false))
                            if self.horos_blending != nil { proceed = true }

                        case HorosAlertPanel.otherResponse:
                            proceed = true

                        default:
                            break
                        }
                    } else {	// FROM DIFFERENT STUDY
                        if HorosAlertPanel.runCritical(title: NSLocalizedString("2D Planes", comment: ""),
                                                       message: NSLocalizedString("These 2D planes are not parallel. If you continue the result will be distorted. You can instead perform a 'Point-based registration' to have correct alignment/orientation.", comment: ""),
                                                       defaultButton: NSLocalizedString("Continue", comment: ""),
                                                       alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                       otherButton: nil) != HorosAlertPanel.defaultResponse {
                            proceed = false
                        } else {
                            proceed = true
                        }
                    }
                } else {
                    self.displayWarningIfGantryTitled()
                    self.horos_blending?.displayWarningIfGantryTitled()

                    proceed = true
                }

                if proceed {
                    self.horos_imageView?.blending = self.horos_blending?.imageView()
                    self.horos_blendingSlider?.isEnabled = true
                    self.horos_blendingPercentage?.isEnabled = true
                    self.horos_blendingPercentage?.stringValue = blendingPercentageString(self.horos_blendingSlider?.floatValue ?? 0)

                    if objcIsEqualToString(self.horos_blending?.curCLUTMenu(), NSLocalizedString("No CLUT", comment: "")) && ((self.horos_blending?.pixList()?.object(at: 0) as? DCMPix)?.isRGB ?? false) == false {
                        if objcIsEqualToString(self.modality(), "PT") || (UserDefaults.standard.bool(forKey: "clutNM") == true && objcIsEqualToString(self.modality(), "NM")) {
                            if objcIsEqualToString(UserDefaults.standard.string(forKey: "PET Clut Mode"), "B/W Inverse") {
                                self.applyCLUTString("B/W Inverse")
                            } else {
                                self.applyCLUTString(UserDefaults.standard.string(forKey: "PET Default CLUT"))
                            }
                        }
                    }

                    self.horos_imageView?.setBlendingFactor(self.horos_blendingSlider?.floatValue ?? 0)

                    self.horos_blendingPopupMenu?.selectItem(withTag: UserDefaults.standard.integer(forKey: "DEFAULTPETFUSION"))
                    self.horos_imageView?.blendingMode = UserDefaults.standard.integer(forKey: "DEFAULTPETFUSION")
                    self.horos_seriesView?.setBlendingMode(Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "DEFAULTPETFUSION")))

                    self.horos_seriesView?.activateBlending(self.horos_blending, blendingFactor: self.horos_blendingSlider?.floatValue ?? 0)
                }

                // [backCurCLUTMenu release]; backCurCLUTMenu = 0L;
                self.horos_backCurCLUTMenu = nil

                if self.horos_blending != nil && objcIsEqualToString(UserDefaults.standard.string(forKey: "PET Clut Mode"), "B/W Inverse") {
                    // backCurCLUTMenu = [curCLUTMenu copy];
                    self.horos_backCurCLUTMenu = self.horos_curCLUTMenu
                    // [curCLUTMenu release]; curCLUTMenu = [[… stringForKey: @"PET Blending CLUT"] copy];
                    self.horos_curCLUTMenu = UserDefaults.standard.string(forKey: "PET Blending CLUT")
                }
            } else {
                // [backCurCLUTMenu release]; backCurCLUTMenu = 0L;
                self.horos_backCurCLUTMenu = nil

                // [curCLUTMenu release]; curCLUTMenu = [NSLocalizedString(@"No CLUT", nil) retain];
                self.horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")

                self.horos_imageView?.blending = nil
                self.horos_blendingSlider?.isEnabled = false
                // The Fusion item keeps showing the percentage the slider holds,
                // dimmed like the slider, instead of a bare "-".
                self.horos_blendingPercentage?.isEnabled = false
                self.horos_blendingPercentage?.stringValue = blendingPercentageString(self.horos_blendingSlider?.floatValue ?? 0)
                self.horos_seriesView?.activateBlending(nil, blendingFactor: self.horos_blendingSlider?.floatValue ?? 0)
                self.horos_imageView?.display()
            }

            self.buildMatrixPreview(false)

            self.horos_imageView?.sendSyncMessage(0)

            self.applyCLUTString(self.horos_curCLUTMenu)
            self.refreshMenus()
        }) {
            _N2LogExceptionImpl(e, false, "-[ViewerController ActivateBlending:]")
        }
    }

    // -blendedWindow, the getter of the declared property, stays in Objective-C.

    @objc(endBlendingType:)
    func endBlendingType(_ sender: Any!) {
        var blendingType = Int32(truncatingIfNeeded: objcSendInteger(sender, "tag"))

        if (sender as? NSObject)?.isKind(of: NSSegmentedControl.self) ?? false {	//Add RGB
            blendingType = Int32(truncatingIfNeeded: Int(blendingType) &+ objcSendInteger(sender, "selectedSegment"))
        }

        self.horos_blendingTypeWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: Int(blendingType)))
    }

    @objc(blendingSheetDidEnd:returnCode:contextInfo:)
    func blendingSheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        var returnCode = returnCode
        if returnCode < 0 {
            returnCode = 0 &- returnCode &- 1
            self.clear8bitRepresentations()

            if objcIsEqualToString((PluginManager.fusionPlugins() as NSArray?)?.object(at: Int(returnCode)) as? String, "Subtraction Angio-CT") {
                self.blend(withViewer: self.horos_blendedWindow, blendingType: 9) // LL filter
            } else {
                self.executeFilter(from: (PluginManager.fusionPlugins() as NSArray?)?.object(at: Int(returnCode)) as? String)
            }
        } else if returnCode > 0 {
            self.clear8bitRepresentations()
            self.blend(withViewer: self.horos_blendedWindow, blendingType: returnCode)
        }

        // [blendedWindow release]; blendedWindow = nil;
        self.horos_blendedWindow = nil
    }

    @objc(blendWithViewer:blendingType:)
    func blend(withViewer bc: ViewerController!, blendingType: Int32) {
        // _blendingType = blendingType;
        self.horos_blendingType = blendingType

        var i = 0
        switch blendingType {
        case -1:	// PLUG-INS METHOD
            //[self executeFilter:sender];
            break

        case 1:		// Image fusion
            self.activateBlending(bc)

        case 2:
            // Image subtraction
            let modifierFlags: UInt = NSApplication.shared.currentEvent?.modifierFlags.rawValue ?? 0

            if (modifierFlags & NSEvent.ModifierFlags.control.rawValue) != 0 {
                let count = min(self.pixList()?.count ?? 0, bc?.pixList()?.count ?? 0)
                i = 0
                while i < count {
                    self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: i))
                    self.horos_imageView?.sendSyncMessage(0)
                    makeViewsDisplay(self.horos_seriesView?.imageViews())

                    bc?.imageView()?.setIndex(Int16(truncatingIfNeeded: i))
                    bc?.imageView()?.sendSyncMessage(0)
                    makeViewsDisplay(bc?.seriesView()?.imageViews())

                    self.horos_imageView?.subtract(bc?.imageView(), absolute: (modifierFlags & NSEvent.ModifierFlags.option.rawValue) != 0)
                    i += 1
                }
            } else {
                i = 0
                while i < (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) {
                    self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: i))
                    self.horos_imageView?.sendSyncMessage(0)
                    makeViewsDisplay(self.horos_seriesView?.imageViews())

                    self.horos_imageView?.subtract(bc?.imageView(), absolute: (modifierFlags & NSEvent.ModifierFlags.option.rawValue) != 0)
                    i += 1
                }
            }

        case 3:		// Image multiplication
            i = 0
            while i < (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) {
                self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: i))
                self.horos_imageView?.sendSyncMessage(0)
                makeViewsDisplay(self.horos_seriesView?.imageViews())

                self.horos_imageView?.multiply(bc?.imageView())
                i += 1
            }

        case 4,		// RGB Composition
             5,
             6:
            i = 0
            while i < (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) {   // Convert all images to RGB images if necessary
                var cwl: Float = 0, cww: Float = 0

                self.horos_imageView?.getWLWW(&cwl, &cww)

                if ((self.horos_pixList(at: Int(self.horos_curMovieIndex))?.object(at: i) as? DCMPix)?.isRGB ?? false) == false {
                    (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.object(at: i) as? DCMPix)?.convert(toRGB: 0, cLong(cwl), cLong(cww))
                }

                let dstPix = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.object(at: i) as? DCMPix
                // The other series may have fewer images: the images past its
                // end are converted and left as they are (-objectAtIndex: raised).
                let srcPix = i < (bc?.pixList()?.count ?? 0) ? bc?.pixList()?.object(at: i) as? DCMPix : nil

                if srcPix == nil {
                    // Nothing to compose with.
                } else if srcPix?.pwidth != dstPix?.pwidth || srcPix?.pheight != dstPix?.pheight {
                    // The composition walks this image's buffer with the other
                    // image's size: a larger image wrote past its end. As the
                    // fusion sheet offers it only for images of one size, an
                    // image of another size is converted and left as it is.
                } else if srcPix?.isRGB ?? false {   // Only works if srcImage is BW
                    let srcPtr = srcPix?.fImage.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self) }
                    let dstPtr = dstPix?.fImage.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self) }

                    var size = (srcPix?.pheight ?? 0) &* (srcPix?.pwidth ?? 0) &* 4
                    var temp: Int

                    while size > 0 {
                        size -= 1
                        temp = Int(dstPtr![size])
                        temp += Int(srcPtr![size])
                        if temp > 255 { temp = 255 }
                        dstPtr![size] = UInt8(truncatingIfNeeded: temp)
                    }
                } else {	// BW SOURCE
                    // Convert srcImage to 8 bits

                    var srcf = vImage_Buffer(), dst8 = vImage_Buffer()

                    srcf.height = vImagePixelCount(UInt(bitPattern: srcPix?.pheight ?? 0))
                    srcf.width = vImagePixelCount(UInt(bitPattern: srcPix?.pwidth ?? 0))
                    srcf.rowBytes = (srcPix?.pwidth ?? 0) &* MemoryLayout<Float>.size
                    srcf.data = srcPix?.fImage.map { UnsafeMutableRawPointer($0) }

                    dst8.height = vImagePixelCount(UInt(bitPattern: srcPix?.pheight ?? 0))
                    dst8.width = vImagePixelCount(UInt(bitPattern: srcPix?.pwidth ?? 0))
                    dst8.rowBytes = srcPix?.pwidth ?? 0
                    // Freed after the composition below (it leaked one per image).
                    dst8.data = malloc(Int(bitPattern: UInt(bitPattern: (srcPix?.pheight ?? 0) &* (srcPix?.pwidth ?? 0))))
                    defer { free(dst8.data) }


                    cwl = srcPix?.wl ?? 0
                    cww = srcPix?.ww ?? 0

                    let min = cLong(cwl - cww / 2)
                    let max = cLong(cwl + cww / 2)

                    vImageConvert_PlanarFtoPlanar8(&srcf, &dst8, Float(max), Float(min), 0)					// FLOAT TO 8 bit

                    let srcPtr = dst8.data.map { $0.assumingMemoryBound(to: UInt8.self) }
                    let dstPtr = dstPix?.fImage.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self) }
                    var size = (srcPix?.pheight ?? 0) &* (srcPix?.pwidth ?? 0)

                    switch blendingType {
                    case 4:
                        while size > 0 {
                            size -= 1
                            dstPtr![size &* 4 &+ 1] = srcPtr![size]
                        }

                    case 5:
                        while size > 0 {
                            size -= 1
                            dstPtr![size &* 4 &+ 2] = srcPtr![size]
                        }

                    case 6:
                        while size > 0 {
                            size -= 1
                            dstPtr![size &* 4 &+ 3] = srcPtr![size]
                        }

                    default:
                        break
                    }
                }

                self.horos_imageView?.getWLWW(&cwl, &cww)
                dstPix?.changeWLWW(cwl, cww)
                self.horos_imageView?.loadTextures()
                self.horos_imageView?.needsDisplay = true
                i += 1
            }

        case 7:		// 2D Registration
            self.computeRegistration(withMovingViewer: bc)

        case 11:
            _ = self.resampleSeries(bc, rescale: true)

        case 12:
            _ = self.resampleSeries(bc, rescale: false)

        case 8:		// 3D Registration

            break

            //		#ifndef OSIRIX_LIGHT
            //		case 9: // LL
            //		{
            //			[self checkEverythingLoaded];
            //			[bc checkEverythingLoaded];
            //			if([LLScoutViewer verifyRequiredConditions:[self pixList] :[bc pixList]])
            //			{
            //				LLScoutViewer *llScoutViewer;
            //				llScoutViewer = [[LLScoutViewer alloc] initWithPixList: pixList[0] :fileList[0] :volumeData[0] :self :bc];
            //				[llScoutViewer showWindow:self];
            //			}
            //		}
            //		break;
            //		#endif

        case 10:	// Copy ROIs
            let splash = WaitRendering(NSLocalizedString("Copy ROIs between series...", comment: ""))
            splash?.showWindow(self)

            let curIndex = Int32(self.horos_imageView?.curImage ?? 0)
            let bcCurIndex = Int32(bc?.imageView()?.curImage ?? 0)

            let count = Swift.min(self.pixList()?.count ?? 0, bc?.pixList()?.count ?? 0)
            var x: Int32 = 0
            while Int(x) < count {
                self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: x))
                self.horos_imageView?.sendSyncMessage(0)
                self.adjustSlider()

                bc?.imageView()?.setIndex(Int16(truncatingIfNeeded: x))
                bc?.imageView()?.sendSyncMessage(0)
                bc?.adjustSlider()

                let bcRoiList = bc?.roiList()?.object(at: Int(bc?.imageView()?.curImage ?? 0)) as? NSArray

                i = 0
                while i < (bcRoiList?.count ?? 0) {
                    var curROI = bcRoiList!.object(at: i) as! ROI

                    // [[curROI copy] autorelease]
                    curROI = curROI.copy() as! ROI

                    curROI.setOriginAndSpacing(Float(self.horos_imageView?.curDCM?.pixelSpacingX ?? 0), Float(self.horos_imageView?.curDCM?.pixelSpacingY ?? 0), DCMPix.originCorrected(accordingToOrientation: self.horos_imageView?.curDCM))
                    self.horos_imageView?.roiSet(curROI)

                    (self.horos_roiList(at: Int(self.horos_curMovieIndex))?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? NSMutableArray)?.add(curROI)
                    i += 1
                }
                x += 1
            }

            self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: curIndex))
            self.horos_imageView?.sendSyncMessage(0)
            self.adjustSlider()

            bc?.imageView()?.setIndex(Int16(truncatingIfNeeded: bcCurIndex))
            bc?.imageView()?.sendSyncMessage(0)
            bc?.adjustSlider()

            splash?.close()
            // [splash autorelease]: alive until the pool drains, as before.
            if let splash { _ = Unmanaged.passUnretained(splash).retain().autorelease() }

        default:
            NSLog("Ignoring request for unsupported blendingType: %d", blendingType)
        }
    }

    @objc(blendingSlider)
    func blendingSlider() -> NSSlider! { return self.horos_blendingSlider }

    @objc(blendingSlider:)
    func blendingSlider(_ sender: Any!) {
        self.horos_imageView?.setBlendingFactor(objcSendFloat(sender, "floatValue"))

        self.horos_blendingPercentage?.stringValue = blendingPercentageString(objcSendFloat(sender, "floatValue"))

        self.horos_seriesView?.setBlendingFactor(objcSendFloat(sender, "floatValue"))
    }

    @objc(blendingMode:)
    func blendingMode(_ sender: Any!) {
        self.horos_imageView?.blendingMode = objcSendInteger(sender, "tag")
        self.horos_seriesView?.setBlendingMode(Int32(truncatingIfNeeded: objcSendInteger(sender, "tag")))
    }

    @objc(copySettingsToOthers:)
    func copySettingsToOthers(_ sender: Any!) {
        self.propagateSettings()

        self.horos_imageView?.needsDisplay = true
    }

    @objc(blendingController)
    func blending() -> ViewerController! {
        return self.horos_blending
    }
}
