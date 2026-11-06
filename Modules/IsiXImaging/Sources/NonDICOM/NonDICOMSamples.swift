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

/// The conversions the readers of the formats that are not DICOM share.
public enum NonDICOMSamples {
    /// 16-bit signed samples to floats (vImageConvert_16SToF, scale 1, offset 0).
    public static func floats(signed source: UnsafePointer<Int16>, count: Int, into destination: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        vDSP_vflt16(source, 1, destination, 1, vDSP_Length(count))
    }

    /// 16-bit unsigned samples to floats (vImageConvert_16UToF, scale 1, offset 0).
    public static func floats(unsigned source: UnsafePointer<UInt16>, count: Int, into destination: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        vDSP_vfltu16(source, 1, destination, 1, vDSP_Length(count))
    }

    /// `(int) d` on arm64: toward zero, saturated, NaN 0.
    @inlinable
    public static func int32(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= 2_147_483_647.0 { return Int32.max }
        if d <= -2_147_483_648.0 { return Int32.min }
        return Int32(d)
    }

    /// `(unsigned char) d` as the Release build of the Objective-C did it: the
    /// low byte of the saturated `int` (-1 is 255). The Debug build saturated a
    /// negative value to zero instead; C leaves both undefined.
    @inlinable
    public static func byte(_ d: Double) -> UInt8 {
        UInt8(truncatingIfNeeded: int32(d))
    }

    /// `(short) f`: the low 16 bits of the saturated `int`.
    @inlinable
    public static func short(_ f: Float) -> Int16 {
        Int16(truncatingIfNeeded: int32(Double(f)))
    }
}

/// Bytes read from a file as `fread` read them at an offset: what is there is
/// copied, what is past the end is not (and is left as it was).
public struct NonDICOMFileBytes {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    /// Copies up to `count` bytes from `offset` into `destination`; answers how many.
    @discardableResult
    public func read(_ destination: UnsafeMutableRawPointer, at offset: Int, count: Int) -> Int {
        guard offset >= 0, offset < data.count, count > 0 else { return 0 }
        let n = Swift.min(count, data.count - offset)
        data.withUnsafeBytes { bytes in
            destination.copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: n)
        }
        return n
    }

    /// The little-endian 16-bit value at `offset` (`fallback` past the end).
    public func uint16(at offset: Int, fallback: UInt16 = 0) -> UInt16 {
        var value = fallback.littleEndian
        _ = read(&value, at: offset, count: 2)
        return UInt16(littleEndian: value)
    }

    /// The little-endian 32-bit value at `offset` (`fallback` past the end).
    public func uint32(at offset: Int, fallback: UInt32 = 0) -> UInt32 {
        var value = fallback.littleEndian
        _ = read(&value, at: offset, count: 4)
        return UInt32(littleEndian: value)
    }

    /// The little-endian double at `offset` (`fallback` past the end).
    public func double(at offset: Int, fallback: Double = 0) -> Double {
        var bits = fallback.bitPattern.littleEndian
        _ = read(&bits, at: offset, count: 8)
        return Double(bitPattern: UInt64(littleEndian: bits))
    }
}
