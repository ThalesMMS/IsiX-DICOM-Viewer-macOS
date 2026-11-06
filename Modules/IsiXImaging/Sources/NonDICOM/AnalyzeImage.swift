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

/// The header of an Analyze 7.5 image (a `.hdr` of 348 bytes beside its `.img`)
/// as DCMPix reads it: in the file's byte order, which is the other one when
/// `dim[0]` is not 0...15.
public struct AnalyzeHeader {
    public let swapsBytes: Bool
    public let width: Int
    public let height: Int
    public let pixelSpacingX: Float
    public let pixelSpacingY: Float
    public let sliceThickness: Float
    public let datatype: Int16

    /// Nil unless `data` is 348 bytes long.
    public init?(_ data: Data) {
        guard data.count == 348 else { return nil }
        let file = NonDICOMFileBytes(data)
        let short = { (offset: Int) in Int16(bitPattern: file.uint16(at: offset)) }
        let float = { (offset: Int) in Float(bitPattern: file.uint32(at: offset)) }
        let swaps = short(40) < 0 || short(40) > 15
        swapsBytes = swaps
        // The C kept a short as it was, and a swapped one as Endian16_Swap answers it: unsigned.
        let dimension = { (offset: Int) in swaps ? Int(UInt16(bitPattern: short(offset)).byteSwapped) : Int(short(offset)) }
        height = dimension(44)
        width = dimension(42)
        let spacing = { (offset: Int) in swaps ? Float(bitPattern: float(offset).bitPattern.byteSwapped) : float(offset) }
        pixelSpacingX = spacing(80)
        pixelSpacingY = spacing(84)
        sliceThickness = spacing(88)
        datatype = swaps ? Int16(bitPattern: UInt16(bitPattern: short(70)).byteSwapped) : short(70)
    }
}

/// A frame of an Analyze image.
public enum AnalyzeImage {
    public struct Frame {
        /// The pixels, `width` x `height` floats; nil when the frame is not read.
        public var pixels: [Float]?
        /// What the reading has to say, in order.
        public var messages: [String] = []
    }

    /// Frame `frame` of `image` (the `.img`, nil when it could not be read), named `name` in the messages.
    /// Bytes (2), signed shorts (4) and unsigned 32-bit integers (8) go through a short,
    /// floats (16) are copied, in the other byte order swapped as the integers are; a frame the file does not hold is not read.
    public static func frame(_ frame: Int, of image: Data?, header: AnalyzeHeader, name: String) -> Frame {
        var result = Frame()
        let width = header.width, height = header.height
        let count = width * height
        let data = image ?? Data()
        let datatype = header.datatype
        let bytesPerVoxel = datatype == 2 ? 1 : datatype == 4 ? 2 : (datatype == 8 || datatype == 16) ? 4 : 0
        if bytesPerVoxel != 0 && UInt(bitPattern: data.count) < UInt(bitPattern: (frame + 1) * height * width * bytesPerVoxel) {
            result.messages.append(String(format: "---- Analyze: %@ is shorter than frame %ld needs", name, frame))
            return result
        }
        // Every other datatype gave an image of 16-bit samples left as malloc gave
        // them; it is zero here.
        var shorts = [Int16](repeating: 0, count: Swift.max(count, 0))
        let file = NonDICOMFileBytes(data)
        switch datatype {
        case 2:
            let start = frame * count
            for i in 0..<shorts.count { shorts[i] = Int16(file.data[file.data.startIndex + start + i]) }
        case 4:
            shorts.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: frame * count * 2, count: count * 2) }
            if header.swapsBytes {
                for i in 0..<shorts.count { shorts[i] = shorts[i].byteSwapped }
            }
        case 8:
            for i in 0..<shorts.count {
                let value = file.uint32(at: (frame * count + i) * 4)
                shorts[i] = Int16(truncatingIfNeeded: header.swapsBytes ? value.byteSwapped : value)
            }
        case 16:
            var floats = [Float](repeating: 0, count: Swift.max(count, 0))
            floats.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: frame * count * 4, count: count * 4) }
            if header.swapsBytes {
                for i in 0..<floats.count { floats[i] = Float(bitPattern: floats[i].bitPattern.byteSwapped) }
            }
            result.pixels = floats
            return result
        case 128:
            result.messages.append("unsupported... please send me this file")
        default:
            break
        }
        var floats = [Float](repeating: 0, count: shorts.count)
        shorts.withUnsafeBufferPointer { s in
            floats.withUnsafeMutableBufferPointer { f in
                if let source = s.baseAddress, let destination = f.baseAddress {
                    NonDICOMSamples.floats(signed: source, count: s.count, into: destination)
                }
            }
        }
        result.pixels = floats
        return result
    }
}
