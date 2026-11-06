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

import Accelerate
import Foundation

// The arithmetic of a viewer's capture: what a raw buffer of the image as
// shown, or as kept in memory, is made of, independent of the view that asks
// for it. The view (DCMView+Capture.swift, in the app) gathers the pixels and
// the geometry; these functions encode, convert, crop, resample and assemble
// them exactly as the former Objective-C code of the view did, byte for byte:
// the buffers are the ones -getRawPixelsWidth:... has always returned, which
// the callers free() and which the DICOM, JPEG/TIFF and print exports write.
public enum CaptureRaster {

    // MARK: - 16-bit samples

    /// How float samples become 16-bit integers. A series whose minimum is
    /// below -1024 is stored signed; one that never goes below 0 unsigned; the
    /// rest (CT above -1024) unsigned, shifted by 1024, and the caller is told
    /// the offset so that the values can be read back.
    public struct SixteenBitEncoding: Equatable, Sendable {
        public let isSigned: Bool
        /// What the caller adds back to a stored value: 0 or -1024.
        public let offset: Int32

        public init(minimumOfSeries: Float) {
            if minimumOfSeries < -1024 {
                isSigned = true
                offset = 0
            } else if minimumOfSeries >= 0 {
                isSigned = false
                offset = 0
            } else {
                isSigned = false
                offset = -1024
            }
        }
    }

    /// Writes `width` × `height` float samples into `destination` as 16-bit
    /// integers, `value * slope` after the offset of `encoding`, with vImage's
    /// rounding and saturation.
    public static func convertFloatSamples(_ source: UnsafeMutableRawPointer?, width: Int, height: Int,
                                           slope: Float, encoding: SixteenBitEncoding,
                                           into destination: UnsafeMutableRawPointer) {
        var src = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: width * MemoryLayout<Float>.size)
        var dst = vImage_Buffer(data: destination, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: width * MemoryLayout<Int16>.size)
        if encoding.isSigned {
            vImageConvert_FTo16S(&src, &dst, 0, slope, vImage_Flags(0))
        } else {
            vImageConvert_FTo16U(&src, &dst, Float(encoding.offset), slope, vImage_Flags(0))
        }
    }

    // MARK: - 8-bit colour

    /// The RGB rows of a `width` × `height` rectangle at (`originX`, `originY`)
    /// of a BGRA frame read back from the screen, rows from the top. Pixels
    /// outside the frame, or every pixel when there is no frame, take `clear`.
    public static func rgbFromBGRAFrame(_ frame: UnsafeRawBufferPointer?, frameWidth: Int, frameHeight: Int,
                                        originX: Int, originY: Int, width: Int, height: Int,
                                        clear: UInt8, into destination: UnsafeMutablePointer<UInt8>) {
        for y in 0..<max(height, 0) {
            let row = destination + y * width * 3
            for x in 0..<max(width, 0) {
                let fx = originX + x, fy = originY + y
                if let frame, fx >= 0, fy >= 0, fx < frameWidth, fy < frameHeight {
                    let bgra = (fy * frameWidth + fx) * 4
                    row[3 * x] = frame[bgra + 2]
                    row[3 * x + 1] = frame[bgra + 1]
                    row[3 * x + 2] = frame[bgra]
                } else {
                    row[3 * x] = clear
                    row[3 * x + 1] = clear
                    row[3 * x + 2] = clear
                }
            }
        }
    }

    /// `pixelCount` ARGB pixels, as a colour DCMPix keeps them, to RGB.
    public static func rgbFromARGB(_ source: UnsafePointer<UInt8>, pixelCount: Int,
                                   into destination: UnsafeMutablePointer<UInt8>) {
        var src = source, dst = destination
        for _ in 0..<max(pixelCount, 0) {
            dst[0] = src[1]
            dst[1] = src[2]
            dst[2] = src[3]
            src += 4
            dst += 3
        }
    }

    // MARK: - Resampling

    /// The height of a picture with square pixels made from one `height` rows
    /// high whose pixels are `spacingX` wide and `spacingY` high, truncated as
    /// before.
    public static func squarePixelHeight(height: Int, spacingX: Double, spacingY: Double) -> Int {
        Int(Double(Float(height)) * spacingY / spacingX)
    }

    /// Resamples an RGB picture into `destination` (`destinationWidth` ×
    /// `destinationHeight`, tightly packed) with vImage's high quality
    /// resampling, through ARGB, which vImage scales. `sourceRowBytes` lets the
    /// source be a crop of a larger picture.
    public static func scaleRGB(_ source: UnsafeMutableRawPointer, width: Int, height: Int, sourceRowBytes: Int,
                                into destination: UnsafeMutableRawPointer,
                                destinationWidth: Int, destinationHeight: Int) {
        var src = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: sourceRowBytes)
        var dst = vImage_Buffer(data: destination, height: vImagePixelCount(destinationHeight),
                                width: vImagePixelCount(destinationWidth), rowBytes: destinationWidth * 3)
        var argbSource = src
        argbSource.rowBytes = width * 4
        argbSource.data = calloc(argbSource.rowBytes * height, 1)
        var argbDestination = dst
        argbDestination.rowBytes = destinationWidth * 4
        argbDestination.data = calloc(argbDestination.rowBytes * destinationHeight, 1)
        defer {
            free(argbSource.data)
            free(argbDestination.data)
        }
        guard argbSource.data != nil, argbDestination.data != nil else { return }
        vImageConvert_RGB888toARGB8888(&src, nil, 0, &argbSource, false, vImage_Flags(0))
        vImageScale_ARGB8888(&argbSource, &argbDestination, nil, vImage_Flags(kvImageHighQualityResampling))
        vImageConvert_ARGB8888toRGB888(&argbDestination, &dst, vImage_Flags(0))
    }

    /// Resamples one 8-bit channel with vImage's high quality resampling.
    public static func scalePlanar8(_ source: UnsafeMutableRawPointer, width: Int, height: Int,
                                    into destination: UnsafeMutableRawPointer,
                                    destinationWidth: Int, destinationHeight: Int) {
        var src = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: width)
        var dst = vImage_Buffer(data: destination, height: vImagePixelCount(destinationHeight),
                                width: vImagePixelCount(destinationWidth), rowBytes: destinationWidth)
        vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
    }

    /// The square at the centre of a `width` × `height` picture that a thumbnail
    /// of the capture is made from: its side, the smaller dimension, and its
    /// offset, in pixels.
    public static func centredSquare(width: Int, height: Int) -> (x: Int, y: Int, side: Int) {
        let side = width > height ? height : width
        return ((width - side) / 2, (height - side) / 2, side)
    }

    // MARK: - Assembling several views

    /// Copies one tile of a viewer's grid, `width` × `height` pixels, to
    /// column `column` and row `row` of the buffer of the whole grid, which is
    /// `gridWidth` pixels wide.
    public static func copyTile(_ tile: UnsafeRawPointer, into grid: UnsafeMutableRawPointer,
                                column: Int, row: Int, gridWidth: Int,
                                width: Int, height: Int, samplesPerPixel: Int, bitsPerSample: Int) {
        let start = grid + samplesPerPixel * gridWidth * row * height * bitsPerSample / 8
            + column * width * samplesPerPixel * bitsPerSample / 8
        let rowBytes = samplesPerPixel * width * bitsPerSample / 8
        for y in 0..<max(height, 0) {
            memcpy(start + y * samplesPerPixel * gridWidth * bitsPerSample / 8,
                   tile + y * samplesPerPixel * width * bitsPerSample / 8, rowBytes)
        }
    }

    /// Where the views of several viewers, given by their rectangles on
    /// screen, go in one picture: each is pushed left until it touches another
    /// or the left edge of them all, then up the same way, so that the gaps
    /// between windows close. Returns the new rectangles and the one that
    /// encloses them.
    public static func arrangeViewRects(_ rects: [NSRect]) -> (rects: [NSRect], union: NSRect) {
        var rects = rects
        guard let first = rects.first else { return (rects, .zero) }
        var unionRect = first
        for rect in rects { unionRect = NSUnionRect(rect, unionRect) }

        for i in rects.indices {
            var current = rects[i]
            var intersect: Bool
            repeat {
                intersect = false
                for x in rects.indices where x != i {
                    if NSIntersectsRect(current, rects[x]) {
                        current.origin.x += 2
                        intersect = true
                    }
                }
                if !intersect {
                    current.origin.x -= 1
                    if current.origin.x <= unionRect.origin.x { intersect = true }
                }
            } while !intersect
            rects[i] = current
        }

        for i in rects.indices {
            var current = rects[i]
            var intersect: Bool
            repeat {
                intersect = false
                for x in rects.indices where x != i {
                    if NSIntersectsRect(current, rects[x]) {
                        current.origin.y -= 2
                        intersect = true
                    }
                }
                if !intersect {
                    current.origin.y += 1
                    if current.origin.y + current.size.height > unionRect.origin.y + unionRect.size.height {
                        intersect = true
                    }
                }
            } while !intersect
            rects[i] = current
        }

        unionRect = rects[0]
        for rect in rects { unionRect = NSUnionRect(rect, unionRect) }
        return (rects, unionRect)
    }

    /// The width, in pixels, of the picture of several views: the enclosing
    /// width, truncated, rounded up to a multiple of 4.
    public static func paddedWidth(_ width: CGFloat) -> Int {
        var padded = Int(width)
        if padded % 4 != 0 { padded += 4 }
        return padded / 4 * 4
    }

    /// Copies the picture of one view, `width` × `height` pixels, to its place
    /// `bounds` (relative to the enclosing rectangle, y up) in the picture of
    /// several views, `canvasWidth` × `canvasHeight` (rows from the top) and
    /// `canvasSize` bytes. A view that would start before the buffer is left
    /// out; rows that would end past it are not written. Returns the number of
    /// rows not written for that reason.
    @discardableResult
    public static func placeView(_ view: UnsafeRawPointer, width: Int, height: Int, samplesPerPixel: Int,
                                 bounds: NSRect, into canvas: UnsafeMutableRawPointer,
                                 canvasWidth: Int, canvasHeight: Int, canvasSamplesPerPixel: Int,
                                 bitsPerSample: Int, canvasSize: Int) -> Int {
        let bytesPerSample = bitsPerSample / 8
        let rowsFromTop = Int(Double(canvasHeight) - bounds.origin.y - Double(height))
        let start = bytesPerSample * canvasSamplesPerPixel * canvasWidth * rowsFromTop
            + Int(bounds.origin.x) * canvasSamplesPerPixel * bytesPerSample
        guard start >= 0 else { return 0 }
        var skipped = 0
        for y in 0..<max(height, 0) {
            let size = bytesPerSample * samplesPerPixel * width
            let rowOffset = bytesPerSample * y * canvasSamplesPerPixel * canvasWidth
            if start + rowOffset + size < canvasSize {
                memcpy(canvas + start + rowOffset, view + bytesPerSample * y * samplesPerPixel * width, size)
            } else {
                skipped += 1
            }
        }
        return skipped
    }

    // MARK: - Smart cropping

    /// The part of the view worth capturing: the image's useful rectangle
    /// (`usefulSize`, as rendered), centred where the view shows it, at least
    /// 256 pixels each way, inside the view's frame (`frameSize`). `origin` is
    /// the view's origin, already flipped and rotated back by the view's
    /// rotation. Returns the rectangle with its fields truncated, whether the
    /// frame cut the useful part off, and the shift of the image's centre that
    /// the cut causes, before rotation (zero when nothing was cut off): the
    /// caller turns it by the view's rotation.
    public static func smartCrop(usefulSize: NSSize, origin: NSPoint, frameSize: NSSize)
        -> (rect: NSRect, cut: Bool, shift: NSPoint) {
        var usefulRect = NSRect(origin: NSPoint(x: frameSize.width / 2 + origin.x - usefulSize.width / 2,
                                                y: frameSize.height / 2 - origin.y - usefulSize.height / 2),
                                size: usefulSize)
        let frameRect = NSRect(origin: .zero, size: frameSize)

        if usefulRect.size.width < 256 {
            usefulRect.origin.x -= CGFloat(Int32((256 - usefulRect.size.width) / 2))
            usefulRect.size.width = 256
        }
        if usefulRect.size.height < 256 {
            usefulRect.origin.y -= CGFloat(Int32((256 - usefulRect.size.height) / 2))
            usefulRect.size.height = 256
        }

        var smartRect = NSIntersectionRect(frameRect, usefulRect)

        var shift = NSPoint.zero
        let cut = !NSEqualRects(usefulRect, smartRect)
        if cut {
            shift.x = (usefulRect.origin.x - smartRect.origin.x) / 2
                + (usefulRect.origin.x + usefulRect.size.width - (smartRect.origin.x + smartRect.size.width)) / 2
            shift.y = -((usefulRect.origin.y - smartRect.origin.y) / 2
                + (usefulRect.origin.y + usefulRect.size.height - (smartRect.origin.y + smartRect.size.height)) / 2)
        }

        smartRect.origin.x = CGFloat(Int32(smartRect.origin.x))
        smartRect.origin.y = CGFloat(Int32(smartRect.origin.y))
        smartRect.size.width = CGFloat(Int32(smartRect.size.width))
        smartRect.size.height = CGFloat(Int32(smartRect.size.height))
        return (smartRect, cut, shift)
    }
}
