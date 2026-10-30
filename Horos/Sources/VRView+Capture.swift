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

import Accelerate
import AppKit

// The pictures VRView hands out: the full-depth capture of the ray caster's
// image (values in the volume's units, for the DICOM exports), the raw pixels
// of the frame (RGB with the 2D layer and the logo, or full depth), the
// NSImage and the copy to the pasteboard. A Swift extension of the class,
// with the same selectors.
//
// The buffers are malloc'ed as before: the callers free them. The @try of
// the two captures are HorosObjCException, with the same logs.

extension VRView {

    // MARK: - Full depth

    @objc(prepareFullDepthCapture)
    func prepareFullDepthCapture() {
        horos_fullDepthEngineCopy = engine

        if engine != 0 {
            engine = 0 // Switch to CPU !
        }

        if horos_firstObject?.isRGB ?? false {
            return
        }

        let controller = horos_controller
        let range = IsiXVTKScalarRange(start: horos_valueFactor * (horos_OFFSET16 + (controller?.minimumValue() ?? 0)),
                                       end: horos_valueFactor * (horos_OFFSET16 + (controller?.maximumValue() ?? 0)))
        let blendingRange = IsiXVTKScalarRange(start: horosBlendingValueFactor * (horosBlendingOffset + (controller?.blendingMinimumValue() ?? 0)),
                                               end: horosBlendingValueFactor * (horosBlendingOffset + (controller?.blendingMaximumValue() ?? 0)))

        var volumeDone: ObjCBool = false
        horos_vtk.prepareFullDepth(with: range, blendingRange: blendingRange, volume: &volumeDone)

        if volumeDone.boolValue {
            horos_fullDepthMode = 1
        }
    }

    @objc(restoreFullDepthCapture)
    func restoreFullDepthCapture() {
        var volumeDone: ObjCBool = false
        horos_vtk.restoreFullDepth(&volumeDone)

        if volumeDone.boolValue {
            horos_fullDepthMode = 0
        }

        if engine != horos_fullDepthEngineCopy {
            engine = horos_fullDepthEngineCopy // Restore !
        }

        minimumStep = 0

        needsDisplay = true
    }

    @objc(imageInFullDepthWidth:height:isRGB:)
    func imageInFullDepthWidth(_ w: UnsafeMutablePointer<Int>!, height h: UnsafeMutablePointer<Int>!,
                               isRGB rgb: UnsafeMutablePointer<ObjCBool>!) -> UnsafeMutablePointer<Float>! {
        return imageInFullDepthWidth(w, height: h, isRGB: rgb, blendingView: false)
    }

    @objc(imageInFullDepthWidth:height:isRGB:blendingView:)
    func imageInFullDepthWidth(_ w: UnsafeMutablePointer<Int>!, height h: UnsafeMutablePointer<Int>!,
                               isRGB rgb: UnsafeMutablePointer<ObjCBool>!, blendingView: Bool) -> UnsafeMutablePointer<Float>! {
        var returnedPtr: UnsafeMutablePointer<Float>? = nil

        if let e = HorosObjCException.caught({
            returnedPtr = self.fullDepthImage(w, h, rgb, blendingView: blendingView)
        }) {
            NSLog("***** exception in %s: %@", "-[VRView imageInFullDepthWidth:height:isRGB:blendingView:]", e)
        }

        return returnedPtr
    }

    /// The body of the @try of -imageInFullDepthWidth:height:isRGB:blendingView:.
    private func fullDepthImage(_ w: UnsafeMutablePointer<Int>, _ h: UnsafeMutablePointer<Int>,
                                _ rgb: UnsafeMutablePointer<ObjCBool>, blendingView: Bool) -> UnsafeMutablePointer<Float>? {
        let vtk = horos_vtk
        guard blendingView ? vtk.hasBlendingMapper : vtk.hasVolumeMapper else { return nil }

        let rayCastImage = vtk.rayCastImageInfoFused(blendingView)

        let im = vtk.rayCastImageFused(blendingView)!

        let fullSize0 = Int(rayCastImage.memorySize.0)

        w.pointee = Int(rayCastImage.inUseSize.0)
        h.pointee = Int(rayCastImage.inUseSize.1)

        let renderingMode = self.renderingMode
        if !(horos_firstObject?.isRGB ?? false) && (renderingMode == 1 || renderingMode == 3 || renderingMode == 2) { // MIP
            let picture = blendingView
                ? VRFullDepthReadback.projection(im, memoryWidth: fullSize0, width: w.pointee, height: h.pointee,
                                                 valueFactor: horosBlendingValueFactor, offset: horosBlendingOffset)
                : VRFullDepthReadback.projection(im, memoryWidth: fullSize0, width: w.pointee, height: h.pointee,
                                                 valueFactor: horos_valueFactor, offset: horos_OFFSET16)
            guard let picture else { return nil }
            rgb.pointee = false
            return picture
        } else {
            guard let picture = VRFullDepthReadback.colour(im, memoryWidth: fullSize0, width: w.pointee, height: h.pointee) else {
                return nil
            }
            rgb.pointee = true
            return UnsafeMutableRawPointer(picture).assumingMemoryBound(to: Float.self)
        }
    }

    // MARK: - Raw pixels

    @objc(getRawPixels::::::)
    dynamic func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!,
                      _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>! {
        return getRawPixels(width, height, spp, bpp, screenCapture, force8bits, offset: nil, isSigned: nil)
    }

    @objc(getRawPixels::::::offset:isSigned:)
    dynamic func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!,
                              _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool,
                              offset: UnsafeMutablePointer<Int32>!, isSigned: UnsafeMutablePointer<ObjCBool>!) -> UnsafeMutablePointer<UInt8>! {
        var buf: UnsafeMutablePointer<UInt8>? = nil

        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        if let e = HorosObjCException.caught({
            buf = self.rawPixels(width, height, spp, bpp, force8bits, offset, isSigned)
        }) {
            _N2LogExceptionImpl(e, true, "-[VRView getRawPixels::::::offset:isSigned:]")
        }

        drawLock?.unlock()

        return buf
    }

    /// The body of the @try of -getRawPixels::::::offset:isSigned:.
    private func rawPixels(_ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>, _ spp: UnsafeMutablePointer<Int>,
                           _ bpp: UnsafeMutablePointer<Int>, _ force8bits: Bool,
                           _ offset: UnsafeMutablePointer<Int32>?, _ isSigned: UnsafeMutablePointer<ObjCBool>?) -> UnsafeMutablePointer<UInt8>? {
        var buf: UnsafeMutablePointer<UInt8>? = nil
        let fullDepthCapture = !force8bits

        if fullDepthCapture {
            var rgb: ObjCBool = false

            guard let sfData = imageInFullDepthWidth(width, height: height, isRGB: &rgb) else { return nil }

            if rgb.boolValue {
                spp.pointee = 3
                bpp.pointee = 8

                let bytes = UnsafeMutableRawPointer(sfData).assumingMemoryBound(to: UInt8.self)
                buf = bytes

                // Each ARGB pixel's four bytes from the R on, over the RGB
                // pixels packed in place (the fourth byte is the next one's).
                var i = width.pointee * height.pointee
                var t_argb = UnsafeMutableRawPointer(bytes + 1)
                var t_rgb = UnsafeMutableRawPointer(bytes)
                while i > 0 {
                    i -= 1
                    t_rgb.storeBytes(of: t_argb.loadUnaligned(as: Int32.self), as: Int32.self)
                    t_argb += 4
                    t_rgb += 3
                }
            } else {
                spp.pointee = 1
                bpp.pointee = 16

                var sf = vImage_Buffer(data: sfData, height: vImagePixelCount(height.pointee), width: vImagePixelCount(width.pointee),
                                       rowBytes: width.pointee * MemoryLayout<Float>.size)

                var d8 = vImage_Buffer()
                d8.height = vImagePixelCount(height.pointee)
                d8.width = vImagePixelCount(width.pointee)
                d8.rowBytes = width.pointee * MemoryLayout<Int16>.size

                var slope: Float = 1

                let controller = horos_controller
                if controller?.viewer2D()?.modality() == "PT" {
                    let firstObject = horos_firstObject
                    slope = (firstObject?.appliedFactorPET2SUV() ?? 0) * (firstObject?.slope ?? 0)
                }

                buf = malloc(width.pointee * height.pointee * spp.pointee * bpp.pointee / 8)?.assumingMemoryBound(to: UInt8.self)
                if let buf {
                    d8.data = UnsafeMutableRawPointer(buf)

                    let minimum = controller?.minimumValue() ?? 0
                    if minimum < -1024 {
                        isSigned?.pointee = true
                        offset?.pointee = 0

                        vImageConvert_FTo16S(&sf, &d8, 0, slope, 0)
                    } else {
                        isSigned?.pointee = false

                        if minimum >= 0 {
                            offset?.pointee = 0
                            vImageConvert_FTo16U(&sf, &d8, 0, slope, 0)
                        } else {
                            offset?.pointee = -1024
                            vImageConvert_FTo16U(&sf, &d8, -1024, slope, 0)
                        }
                    }
                }

                free(sfData)
            }
        } else {
            spp.pointee = 3
            bpp.pointee = 8
            // Two pictures, one an eye, side by side as the original stereo exported them.
            let bothEyes = horosStereoMode() == StereoMode.oneScreen.rawValue || horosStereoMode() == StereoMode.twoScreens.rawValue
            buf = horos_vtk.copyFrameRGBWidth(width, height: height, stereo: bothEyes)
            if let buf {
                let rowBytes = width.pointee * 3
                // The text and 2D actors are over the volume, not in it.
                for overlay in subviews {
                    if let overlay = overlay as? AnnotationOverlay {
                        overlay.composite(onto: buf, width: width.pointee, height: height.pointee, originX: 0, originY: 0)
                    }
                }
                // Add the small logo at the lower-left corner of the image.
                let logo = NSImage(named: "SmallLogo.tif")

                if let tiff = logo?.tiffRepresentation, let TIFFRep = NSBitmapImageRep(data: tiff) {
                    let rows = min(TIFFRep.pixelsHigh, height.pointee)
                    let columns = max(0, min(TIFFRep.pixelsWide, width.pointee - 2))
                    var y = 0
                    while y < rows && columns > 0 {
                        var destination = buf + (height.pointee - rows + y) * rowBytes + 2 * 3
                        for x in 0..<columns {
                            if let color = TIFFRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                               color.redComponent != 0 || color.greenComponent != 0 || color.blueComponent != 0 {
                                destination[0] = UInt8(truncatingIfNeeded: lround(Double(color.redComponent * 255)))
                                destination[1] = UInt8(truncatingIfNeeded: lround(Double(color.greenComponent * 255)))
                                destination[2] = UInt8(truncatingIfNeeded: lround(Double(color.blueComponent * 255)))
                            }
                            destination += 3
                        }
                        y += 1
                    }
                }
            }
        }

        return buf
    }

    // MARK: - The picture

    @objc(nsimage:)
    func nsimage(_ originalSize: Bool) -> NSImage! {
        var width = 0, height = 0, spp = 0, bpp = 0

        resetAutorotate(self)

        guard let dataPtr = getRawPixels(&width, &height, &spp, &bpp, !originalSize, true) else { return nil }

        let colorSpace: NSColorSpaceName = spp == 3 ? .calibratedRGB : .calibratedWhite

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: bpp,
                                   samplesPerPixel: spp, hasAlpha: false, isPlanar: false, colorSpaceName: colorSpace,
                                   bytesPerRow: width * bpp * spp / 8, bitsPerPixel: bpp * spp)!

        memcpy(rep.bitmapData, dataPtr, height * width * bpp * spp / 8)

        let image = NSImage()
        image.addRepresentation(rep)

        free(dataPtr)

        return image
    }

    @objc(copy:)
    func copy(_ sender: Any?) {
        let pb = NSPasteboard.general

        pb.declareTypes([.tiff], owner: self)

        let im = nsimage(false)

        pb.setData(im?.tiffRepresentation, forType: .tiff)
    }
}

/// The two readbacks of the ray caster's image (four 16-bit words a sample,
/// R first, rows from the bottom, `memoryWidth` samples a row in memory), rows
/// top first, in buffers the caller frees.
enum VRFullDepthReadback {

    /// A projection: the fourth word of each sample, the projected value
    /// (`-prepareFullDepthCapture`), in the volume's units: divided by
    /// `valueFactor` (unless 1) less `offset`. Nil when the first buffer cannot
    /// be had; nil inside when the second cannot.
    static func projection(_ im: UnsafeMutablePointer<UInt16>, memoryWidth fullSize0: Int, width w: Int, height h: Int,
                           valueFactor: Float, offset: Float) -> UnsafeMutablePointer<Float>?? {
        guard let destFixedPtr = malloc((w + 1) * (h + 1) * MemoryLayout<UInt16>.size)?
            .assumingMemoryBound(to: UInt16.self) else { return nil }
        var destPtr = destFixedPtr

        var iptr = im + 3 + 4 * (h - 1) * fullSize0

        var j = h
        let rowBytes = 4 * fullSize0
        while j > 0 {
            j -= 1
            var iptrTemp = iptr
            var i = w
            while i > 0 {
                i -= 1
                destPtr.pointee = iptrTemp.pointee
                destPtr += 1
                iptrTemp += 4
            }

            iptr -= rowBytes
        }

        var mul = Float(1.0 / Double(valueFactor))
        let add = -offset

        if valueFactor == 1 {
            mul = 1
        }

        var src = vImage_Buffer(data: destFixedPtr, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)

        var dst = vImage_Buffer()
        dst.data = malloc((w + 1) * (h + 1) * MemoryLayout<Float>.size)
        if dst.data != nil {
            dst.height = vImagePixelCount(h)
            dst.width = vImagePixelCount(w)
            dst.rowBytes = w * 4

            vImageConvert_16UToF(&src, &dst, add, mul, 0)
        }

        free(destFixedPtr)

        return .some(dst.data?.assumingMemoryBound(to: Float.self))
    }

    /// A colour picture: each sample's own R, G and B, as ARGB bytes.
    static func colour(_ im: UnsafeMutablePointer<UInt16>, memoryWidth fullSize0: Int, width w: Int, height h: Int) -> UnsafeMutablePointer<UInt8>? {
        guard let destFixedPtr = malloc((w + 1) * (h + 1) * 4)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var destPtr = destFixedPtr

        // The ray-cast image is RGBA, four components per pixel, R first:
        // each pixel's own R, G and B, as ARGB bytes. The loop used to start
        // on the alpha and skip it, reading the next pixel's colour.
        var iptr = im + 4 * (h - 1) * fullSize0

        var j = h
        let rowBytes = 4 * fullSize0
        while j > 0 {
            j -= 1
            var iptrTemp = iptr
            var i = w
            while i > 0 {
                i -= 1
                destPtr[0] = 255
                destPtr[1] = UInt8(truncatingIfNeeded: iptrTemp[0] >> 7)
                destPtr[2] = UInt8(truncatingIfNeeded: iptrTemp[1] >> 7)
                destPtr[3] = UInt8(truncatingIfNeeded: iptrTemp[2] >> 7)
                destPtr += 4
                iptrTemp += 4
            }

            iptr -= rowBytes
        }

        return destFixedPtr
    }
}
