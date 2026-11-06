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

import CoreGraphics
import Foundation

/// A brush ROI's texture placed on an image: `bytes` (nonzero where painted)
/// of `width` x `height`, its upper-left pixel at (`originX`, `originY`).
public struct ROITexture {
    public var bytes: UnsafePointer<UInt8>?
    public var width: Int
    public var height: Int
    public var originX: Int
    public var originY: Int

    public init(bytes: UnsafePointer<UInt8>?, width: Int, height: Int, originX: Int, originY: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
    }

    @inline(__always)
    func painted(column x: Int, row y: Int) -> Bool {
        bytes![(y - originY) * width + (x - originX)] != 0
    }

    /// Whether the image point `point` is painted (-[DCMPix isInROI::] for a
    /// brush): the texel that contains it, column x covering x..<x + 1 of the
    /// image as the brush is drawn and masked.
    public func contains(_ point: CGPoint) -> Bool {
        guard let bytes,
              point.x >= Double(originX), point.x < Double(originX + width),
              point.y >= Double(originY), point.y < Double(originY + height) else { return false }
        let column = Int((point.x - Double(originX)).rounded(.down))
        let row = Int((point.y - Double(originY)).rounded(.down))
        return bytes[row * width + column] != 0
    }
}

/// What DCMPix reads and writes of an image under a brush ROI.
public enum ROIBrushRaster {
    /// The values and locations of the painted pixels on the image, row by
    /// row, into buffers of `width` x `height` of the texture; an ARGB pixel
    /// counts as the mean of its three colours. Answers how many were written.
    public static func sample(_ texture: ROITexture, image: UnsafePointer<Float>, imageWidth: Int, imageHeight: Int, isRGB: Bool,
                              values: UnsafeMutablePointer<Float>, locations: UnsafeMutablePointer<Float>?) -> Int {
        guard let bytes = texture.bytes else { return 0 }
        let pixels = UnsafeRawPointer(image).assumingMemoryBound(to: UInt8.self)
        var count = 0
        var y = 0
        while y < texture.height {
            defer { y += 1 }
            let yy = y + texture.originY
            var x = 0
            while x < texture.width {
                defer { x += 1 }
                if bytes[x + y * texture.width] == 0 { continue }
                let xx = x + texture.originX
                guard xx >= 0 && xx < imageWidth && yy >= 0 && yy < imageHeight else { continue }
                if isRGB {
                    let pixel = pixels + (yy * imageWidth + xx) * 4
                    values[count] = Float(Double(Int(pixel[1]) + Int(pixel[2]) + Int(pixel[3])) / 3.0)
                } else {
                    values[count] = image[yy * imageWidth + xx]
                }
                if let locations {
                    locations[count * 2] = Float(xx)
                    locations[count * 2 + 1] = Float(yy)
                }
                count += 1
            }
        }
        return count
    }

    /// The calcium scoring cofactor of the painted pixels of a grey image: 4,
    /// 3 or 2 when more than two exceed 400, 300 or 200, else 1
    /// (-[DCMPix calciumCofactorForROI:threshold:]).
    public static func calciumCofactor(_ texture: ROITexture, image: UnsafePointer<Float>, imageWidth: Int, imageHeight: Int,
                                       isRGB: Bool, threshold: Int32) -> Int32 {
        var above200 = 0, above300 = 0, above400 = 0
        if let bytes = texture.bytes, !isRGB {
            var y = 0
            while y < texture.height {
                defer { y += 1 }
                var x = 0
                while x < texture.width {
                    defer { x += 1 }
                    if bytes[y * texture.width + x] == 0 { continue }
                    let xx = x + texture.originX, yy = y + texture.originY
                    guard xx >= 0 && xx < imageWidth && yy >= 0 && yy < imageHeight else { continue }
                    let value = image[yy * imageWidth + xx]
                    if value > 200 { above200 += 1 }
                    if value > 300 { above300 += 1 }
                    if value > 400 { above400 += 1 }
                }
            }
        }
        _ = threshold  // counted by the Objective-C too, never used for the result
        if above400 > 2 { return 4 }
        if above300 > 2 { return 3 }
        if above200 > 2 { return 2 }
        return 1
    }

    /// Fills the painted pixels of an image (`outside` false) or the others
    /// within the clip rectangle (`outside` true), as -[DCMPix fillROI:...]
    /// did for a brush. Inside, only the part of the texture on the image
    /// (`inside`: column, row, width, height) is walked and a pixel is
    /// written within the clip only; with `restore`, it comes back from the
    /// copy. Outside always sets or adds `value`.
    public static func fill(_ texture: ROITexture, inside: (x: Int, y: Int, width: Int, height: Int),
                            image: UnsafeMutablePointer<Float>, imageWidth: Int, isRGB: Bool,
                            clipMin: CGPoint, clipMax: CGPoint, minimum: Float, maximum: Float, value: Float,
                            addition: Bool, outside: Bool, restore: UnsafeMutablePointer<Float>?) {
        // The pixels are walked in runs along a row, each pixel tested on its
        // own as before: the same pixels change, with the same values.
        @inline(__always) func paint(_ index: Int, _ count: Int) {
            ROIPlane.paint(image, isRGB: isRGB, from: index, step: 1, count: count,
                           minimum: minimum, maximum: maximum, value: value, addition: addition)
        }

        if !outside {
            guard let bytes = texture.bytes else { return }
            // The C tested x >= clipMin.x && x < clipMax.x on each pixel: the
            // columns from ceil(clipMin.x) to before ceil(clipMax.x).
            let (clipX0, clipX1) = span(clipMin.x, clipMax.x), (clipY0, clipY1) = span(clipMin.y, clipMax.y)
            var x0 = inside.x, x1 = inside.x + (inside.width > 0 ? inside.width : 0)
            var y0 = inside.y, y1 = inside.y + (inside.height > 0 ? inside.height : 0)
            if clipX0 > x0 { x0 = clipX0 }
            if clipX1 < x1 { x1 = clipX1 }
            if clipY0 > y0 { y0 = clipY0 }
            if clipY1 < y1 { y1 = clipY1 }
            guard x0 < x1, y0 < y1 else { return }
            var y = y0
            while y < y1 {
                defer { y += 1 }
                let base = (y - texture.originY) * texture.width - texture.originX
                var x = x0
                while x < x1 {
                    x = run(bytes, base, from: x, to: x1, painted: false)
                    if x == x1 { break }
                    let start = x
                    x = run(bytes, base, from: x, to: x1, painted: true)
                    let index = start + y * imageWidth, count = x - start
                    guard let restore else {
                        paint(index, count)
                        continue
                    }
                    if isRGB {
                        let source = UnsafeMutableRawPointer(restore).assumingMemoryBound(to: UInt8.self) + index * 4
                        let pixel = UnsafeMutableRawPointer(image).assumingMemoryBound(to: UInt8.self) + index * 4
                        var k = 0
                        while k < count {
                            pixel[k * 4 + 1] = source[k * 4 + 1]
                            pixel[k * 4 + 2] = source[k * 4 + 2]
                            pixel[k * 4 + 3] = source[k * 4 + 3]
                            k += 1
                        }
                    } else {
                        (image + index).update(from: restore + index, count: count)
                    }
                }
            }
            return
        }

        // Outside: every pixel of the clip rectangle off the painted ones, the
        // rows and columns counted from the clip corner truncated to an integer
        // while below the far corner, as the C loops did.
        let x0 = ROIRasterConversion.long(Double(clipMin.x)), y0 = ROIRasterConversion.long(Double(clipMin.y))
        let x1 = end(from: x0, below: clipMax.x), y1 = end(from: y0, below: clipMax.y)
        guard x0 < x1, y0 < y1 else { return }
        let textureX0 = texture.originX, textureX1 = texture.originX + texture.width
        let onX0 = x0 > textureX0 ? x0 : textureX0, onX1 = x1 < textureX1 ? x1 : textureX1
        let beforeEnd = x1 < textureX0 ? x1 : textureX0, afterStart = x0 > textureX1 ? x0 : textureX1
        var y = y0
        while y < y1 {
            defer { y += 1 }
            let row = y * imageWidth
            guard let bytes = texture.bytes, y >= texture.originY && y < texture.originY + texture.height, onX0 < onX1 else {
                paint(row + x0, x1 - x0)
                continue
            }
            if x0 < beforeEnd { paint(row + x0, beforeEnd - x0) }
            let base = (y - texture.originY) * texture.width - texture.originX
            var x = onX0
            while x < onX1 {
                x = run(bytes, base, from: x, to: onX1, painted: true)
                let start = x
                x = run(bytes, base, from: x, to: onX1, painted: false)
                if x > start { paint(row + start, x - start) }
            }
            if afterStart < x1 { paint(row + afterStart, x1 - afterStart) }
        }
    }

    /// The end of the run of painted (or unpainted) texels of a row from column
    /// `from`, before `to`; `base` is the row's offset in the texture less its
    /// first column. Four texels a turn while they all match: without
    /// optimization (Debug) the loop costs more than the test.
    @inline(__always)
    private static func run(_ bytes: UnsafePointer<UInt8>, _ base: Int, from: Int, to end: Int, painted: Bool) -> Int {
        var t = base &+ from
        let last = base &+ end
        if painted {
            while last &- t >= 4 {
                if bytes[t] == 0 { return t &- base }
                if bytes[t &+ 1] == 0 { return t &+ 1 &- base }
                if bytes[t &+ 2] == 0 { return t &+ 2 &- base }
                if bytes[t &+ 3] == 0 { return t &+ 3 &- base }
                t &+= 4
            }
            while t < last {
                if bytes[t] == 0 { return t &- base }
                t &+= 1
            }
        } else {
            while last &- t >= 4 {
                if bytes[t] != 0 { return t &- base }
                if bytes[t &+ 1] != 0 { return t &+ 1 &- base }
                if bytes[t &+ 2] != 0 { return t &+ 2 &- base }
                if bytes[t &+ 3] != 0 { return t &+ 3 &- base }
                t &+= 4
            }
            while t < last {
                if bytes[t] != 0 { return t &- base }
                t &+= 1
            }
        }
        return end
    }

    /// The integers x with `lower <= Double(x) < upper`, as a half-open range.
    @inline(__always)
    private static func span(_ lower: CGFloat, _ upper: CGFloat) -> (Int, Int) {
        guard lower < upper else { return (0, 0) }
        return (ROIRasterConversion.long(Double(lower).rounded(.up)), ROIRasterConversion.long(Double(upper).rounded(.up)))
    }

    /// The first integer from `start` on that is not below `upper` (`start` if none is).
    @inline(__always)
    private static func end(from start: Int, below upper: CGFloat) -> Int {
        guard Double(start) < Double(upper) else { return start }
        return Swift.max(start, ROIRasterConversion.long(Double(upper).rounded(.up)))
    }
}
