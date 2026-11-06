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
import CoreGraphics
import Foundation

/// The mask of a brush ROI: a byte per pixel, nonzero where it is painted,
/// over a rectangle of the image whose corners it keeps.
///
/// The bytes are allocated with malloc and freed with free, by the ROI that
/// holds the mask: a mask is a value that names them, not their owner. The
/// arithmetic is the one the Objective-C ROI always did, `int` and `float`
/// conversions included, so that a stroke paints the same pixels.
public struct ROIBrushMask {
    public var buffer: UnsafeMutablePointer<UInt8>?
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var upLeftX: Int32 = 0
    public var upLeftY: Int32 = 0
    public var downRightX: Int32 = 0
    public var downRightY: Int32 = 0

    public init() {}

    /// A painted pixel this close to an edge is close enough: a mask is cut
    /// down only when more than this is empty on one side.
    static let cutoff: Int32 = 8

    // MARK: Painting

    /// What a stroke from `previous` to `point` with a round brush of
    /// `thickness` pixels does: the mask grows to hold the brush, keeping
    /// what it had, and the pixels the brush covers along the line are set to
    /// `value`. The old bytes are freed and replaced; `released` is called
    /// once they are, as the ROI forgets what it derived from them.
    public mutating func paint(from previous: CGPoint, to point: CGPoint, thickness: Float, value: UInt8, released: () -> Void) {
        let t = Double(thickness)
        var growDownX = true, growDownY = true
        var oldUpLeftX: Float = 0, oldUpLeftY: Float = 0

        if Double(upLeftX) > point.x - t {
            oldUpLeftX = Float(upLeftX)
            upLeftX = ROIBrushMask.int32(point.x - t - 4)
            growDownX = false
        }
        if Double(upLeftY) > point.y - t {
            oldUpLeftY = Float(upLeftY)
            upLeftY = ROIBrushMask.int32(point.y - t - 4)
            growDownY = false
        }
        if Double(downRightX) < point.x + t {
            downRightX = ROIBrushMask.int32(point.x + t + 4)
            growDownX = true
        }
        if Double(downRightY) < point.y + t {
            downRightY = ROIBrushMask.int32(point.y + t + 4)
            growDownY = true
        }

        let oldHeight = height, oldWidth = width
        var kept: UnsafeMutablePointer<UInt8>? = nil
        if let old = buffer {
            let count = Int(oldHeight) &* Int(oldWidth)
            kept = malloc(count)?.assumingMemoryBound(to: UInt8.self)
            if let kept { memcpy(kept, old, count) }
            free(old)
            buffer = nil
            released()
        }

        width = (downRightX &- upLeftX) &+ 1
        height = (downRightY &- upLeftY) &+ 1
        downRightX = width &+ upLeftX &- 1
        downRightY = height &+ upLeftY &- 1
        // The mask cannot get smaller.
        if width < oldWidth { width = oldWidth }
        if height < oldHeight { height = oldHeight }

        buffer = calloc(Int(width) &* Int(height), 1)?.assumingMemoryBound(to: UInt8.self)
        if let buffer {
            let w = Int(width), ow = Int(oldWidth)
            let source = kept
            if growDownX && growDownY {
                for j in 0..<Int(oldHeight) { for i in 0..<ow { buffer[i + j * w] = source![i + j * ow] } }
            }
            if !growDownX && growDownY {
                let offsetX = oldUpLeftX - Float(upLeftX)
                for j in 0..<Int(oldHeight) {
                    for i in 0..<ow { buffer[ROIBrushMask.int(Float(i) + offsetX + Float(j * w))] = source![i + j * ow] }
                }
            }
            if growDownX && !growDownY {
                let offsetY = oldUpLeftY - Float(upLeftY)
                for j in 0..<Int(oldHeight) {
                    for i in 0..<ow { buffer[ROIBrushMask.int(Float(i).addingProduct(Float(j) + offsetY, Float(w)))] = source![i + j * ow] }
                }
            }
            if !growDownX && !growDownY {
                let offsetY = oldUpLeftY - Float(upLeftY)
                let offsetX = oldUpLeftX - Float(upLeftX)
                for j in 0..<Int(oldHeight) {
                    for i in 0..<ow {
                        buffer[ROIBrushMask.int((Float(i) + offsetX).addingProduct(Float(j) + offsetY, Float(w)))] = source![i + j * ow]
                    }
                }
            }
        }
        free(kept)

        let radius = Int(ROIBrushMask.int32(Double(thickness)))
        let side = radius * 2
        var brush = [UInt8](repeating: 0, count: max(side * side, 0))
        if side > 0 { brush.withUnsafeMutableBufferPointer { ROIBrushMask.fillCircle($0.baseAddress!, width: Int32(side), value: 0xFF) } }
        let line = ROIBrushMask.line(from: (ROIBrushMask.int32(previous.x), ROIBrushMask.int32(previous.y)),
                                     to: (ROIBrushMask.int32(point.x), ROIBrushMask.int32(point.y)))
        guard let buffer else { return }
        let w = Int(width), left = Int(upLeftX), top = Int(upLeftY), right = Int(downRightX), bottom = Int(downRightY)
        for (xx, yy) in line {
            for j in -radius..<radius {
                for i in -radius..<radius {
                    // The column is tested with j and written with i, as it always was.
                    if xx + j > left && xx + j < right && yy + i > top && yy + i < bottom
                        && brush[(j + radius) + (i + radius) * side] != 0 {
                        buffer[i + (xx - left) + w * (j + (yy - top))] = value
                    }
                }
            }
        }
    }

    /// The pixels of the line from `a` to `b`, both included, by Bresenham's
    /// algorithm, in the order the brush paints them.
    public static func line(from a: (Int32, Int32), to b: (Int32, Int32)) -> [(Int, Int)] {
        var (ax, ay) = (Int(a.0), Int(a.1))
        let (bx, by) = (Int(b.0), Int(b.1))
        var dX = abs(bx - ax), dY = abs(by - ay)
        let xIncrement = ax > bx ? -1 : 1, yIncrement = ay > by ? -1 : 1
        var points: [(Int, Int)] = []
        points.reserveCapacity(max(dX, dY) + 1)
        if dX >= dY {
            let right = dY << 1, up = right - (dX << 1)
            var decision = right - dX
            while dX >= 0 {
                points.append((ax, ay))
                if decision > 0 { ax += xIncrement; ay += yIncrement; decision += up } else { ax += xIncrement; decision += right }
                dX -= 1
            }
        } else {
            let right = dX << 1, up = right - (dY << 1)
            var decision = right - dY
            while dY >= 0 {
                points.append((ax, ay))
                if decision > 0 { ax += xIncrement; ay += yIncrement; decision += up } else { ay += yIncrement; decision += right }
                dY -= 1
            }
        }
        return points
    }

    /// Sets to `value` the disc of diameter `width` centred in the square `buffer`.
    public static func fillCircle(_ buffer: UnsafeMutablePointer<UInt8>, width: Int32, value: UInt8) {
        let w = Int(width)
        let radiusSquared = (w * w) / 4
        let radius = w / 2
        for x in 0..<max(radius, 0) {
            let xSquared = x * x
            for y in 0..<radius {
                guard xSquared + y * y < radiusSquared else { break }
                buffer[radius + x + (radius + y) * w] = value
                buffer[radius - x + (radius + y) * w] = value
                buffer[radius + x + (radius - y) * w] = value
                buffer[radius - x + (radius - y) * w] = value
            }
        }
    }

    // MARK: Size

    /// Cuts the mask down to its painted pixels and a margin of two, when
    /// more than `cutoff` pixels are empty on a side. Answers true when
    /// nothing is painted (or there are no bytes), false otherwise, as
    /// -reduceTextureIfPossible did; `replaced` tells whether the bytes were.
    public mutating func reduceIfPossible() -> (empty: Bool, replaced: Bool) {
        guard let old = buffer else { return (false, false) }
        var minX = width, maxX: Int32 = 0, minY = height, maxY: Int32 = 0
        var p = old
        for y in 0..<max(height, 0) {
            for x in 0..<max(width, 0) {
                if p.pointee != 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                p += 1
            }
        }
        if minX > maxX || minY > maxY { return (true, false) }

        let cutoff = ROIBrushMask.cutoff
        guard minX > cutoff || maxX < width - cutoff || minY > cutoff || maxY < height - cutoff else { return (false, false) }
        minX -= 2; minY -= 2; maxX += 2; maxY += 2
        if minX < 0 { minX = 0 }
        if minY < 0 { minY = 0 }
        if maxX - minX > width { maxX = width + 1 + minX }
        if maxY - minY > height { maxY = height + 1 + minY }

        var offsetY = minY, offsetX = minX
        let oldWidth = width, oldHeight = height
        width = maxX - minX + 1
        height = maxY - minY + 1
        if width > oldWidth { width = oldWidth; offsetX = 0 }
        if oldWidth < width + offsetX { width = oldWidth; offsetX = 0 }
        if height > oldHeight { height = oldHeight; offsetY = 0 }

        guard let reduced = calloc((1 + Int(width)) * (1 + Int(height)), 1)?.assumingMemoryBound(to: UInt8.self) else {
            width = oldWidth
            height = oldHeight
            return (false, false)
        }
        for y in 0..<Int(height) where y + Int(offsetY) < Int(oldHeight) {
            memcpy(reduced + y * Int(width), old + Int(offsetX) + (y + Int(offsetY)) * Int(oldWidth), Int(width))
        }
        free(old)
        buffer = reduced
        upLeftX += offsetX
        upLeftY += offsetY
        downRightX = upLeftX + width - 1
        downRightY = upLeftY + height - 1
        return (false, true)
    }

    /// A copy of `width` × `height` bytes with `margin` empty pixels around
    /// them, allocated with calloc; nil when it cannot be.
    public static func addingMargin(_ margin: Int32, to buffer: UnsafePointer<UInt8>?, width: Int32, height: Int32) -> UnsafeMutablePointer<UInt8>? {
        let m = Int(margin), w = Int(width), h = Int(height)
        let newWidth = w + 2 * m, newHeight = h + 2 * m
        guard let result = calloc(newWidth * newHeight, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var target = result + max(m, 0) * newWidth
        var source = buffer
        for _ in 0..<max(h, 0) {
            target += m
            if let s = source { memcpy(target, s, w) }
            target += w + m
            source = source.map { $0 + w }
        }
        return result
    }

    /// The outline drawn around a selected brush: with a pixel of margin all
    /// around, the mask's pixels dilated by one less the mask itself;
    /// allocated with calloc, nil when it cannot be.
    public static func selectionOutline(of buffer: UnsafePointer<UInt8>?, width: Int32, height: Int32) -> UnsafeMutablePointer<UInt8>? {
        let margin: Int32 = 1
        guard let outline = addingMargin(margin, to: buffer, width: width, height: height) else { return nil }
        let w = Int(width + 2 * margin), h = Int(height + 2 * margin)
        let count = w * h
        guard let painted = malloc(count)?.assumingMemoryBound(to: UInt8.self) else { return outline }
        memcpy(painted, outline, count)

        let side = Int(2 * margin + 1)
        if let kernel = calloc(side * side, 1)?.assumingMemoryBound(to: UInt8.self) {
            if let dilated = malloc(count) {
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(outline), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var destination = vImage_Buffer(data: dilated, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                _ = vImageDilate_Planar8(&source, &destination, 0, 0, kernel, vImagePixelCount(side), vImagePixelCount(side),
                                         vImage_Flags(kvImageDoNotTile))
                memcpy(outline, dilated, count)
                free(dilated)
            }
            free(kernel)
        }
        for i in 0..<count where painted[i] != 0 { outline[i] = 0 }
        free(painted)
        return outline
    }

    /// The mask with `margin` empty pixels around it.
    public mutating func addMargin(_ margin: Int32) {
        let wider = ROIBrushMask.addingMargin(margin, to: buffer, width: width, height: height)
        width += 2 * margin
        height += 2 * margin
        free(buffer)
        buffer = wider
        downRightX += margin
        downRightY += margin
        upLeftX -= margin
        upLeftY -= margin
    }

    /// The union of this mask and `other`, over the rectangle that holds both,
    /// then cut down as `reduceIfPossible()` does.
    public mutating func merge(with other: ROIBrushMask) {
        let left = min(upLeftX, other.upLeftX), right = max(downRightX, other.downRightX)
        let top = min(upLeftY, other.upLeftY), bottom = max(downRightY, other.downRightY)
        // The width does not count the last column, as it never did.
        let newWidth = Int(right) - Int(left), newHeight = Int(bottom) - Int(top)
        let merged = calloc(max(newWidth * newHeight, 0), 1)?.assumingMemoryBound(to: UInt8.self)
        func contains(_ mask: ROIBrushMask, _ x: Double, _ y: Double) -> Bool {
            x >= Double(mask.upLeftX) && y >= Double(mask.upLeftY)
                && x < Double(mask.upLeftX) + Double(mask.width) && y < Double(mask.upLeftY) + Double(mask.height)
        }
        if let merged {
            for y in 0..<max(newHeight, 0) {
                for x in 0..<max(newWidth, 0) {
                    let px = Double(x + Int(left)), py = Double(y + Int(top))
                    for mask in [self, other] where contains(mask, px, py) {
                        let v = mask.buffer![x + Int(left) - Int(mask.upLeftX) + Int(mask.width) * (y + Int(top) - Int(mask.upLeftY))]
                        if v != 0 { merged[x + y * newWidth] = v }
                    }
                }
            }
        }
        upLeftX = left
        downRightX = right
        upLeftY = top
        downRightY = bottom
        width = Int32(truncatingIfNeeded: newWidth)
        height = Int32(truncatingIfNeeded: newHeight)
        free(buffer)
        buffer = merged
        _ = reduceIfPossible()
    }

    /// `width` × `height` bytes resampled to `newWidth` × `newHeight` with
    /// vImage's high-quality filter, then made a mask again (0 or 255 at
    /// 127); allocated with malloc.
    public static func rescaled(_ buffer: UnsafeMutablePointer<UInt8>?, width: Int32, height: Int32,
                                to newWidth: Int32, _ newHeight: Int32) -> UnsafeMutablePointer<UInt8>? {
        let count = Int(newWidth) &* Int(newHeight)
        let scaled = malloc(count)?.assumingMemoryBound(to: UInt8.self)
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(buffer), height: vImagePixelCount(UInt32(bitPattern: height)),
                                   width: vImagePixelCount(UInt32(bitPattern: width)), rowBytes: Int(width))
        var destination = vImage_Buffer(data: UnsafeMutableRawPointer(scaled), height: vImagePixelCount(UInt32(bitPattern: newHeight)),
                                        width: vImagePixelCount(UInt32(bitPattern: newWidth)), rowBytes: Int(newWidth))
        _ = vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        if let scaled {
            for x in 0..<Int(max(newWidth, 0)) {
                for y in 0..<Int(max(newHeight, 0)) {
                    scaled[y * Int(newWidth) + x] = scaled[y * Int(newWidth) + x] < 127 ? 0 : 0xFF
                }
            }
        }
        return scaled
    }

    // MARK: Conversions

    /// `(int) value` as the Objective-C ROI converted a coordinate: toward
    /// zero, saturating, and 0 for NaN, as arm64 converts.
    public static func int32(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= 2147483647 { return .max }
        if value <= -2147483648 { return .min }
        return Int32(value.rounded(.towardZero))
    }

    /// `(long) value` of a float, as above.
    static func int(_ value: Float) -> Int {
        if value.isNaN { return 0 }
        if value >= 9.2233720368547758e18 { return .max }
        if value <= -9.2233720368547758e18 { return .min }
        return Int(value.rounded(.towardZero))
    }
}

/// The pixels a layer ROI draws: its image's samples as ARGB bytes, the alpha
/// first, coloured when the layer is.
public enum ROILayerPixels {
    /// ARGB bytes, allocated with malloc, from `height` rows of `bytesPerRow`
    /// bytes of 8-bit samples, `samplesPerPixel` of them a pixel: grey and RGB
    /// are given an opaque alpha, RGBA has its alpha moved first. A layer
    /// whose opacity is not constant gets the mean of its pixel's components,
    /// times `opacity`, for alpha instead. Answers the bytes and their row
    /// length.
    public static func argb(from samples: UnsafePointer<UInt8>, height: Int, bytesPerRow: Int, samplesPerPixel: Int,
                            opacity: Float, constantOpacity: Bool) -> (bytes: UnsafeMutablePointer<UInt8>?, bytesPerRow: Int) {
        var rowBytes = Int(Int32(truncatingIfNeeded: bytesPerRow))
        var bytes: UnsafeMutablePointer<UInt8>?
        if samplesPerPixel == 1 || samplesPerPixel == 3 {
            rowBytes = rowBytes / samplesPerPixel * 4
            var remaining = Int32(truncatingIfNeeded: height * rowBytes / 4)
            bytes = malloc(rowBytes * height)?.assumingMemoryBound(to: UInt8.self)
            var target = bytes, source = samples
            while remaining > 0, let t = target {
                if samplesPerPixel == 1 {
                    t[0] = source[0]; t[1] = source[0]; t[2] = source[0]; source += 1
                } else {
                    t[0] = source[0]; t[1] = source[1]; t[2] = source[2]; source += 3
                }
                t[3] = 255
                target = t + 4
                remaining -= 1
            }
        } else {
            bytes = malloc(rowBytes * height)?.assumingMemoryBound(to: UInt8.self)
            if let bytes { memcpy(bytes, samples, bytesPerRow * height) }
        }
        guard let bytes else { return (nil, rowBytes) }
        var p = bytes
        for _ in 0..<(rowBytes / 4 * height) {
            let r = p[0], g = p[1], b = p[2], a = p[3]
            if constantOpacity {
                p[0] = a
            } else {
                p[0] = byte(Float((Int32(r) + Int32(g) + Int32(b)) / 3) * opacity)
            }
            p[1] = r; p[2] = g; p[3] = b
            p += 4
        }
        return (bytes, rowBytes)
    }

    /// Multiplies the ARGB bytes by a colour, and their alpha by `opacity`.
    public static func colorize(_ bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                red: Double, green: Double, blue: Double, opacity: Float) {
        var redTable = [UInt8](repeating: 0, count: 256), greenTable = redTable, blueTable = redTable, alphaTable = redTable
        for i in 0..<256 {
            redTable[i] = byte(Double(Float(i)) * red)
            greenTable[i] = byte(Double(Float(i)) * green)
            blueTable[i] = byte(Double(Float(i)) * blue)
            alphaTable[i] = byte(Float(i) * opacity)
        }
        var buffer = vImage_Buffer(data: UnsafeMutableRawPointer(bytes), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
        var source = buffer
        _ = vImageTableLookUp_ARGB8888(&source, &buffer, alphaTable, redTable, greenTable, blueTable, vImage_Flags(0))
    }

    /// `(unsigned char) value`: the low byte of the value converted to int.
    static func byte(_ value: Float) -> UInt8 { UInt8(truncatingIfNeeded: ROIBrushMask.int32(Double(value))) }
    static func byte(_ value: Double) -> UInt8 { UInt8(truncatingIfNeeded: ROIBrushMask.int32(value)) }
}
