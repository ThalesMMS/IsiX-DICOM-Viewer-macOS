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
import CoreGraphics
import Foundation

/// The float images DCMPix renders turned, scaled and flipped, merges and
/// copies into one another (-renderWithRotation:..., -mergeWithDCMPix:offset:,
/// -drawImage:inImage:offset:background:transparency:): the buffer work, with
/// vImage as the Objective-C did it.
public enum ImageRendering {
    /// Copies `source` into `destination` with its first pixel at `offset`
    /// (truncated to whole pixels), clipped to the destination. Opaque, the
    /// destination is first filled with `background`; transparent, only the
    /// source pixels more than 900 above the background are copied.
    public static func draw(_ source: vImage_Buffer, into destination: vImage_Buffer, offset: CGPoint, background: Float, transparency: Bool) {
        let dstData = destination.data.assumingMemoryBound(to: Float.self)
        let srcData = source.data.assumingMemoryBound(to: Float.self)
        if !transparency {
            var i = Int32(truncatingIfNeeded: destination.height * destination.width)
            var f = dstData
            while i > 0 {
                i -= 1
                f.pointee = background
                f += 1
            }
        }
        let ox = ImagePlaneCoordinates.cInt(Double(offset.x))
        let oy = ImagePlaneCoordinates.cInt(Double(offset.y))
        let dstRect = NSRect(x: 0, y: 0, width: Double(destination.width), height: Double(destination.height))
        let srcRect = NSRect(x: Double(ox), y: Double(oy), width: Double(source.width), height: Double(source.height))
        let union = NSIntersectionRect(dstRect, srcRect)
        let y1 = Int(ImagePlaneCoordinates.cInt(Double(union.origin.y)))
        let y2 = Int(ImagePlaneCoordinates.cInt(Double(union.origin.y + union.size.height)))
        let x1 = Int(ImagePlaneCoordinates.cInt(Double(union.origin.x)))
        let x2 = Int(ImagePlaneCoordinates.cInt(Double(union.origin.x + union.size.width)))
        let dstWidth = Int(destination.width), srcWidth = Int(source.width)
        let left = Int(ox), top = Int(oy)
        if !transparency {
            let lineBytes = (x2 - x1) * MemoryLayout<Float>.size
            var y = y1
            while y < y2 {
                memcpy(dstData + (y * dstWidth + x1), srcData + ((y - top) * srcWidth + (x1 - left)), lineBytes)
                y += 1
            }
        } else {
            var y = y1
            while y < y2 {
                var x = x1
                while x < x2 {
                    let s = srcData[(y - top) * srcWidth + (x - left)]
                    if ImagePlaneCoordinates.cInt(s - background) > 900 {
                        dstData[y * dstWidth + x] = s
                    }
                    x += 1
                }
                y += 1
            }
        }
    }

    /// Brings `count` values of one window to another: `wl` added, then
    /// scaled by `ww`.
    public static func adaptWindow(_ values: UnsafeMutablePointer<Float>, count: Int, levelShift wl: Float, widthScale ww: Float) {
        var p = values
        var i = count
        while i > 0 {
            i -= 1
            p.pointee += wl
            p.pointee *= ww
            p += 1
        }
    }

    /// A shutter rectangle as the rendering uses it: each side rounded to a
    /// whole pixel (in single precision) and the rectangle kept in the image.
    public static func shutterRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        var r = rect
        r.origin.y = Double(roundf(Float(r.origin.y)))
        r.origin.x = Double(roundf(Float(r.origin.x)))
        r.size.width = Double(roundf(Float(r.size.width)))
        r.size.height = Double(roundf(Float(r.size.height)))
        if r.origin.x < 0 { r.size.width += r.origin.x; r.origin.x = 0 }
        if r.origin.y < 0 { r.size.height += r.origin.y; r.origin.y = 0 }
        if r.origin.x + r.size.width > Double(width) { r.size.width = Double(width) - r.origin.x }
        if r.origin.y + r.size.height > Double(height) { r.size.height = Double(height) - r.origin.y }
        return r
    }

    /// A copy of `image` that keeps only `rect` (a rectangle from
    /// `shutterRect`) and fills the rest with `fill`; nil when it cannot be allocated.
    public static func shuttered(_ image: UnsafePointer<Float>, width: Int, height: Int, rect: CGRect, fill: Float) -> UnsafeMutablePointer<Float>? {
        guard let copy = malloc(width * height * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { return nil }
        var i = width * height
        var d = copy
        while i > 0 {
            i -= 1
            d.pointee = fill
            d += 1
        }
        let first = ImagePlaneCoordinates.cLong(Double(rect.origin.x).addingProduct(Double(rect.origin.y), Double(width)))
        var s = image + first
        d = copy + first
        let rowBytes = Int(ImagePlaneCoordinates.cUnsignedLong(Double(rect.size.width) * 4))
        var rows = ImagePlaneCoordinates.cLong(Double(rect.size.height))
        while rows > 0 {
            rows -= 1
            memcpy(d, s, rowBytes)
            d += width
            s += width
        }
        return copy
    }

    /// An image flipped, then scaled to `scaledWidth` by `scaledHeight` and
    /// turned by `rotation` degrees (the turn reversed by each flip) into
    /// `outputWidth` by `outputHeight`, with vImage's high-quality resampling.
    /// A turn of a multiple of 90° keeps vImage's own edge; any other fills it
    /// with `background` plus `backgroundOffset`. `source` is freed when
    /// `ownsSource`; the result is allocated, or nil when an allocation failed.
    public static func rotatedImage(_ source: UnsafeMutableRawPointer?, ownsSource: Bool, width: Int, height: Int,
                                    xFlipped: Bool, yFlipped: Bool, scaledWidth: UInt, scaledHeight: UInt,
                                    rotation: Float, outputWidth: Int32, outputHeight: Int32,
                                    background: Float, backgroundOffset: Float) -> UnsafeMutableRawPointer? {
        var rot = rotation * ImagePlaneCoordinates.degreesToRadians
        var src = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var owned = ownsSource
        var dst = vImage_Buffer()

        // Flipping X-Y
        for (flip, horizontal) in [(xFlipped, true), (yFlipped, false)] where flip {
            dst = src
            dst.data = malloc(Int(dst.height) * dst.rowBytes)
            if dst.data != nil && src.data != nil {
                if horizontal {
                    vImageHorizontalReflect_PlanarF(&src, &dst, 0)
                } else {
                    vImageVerticalReflect_PlanarF(&src, &dst, 0)
                }
            }
            if owned { free(src.data) }
            if dst.data == nil { return nil }
            src = dst
            owned = true
            rot = Float(Double(rot) * -1.0)
        }

        // Scaling
        dst.height = scaledHeight
        dst.width = scaledWidth
        dst.rowBytes = Int(dst.width) * 4
        dst.data = malloc(Int(dst.height) * dst.rowBytes)
        if dst.data != nil && src.data != nil {
            vImageScale_PlanarF(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        }

        // Rotation
        if owned { free(src.data) }
        if dst.data == nil { return nil }
        src = dst

        dst.height = vImagePixelCount(bitPattern: Int(outputHeight))
        dst.width = vImagePixelCount(bitPattern: Int(outputWidth))
        dst.rowBytes = Int(outputWidth) * 4
        dst.data = malloc(Int(dst.height) * dst.rowBytes)
        if dst.data != nil && src.data != nil {
            let v = ImagePlaneCoordinates.cInt(rotation)
            if v % 90 == 0 {
                vImageRotate_PlanarF(&src, &dst, nil, -rot, background, vImage_Flags(kvImageHighQualityResampling))
            } else {
                vImageRotate_PlanarF(&src, &dst, nil, -rot, background + backgroundOffset,
                                     vImage_Flags(kvImageHighQualityResampling + kvImageBackgroundColorFill))
            }
        }
        free(src.data)
        return dst.data
    }
}
