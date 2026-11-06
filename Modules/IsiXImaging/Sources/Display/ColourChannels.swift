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

/// An image changed between grey and colour in place (-[DCMPix ConvertToBW:],
/// -ConvertToRGB:::), and a colour picture repacked without its alpha byte
/// (-[DCMPix image]).
public enum ColourChannels {
    /// The grey of each ARGB pixel of `source` into `destination`: its red (0),
    /// green (1) or blue (2), or the mean of the three (3). Another mode writes nothing.
    public static func grey(fromARGB source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<Float>, count: Int,
                            mode: Int) {
        switch mode {
        case 0, 1, 2:
            for i in 0..<max(count, 0) { destination[i] = Float(source[i * 4 + mode + 1]) }
        case 3:
            for i in 0..<max(count, 0) {
                let sum = Float(source[i * 4 + 1]) + Float(source[i * 4 + 2]) + Float(source[i * 4 + 3])
                destination[i] = Float(Double(sum) / 3.0)
            }
        default:
            break
        }
    }

    /// The grey floats of `pixels` (`width` × `height`) through the window
    /// `level`/`window` into 8 bits, written back over them as ARGB: in the red
    /// (0), green (1) or blue (2) channel, the rest zero, or in all three and
    /// the alpha (3). Another mode leaves the floats as they are. The alpha is
    /// not the mean yet: `fillAlpha` does that.
    public static func toARGB(_ pixels: UnsafeMutablePointer<Float>, width: Int, height: Int, mode: Int, level: Int, window: Int) {
        let count = width * height
        guard let planar = malloc(count) else { return }
        defer { free(planar) }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        var eight = vImage_Buffer(data: planar, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        let minimum = level - window / 2, maximum = level + window / 2
        vImageConvert_PlanarFtoPlanar8(&source, &eight, Float(maximum), Float(minimum), vImage_Flags(0))

        let grey = planar.assumingMemoryBound(to: UInt8.self)
        let argb = UnsafeMutableRawPointer(pixels).assumingMemoryBound(to: UInt8.self)
        switch mode {
        case 0, 1, 2:
            memset(argb, 0, count * 4)
            for i in 0..<count { argb[i * 4 + mode + 1] = grey[i] }
        case 3:
            var colour = vImage_Buffer(data: UnsafeMutableRawPointer(pixels), height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            vImageConvert_Planar8toARGB8888(&eight, &eight, &eight, &eight, &colour, vImage_Flags(0))
        default:
            break
        }
    }

    /// The alpha byte of each ARGB pixel set to the mean of its red, green and blue.
    public static func fillAlpha(_ argb: UnsafeMutablePointer<UInt8>, count: Int) {
        var pixel = argb
        for _ in 0..<max(count, 0) {
            pixel[0] = UInt8(truncatingIfNeeded: (Int32(pixel[1]) + Int32(pixel[2]) + Int32(pixel[3])) / 3)
            pixel += 4
        }
    }

    /// `count` RGBA pixels of `source` as ARGB into `destination` (-[DCMPix
    /// initWithData:] with a pixel size of 8).
    public static func argb(fromRGBA source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>, count: Int) {
        for i in stride(from: 0, to: max(count, 0) * 4, by: 4) {
            destination[i] = source[i + 3]
            destination[i + 1] = source[i]
            destination[i + 2] = source[i + 1]
            destination[i + 3] = source[i + 2]
        }
    }

    /// The red, green and blue of `count` ARGB pixels, three bytes each.
    public static func rgb(fromARGB source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>, count: Int) {
        for i in 0..<max(count, 0) {
            destination[i * 3] = source[i * 4 + 1]
            destination[i * 3 + 1] = source[i * 4 + 2]
            destination[i * 3 + 2] = source[i * 4 + 3]
        }
    }
}
