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

/// The 8-bit picture of an image under its window: what the viewer draws.
public enum WindowRendering {
    /// Grey values through a straight window: level - width / 2 is black,
    /// level + width / 2 white.
    public static func linear(_ pixels: UnsafePointer<Float>, into picture: UnsafeMutablePointer<UInt8>,
                              width: Int, height: Int, level: Float, window: Float) {
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        var destination = vImage_Buffer(data: picture, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: width)
        let low = level - window / 2, high = level + window / 2
        vImageConvert_PlanarFtoPlanar8(&source, &destination, high, low, vImage_Flags(kvImageNoFlags))
    }

    /// Grey values through a transfer function: the window maps onto the
    /// function's 4096 entries, each between 0 and 1, which give the shade.
    /// The rows are shared out among `threads` workers.
    public static func throughTable(_ pixels: UnsafePointer<Float>, into picture: UnsafeMutablePointer<UInt8>,
                                    width: Int, height: Int, level: Float, window: Float,
                                    table: UnsafePointer<Float>, threads: Int) {
        // In double precision, then rounded to float, as the Objective-C worker did.
        let from = Float(Double(level) - Double(window) / 2.0)
        let ratio = Float(4096.0 / Double(window))
        let workers = max(threads, 1)
        let buffers = Buffers(pixels: pixels, picture: picture, table: table)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            // Every row belongs to one worker.
            let start = worker * height / workers, end = (worker + 1) * height / workers
            let table = buffers.table
            var source = buffers.pixels + start * width, destination = buffers.picture + start * width
            var left = (end - start) * width
            while left > 0 {
                var value = cInt(ratio * (source.pointee - from))
                if value < 0 { value = 0 } else if value >= 4095 { value = 4095 }
                destination.pointee = shade(255.0 * Double(table[Int(value)]))
                source += 1
                destination += 1
                left &-= 1
            }
        }
    }

    /// The buffers the workers share: each writes its own rows of the picture.
    private struct Buffers: @unchecked Sendable {
        let pixels: UnsafePointer<Float>
        let picture: UnsafeMutablePointer<UInt8>
        let table: UnsafePointer<Float>
    }

    /// The lookup table that windows each channel of a colour picture, the
    /// same for alpha, red, green and blue; through the transfer function
    /// when there is one (a 4096-entry table read every 16th entry).
    public static func colourTable(level: Float, window: Float, table: UnsafePointer<Float>?) -> [UInt8] {
        let low = level - window / 2, high = level + window / 2
        // A colour frame carries no scalar intensity to window, so a
        // zero-width window asks for the frame as it is, not for a division by zero.
        var difference = cLong(high - low)
        if difference == 0 { difference = 1 }
        return (0..<256).map { index -> UInt8 in
            var value = cLong((Float(index) - low) * 255 / Float(difference))
            value = min(max(value, 0), 255)
            if let table {
                value = cLong(255.0 * Double(table[value * 16]))
                value = min(max(value, 0), 255)
            }
            return UInt8(value)
        }
    }

    /// A colour picture through a channel table.
    public static func colour(_ pixels: UnsafeRawPointer, into picture: UnsafeMutableRawPointer, width: Int, height: Int,
                              table: [UInt8]) {
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * 4)
        var destination = vImage_Buffer(data: picture, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: width * 4)
        table.withUnsafeBufferPointer { entries in
            let entry = entries.baseAddress!
            _ = vImageTableLookUp_ARGB8888(&source, &destination, entry, entry, entry, entry, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Black for white: the picture of an inverted (MONOCHROME1) image.
    public static func invert(_ picture: UnsafeMutablePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        var buffer = vImage_Buffer(data: picture, height: 1, width: vImagePixelCount(count), rowBytes: count)
        let table = (0..<256).map { UInt8(255 - $0) }
        _ = table.withUnsafeBufferPointer { vImageTableLookUp_Planar8(&buffer, &buffer, $0.baseAddress!, vImage_Flags(kvImageNoFlags)) }
    }

    /// A float to a C `int` as arm64 converts it: truncated, saturated, zero for NaN.
    static func cInt(_ value: Float) -> Int32 { ImageWindow.cInt(value) }

    /// A float to a C `long` as arm64 converts it.
    static func cLong(_ value: Float) -> Int { ParsedValue.cLong(value) }

    static func cLong(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    /// A double stored into an `unsigned char` as arm64 does it: converted to
    /// an unsigned 32-bit integer, saturating, and its low byte kept.
    static func shade(_ value: Double) -> UInt8 {
        let whole: UInt32
        if value.isNaN || value <= 0 { whole = 0 } else if value >= Double(UInt32.max) { whole = UInt32.max } else { whole = UInt32(value) }
        return UInt8(truncatingIfNeeded: whole)
    }
}
