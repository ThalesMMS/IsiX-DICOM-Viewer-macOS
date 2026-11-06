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
import Foundation

/// The small picture of an image in the browser and the series list
/// (-[DCMPix generateThumbnailImageWithWW:WL:]): the image shrunk to fit
/// `previewSize` by sampling, through a linear window computed in integers.
public enum ThumbnailIcon {
    /// The longest side of a thumbnail, in pixels.
    public static let previewSize: Float = 68

    /// How many image pixels a thumbnail pixel stands for.
    public static func ratio(width: Int, height: Int) -> Float {
        let across = Float(width) / previewSize, down = Float(height) / previewSize
        return across > down ? across : down
    }

    /// The size of the thumbnail of a `width` × `height` image.
    public static func size(width: Int, height: Int) -> (width: Int, height: Int) {
        let r = ratio(width: width, height: height)
        return (Int(ImagePlaneCoordinates.cInt(Float(width) / r)), Int(ImagePlaneCoordinates.cInt(Float(height) / r)))
    }

    /// Draws the thumbnail of `image` (floats, or ARGB bytes when `isRGB`)
    /// into `icon`, whose rows are `iconWidth` pixels (one byte a pixel, or
    /// three of four for colour), through the window `level`/`window`.
    ///
    /// The sampled rows and columns are computed once; the loop over the icon
    /// does only the window, so that it stays as fast as the C it replaces in a
    /// Debug build too.
    public static func draw(_ image: UnsafeRawPointer, into icon: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32,
                            iconWidth: Int, level: Int, window: Int, isRGB: Bool) {
        let minimum = level - window / 2
        var maximum = level + window / 2
        var difference = maximum - minimum
        if difference <= 0 {
            difference = 1
            maximum = minimum + 1
        }
        let r = ratio(width: Int(width), height: Int(height))
        let destWidth = ImagePlaneCoordinates.cLong(Double(Float(width) / r))
        let destHeight = ImagePlaneCoordinates.cLong(Double(Float(height) / r))
        guard destWidth > 0, destHeight > 0 else { return }
        if !isRGB && drawGreyVectors(image.assumingMemoryBound(to: Float.self), into: icon, width: Int(width), height: Int(height),
                                     iconWidth: iconWidth, iconSize: (destWidth, destHeight), ratio: r,
                                     minimum: minimum, maximum: maximum, difference: difference) {
            return
        }
        let lineWidth = Int(width) * (isRGB ? 4 : 1)
        // The image pixel each icon row and column samples: (long)(ratio * i).
        let rows = UnsafeMutableBufferPointer<Int>.allocate(capacity: destHeight)
        let columns = UnsafeMutableBufferPointer<Int>.allocate(capacity: destWidth)
        defer { rows.deallocate(); columns.deallocate() }
        for i in 0..<destHeight { rows[i] = lineWidth * ImagePlaneCoordinates.cLong(Double(r * Float(i))) }
        for j in 0..<destWidth { columns[j] = ImagePlaneCoordinates.cLong(Double(Float(j) * r)) * (isRGB ? 4 : 1) }

        if isRGB {
            let rgb = image.assumingMemoryBound(to: UInt8.self)
            let rowBytes = iconWidth * 4
            var i = 0
            while i < destHeight {
                let line = rgb + rows[i]
                var pixel = icon + rowBytes * i
                var j = 0
                while j < destWidth {
                    let source = line + columns[j]
                    var x = 1
                    while x < 4 {
                        var v = Int(source[x])
                        if v > maximum { v = maximum } else if v < minimum { v = minimum }
                        pixel.pointee = UInt8(truncatingIfNeeded: ((v &- minimum) &* 255) / difference)
                        pixel += 1
                        x += 1
                    }
                    j += 1
                }
                i += 1
            }
        } else {
            let grey = image.assumingMemoryBound(to: Float.self)
            // A float to a C long (fcvtzs): toward zero, saturated, NaN to 0.
            let top: Float = 9223372036854775807.0, bottom: Float = -9223372036854775808.0
            var i = 0
            while i < destHeight {
                let line = grey + rows[i]
                var pixel = icon + iconWidth * i
                var j = 0
                while j < destWidth {
                    let f = line[columns[j]]
                    var v: Int
                    if f.isNaN { v = 0 } else if f >= top { v = Int.max } else if f <= bottom { v = Int.min } else { v = Int(f) }
                    if v > maximum { v = maximum } else if v < minimum { v = minimum }
                    pixel.pointee = UInt8(truncatingIfNeeded: ((v &- minimum) &* 255) / difference)
                    pixel += 1
                    j += 1
                }
                i += 1
            }
        }
    }

    /// The grey thumbnail drawn with vectors (Accelerate), when they give the
    /// same bytes as the loop: every sample finite, the window and the image
    /// small enough for single precision to hold them exactly. Clamping the
    /// sample to the window and then truncating it is the same as truncating it
    /// and then clamping, the window's bounds being whole numbers; the integer
    /// division is a division in double precision, exact to well below the
    /// distance from a quotient to the next whole number. NO when the loop has
    /// to draw it.
    private static func drawGreyVectors(_ grey: UnsafePointer<Float>, into icon: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
                                        iconWidth: Int, iconSize: (width: Int, height: Int), ratio: Float,
                                        minimum: Int, maximum: Int, difference: Int) -> Bool {
        let exact = 1 << 24
        guard iconWidth == iconSize.width, width * height < exact, minimum > -exact, maximum < exact, difference < exact else {
            return false
        }
        let count = iconSize.width * iconSize.height
        let n = vDSP_Length(count)
        let longest = max(iconSize.width, iconSize.height)
        let ramp = UnsafeMutablePointer<Float>.allocate(capacity: longest)
        let across = UnsafeMutablePointer<Float>.allocate(capacity: iconSize.width)
        let down = UnsafeMutablePointer<Float>.allocate(capacity: iconSize.height)
        let indices = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let integers = UnsafeMutablePointer<Int32>.allocate(capacity: max(count, longest))
        let shades = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer {
            ramp.deallocate(); across.deallocate(); down.deallocate(); indices.deallocate(); samples.deallocate()
            integers.deallocate(); shades.deallocate()
        }

        // The pixel each icon pixel samples, (long)(ratio * i) down and
        // (long)(j * ratio) across, as the float index vDSP_vindex takes.
        var zero: Float = 0, one: Float = 1, r = ratio, lineWidth = Float(width)
        vDSP_vramp(&zero, &one, ramp, 1, vDSP_Length(longest))
        vDSP_vsmul(ramp, 1, &r, across, 1, vDSP_Length(iconSize.width))
        vDSP_vfix32(across, 1, integers, 1, vDSP_Length(iconSize.width))
        vDSP_vflt32(integers, 1, across, 1, vDSP_Length(iconSize.width))
        vDSP_vsmul(ramp, 1, &r, down, 1, vDSP_Length(iconSize.height))
        vDSP_vfix32(down, 1, integers, 1, vDSP_Length(iconSize.height))
        vDSP_vflt32(integers, 1, down, 1, vDSP_Length(iconSize.height))
        vDSP_vsmul(down, 1, &lineWidth, down, 1, vDSP_Length(iconSize.height))
        for i in 0..<iconSize.height {
            vDSP_vsadd(across, 1, down + i, indices + i * iconSize.width, 1, vDSP_Length(iconSize.width))
        }
        vDSP_vindex(grey, indices, 1, samples, 1, n)
        var sum: Float = 0
        vDSP_sve(samples, 1, &sum, n)
        guard sum.isFinite else { return false }

        var low = Float(minimum), high = Float(maximum)
        vDSP_vclip(samples, 1, &low, &high, samples, 1, n)
        vDSP_vfix32(samples, 1, integers, 1, n)
        vDSP_vflt32D(integers, 1, shades, 1, n)
        var shift = -Double(minimum), scale = 255.0, divisor = Double(difference)
        vDSP_vsaddD(shades, 1, &shift, shades, 1, n)
        vDSP_vsmulD(shades, 1, &scale, shades, 1, n)
        vDSP_vsdivD(shades, 1, &divisor, shades, 1, n)
        vDSP_vfixu8D(shades, 1, icon, 1, n)
        return true
    }

    /// The first `count` bytes of a thumbnail inverted (MONOCHROME1 polarity).
    public static func invert(_ icon: UnsafeMutablePointer<UInt8>, count: Int) {
        for i in 0..<max(count, 0) { icon[i] = 255 &- icon[i] }
    }
}
