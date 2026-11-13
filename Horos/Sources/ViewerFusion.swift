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
import IsiXImaging
import IsiXPreferences

// The fusion of a 2D viewer with another, which the "blending" block of the
// former viewer did: the PET-CT fusion of the Fusion command, the fusion
// itself (-ActivateBlending:), the sheet a viewer dropped on another opens
// and what it chooses (fusion, subtraction, multiplication, division, RGB
// composition, registration, resampling, ROI copy, a fusion plug-in), the
// Fusion slider and mode, and the "Re-sync origin" of a fused series. The
// blend of the view itself is IsiXImaging's FusionBlend, which DCMView keeps;
// the origin arithmetic is FusionOriginAlignment. ViewerController keeps the
// former selectors, which come here.
//
// blendingController is assigned without retain, as before (the assign store
// of the accessor); blendedWindow is released and cleared through the retain
// setter. A message to nil answered nil, 0 or NO: the optional chains below
// answer the same. An @try is HorosObjCException.caught, and the
// code of its @finally runs after it. Messages the former code sent to an
// `id` sender (tag, selectedSegment, floatValue) are sent as Objective-C sent
// them (objcSend…). The C conversions from float to long saturate and take NaN
// to 0, as on arm64 (cLong).

/// `static int noActivateBlendingReentry` of -ActivateBlending:, shared by
/// all viewers.
@MainActor fileprivate var noActivateBlendingReentry: Int32 = 0

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
/// not offer: `views` is a series view's list of image views.
@MainActor fileprivate func makeViewsDisplay(_ views: Any?) {
    for case let view as NSView in views as? [Any] ?? [] {
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

/// The fusion of one 2D viewer, made for one call.
@MainActor final class ViewerFusion {
    /// Held strongly for the length of a call: forming an unowned or weak
    /// reference to an object being deallocated traps, and the viewer's
    /// teardown ends its fusion through here.
    let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let registry: ViewerRegistry
    private let sync: ViewerSyncState

    init(viewer: ViewerController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.viewer = viewer
        self.preferences = preferences
        registry = processGraph.viewerRegistry
        sync = processGraph.viewerSync
    }

    /// The tag of the sheet's Division button, the blending type it ends the
    /// sheet with: the types up to 12 were taken before it.
    static let divisionBlendingType: Int32 = 13

    /// The name of the fusion plug-in of the sheet's menu item `index`.
    private func fusionPlugin(at index: Int) -> String? {
        PluginManager.fusionPlugins()?.object(at: index) as? String
    }

    // MARK: - Fusion

    func blendWindows(_ sender: Any!) {
        let viewersCT = registry.displayedViewers
        let viewersPET = registry.displayedViewers
        var fused = false

        if sender != nil && viewer.horos_blending != nil {
            activateBlending(nil)
            return
        }

        if sender != nil {
            // The secondary viewer does not own the link. Find its existing owner
            // before trying to create a new pair or reporting incompatibility.
            for owner in viewersCT {
                if owner.blending() === viewer {
                    owner.fusion.activateBlending(nil)
                    return
                }
            }
        }

        for vCT in viewersCT {
            if objcIsEqualToString(vCT.modality(), "CT") {
                for vPET in viewersPET {
                    if sender != nil && vCT !== viewer && vPET !== viewer { continue }
                    if vPET !== vCT {
                        if (objcIsEqualToString(vPET.modality(), "PT") || objcIsEqualToString(vPET.modality(), "NM")) && objcIsEqualToString(vPET.studyInstanceUID(), vCT.studyInstanceUID()) {
                            let a = vCT

                            if a.blending() == nil {
                                let b = vPET

                                var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)

                                a.imageView()?.curDCM?.orientation(&orientA)
                                b.imageView()?.curDCM?.orientation(&orientB)

                                if normalsAngle(&orientA, &orientB) < preferences[ViewerPreferences.parallelPlaneTolerance] {
                                    if a.isGantryTitled() == false && b.isGantryTitled() == false {
                                        a.imageView()?.sendSyncMessage(0)
                                        a.fusion.activateBlending(b)

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

    func activateBlending(_ bC: ViewerController!) {
        if noActivateBlendingReentry > 0 {
            return
        }

        noActivateBlendingReentry += 1

        activateBlendingInside(bC)

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
        if let e = HorosObjCException.caught({
            if bC === viewer { return }
            if viewer.horos_blending === bC { return }

            if let bC {
                if let reason = viewer.fourDFusionRefusalReason(forOverlay: bC) {
                    _ = HorosAlertPanel.run(title: NSLocalizedString("PET-CT Fusion", comment: ""), message: reason,
                                            defaultButton: nil, alternateButton: nil, otherButton: nil)
                    return
                }
            }

            if viewer.horos_blending != nil && bC != nil {
                activateBlendingInside(nil)
            }

            viewer.horos_imageView?.sendSyncMessage(0)

            // blendingController = bC; (not retained)
            viewer.horos_assignBlendingController(bC)

            if viewer.horos_blending != nil {
                NSLog("Blending Activated!")

                if viewer.horos_blending?.blending() === viewer {	// NO cross blending !
                    viewer.horos_blending?.fusion.activateBlendingInside(nil)
                }

                if objcIsEqualToString(viewer.studyInstanceUID(), viewer.horos_blending?.studyInstanceUID()) {
                    // By default, re-activate 'propagate settings'

                    TemporaryPreferenceHolds.standard.choose(true, for: ViewerPreferences.copySettings)
                }

                var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)

                var proceed = false

                viewer.imageView()?.curDCM?.orientation(&orientA)
                viewer.horos_blending?.imageView()?.curDCM?.orientation(&orientB)

                if orientB[6] == 0 && orientB[7] == 0 && orientB[8] == 0 { proceed = true }
                if orientA[6] == 0 && orientA[7] == 0 && orientA[8] == 0 { proceed = true }

                if normalsAngle(&orientA, &orientB) > preferences[ViewerPreferences.parallelPlaneTolerance] {  // Planes are not paralel!
                    // FROM SAME STUDY

                    if objcIsEqualToString(viewer.studyInstanceUID(), viewer.horos_blending?.studyInstanceUID()) {
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
                            viewer.horos_assignBlendingController(viewer.resampleSeries(viewer.horos_blending, rescale: false))
                            if viewer.horos_blending != nil { proceed = true }

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
                    viewer.displayWarningIfGantryTitled()
                    viewer.horos_blending?.displayWarningIfGantryTitled()

                    proceed = true
                }

                if proceed {
                    viewer.horos_imageView?.blending = viewer.horos_blending?.imageView()
                    viewer.horos_blendingSlider?.isEnabled = true
                    viewer.horos_blendingPercentage?.isEnabled = true
                    viewer.horos_blendingPercentage?.stringValue = blendingPercentageString(viewer.horos_blendingSlider?.floatValue ?? 0)

                    if objcIsEqualToString(viewer.horos_blending?.curCLUTMenu(), NSLocalizedString("No CLUT", comment: "")) && ((viewer.horos_blending?.pixList()?.object(at: 0) as? DCMPix)?.isRGB ?? false) == false {
                        if objcIsEqualToString(viewer.modality(), "PT") || (preferences[ViewerPreferences.petCLUTForNM] == true && objcIsEqualToString(viewer.modality(), "NM")) {
                            if objcIsEqualToString(preferences[ViewerPreferences.petCLUTMode], "B/W Inverse") {
                                viewer.applyCLUTString("B/W Inverse")
                            } else {
                                viewer.applyCLUTString(preferences[ViewerPreferences.petDefaultCLUT])
                            }
                        }
                    }

                    viewer.horos_imageView?.setBlendingFactor(viewer.horos_blendingSlider?.floatValue ?? 0)

                    viewer.horos_blendingPopupMenu?.selectItem(withTag: preferences[ViewerPreferences.defaultPETFusion])
                    viewer.horos_imageView?.blendingMode = preferences[ViewerPreferences.defaultPETFusion]
                    viewer.horos_seriesView?.setBlendingMode(Int32(truncatingIfNeeded: preferences[ViewerPreferences.defaultPETFusion]))

                    viewer.horos_seriesView?.activateBlending(viewer.horos_blending, blendingFactor: viewer.horos_blendingSlider?.floatValue ?? 0)
                }

                // [backCurCLUTMenu release]; backCurCLUTMenu = 0L;
                viewer.horos_backCurCLUTMenu = nil

                if viewer.horos_blending != nil && objcIsEqualToString(preferences[ViewerPreferences.petCLUTMode], "B/W Inverse") {
                    // backCurCLUTMenu = [curCLUTMenu copy];
                    viewer.horos_backCurCLUTMenu = viewer.horos_curCLUTMenu
                    // [curCLUTMenu release]; curCLUTMenu = [[… stringForKey: @"PET Blending CLUT"] copy];
                    viewer.horos_curCLUTMenu = preferences[ViewerPreferences.petBlendingCLUT]
                }
            } else {
                // [backCurCLUTMenu release]; backCurCLUTMenu = 0L;
                viewer.horos_backCurCLUTMenu = nil

                // [curCLUTMenu release]; curCLUTMenu = [NSLocalizedString(@"No CLUT", nil) retain];
                viewer.horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")

                viewer.horos_imageView?.blending = nil
                viewer.horos_blendingSlider?.isEnabled = false
                // The Fusion item keeps showing the percentage the slider holds,
                // dimmed like the slider, instead of a bare "-".
                viewer.horos_blendingPercentage?.isEnabled = false
                viewer.horos_blendingPercentage?.stringValue = blendingPercentageString(viewer.horos_blendingSlider?.floatValue ?? 0)
                viewer.horos_seriesView?.activateBlending(nil, blendingFactor: viewer.horos_blendingSlider?.floatValue ?? 0)
                viewer.horos_imageView?.display()
            }

            viewer.buildMatrixPreview(false)

            viewer.horos_imageView?.sendSyncMessage(0)

            viewer.applyCLUTString(viewer.horos_curCLUTMenu)
            viewer.refreshMenus()
        }) {
            _N2LogExceptionImpl(e, false, "-[ViewerController ActivateBlending:]")
        }
    }

    func endBlendingType(_ sender: Any!) {
        var blendingType = Int32(truncatingIfNeeded: objcSendInteger(sender, "tag"))

        if (sender as? NSObject)?.isKind(of: NSSegmentedControl.self) ?? false {	//Add RGB
            blendingType = Int32(truncatingIfNeeded: Int(blendingType) &+ objcSendInteger(sender, "selectedSegment"))
        }

        viewer.horos_blendingTypeWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: Int(blendingType)))
    }

    func blendingSheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        var returnCode = returnCode
        if returnCode < 0 {
            returnCode = 0 &- returnCode &- 1
            viewer.clear8bitRepresentations()

            if objcIsEqualToString(fusionPlugin(at: Int(returnCode)), "Subtraction Angio-CT") {
                blend(withViewer: viewer.horos_blendedWindow, blendingType: 9) // LL filter
            } else {
                viewer.executeFilter(from: fusionPlugin(at: Int(returnCode)))
            }
        } else if returnCode > 0 {
            viewer.clear8bitRepresentations()
            blend(withViewer: viewer.horos_blendedWindow, blendingType: returnCode)
        }

        // [blendedWindow release]; blendedWindow = nil;
        viewer.horos_blendedWindow = nil
    }

    /// The viewer whose images subtraction, multiplication and division
    /// combine with this one's, pixel by pixel, which needs one matrix. A
    /// series of the same study with another matrix is first resampled onto
    /// this viewer's grid, as the panel's Resample does: it then has this
    /// viewer's images, in their order, and each pairs with the image of its
    /// own index. Nil when the resampling could not be done, which it has
    /// already explained.
    private func horos_arithmeticOperand(_ bc: ViewerController?) -> (ViewerController?, Bool)? {
        guard let own = viewer.horos_imageView?.curDCM, let other = bc?.imageView()?.curDCM,
              own.pwidth != other.pwidth || own.pheight != other.pheight else { return (bc, false) }
        guard let resampled = viewer.resampleSeries(bc, rescale: true) else { return nil }
        return (resampled, true)
    }

    func blend(withViewer bc: ViewerController!, blendingType: Int32) {
        // _blendingType = blendingType;
        viewer.horos_blendingType = blendingType

        var i = 0
        switch blendingType {
        case -1:	// PLUG-INS METHOD
            //[self executeFilter:sender];
            break

        case 1:		// Image fusion
            activateBlending(bc)

        case 2:
            // Image subtraction
            let modifierFlags: UInt = NSApplication.shared.currentEvent?.modifierFlags.rawValue ?? 0
            guard let arithmetic = horos_arithmeticOperand(bc) else { break }
            let (operand, pairedByIndex) = arithmetic

            if (modifierFlags & NSEvent.ModifierFlags.control.rawValue) != 0 || pairedByIndex {
                let count = min(viewer.pixList()?.count ?? 0, operand?.pixList()?.count ?? 0)
                i = 0
                while i < count {
                    viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: i))
                    viewer.horos_imageView?.sendSyncMessage(0)
                    makeViewsDisplay(viewer.horos_seriesView?.imageViews())

                    operand?.imageView()?.setIndex(Int(truncatingIfNeeded: i))
                    // A resampled series is already on this grid; its sync
                    // could only move this viewer off the image being paired.
                    if !pairedByIndex {
                        operand?.imageView()?.sendSyncMessage(0)
                    }
                    makeViewsDisplay(operand?.seriesView()?.imageViews())

                    viewer.horos_imageView?.subtract(operand?.imageView(), absolute: (modifierFlags & NSEvent.ModifierFlags.option.rawValue) != 0)
                    i += 1
                }
            } else {
                i = 0
                while i < (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) {
                    viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: i))
                    viewer.horos_imageView?.sendSyncMessage(0)
                    makeViewsDisplay(viewer.horos_seriesView?.imageViews())

                    viewer.horos_imageView?.subtract(operand?.imageView(), absolute: (modifierFlags & NSEvent.ModifierFlags.option.rawValue) != 0)
                    i += 1
                }
            }

        case 3:		// Image multiplication
            horos_combineImages(bc) { view, operand in view?.multiply(operand) }

        case ViewerFusion.divisionBlendingType:		// Image division, the ratio map
            let divided = horos_combineImages(bc) { view, operand in
                guard let view else { return }
                view.curDCM?.divide(by: operand?.curDCM)
                view.reapplyWindowLevel()
                view.loadTextures()
                view.needsDisplay = true
            }
            // A ratio has none of the values the window of either series was
            // set for: the full range of the ratio shows it.
            if divided { viewer.horos_imageView?.setWLWW(0, 0) }

        case 4,		// RGB Composition
             5,
             6:
            i = 0
            while i < (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) {   // Convert all images to RGB images if necessary
                var cwl: Float = 0, cww: Float = 0

                viewer.horos_imageView?.getWLWW(&cwl, &cww)

                if ((viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.object(at: i) as? DCMPix)?.isRGB ?? false) == false {
                    (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.object(at: i) as? DCMPix)?.convert(toRGB: 0, cLong(cwl), cLong(cww))
                }

                let dstPix = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.object(at: i) as? DCMPix
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

                viewer.horos_imageView?.getWLWW(&cwl, &cww)
                dstPix?.changeWLWW(cwl, cww)
                viewer.horos_imageView?.loadTextures()
                viewer.horos_imageView?.needsDisplay = true
                i += 1
            }

        case 7:		// 2D Registration
            viewer.computeRegistration(withMovingViewer: bc)

        case 11:
            _ = viewer.resampleSeries(bc, rescale: true)

        case 12:
            _ = viewer.resampleSeries(bc, rescale: false)

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
            //				llScoutViewer = [[LLScoutViewer alloc] initWithPixList: pixList[0] :fileList[0] :volumeData[0] :viewer :bc];
            //				[llScoutViewer showWindow:viewer];
            //			}
            //		}
            //		break;
            //		#endif

        case 10:	// Copy ROIs
            // Two series that can be related in the patient (the same frame of reference, or a
            // registration) are copied by position: each ROI goes to the image where it lies, and a
            // brush is resampled onto this series' pixels and slices (GuidedROICopy). Series that
            // cannot be related are paired image by image, below, as they always were.
            if let plan = viewer.registration.guidedCopyPlan(from: bc, offsetMM: nil).plan {
                let added = viewer.horosApplyGuidedCopyPlan(plan, from: bc)
                if added == 0 || !plan.refused.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Copy ROIs between series...", comment: "")
                    alert.informativeText = plan.placements.isEmpty ? NSLocalizedString("No ROIs in this series!", comment: "") : plan.summary
                    alert.runModal()
                }
                break
            }

            let splash = WaitRendering(NSLocalizedString("Copy ROIs between series...", comment: ""))
            splash?.showWindow(viewer)

            let curIndex = Int32(viewer.horos_imageView?.curImage ?? 0)
            let bcCurIndex = Int32(bc?.imageView()?.curImage ?? 0)

            let count = Swift.min(viewer.pixList()?.count ?? 0, bc?.pixList()?.count ?? 0)
            var x: Int32 = 0
            while Int(x) < count {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: x))
                viewer.horos_imageView?.sendSyncMessage(0)
                viewer.adjustSlider()

                bc?.imageView()?.setIndex(Int(truncatingIfNeeded: x))
                bc?.imageView()?.sendSyncMessage(0)
                bc?.adjustSlider()

                let bcRoiList = bc?.roiList()?.object(at: Int(bc?.imageView()?.curImage ?? 0)) as? [ROI] ?? []

                i = 0
                while i < bcRoiList.count {
                    // [[curROI copy] autorelease]
                    guard let curROI = bcRoiList[i].copy() as? ROI else { i += 1; continue }

                    curROI.setOriginAndSpacing(Float(viewer.horos_imageView?.curDCM?.pixelSpacingX ?? 0), Float(viewer.horos_imageView?.curDCM?.pixelSpacingY ?? 0), DCMPix.originCorrected(accordingToOrientation: viewer.horos_imageView?.curDCM))
                    viewer.horos_imageView?.roiSet(curROI)

                    (viewer.horos_roiList(at: Int(viewer.horos_curMovieIndex))?.object(at: Int(viewer.horos_imageView?.curImage ?? 0)) as? NSMutableArray)?.add(curROI)
                    i += 1
                }
                x += 1
            }

            viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: curIndex))
            viewer.horos_imageView?.sendSyncMessage(0)
            viewer.adjustSlider()

            bc?.imageView()?.setIndex(Int(truncatingIfNeeded: bcCurIndex))
            bc?.imageView()?.sendSyncMessage(0)
            bc?.adjustSlider()

            splash?.close()
            // [splash autorelease]: alive until the pool drains, as before.
            if let splash { _ = Unmanaged.passUnretained(splash).retain().autorelease() }

        default:
            NSLog("Ignoring request for unsupported blendingType: %d", blendingType)
        }
    }

    /// Combines each image of this viewer with the operand's image under it,
    /// in place, as multiplication and division do: `combine` gets this
    /// viewer's view and the operand's, each on the image being combined.
    /// False when the operand could not be resampled onto this grid.
    @discardableResult
    private func horos_combineImages(_ bc: ViewerController?, _ combine: (DCMView?, DCMView?) -> Void) -> Bool {
        guard let arithmetic = horos_arithmeticOperand(bc) else { return false }
        let (operand, pairedByIndex) = arithmetic
        var i = 0
        while i < (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) {
            viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: i))
            viewer.horos_imageView?.sendSyncMessage(0)
            makeViewsDisplay(viewer.horos_seriesView?.imageViews())

            if pairedByIndex {
                guard i < (operand?.pixList()?.count ?? 0) else { break }
                operand?.imageView()?.setIndex(Int(truncatingIfNeeded: i))
                makeViewsDisplay(operand?.seriesView()?.imageViews())
            }

            combine(viewer.horos_imageView, operand?.imageView())
            i += 1
        }
        return true
    }

    func blendingSlider(_ sender: Any!) {
        viewer.horos_imageView?.setBlendingFactor(objcSendFloat(sender, "floatValue"))

        viewer.horos_blendingPercentage?.stringValue = blendingPercentageString(objcSendFloat(sender, "floatValue"))

        viewer.horos_seriesView?.setBlendingFactor(objcSendFloat(sender, "floatValue"))
    }

    func blendingMode(_ sender: Any!) {
        viewer.horos_imageView?.blendingMode = objcSendInteger(sender, "tag")
        viewer.horos_seriesView?.setBlendingMode(Int32(truncatingIfNeeded: objcSendInteger(sender, "tag")))
    }

    // MARK: - A viewer dropped on this one

    /// Opens the sheet that asks what to do with `vc`, dropped on this viewer:
    /// fuse, subtract, multiply, divide, compose, register, resample, copy ROIs, or
    /// run a fusion plug-in. What does not apply to the two series is greyed.
    func completeDragOperation(_ vc: ViewerController!) {
        viewer.horosLoadViewerPanels()

        // First reset all controls.
        for view in viewer.horos_blendingTypeWindow?.contentView?.subviews ?? [] {
            if let control = view as? NSControl {
                control.isEnabled = true
            }
        }

        let sameStudy = viewerSameString(viewer.studyInstanceUID(), vc?.studyInstanceUID())

        // Subtraction, multiplication and division combine images of one
        // matrix. Within a study they resample a series of another matrix onto
        // this one's first. The Division button has no outlet of its own: it is
        // found by its tag.
        if (vc?.imageView()?.curDCM?.pwidth ?? 0) != (viewer.horos_imageView?.curDCM?.pwidth ?? 0) ||
           (vc?.imageView()?.curDCM?.pheight ?? 0) != (viewer.horos_imageView?.curDCM?.pheight ?? 0) {
            if sameStudy == false {
                viewer.blendingTypeMultiply?.isEnabled = false
                viewer.blendingTypeSubtract?.isEnabled = false
                (viewer.horos_blendingTypeWindow?.contentView?.viewWithTag(Int(ViewerFusion.divisionBlendingType)) as? NSControl)?.isEnabled = false
            }
            viewer.blendingTypeRGB?.isEnabled = false
        }

        if (vc?.pixList()?.object(at: 0) as? DCMPix)?.isRGB == true {
            viewer.blendingTypeRGB?.isEnabled = false
        }

        if sameStudy == false {
            viewer.blendingResample?.isEnabled = false
        }

        // Prepare the menu of the fusion plug-ins.
        let fusionPlugins = PluginManager.fusionPluginsMenu()
        var iz = 0
        while iz < (fusionPlugins?.numberOfItems ?? 0) {
            let item = fusionPlugins?.item(at: iz)
            item?.tag = -iz

            if item?.hasSubmenu == true {
                let subMenu = item?.submenu

                var xz = 0
                while xz < (subMenu?.numberOfItems ?? 0) {
                    subMenu?.item(at: xz)?.tag = -iz
                    subMenu?.item(at: xz)?.target = viewer
                    subMenu?.item(at: xz)?.action = #selector(ViewerController.endBlendingType(_:))
                    xz += 1
                }
            } else {
                item?.target = viewer
                item?.action = #selector(ViewerController.endBlendingType(_:))
            }
            iz += 1
        }
        viewer.blendingPlugins?.menu = fusionPlugins

        viewer.horos_blendedWindow = vc

        // What type of blending?
        if let sheet = viewer.horos_blendingTypeWindow {
            let viewer = viewer
            viewer.window?.beginSheet(sheet) { returnCode in
                viewer.blendingSheetDidEnd(viewer.horos_blendingTypeWindow, returnCode: Int32(truncatingIfNeeded: returnCode.rawValue), contextInfo: nil)
            }
        }

        sync.draggedViewer = nil
    }

    // MARK: - Re-sync origin

    /// "Re-sync origin" of a fusion whose settings are not propagated: every
    /// slice gets the spacing and origin that put it where the fused series is
    /// shown, then the views are synchronized by location.
    func reSyncOrigin() {
        guard let blending = viewer.horos_blending else {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                message: NSLocalizedString("Only useful if image fusion is activated.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        guard let imageView = viewer.horos_imageView,
              !preferences[ViewerPreferences.copySettings] || imageView.syncro() != Int16(syncroLOC) else {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                message: NSLocalizedString("Only useful if propagate settings is OFF.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        let fusedView = blending.imageView()
        let fusedSlice = fusedView?.curDCM
        let zShift = Float((fusedSlice?.sliceLocation ?? 0) - (imageView.curDCM?.sliceLocation ?? 0))

        for movie in 0..<viewer.horos_movieCount {
            for pic in viewer.horos_pixArray(movie) {
                var vectors = [Float](repeating: 0, count: 9)
                pic.orientation(&vectors)

                // The viewer's current image is one of these slices: its
                // spacing is read again for each, as it changes on the way.
                let current = imageView.curDCM
                pic.pixelSpacingX = FusionOriginAlignment.pixelSpacing(current: current?.pixelSpacingX ?? 0, fusedView: fusedView?.pixelSpacingX ?? 0,
                                                                       fusedScale: fusedView?.scaleValue ?? 0, scale: imageView.scaleValue)
                pic.pixelSpacingY = FusionOriginAlignment.pixelSpacing(current: imageView.curDCM?.pixelSpacingY ?? 0, fusedView: fusedView?.pixelSpacingY ?? 0,
                                                                       fusedScale: fusedView?.scaleValue ?? 0, scale: imageView.scaleValue)

                let fused = FusionOriginAlignment.View(
                    origin: (fusedSlice?.originX ?? 0, fusedSlice?.originY ?? 0, fusedSlice?.originZ ?? 0),
                    width: Int(fusedSlice?.pwidth ?? 0), height: Int(fusedSlice?.pheight ?? 0),
                    pixelSpacingX: fusedSlice?.pixelSpacingX ?? 0, pixelSpacingY: fusedSlice?.pixelSpacingY ?? 0,
                    viewOrigin: fusedView?.origin ?? .zero, scale: fusedView?.scaleValue ?? 0,
                    viewPixelSpacingX: fusedView?.pixelSpacingX ?? 0, viewPixelSpacingY: fusedView?.pixelSpacingY ?? 0)
                let own = FusionOriginAlignment.View(
                    origin: (pic.originX, pic.originY, pic.originZ), width: Int(pic.pwidth), height: Int(pic.pheight),
                    pixelSpacingX: pic.pixelSpacingX, pixelSpacingY: pic.pixelSpacingY,
                    viewOrigin: imageView.origin, scale: imageView.scaleValue,
                    viewPixelSpacingX: imageView.pixelSpacingX, viewPixelSpacingY: imageView.pixelSpacingY)
                let o = FusionOriginAlignment.origin((pic.originX, pic.originY, pic.originZ), vectors: vectors,
                                                     width: Int(pic.pwidth), height: Int(pic.pheight),
                                                     spacingX: pic.pixelSpacingX, spacingY: pic.pixelSpacingY,
                                                     fused: fused, view: own, zShift: zShift)
                var origin = [o.0, o.1, o.2]
                pic.setOrigin(&origin)
                pic.computeSliceLocation()
            }
        }

        TemporaryPreferenceHolds.standard.choose(true, for: ViewerPreferences.copySettings)
        imageView.setSyncro(Int16(syncroLOC))
        imageView.sendSyncMessage(0)
        viewer.settingsPropagator.propagateSettings()
    }
}
