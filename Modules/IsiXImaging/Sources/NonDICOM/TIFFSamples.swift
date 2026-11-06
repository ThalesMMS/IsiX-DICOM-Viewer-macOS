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

/// What DCMPix makes of the scanlines libtiff reads: grey samples as 16-bit
/// values, colour as four bytes a pixel (alpha first), a colour page whose
/// pixels are all grey turned back into grey.
public enum TIFFSamples {
    /// A scanline of 16-bit RGB as ARGB (the high byte of each sample, alpha 0).
    /// Answers whether a pixel's samples differ.
    public static func argb(rgb16 row: UnsafePointer<UInt16>, pixels: Int, into argb: UnsafeMutablePointer<UInt8>) -> Bool {
        var colour = false
        for i in 0..<Swift.max(pixels, 0) {
            argb[i * 4] = 0
            argb[i * 4 + 1] = UInt8(truncatingIfNeeded: row[i * 3] / 256)
            argb[i * 4 + 2] = UInt8(truncatingIfNeeded: row[i * 3 + 1] / 256)
            argb[i * 4 + 3] = UInt8(truncatingIfNeeded: row[i * 3 + 2] / 256)
            if !(row[i * 3] == row[i * 3 + 1] && row[i * 3] == row[i * 3 + 2]) { colour = true }
        }
        return colour
    }

    /// A scanline of 8-bit RGB as ARGB (alpha 0). Answers whether a pixel's samples differ.
    public static func argb(rgb8 row: UnsafePointer<UInt8>, pixels: Int, into argb: UnsafeMutablePointer<UInt8>) -> Bool {
        var colour = false
        for i in 0..<Swift.max(pixels, 0) {
            argb[i * 4] = 0
            argb[i * 4 + 1] = row[i * 3]
            argb[i * 4 + 2] = row[i * 3 + 1]
            argb[i * 4 + 3] = row[i * 3 + 2]
            if !(row[i * 3] == row[i * 3 + 1] && row[i * 3] == row[i * 3 + 2]) { colour = true }
        }
        return colour
    }

    /// TIFFReadRGBAImage's RGBA turned into ARGB in place over `byteCount` bytes
    /// (alpha 0). Answers whether a pixel's colours differ.
    public static func argbInPlace(rgba bytes: UnsafeMutablePointer<UInt8>, byteCount: Int) -> Bool {
        var colour = false
        var i = 0
        while i < byteCount {
            bytes[i + 3] = bytes[i + 2]
            bytes[i + 2] = bytes[i + 1]
            bytes[i + 1] = bytes[i]
            if !(bytes[i + 1] == bytes[i + 2] && bytes[i + 2] == bytes[i + 3]) { colour = true }
            bytes[i] = 0
            i += 4
        }
        return colour
    }

    /// An ARGB image whose pixels are grey turned into 16-bit samples, in place:
    /// sample n is the red byte of pixel n, over the same bytes, front to back.
    public static func greyInPlace(argb buffer: UnsafeMutableRawPointer, byteCount: Int) {
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < byteCount {
            let value = Int16(bytes[i + 1])
            buffer.storeBytes(of: value, toByteOffset: (i / 4) * 2, as: Int16.self)
            i += 4
        }
    }

    /// A scanline of 8-bit grey as 16-bit samples.
    public static func samples(grey8 row: UnsafePointer<UInt8>, count: Int, into samples: UnsafeMutablePointer<Int16>) {
        for i in 0..<Swift.max(count, 0) { samples[i] = Int16(row[i]) }
    }

    /// The lowest and highest of a scanline of floats, folded into `range`.
    public static func fold(_ row: UnsafePointer<Float>, count: Int, into range: inout (min: Float, max: Float)) {
        for i in 0..<Swift.max(count, 0) {
            if row[i] < range.min { range.min = row[i] }
            if row[i] > range.max { range.max = row[i] }
        }
    }

    /// A scanline of floats scaled from `range` onto 0...16000 as 16-bit samples.
    public static func samples(float row: UnsafePointer<Float>, count: Int, range: (min: Float, max: Float), into samples: UnsafeMutablePointer<Int16>) {
        let difference = range.max - range.min
        for i in 0..<Swift.max(count, 0) {
            samples[i] = NonDICOMSamples.short(((row[i] - range.min) * 16000) / difference)
        }
    }
}
