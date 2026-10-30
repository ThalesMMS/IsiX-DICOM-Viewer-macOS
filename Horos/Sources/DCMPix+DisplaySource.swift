/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXImaging
import ObjectiveC

/// What the 8-bit picture is made from: the image, or its thick slab with the
/// neighbours (mean, maximum, minimum, or the volume rendering of a
/// ThickSlabController), the MPR's display plane in place of the image, and the
/// presentation convolution; and the value read at a pixel through the slab.
/// The reductions are IsiXImaging's (ThickSlabReduction, ImageConvolution).
extension DCMPix {
    /// The key of the MPR's display plane, kept beside the image.
    nonisolated(unsafe) private static var mprDisplayPixelsKey: UInt8 = 0

    // MARK: - What is drawn

    /// The same pixels without the presentation convolution: what a measurement
    /// reads. A thick slab is the image the ROI was drawn on, so a measurement
    /// follows it; a convolution filter is presentation, so a measurement must
    /// not read through it.
    @objc(computefImageForMeasurement)
    public dynamic func computefImageForMeasurement() -> UnsafeMutablePointer<Float>! {
        horos_thickSlabVRActivated = false
        // = STACK IMAGES thickslab
        if stackMode > 0 && horos_stack >= 1 && (horos_pixArray?.count ?? 0) > 1 {
            return computeThickSlab()
        }
        return horos_fImage
    }

    /// The pixels shown: the slab, through the convolution.
    @objc(computefImage)
    public dynamic func computefImage() -> UnsafeMutablePointer<Float>! {
        var result = computefImageForMeasurement()
        if horos_convolution { result = applyConvolution(onImage: result, rgb: false) }
        return result
    }

    /// The MPR's cubic display plane: `pwidth * pheight` floats, or nil. Only drawn.
    @objc public var horosMPRDisplayPixels: NSData? {
        get { objc_getAssociatedObject(self, &DCMPix.mprDisplayPixelsKey) as? NSData }
        set {
            objc_setAssociatedObject(self, &DCMPix.mprDisplayPixelsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            needToCompute8bitRepresentation = true
            horos_updateToBeApplied = true
        }
    }

    /// What is drawn: computefImage, with the MPR's display plane in place of
    /// the image when this one has it. The plane is handed over as a copy:
    /// callers and the convolution free any buffer that is not fImage.
    @objc(computefImageForDisplay)
    public dynamic func computefImageForDisplay() -> UnsafeMutablePointer<Float>! {
        var result = computefImageForMeasurement()
        // The MPR's cubic plane stands in for fImage only: a stack slab is its own reduction.
        if result == horos_fImage, let display = horosMPRDisplayPixels,
           display.length == horos_width * horos_height * MemoryLayout<Float>.size,
           let copy = malloc(display.length) {
            memcpy(copy, display.bytes, display.length)
            result = copy.assumingMemoryBound(to: Float.self)
        }
        if horos_convolution { result = applyConvolution(onImage: result, rgb: false) }
        return result
    }

    // MARK: - Thick slab

    /// Whether the slab is the volume rendering of the ThickSlabController.
    @objc(thickSlabVRActivated)
    public dynamic func thickSlabVRActivated() -> Bool { horos_thickSlabVRActivated }

    @objc(setThickSlabController:)
    public dynamic func setThickSlabController(_ ts: ThickSlabController!) { horos_thickSlab = ts }

    /// Whether the picture is drawn through a fixed 8-bit window (127/256).
    @objc(setFixed8bitsWLWW:)
    public dynamic func setFixed8bitsWLWW(_ f: Bool) { horos_fixed8bitsWLWW = f }

    // What the planar renderer asks of the presentation (DCMView+PlanarSnapshot.swift).

    /// Whether a convolution filters the picture.
    @objc(horosPlanarHasPresentationFilter)
    public dynamic func horosPlanarHasPresentationFilter() -> Bool { horos_convolution }

    /// Whether the picture is drawn through the fixed 8-bit window.
    @objc(horosPlanarUsesFixedWindow)
    public dynamic func horosPlanarUsesFixedWindow() -> Bool { horos_fixed8bitsWLWW }

    /// The controller of a volume-rendered slab, or nil.
    @objc(horosPlanarThickSlab)
    public dynamic func horosPlanarThickSlab() -> ThickSlabController? { horos_thickSlab }

    /// The images of the slab after this one, or before it (`stackDirection`),
    /// that have pixels, up to `stack` images in all.
    private func slabNeighbours(stack: Int) -> [UnsafePointer<Float>] {
        let list = horos_pixArray ?? []
        var neighbours: [UnsafePointer<Float>] = []
        var i = 1
        while i < stack {
            let next = stackDirection != 0 ? Int(pixPos) - i : Int(pixPos) + i
            if next >= 0 && next < list.count, let pix = list[next] as? DCMPix, let pixels = pix.fImage {
                neighbours.append(UnsafePointer(pixels))
            }
            i += 1
        }
        return neighbours
    }

    /// The thick slab of a grey image: a new buffer with the mean, maximum or
    /// minimum of the slab; for the volume rendering modes the
    /// ThickSlabController's picture becomes the 8-bit one and nil is returned.
    @objc(computeThickSlab)
    public dynamic func computeThickSlab() -> UnsafeMutablePointer<Float>! {
        let fixed = horos_fixed8bitsWLWW
        let iww: Float = fixed ? 256 : horos_ww
        let iwl: Float = fixed ? 127 : horos_wl
        let width = horos_width, height = horos_height
        let stack = Int(horos_stack), position = Int(pixPos)

        switch stackMode {
        case 4, 5:    // Volume Rendering
            guard horos_thickSlab != nil else { return nil }
            let count = horos_pixArray?.count ?? 0
            let stackSize: Int
            if stackDirection != 0 {
                stackSize = position - stack < 0 ? position + 1 : stack + 1
            } else {
                stackSize = position + stack < count ? stack : count - position
            }
            // Backwards, the slab starts at the first of its images, before this one.
            let source = stackDirection != 0 ? horos_fImage.map { $0 - (stackSize - 1) * height * width } : horos_fImage
            let rgba = HorosDCMPixRenderThickSlab(horos_thickSlab, source, stackSize, iwl, displayInverted ? -iww : iww)
            horos_thickSlabVRActivated = true
            baseAddr = rgba.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self) }
            return nil

        case 1, 2, 3:    // Mean, Maximum IP, Minimum IP
            countstackMean = 1
            let count = height * width
            guard let result = malloc(count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { return nil }
            if let pixels = horos_fImage { memcpy(result, pixels, count * MemoryLayout<Float>.size) }
            let neighbours = slabNeighbours(stack: stack)
            ThickSlabReduction.fold(into: result, count: count, slices: neighbours, mode: Int(stackMode),
                                    workers: Int(DCMPix.maxProcessors()))
            if stackMode == Int16(ThickSlabReduction.mean) { countstackMean = Float(1 + neighbours.count) }
            ThickSlabReduction.divide(result, count: count, by: countstackMean)
            return result

        default:
            return nil
        }
    }

    /// The thick slab of a colour image: a new buffer, each byte the maximum or
    /// minimum of the slab's; the image itself for the other modes.
    @objc(computeThickSlabRGB)
    public dynamic func computeThickSlabRGB() -> UnsafeMutablePointer<Float>! {
        let count = horos_height * horos_width
        guard let result = malloc(count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { return nil }
        guard let pixels = horos_fImage else { return result }
        if stackMode == Int16(ThickSlabReduction.maximum) || stackMode == Int16(ThickSlabReduction.minimum) {
            // Every channel byte of the slab is reduced into the result. The first
            // slice that has pixels is compared with the current one; each later
            // slice is compared with what has been reduced so far.
            let list = horos_pixArray ?? []
            var reduced = UnsafeMutableRawPointer(pixels)
            var i = 1
            while i < Int(horos_stack) {
                let next = stackDirection != 0 ? Int(pixPos) - i : Int(pixPos) + i
                if next < 0 || next >= list.count { break }
                if let pix = list[next] as? DCMPix, let slice = pix.fImage {
                    ThickSlabReduction.foldBytes(reduced, UnsafeRawPointer(slice), into: UnsafeMutableRawPointer(result), pixels: count,
                                                 keepLarger: stackMode == Int16(ThickSlabReduction.maximum))
                    reduced = UnsafeMutableRawPointer(result)
                }
                i += 1
            }
            // No other slice had pixels: the slab is the current slice.
            if reduced != UnsafeMutableRawPointer(result) { memcpy(result, pixels, count * MemoryLayout<Float>.size) }
        } else {
            memcpy(result, pixels, count * MemoryLayout<Float>.size)
        }
        return result
    }

    /// The value at a pixel, through the slab (the mean of a colour pixel's
    /// red, green and blue); 0 outside the image.
    @objc(getPixelValueX:Y:)
    public dynamic func getPixelValueX(_ x: Int, y: Int) -> Float {
        let width = horos_width
        if x < 0 || x >= width || y < 0 || y >= horos_height { return 0 }
        guard let pixels = horos_fImage else { return 0 }
        let slab = (stackMode == 1 || stackMode == 2 || stackMode == 3) && horos_stack >= 1
        return ThickSlabReduction.value(at: x + y * width, current: pixels,
                                        neighbours: slab ? slabNeighbours(stack: Int(horos_stack)) : nil,
                                        mode: Int(stackMode), isRGB: horos_isRGB)
    }

    // MARK: - Convolution

    @objc(normalization)
    public dynamic func normalization() -> Float { horos_normalization }

    @objc(kernelsize)
    public dynamic func kernelsize() -> Int16 { horos_kernelsize }

    /// The convolution's weights (25 floats, `kernelsize` × `kernelsize` used).
    @objc(kernel)
    public dynamic func kernel() -> UnsafeMutablePointer<Float>! { horos_kernel }

    /// Sets the presentation convolution, or turns it off with no weights.
    @objc(setConvolutionKernel:::)
    public dynamic func setConvolutionKernel(_ val: UnsafeMutablePointer<Float>!, _ size: Int16, _ norm: Float) {
        if let val {
            horos_kernelsize = size
            horos_convolution = true
            horos_normalization = norm
            // The weights have room for 5 × 5.
            for i in 0..<min(Int(size) * Int(size), 25) { horos_kernel[i] = val[i] }
        } else {
            horos_convolution = false
        }
        horos_updateToBeApplied = true
    }

    /// `src` through the convolution, in a new buffer; `src` is freed unless
    /// it is fImage. Nil for no pixels.
    @objc(applyConvolutionOnImage:RGB:)
    public dynamic func applyConvolution(onImage src: UnsafeMutablePointer<Float>!, rgb color: Bool) -> UnsafeMutablePointer<Float>! {
        var result = src
        if let exception = HorosObjCException.caught({
            self.checkLoad()
            guard let src else {
                result = nil
                return
            }
            let convolution = ImageConvolution(weights: self.horos_kernel, size: Int(self.horos_kernelsize),
                                               normalization: self.horos_normalization)
            if color {
                result = convolution.filtered(argb: UnsafeRawPointer(src), width: self.horos_width, height: self.horos_height)?
                    .assumingMemoryBound(to: Float.self)
            } else {
                result = convolution.filtered(src, width: self.horos_width, height: self.horos_height)
            }
            if result != nil && src != self.horos_fImage { free(src) }
        }) {
            _N2LogExceptionImpl(exception, false, "-[DCMPix applyConvolutionOnImage:RGB:]")
        }
        return result
    }

    /// The convolution applied to the pixels themselves.
    @objc(applyConvolutionOnSourceImage)
    public dynamic func applyConvolutionOnSourceImage() {
        checkLoad()
        let result = applyConvolution(onImage: horos_fImage, rgb: horos_isRGB)
        if result != horos_fImage, let result, let pixels = horos_fImage {
            memcpy(pixels, result, horos_height * horos_width * MemoryLayout<Float>.size)
            free(result)
        }
    }
}
