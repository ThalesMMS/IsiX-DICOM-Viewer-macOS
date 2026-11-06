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

/// A decoded frame, as the decoder handed it over: its bytes are read where
/// they are, never copied to be read.
///
/// The Objective-C loading copied every frame into a buffer of the frame's
/// own length and read the samples from there - past its end, where the
/// object declared more pixels than the frame carried. Here what lies past
/// the end reads as zero: where the old reading stayed inside the frame the
/// values are the same, and where it did not they no longer depend on
/// whatever followed the allocation.
struct FrameBytes {
    let base: UnsafeRawPointer?
    let count: Int

    /// The first `length` bytes at an address aligned for `alignment`: the
    /// frame itself when it is long enough and aligned, otherwise a copy
    /// padded with zeros, which `scratch` frees.
    func prefix(_ length: Int, alignment: Int, scratch: FrameScratch) -> UnsafeRawPointer? {
        if let base, count >= length, Int(bitPattern: base) % alignment == 0 { return base }
        guard let copy = scratch.zeroed(length) else { return nil }
        if let base, count > 0 { copy.copyMemory(from: base, byteCount: min(count, length)) }
        return UnsafeRawPointer(copy)
    }

    /// Copies the first `length` bytes into `destination`, zeros past the frame's end.
    func copy(_ length: Int, into destination: UnsafeMutableRawPointer) {
        let carried = base == nil ? 0 : min(count, length)
        if carried > 0 { destination.copyMemory(from: base!, byteCount: carried) }
        if carried < length { memset(destination + carried, 0, length - carried) }
    }
}

/// The working buffers of one frame's loading, freed when it is done.
final class FrameScratch {
    private var buffers: [UnsafeMutableRawPointer] = []

    func zeroed(_ length: Int) -> UnsafeMutableRawPointer? {
        guard let buffer = calloc(max(length, 1), 1) else { return nil }
        buffers.append(buffer)
        return buffer
    }

    func uninitialized(_ length: Int) -> UnsafeMutableRawPointer? {
        guard let buffer = malloc(max(length, 1)) else { return nil }
        buffers.append(buffer)
        return buffer
    }

    deinit {
        for buffer in buffers { free(buffer) }
    }
}

/// The samples of a decoded frame, unpacked into what the conversion to
/// floating point reads: 16-bit grey samples or 8-bit ARGB pixels.
enum FrameSamples {
    /// Sign-extends `count` samples whose value is the low `bitsStored` bits
    /// of a 16-bit word: what Pixel Representation 1 with Bits Stored below
    /// Bits Allocated means (PS 3.5 8.1.1). The bits above are ignored, as
    /// `((short)(v << shift)) / (1 << shift)` ignored them.
    ///
    /// Four samples go through at a time, each in a 16-bit lane of a 64-bit
    /// word: the field is masked, and its sign bit, multiplied by the bits
    /// above the field, fills them. A lane's product never reaches the next
    /// lane, so nothing carries across. The unoptimized build runs this at
    /// about the speed of the Objective-C loop.
    static func signExtend(_ source: UnsafeRawPointer, into destination: UnsafeMutableRawPointer, count: Int, bitsStored: Int) {
        let lanes: UInt64 = 0x0001_0001_0001_0001
        let field = lanes &* UInt64((1 << bitsStored) - 1)
        let above = UInt64(0xFFFF ^ ((1 << bitsStored) - 1))
        let signBit = UInt64(bitsStored - 1)
        let wordBytes = count / 4 * 8
        var offset = 0
        while offset < wordBytes {
            let value = source.loadUnaligned(fromByteOffset: offset, as: UInt64.self) & field
            destination.storeBytes(of: value | (((value &>> signBit) & lanes) &* above), toByteOffset: offset, as: UInt64.self)
            offset &+= 8
        }
        let shift = UInt16(16 - bitsStored)
        while offset < count * 2 {
            let word = source.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            destination.storeBytes(of: Int16(bitPattern: word &<< shift) &>> Int16(shift), toByteOffset: offset, as: Int16.self)
            offset &+= 2
        }
    }

    /// Widens `count` 8-bit samples into the low bytes of 16-bit words whose
    /// high bytes are already zero.
    static func widen(_ source: UnsafeRawPointer, into destination: UnsafeMutableRawPointer, count: Int) {
        guard count > 0 else { return }
        var plane = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                  width: vImagePixelCount(count), rowBytes: count)
        withUnsafePointer(to: &plane) { plane in
            var planes: UnsafePointer<vImage_Buffer>? = plane
            var channel: UnsafeMutableRawPointer? = destination
            _ = vImageConvert_PlanarToChunky8(&planes, &channel, 1, 2, vImagePixelCount(count), 1, count * 2, vImage_Flags(kvImageNoFlags))
        }
    }

    /// `count` interleaved 8-bit RGB pixels into ARGB, alpha opaque.
    static func argb(fromRGB source: UnsafeRawPointer, into destination: UnsafeMutableRawPointer, count: Int) {
        guard count > 0 else { return }
        var rgb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                width: vImagePixelCount(count), rowBytes: count * 3)
        var argb = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_RGB888toARGB8888(&rgb, nil, 255, &argb, false, vImage_Flags(kvImageNoFlags))
    }

    /// `count` interleaved 16-bit RGB pixels into ARGB, alpha opaque. Each
    /// sample keeps its low byte, as it always did: the high byte is dropped,
    /// not scaled.
    static func argb(fromRGB16 source: UnsafeRawPointer, into destination: UnsafeMutableRawPointer, count: Int) {
        var from = source, to = destination
        var left = count
        while left > 0 {
            // Little-endian: a sample's low byte comes first.
            to.storeBytes(of: 255, as: UInt8.self)
            (to + 1).storeBytes(of: from.load(as: UInt8.self), as: UInt8.self)
            (to + 2).storeBytes(of: (from + 2).load(as: UInt8.self), as: UInt8.self)
            (to + 3).storeBytes(of: (from + 4).load(as: UInt8.self), as: UInt8.self)
            from += 6
            to += 4
            left &-= 1
        }
    }
}
