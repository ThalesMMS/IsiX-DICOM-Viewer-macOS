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

// The volumes of VRView: the series' volume the view is built on
// (-setPixSource::, its 16-bit copy and its affine map, the VTK pipeline), the
// fused series' volume (-setBlendingPixSource:), and the frames of a 4D series
// or of a fused one (-movieChangeSource:, -movieBlendingChangeSource:). A
// Swift extension of the class, with the same selectors; the buffers the view
// owns are malloc'ed and retained as before, by hand.
//
// The @try of -setPixSource:: and of -movieChangeSource:showWait: are
// HorosObjCException, with the same logs and outcome.

/// The 16-bit range a volume is spread over.
private let maxDynamicValue = 32000.0

/// A step of the pipeline's build: a C++ exception VTK threw stops the build;
/// another error is logged and the build goes on.
@MainActor private func buildFailed(_ step: () throws -> Void) -> Bool {
    do {
        try step()
        return false
    } catch {
        let error = error as NSError
        if error.code == IsiXVTKError.Code.exception.rawValue {
            NSLog("setPixSource VRView C++ exception: %@", error)
            return true
        }
        NSLog("setPixSource VRView: %@", error)
        return false
    }
}

extension VRView {

    // MARK: - The series' volume

    @objc(setPixSource::)
    dynamic func setPixSource(_ pix: NSMutableArray!, _ volumeData: UnsafeMutablePointer<Float>!) -> Int16 {
        let vtk = horos_vtk
        let error: Int16 = 0

        if window?.windowController is VRController {
            window?.acceptsMouseMovedEvents = true
        }

        // Retained by hand, as the view releases it in -dealloc.
        if let pix { _ = Unmanaged.passUnretained(pix).retain() }
        horos_pixList = pix

        projectionMode = 1

        horos_data = volumeData

        vtk.useOwnRenderer()
        let firstObject = pix.object(at: 0) as? DCMPix
        horos_firstObject = firstObject
        var sliceThickness = Float(firstObject?.sliceInterval ?? 0)

        if sliceThickness == 0 {
            NSLog("slice interval = slice thickness!")
            sliceThickness = Float(firstObject?.sliceThickness ?? 0)
        }

        horos_wl = firstObject?.wl ?? 0
        horos_ww = firstObject?.ww ?? 0

        horos_isRGB = false
        if firstObject?.isRGB ?? false {
            horos_isRGB = true
        } else {
            let pheight = Int(firstObject?.pheight ?? 0), pwidth = Int(firstObject?.pwidth ?? 0)
            // Convert float to short !!!
            let srcf = horos_srcf, dst8 = horos_dst8
            srcf.pointee.height = vImagePixelCount(pheight * pix.count)
            srcf.pointee.width = vImagePixelCount(pwidth)
            srcf.pointee.rowBytes = pwidth * MemoryLayout<Float>.size

            dst8.pointee.height = vImagePixelCount(pheight * pix.count)
            dst8.pointee.width = vImagePixelCount(pwidth)
            dst8.pointee.rowBytes = pwidth * MemoryLayout<Int16>.size

            guard let data8 = malloc(Int(dst8.pointee.height * dst8.pointee.width) * MemoryLayout<Int16>.size) else {
                horos_data8 = nil
                return -1
            }
            horos_data8 = data8.assumingMemoryBound(to: CChar.self)

            dst8.pointee.data = data8
            srcf.pointee.data = UnsafeMutableRawPointer(volumeData)

            NSLog("maxValueOfSeries = %f", Double(horos_controller?.maximumValue() ?? 0))
            NSLog("minValueOfSeries = %f", Double(horos_controller?.minimumValue() ?? 0))

            horos_firstPixel = volumeData[0 + pwidth]
            horos_secondPixel = volumeData[1 + pwidth]

            // The 4D min/max guard is applied to the 16-bit copy after conversion
            // (applyMovieRangeGuardTo16BitVolume), not to the shared float volume.
            computeValueFactor()
            BrowserController.multiThreadedImageConvert("FTo16U", srcf, dst8, -horos_OFFSET16, Float(1.0 / Double(horos_valueFactor)))
            applyMovieRangeGuardTo16BitVolume()
        }

        var built: Int16? = nil
        if HorosObjCException.caught({ built = self.buildPipeline(sliceThickness: sliceThickness) }) != nil {
            // A C++ exception of VTK comes back as an error and stops the build;
            // an Objective-C one stops it here, as the C++ catch-all did.
            NSLog("setPixSource VRView C++ exception")
            return -1
        }
        if let built { return built }

        return error
    }

    /// The body of the @try of -setPixSource::: the VTK pipeline of the volume.
    /// -1 when a step failed, nil when it is built.
    private func buildPipeline(sliceThickness: Float) -> Int16? {
        let vtk = horos_vtk
        var sliceThickness = sliceThickness
        let firstObject = horos_firstObject
        let isRGB = horos_isRGB
        let voxels = isRGB ? UnsafeMutableRawPointer(horos_data) : UnsafeMutableRawPointer(horos_data8)

        if buildFailed({ try vtk.importVolume(voxels!, rgb: isRGB, width: Int(firstObject?.pwidth ?? 0), height: Int(firstObject?.pheight ?? 0),
                                              depth: horos_pixList?.count ?? 0) }) {
            return -1
        }
        firstObject?.orientation(horos_cosines)

        horos_factor = 1.0

        horos_needToFlip = false
        if sliceThickness < 0 {
            sliceThickness = abs(sliceThickness)
            NSLog("We should not be here....")
            horos_needToFlip = true
            NSLog("Flip !!")
        }

        let pixelSpacingX = firstObject?.pixelSpacingX ?? 0, pixelSpacingY = firstObject?.pixelSpacingY ?? 0
        horos_factor = Float(Double(horos_superSampling) / pixelSpacingX)
        let factor = horos_factor

        if pixelSpacingX == 0 || pixelSpacingY == 0 {
            vtk.setImportSpacingX(1, y: 1, z: Double(sliceThickness))
        } else {
            vtk.setImportSpacingX(Double(factor) * pixelSpacingX, y: Double(factor) * pixelSpacingY, z: Double(factor * sliceThickness))
        }

        var opacityAdapter: Float = 1

        if renderingMode == 0 { // VR
            opacityAdapter = horos_superSampling
        }

        let invertedPolarity = vrDisplayUsesInvertedPolarity()

        if buildFailed({ try vtk.makeTransferFunctionsRGB(isRGB, invertedPolarity: invertedPolarity, opacityAdapter: opacityAdapter) }) {
            return -1
        }

        setCLUT(nil, nil, nil)

        setShadingValues(0.15, 0.9, 0.3, 15)

        let nearest = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false

        horos_LOD = 2.0

        if buildFailed({ try vtk.makeVolumeNearest(nearest, cosines: horos_cosines, factor: factor, originX: firstObject?.originX ?? 0,
                                                   y: firstObject?.originY ?? 0, z: firstObject?.originZ ?? 0) }) {
            return -1
        }

        if horos_controller?.style() != "noNib" {
            if buildFailed({ try vtk.makeCropBox() }) {
                return -1
            }
        }

        let wl = horos_wl, ww = horos_ww
        let text = ww < 50 ? String(format: "WL: %0.4f WW: %0.4f ", Double(wl), Double(ww))
                           : String(format: "WL: %0.f WW: %0.f ", Double(wl), Double(ww))
        let windowText = horos_WLWWString
        _ = strlcpy(windowText, text, 200)

        // A series corrected for gantry tilt says so in the lower left corner.
        let tiltViewer = horos_controller?.viewer2D()
        let tiltDegrees = GantryTiltPolicy.correctedDegrees(of: tiltViewer)
        let tiltText = tiltDegrees.map { GantryTiltPolicy.overlayText(degrees: $0.floatValue) }

        if buildFailed({ try vtk.makeTexts(withWindowText: windowText, corner: isViewportResizable(), tilt: tiltText) }) {
            return -1
        }

        if buildFailed({ try vtk.makeCamera() }) {
            return -1
        }

        if buildFailed({ try vtk.makeMeasurementActors(withNotice: NSLocalizedString("Return to the original parallel view to show stored measurements.", comment: "")) }) {
            return -1
        }

        // Not retained by the block: the view forgets the observer before it goes.
        vtk.observeRenderStart(handler: { [unowned(unsafe) self] in self.updateLineMeasurementProjections() })

        horosObserveOverlay()

        saView(self)

        needsDisplay = true

        initAnnotatedCubeActor()

        if invertedPolarity {
            changeColor(with: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1))
        }
        return nil
    }

    @objc(computeValueFactor)
    dynamic func computeValueFactor() {
        if let firstObject = horos_firstObject {
            let maximum = horos_controller?.maximumValue() ?? 0, minimum = horos_controller?.minimumValue() ?? 0
            if firstObject.suvConverted {
                horos_valueFactor = Float(maxDynamicValue / Double(maximum))
                horos_OFFSET16 = 0
            } else {
                if Double(maximum - minimum) > maxDynamicValue || maximum - minimum < 50 {
                    horos_valueFactor = Float(maxDynamicValue / Double(maximum - minimum))
                    horos_OFFSET16 = -minimum // restored: the narrow/wide-range branch must set both halves of the affine map
                } else {
                    horos_valueFactor = 1
                    horos_OFFSET16 = -minimum
                }
            }
        }
    }

    // VTK builds its lookup tables from the scalar range of the volume it is given,
    // so every time of a 4D set must expose the same 16-bit range, otherwise a time
    // whose own range is narrower is indexed against a different table and the
    // full-depth capture decodes the wrong values. The former guard patched
    // two voxels of the shared float volume, and only for the first time; this one
    // patches the private 16-bit copy after each conversion, for every time.
    @objc(applyMovieRangeGuardTo16BitVolume)
    func applyMovieRangeGuardTo16BitVolume() {
        guard !horos_isRGB, let data8 = horos_data8, let firstObject = horos_firstObject, let controller = horos_controller else {
            return
        }

        if (controller.viewer2D()?.maxMovieIndex() ?? 0) <= 1 {
            return
        }

        let width = Int(firstObject.pwidth)
        let dst8 = horos_dst8.pointee
        if width <= 0 || Int(dst8.width) * Int(dst8.height) < width + 2 {
            return
        }

        let low = (controller.minimumValue() + horos_OFFSET16) * horos_valueFactor
        let high = (controller.maximumValue() + horos_OFFSET16) * horos_valueFactor

        /// `(unsigned short)` of the value within 0...65535, as arm64 converts it.
        func clamped(_ value: Float) -> UInt16 {
            let v: Float = value < 0 ? 0 : (value > 65535 ? 65535 : value)
            return v.isNaN ? 0 : UInt16(v)
        }

        let volume16 = UnsafeMutableRawPointer(data8).assumingMemoryBound(to: UInt16.self) + width
        volume16[0] = clamped(low)
        volume16[1] = clamped(high)
    }

    // The 16-bit conversion is fixed when the first time of a 4D set is loaded; every
    // later time added through addMoviePixList: can widen the controller's range and
    // would otherwise be converted with the stale factor and saturate.
    @objc(recomputeValueFactorAfterRangeChange) @discardableResult
    func recomputeValueFactorAfterRangeChange() -> Bool {
        if horos_firstObject == nil || horos_isRGB || horos_data == nil {
            return false
        }

        let previousFactor = horos_valueFactor, previousOffset = horos_OFFSET16
        computeValueFactor()

        if previousFactor == horos_valueFactor && previousOffset == horos_OFFSET16 {
            // Same mapping, wider range: only the guard voxels change.
            applyMovieRangeGuardTo16BitVolume()
            if horos_data8 != nil {
                horos_vtk.markImportModified()
            }
            return false
        }

        movieChangeSource(horos_data, showWait: false)
        setWLWW(horos_wl, horos_ww)

        return true
    }

    // The orientation cube is drawn over the volume by HorosVROverlay;
    // VTK's marker widget drew it in OpenGL.
    @objc(initAnnotatedCubeActor)
    func initAnnotatedCubeActor() {
        horos_orientationCubeShown = true
    }

    // MARK: - The frames of a 4D series

    @objc(movieChangeSource:showWait:)
    func movieChangeSource(_ volumeData: UnsafeMutablePointer<Float>!, showWait: Bool) {
        horos_controller?.horosVolumeMetalRelease()
        let previousLOD = horos_LOD, previousLowResLODFactor = lowResLODFactor
        var www: WaitRendering? = nil

        if showWait {
            www = WaitRendering(NSLocalizedString("Preparing 3D data...", comment: ""))
            www?.start()
        }

        if let e = HorosObjCException.caught({
            self.changeSource(volumeData, previousLOD: previousLOD, previousLowResLODFactor: previousLowResLODFactor)
        }) {
            NSLog("movieChangeSource exception: %@", e)
        }

        if showWait {
            www?.end()
            www?.close()
        }
    }

    /// The body of the @try of -movieChangeSource:showWait:.
    private func changeSource(_ volumeData: UnsafeMutablePointer<Float>!, previousLOD: Float, previousLowResLODFactor: Float) {
        let vtk = horos_vtk
        horos_data = volumeData

        if horos_isRGB {
            vtk.setImportVoxels(UnsafeMutableRawPointer(volumeData))
        } else {
            horos_srcf.pointee.data = UnsafeMutableRawPointer(volumeData)
            BrowserController.multiThreadedImageConvert("FTo16U", horos_srcf, horos_dst8, -horos_OFFSET16, Float(1.0 / Double(horos_valueFactor)))
            applyMovieRangeGuardTo16BitVolume()

            vtk.setImportVoxels(UnsafeMutableRawPointer(horos_data8!))
        }
        _ = try? vtk.updateImport()
        if vtk.hasVolumeMapper {
            vtk.discardVolumeMapper()

            instantiateEngine(horos_engine == 2 ? 2 : 0)
        }

        if horos_engine == 0 || horos_engine == 2 {
            vtk.attachVolumeMapper()
        }

        if horos_engine == 2 {
            lowResLODFactor = previousLowResLODFactor
            setLOD(previousLOD)
        }

        if let blendingController = horos_blendingController {
            if horos_blendingData != blendingController.volumePtr() {
                horos_blendingData = blendingController.volumePtr()

                if horos_isBlendingRGB {
                    vtk.setBlendingImportVoxels(UnsafeMutableRawPointer(horos_blendingData!))
                } else {
                    horos_blendingSrcf.pointee.data = UnsafeMutableRawPointer(horos_blendingData)
                    BrowserController.multiThreadedImageConvert("FTo16U", horos_blendingSrcf, horos_blendingDst8, -horos_blendingOFFSET16,
                                                                Float(1.0 / Double(horos_blendingValueFactor)))

                    vtk.setBlendingImportVoxels(UnsafeMutableRawPointer(horos_blendingData8!))
                }

                vtk.updateBlendingImport()
                vtk.discardBlendingMapper()

                setBlendingEngine(Int(engine), showWait: false)
            }
        }
    }

    @objc(movieChangeSource:)
    func movieChangeSource(_ volumeData: UnsafeMutablePointer<Float>!) {
        movieChangeSource(volumeData, showWait: true)
    }

    // MARK: - The fused series

    @objc(setBlendingPixSource:)
    func setBlendingPixSource(_ bC: ViewerController!) {
        let vtk = horos_vtk
        horos_blendingController = bC

        if let bC {
            // Retained by hand, released when the fusion goes.
            let blendingPixList = bC.pixList()
            if let blendingPixList { _ = Unmanaged.passUnretained(blendingPixList).retain() }
            horos_blendingPixList = blendingPixList

            horos_blendingData = bC.volumePtr()

            let blendingFirstObject = blendingPixList?.object(at: 0) as? DCMPix
            horos_blendingFirstObject = blendingFirstObject

            var blendingSliceThickness = Float(blendingFirstObject?.sliceInterval ?? 0)

            if blendingSliceThickness == 0 {
                NSLog("Blending slice interval = slice thickness!")
                blendingSliceThickness = Float(blendingFirstObject?.sliceThickness ?? 0)
            }
            // PLAN
            blendingFirstObject?.orientation(horos_blendingcosines)

            let count = blendingPixList?.count ?? 0
            let pheight = Int(blendingFirstObject?.pheight ?? 0), pwidth = Int(blendingFirstObject?.pwidth ?? 0)

            horos_isBlendingRGB = false
            if blendingFirstObject?.isRGB ?? false {
                horos_isBlendingRGB = true
            } else {
                // Convert float to short !!!
                let srcf = horos_blendingSrcf, dst8 = horos_blendingDst8
                srcf.pointee.height = vImagePixelCount(pheight * count)
                srcf.pointee.width = vImagePixelCount(pwidth)
                srcf.pointee.rowBytes = pwidth * MemoryLayout<Float>.size

                dst8.pointee.height = vImagePixelCount(pheight * count)
                dst8.pointee.width = vImagePixelCount(pwidth)
                dst8.pointee.rowBytes = pwidth * MemoryLayout<Int16>.size

                guard let blendingData8 = malloc(Int(dst8.pointee.height * dst8.pointee.width) * MemoryLayout<Int16>.size) else {
                    horos_blendingData8 = nil
                    if let blendingPixList { Unmanaged.passUnretained(blendingPixList).release() }
                    horos_blendingController = nil
                    return
                }
                horos_blendingData8 = blendingData8.assumingMemoryBound(to: CChar.self)

                dst8.pointee.data = blendingData8
                srcf.pointee.data = UnsafeMutableRawPointer(horos_blendingData)

                let controller = horos_controller
                let maximum = controller?.blendingMaximumValue() ?? 0, minimum = controller?.blendingMinimumValue() ?? 0
                if blendingFirstObject?.suvConverted ?? false {
                    horos_blendingValueFactor = Float(maxDynamicValue / Double(maximum))
                    horos_blendingOFFSET16 = 0
                } else {
                    if Double(maximum - minimum) > maxDynamicValue || maximum - minimum < 50 {
                        horos_blendingValueFactor = Float(maxDynamicValue / Double(maximum - minimum))
                        horos_blendingOFFSET16 = -minimum
                    } else {
                        horos_blendingValueFactor = 1
                        horos_blendingOFFSET16 = -minimum
                    }
                }
                BrowserController.multiThreadedImageConvert("FTo16U", srcf, dst8, -horos_blendingOFFSET16,
                                                            Float(1.0 / Double(horos_blendingValueFactor)))
            }

            horos_blendingWl = blendingFirstObject?.wl ?? 0
            horos_blendingWw = blendingFirstObject?.ww ?? 0

            let factor = horos_factor
            let isBlendingRGB = horos_isBlendingRGB
            do {
                try vtk.fuseVoxels(isBlendingRGB ? UnsafeMutableRawPointer(horos_blendingData!) : UnsafeMutableRawPointer(horos_blendingData8!),
                                   rgb: isBlendingRGB, width: pwidth, height: pheight, depth: count,
                                   spacingX: Double(factor) * (blendingFirstObject?.pixelSpacingX ?? 0),
                                   y: Double(factor) * (blendingFirstObject?.pixelSpacingY ?? 0),
                                   z: Double(factor * blendingSliceThickness))
            } catch {
                NSLog("setBlendingPixSource: %@", error as NSError)
            }

            horos_blendingNeedToFlip = false
            if blendingSliceThickness < 0 {
                NSLog("ERROR : NEED TO FLIP....")
            }

            setBlendingFactor(horos_blendingFactor)

            vtk.makeBlendingPropertyRGB(isBlendingRGB)

            setBlendingCLUT(nil, nil, nil)

            vtk.makeBlendingVolume()

            setBlendingEngine(Int(engine))

            do {
                try vtk.finishFusion(withCosines: horos_blendingcosines, factor: factor, originX: blendingFirstObject?.originX ?? 0,
                                     y: blendingFirstObject?.originY ?? 0, z: blendingFirstObject?.originZ ?? 0)
            } catch {
                NSLog("setBlendingPixSource: %@", error as NSError)
            }
        } else {
            if vtk.hasBlendingVolume {
                vtk.releaseFusion()

                if let blendingData8 = horos_blendingData8 { free(blendingData8) }
                horos_blendingData8 = nil

                if let blendingPixList = horos_blendingPixList { Unmanaged.passUnretained(blendingPixList).release() }
                horos_blendingPixList = nil
            }
        }
    }

    @objc(movieBlendingChangeSource:)
    func movieBlendingChangeSource(_ index: Int) {
        if let blendingController = horos_blendingController {
            if let old = horos_blendingPixList { Unmanaged.passUnretained(old).release() }
            let blendingPixList = blendingController.pixList(index)
            if let blendingPixList { _ = Unmanaged.passUnretained(blendingPixList).retain() }
            horos_blendingPixList = blendingPixList

            horos_blendingData = blendingController.volumePtr(index)

            // Force min/max recomputing
            horos_vtk.replaceBlendingVoxels(UnsafeMutableRawPointer(horos_blendingData!), minimumImageSampleDistance: horos_LOD)

            needsDisplay = true
        }
    }
}
