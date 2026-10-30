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

import Accelerate
import AppKit
import Foundation
import IsiXImaging

/// What an image shows: its 8-bit picture through the window (linear, a
/// transfer function, a subtraction, colour), inverted for MONOCHROME1 and
/// shuttered; the pictures made of it (-image, the thumbnail); its change to
/// grey or colour; and the windows it offers before anyone sets one. The
/// arithmetic is IsiXImaging's (WindowRendering, ShutterMask, ThumbnailIcon,
/// ColourChannels, DisplayWindowRange); this reads and writes the image.
extension DCMPix {
    // MARK: - The 8-bit picture

    /// The 8-bit picture (one byte a pixel, or ARGB), made when it is missing
    /// or out of date.
    @objc public var baseAddr: UnsafeMutablePointer<CChar>! {
        @objc(baseAddr) get {
            checkLoad()
            if horos_baseAddr == nil { allocate8bitRepresentation() }
            if needToCompute8bitRepresentation { compute8bitRepresentation() }
            return horos_baseAddr
        }
        @objc(setBaseAddr:) set {
            if let old = horos_baseAddr { free(old) }
            horos_baseAddr = newValue
        }
    }

    /// The picture for a 12-bit display, made with the 8-bit one.
    @objc(LUT12baseAddr) public var lut12baseAddr: UnsafeMutablePointer<UInt8>! {
        get {
            checkLoad()
            if horos_LUT12baseAddr == nil { allocate8bitRepresentation() }
            return horos_LUT12baseAddr
        }
        set {
            if newValue != horos_LUT12baseAddr {
                if let old = horos_LUT12baseAddr { free(old) }
                horos_LUT12baseAddr = newValue
            }
        }
    }

    /// A new 8-bit picture, made through the current window.
    @objc(allocate8bitRepresentation)
    public dynamic func allocate8bitRepresentation() {
        checkLoad()
        if let old = horos_baseAddr { free(old) }
        horos_baseAddr = nil
        let pixels = (horos_width + 4) * (horos_height + 4)
        horos_baseAddr = calloc(horos_isRGB ? pixels * 4 : pixels, 1)?.assumingMemoryBound(to: CChar.self)
        if horos_baseAddr != nil {
            changeWLWW(horos_wl, horos_ww)
        } else {
            NSLog("****** allocate8bitRepresentation calloc failed: %d %d", Int32(truncatingIfNeeded: horos_width),
                  Int32(truncatingIfNeeded: horos_height))
        }
    }

    /// Drops the 8-bit picture; the next one is made again.
    @objc(kill8bitsImage)
    public dynamic func kill8bitsImage() {
        needToCompute8bitRepresentation = true
        if let old = horos_baseAddr { free(old) }
        horos_baseAddr = nil
    }

    /// Takes the window and makes the 8-bit picture when there is none.
    @objc(checkImageAvailble::)
    public dynamic func checkImageAvailble(_ newWW: Float, _ newWL: Float) {
        checkLoad()
        horos_ww = newWW
        horos_wl = newWL
        if horos_baseAddr == nil { allocate8bitRepresentation() }
    }

    /// Takes a window for the picture: a width of zero, or a value that is not
    /// a number, asks for the full window.
    @objc(changeWLWW::)
    public dynamic func changeWLWW(_ newWL: Float, _ newWW: Float) {
        if horos_baseAddr == nil {
            checkImageAvailble(newWW, newWL)
            return
        }
        checkLoad()
        if let window = ImageWindow.requested(level: newWL, width: newWW, fullWidth: horos_fullww, slope: horos_slope) {
            horos_ww = window.width
            horos_wl = window.level
        } else {
            computePixMinPixMax()
            horos_ww = horos_fullww
            horos_wl = horos_fullwl
        }
        if horos_baseAddr != nil { needToCompute8bitRepresentation = true }
    }

    /// The 8-bit picture of what is shown (computefImageForDisplay, or the
    /// colour slab) through the window, the transfer function or the
    /// subtraction's gamma; inverted for MONOCHROME1 and shuttered.
    @objc(compute8bitRepresentation)
    public dynamic func compute8bitRepresentation() {
        let fixed = horos_fixed8bitsWLWW
        let iww: Float = fixed ? 256 : horos_ww
        let iwl: Float = fixed ? 127 : horos_wl
        guard let base = horos_baseAddr else { return }
        checkLoad()
        needToCompute8bitRepresentation = false
        horos_updateToBeApplied = false

        let width = horos_width, height = horos_height
        let picture = UnsafeMutableRawPointer(base).assumingMemoryBound(to: UInt8.self)
        if !horos_isRGB {
            guard var source = computefImageForDisplay() else { return }
            if !horos_thickSlabVRActivated {
                if let mask = subtractedfImage {
                    // The window of a subtraction is its gamma curve and zero.
                    let window = SubtractionSliders.window(level: horos_wl, width: horos_ww)
                    horos_wl = window.level
                    horos_ww = window.width
                    setSubSlidersPercent(horos_subtractedfPercent, gamma: window.gamma, zero: window.zero)
                    source = subtractImages(source, mask)
                    var floats = vImage_Buffer(data: UnsafeMutableRawPointer(source), height: vImagePixelCount(bitPattern: height),
                                               width: vImagePixelCount(bitPattern: width), rowBytes: width * MemoryLayout<Float>.size)
                    var eight = vImage_Buffer(data: UnsafeMutableRawPointer(base), height: vImagePixelCount(bitPattern: height),
                                              width: vImagePixelCount(bitPattern: width), rowBytes: width)
                    vImageGamma_PlanarFtoPlanar8(&floats, &eight, horos_subGammaFunction, vImage_Flags(0))
                } else {
                    if let table = transferFunctionPtr {
                        WindowRendering.throughTable(source, into: picture, width: width, height: height, level: horos_wl,
                                                     window: horos_ww, table: table, threads: Int(DCMPix.maxProcessors()))
                    } else {
                        WindowRendering.linear(source, into: picture, width: width, height: height, level: iwl, window: iww)
                    }
                    horos_fill12BitBuffer(from: source)
                }
                if source != horos_fImage { free(source) }
            }
        }

        if horos_isRGB {
            var source: UnsafeMutablePointer<Float>?
            if stackMode > 0 && horos_stack >= 1 && horos_pixArray?.count ?? 0 > 1 {
                source = computeThickSlabRGB()
            } else {
                source = horos_fImage
            }
            if horos_convolution { source = applyConvolution(onImage: source, rgb: true) }
            if let source {
                WindowRendering.colour(source, into: base, width: width, height: height,
                                       table: WindowRendering.colourTable(level: iwl, window: iww, table: transferFunctionPtr))
                if source != horos_fImage { free(source) }
            }
        }

        // Polarity follows the VOI/transfer function. fImage remains in the
        // calibrated domain for measurements, session consumers and exports.
        if displayInverted && !horos_thickSlabVRActivated {
            WindowRendering.invert(picture, count: width * height)
        }

        applyShutter()
    }

    // MARK: - Polarity

    /// MONOCHROME1 presentation polarity, independent of calibrated fImage values.
    @objc public var displayInverted: Bool {
        @objc(displayInverted) get { horos_inverseVal && !horos_isRGB }
        @objc(setDisplayInverted:) set {
            horos_inverseVal = newValue
            needToCompute8bitRepresentation = true
            horos_updateToBeApplied = true
        }
    }

    /// A window level in the stored sign domain (database, workspace) for a calibrated one.
    @objc(storedWindowLevelForCalibratedLevel:)
    public dynamic func storedWindowLevel(forCalibratedLevel level: Float) -> Float {
        checkLoad()
        return displayInverted ? -level : level
    }

    /// A calibrated window level for one in the stored sign domain.
    @objc(calibratedWindowLevelForStoredLevel:)
    public dynamic func calibratedWindowLevel(forStoredLevel level: Float) -> Float {
        checkLoad()
        return displayInverted ? -level : level
    }

    // MARK: - Shutter

    @objc(setBlackIndex:)
    public dynamic func setBlackIndex(_ i: Int32) {
        horos_blackIndex = CChar(truncatingIfNeeded: i)
    }

    /// The shutter applied to the 8-bit picture, when it is on: its rectangle
    /// held inside the image and rounded, then the circle and the polygon.
    @objc(applyShutter)
    public dynamic func applyShutter() {
        guard shutterEnabled else { return }
        let width = horos_width, height = horos_height
        horos_shutterRect = ShutterMask.heldRect(horos_shutterRect, width: width, height: height)
        guard let base = horos_baseAddr else { return }
        if horos_isRGB || horos_thickSlabVRActivated {
            ShutterMask.maskColour(UnsafeMutableRawPointer(base), width: width, height: height, rect: horos_shutterRect)
        } else {
            ShutterMask.maskGrey(UnsafeMutableRawPointer(base).assumingMemoryBound(to: UInt8.self), width: width, height: height,
                                    rect: horos_shutterRect, black: UInt8(bitPattern: horos_blackIndex),
                                    circleCentre: horos_shutterCircular, circleRadius: horos_shutterCircular_radius,
                                    polygon: shutterPolygonal.map { UnsafePointer($0) }, polygonCount: horos_shutterPolygonalSize)
        }
    }

    /// Whether `x` is inside the polygon of `no` points.
    @objc(IsPoint:inPolygon:size:)
    public static dynamic func isPoint(_ x: NSPoint, inPolygon pts: UnsafeMutablePointer<NSPoint>!, size no: Int32) -> Bool {
        guard let pts else { return false }
        return ShutterMask.contains(pts, count: Int(no), x: Float(x.x), y: Float(x.y))
    }

    // MARK: - Pictures

    /// The 8-bit picture as an image, full size, through the current window.
    @objc(image)
    public dynamic func image() -> NSImage! {
        compute8bitRepresentation()
        var made: NSImage?
        if let exception = HorosObjCException.caught({ made = self.bitmapImage() }) {
            _N2LogExceptionImpl(exception, false, "-[DCMPix image]")
        }
        return made
    }

    private func bitmapImage() -> NSImage? {
        let width = horos_width, height = horos_height
        let colour = isRGB
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: colour ? 3 : 1, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: colour ? .calibratedRGB : .calibratedWhite,
                                         bytesPerRow: colour ? width * 3 : width, bitsPerPixel: colour ? 24 : 8),
              let bitmap = rep.bitmapData else { return nil }
        guard let picture = baseAddr else { return nil }
        if colour {
            ColourChannels.rgb(fromARGB: UnsafeRawPointer(picture).assumingMemoryBound(to: UInt8.self), into: bitmap,
                               count: width * height)
        } else {
            memcpy(bitmap, picture, height * width)
        }
        let image = NSImage()
        image.addRepresentation(rep)
        return image
    }

    /// The thumbnail of the image through `newWW`/`newWL` (the current window
    /// when both are zero, the full one when there is none), inverted for MONOCHROME1.
    @objc(generateThumbnailImageWithWW:WL:)
    public dynamic func generateThumbnailImage(withWW newWW: Float, wl newWL: Float) -> NSImage! {
        checkLoad()
        let width = horos_width, height = horos_height
        // A frame that never established a size - Enhanced objects that omit Rows
        // or arrive with zero - used to divide that zero into the thumbnail size,
        // which is the SIGFPE the Bruker import crash reports die on. No picture
        // is better than taking the process down while drawing a series icon.
        if width < 1 || height < 1 {
            NSLog("---- thumbnail: %@ has no usable image size (%d x %d)", ((srcFile as NSString?)?.lastPathComponent ?? "(null)") as NSString,
                  Int32(truncatingIfNeeded: width), Int32(truncatingIfNeeded: height))
            return nil
        }
        let size = ThumbnailIcon.size(width: width, height: height)
        let colour = horos_isRGB
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height, bitsPerSample: 8,
                                         samplesPerPixel: colour ? 3 : 1, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: colour ? .calibratedRGB : .calibratedWhite,
                                         bytesPerRow: colour ? size.width * 4 : size.width, bitsPerPixel: colour ? 24 : 8),
              let icon = rep.bitmapData else {
            NSLog("Memory error... not enough RAM")
            return nil
        }
        var ww = newWW, wl = newWL
        if ww == 0 && wl == 0 {
            if horos_ww == 0 && horos_wl == 0 {
                computePixMinPixMax()
                horos_ww = horos_fullww
                horos_wl = horos_fullwl
            }
            ww = horos_ww
            wl = horos_wl
        }
        if let pixels = horos_fImage {
            ThumbnailIcon.draw(UnsafeRawPointer(pixels), into: icon, width: Int32(truncatingIfNeeded: width),
                               height: Int32(truncatingIfNeeded: height), iconWidth: size.width,
                               level: ImagePlaneCoordinates.cLong(Double(wl)), window: ImagePlaneCoordinates.cLong(Double(ww)), isRGB: colour)
        }
        // MONOCHROME1 polarity is applied for display, not to fImage: the
        // icon follows it as the viewer's 8-bit image does.
        if displayInverted { ThumbnailIcon.invert(icon, count: size.width * size.height) }
        let image = NSImage(size: NSSize(width: size.width, height: size.height))
        image.addRepresentation(rep)
        return image
    }

    /// `currentImage` redrawn smaller when it is much larger than the pixels of
    /// `dcmPix` (DisplayWindowRange.resizedSize), else itself.
    @objc(resizeIfNecessary:dcmPix:)
    public static dynamic func resizeIfNecessary(_ currentImage: NSImage!, dcmPix: DCMPix!) -> NSImage! {
        guard let currentImage else { return nil }
        let size = currentImage.size
        guard size.width > 512 && size.height > 512 else { return currentImage }
        var resized: NSImage?
        if let exception = HorosObjCException.caught({
            guard let target = DisplayWindowRange.resizedSize(size, pixelWidth: dcmPix?.pwidth ?? 0,
                                                              pixelHeight: dcmPix?.pheight ?? 0) else { return }
            let sourceRect = NSRect(origin: .zero, size: size)
            resized = NSImage(size: target, flipped: false) { bounds in
                currentImage.draw(in: bounds, from: sourceRect, operation: .copy, fraction: 1.0)
                return true
            }
        }) {
            _N2LogExceptionImpl(exception, true, "+[DCMPix resizeIfNecessary:dcmPix:]")
        }
        return resized ?? currentImage
    }

    // MARK: - Grey and colour

    /// A colour image made grey from its red (0), green (1) or blue (2), or the
    /// mean of the three (3).
    @objc(ConvertToBW:)
    public dynamic func convert(toBW mode: Int) {
        if !horos_isRGB { return }
        let count = horos_height * horos_width
        guard let grey = malloc(count * 4)?.assumingMemoryBound(to: Float.self) else { return }
        if let source = fImage {
            ColourChannels.grey(fromARGB: UnsafeRawPointer(source).assumingMemoryBound(to: UInt8.self), into: grey, count: count,
                                mode: mode)
        }
        baseAddr = malloc(pwidth * pheight)?.assumingMemoryBound(to: CChar.self)
        isRGB = false
        if let pixels = horos_fImage { memcpy(pixels, grey, count * 4) }
        changeWLWW(horos_wl, horos_ww)
        free(grey)
    }

    /// A grey image made colour through the window `cwl`/`cww`: in the red (0),
    /// green (1) or blue (2) channel, or in all three (3); the alpha is the
    /// mean of red, green and blue.
    @objc(ConvertToRGB:::)
    public dynamic func convert(toRGB mode: Int, _ cwl: Int, _ cww: Int) {
        if horos_isRGB { return }
        let width = pwidth, height = pheight
        if let pixels = fImage {
            ColourChannels.toARGB(pixels, width: width, height: height, mode: mode, level: cwl, window: cww)
        }
        baseAddr = malloc(width * height * 4)?.assumingMemoryBound(to: CChar.self)
        isRGB = true
        changeWLWW(127, 256)
        if horos_isRGB, let pixels = horos_fImage {
            ColourChannels.fillAlpha(UnsafeMutableRawPointer(pixels).assumingMemoryBound(to: UInt8.self),
                                     count: horos_width * horos_height)
        }
    }

    // MARK: - Windows before anyone sets one

    /// YES for a frame with colour samples, which has no scalar intensity to window.
    @objc(isColorPreviewFrame)
    public dynamic func isColorPreviewFrame() -> Bool {
        checkLoad()
        return horos_isRGB
    }

    /// Window Center/Width as the file stores them, or nil when it stores none that is usable.
    @objc(dicomPreviewWindow)
    public dynamic func dicomPreviewWindow() -> Any? {
        checkLoad()
        // savedWW/savedWL hold Window Width/Center as the file gave them, after
        // the sign fix the loader applies.
        guard DisplayWindowRange.isUsableStoredWindow(level: horos_savedWL, width: horos_savedWW) else { return nil }
        return PreviewWindow(level: horos_savedWL, width: horos_savedWW, source: .dicom)
    }

    /// The window this frame's own intensities suggest, sampled; nil when it
    /// has too few usable samples to guess from.
    @objc(automaticPreviewWindow)
    public dynamic func automaticPreviewWindow() -> Any? {
        // The one decode this frame needs; it is shared with whatever draws it.
        checkLoad()
        // A colour frame has no scalar intensity, and a frame with no pixels has
        // nothing to sample. Neither is a failure worth guessing around.
        guard !horos_isRGB, let pixels = horos_fImage, horos_width >= 1, horos_height >= 1 else { return nil }
        return PreviewAutomaticWindow.window(values: pixels, width: horos_width, height: horos_height, modality: modalityString)
    }

    /// The range this frame's own values occupy, from its minimum and maximum.
    @objc(frameRangePreviewWindow)
    public dynamic func frameRangePreviewWindow() -> Any? {
        checkLoad()
        guard !horos_isRGB, horos_fImage != nil, horos_width >= 1, horos_height >= 1 else { return nil }
        // The same minimum and maximum a request of (0,0) has always used here.
        computePixMinPixMax()
        guard DisplayWindowRange.isUsableFrameRange(level: horos_fullwl, width: horos_fullww) else { return nil }
        return PreviewWindow(level: horos_fullwl, width: horos_fullww, source: .frameRange)
    }

    /// The range the stored bits can represent, after rescale: the last resort.
    @objc(storedRangePreviewWindow)
    public dynamic func storedRangePreviewWindow() -> Any? {
        checkLoad()
        if horos_isRGB { return PreviewWindow(level: 127.5, width: 255, source: .color) }
        guard let range = DisplayWindowRange.storedRange(bitsStored: Int(horos_bitsStored), bitsAllocated: Int(horos_bitsAllocated),
                                                         isSigned: horos_fIsSigned, slope: horos_slope,
                                                         intercept: horos_offset) else { return nil }
        return PreviewWindow(level: range.level, width: range.width, source: .storedRange)
    }
}
