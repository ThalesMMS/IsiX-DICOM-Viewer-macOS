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

/// Grey samples to the floating-point values the image holds: the modality
/// LUT, `value * slope + offset` (PS 3.3 C.11.1), applied as it always was.
enum FrameConversion {
    /// 16-bit samples, signed or not, through vImage.
    static func floats(from16 samples: UnsafeRawPointer, signed: Bool, width: Int, height: Int,
                       slope: Float, offset: Float, into destination: UnsafeMutablePointer<Float>) {
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: samples), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * 2)
        var floats = vImage_Buffer(data: destination, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        if signed {
            vImageConvert_16SToF(&source, &floats, offset, slope, vImage_Flags(kvImageNoFlags))
        } else {
            vImageConvert_16UToF(&source, &floats, offset, slope, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Bytes taken one a value, for a frame declared 16 bits that carries one
    /// byte a pixel. The modality LUT is not applied, as it never was here.
    static func floats(fromBytes bytes: UnsafeRawPointer, count: Int, into destination: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        vDSP_vfltu8(bytes.assumingMemoryBound(to: UInt8.self), 1, destination, 1, vDSP_Length(count))
    }

    /// 32-bit integers, converted in place in a buffer that holds their words.
    ///
    /// Pixel Data (7FE0,0010) holds integers. Floating point pixels have their
    /// own attributes - Float Pixel Data (7FE0,0008) and Double Float Pixel
    /// Data (7FE0,0009) - and an object that carries Pixel Data has to state
    /// Pixel Representation, which floating point pixels do not have. Copying
    /// the words into a float buffer and calling them floats made every
    /// ordinary value a denormal: a 64x64 unsigned ramp from 0 to 4000000
    /// arrived as one flat grey. So the words are integers when Pixel
    /// Representation is there, when a rescale is, or when the preference
    /// says they always are, and are left as floats otherwise.
    ///
    /// The value is `value * slope + offset` in double precision with one
    /// rounding, which is what the Objective-C compiler made of that
    /// expression, then rounded to float.
    static func integersToFloats(_ buffer: UnsafeMutablePointer<Float>, count: Int, signed: Bool, slope: Float, offset: Float) {
        let words = UnsafeMutableRawPointer(buffer)
        let dSlope = Double(slope), dOffset = Double(offset)
        var index = 0
        if signed {
            while index < count {
                let value = Double(words.load(fromByteOffset: index &* 4, as: Int32.self))
                buffer[index] = Float(dOffset.addingProduct(value, dSlope))
                index &+= 1
            }
        } else {
            while index < count {
                let value = Double(words.load(fromByteOffset: index &* 4, as: UInt32.self))
                buffer[index] = Float(dOffset.addingProduct(value, dSlope))
                index &+= 1
            }
        }
    }
}
