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

/// YBR samples turned into RGB, three bytes a pixel (-[DCMPix ConvertYbrToRgb:::::]).
public enum YBRConversion {
    /// The kinds of YBR the conversion knows (the photometric interpretation codes of DCMPix).
    public static let full = 7, full422 = 8, partial422 = 9

    /// `width` x `height` pixels of `kind` stored `planar` (0: interleaved, 1: one
    /// plane after the other, only for YBR_FULL) into a malloc'd RGB buffer the
    /// caller frees; nil for a planar kind other than YBR_FULL. A kind or planar
    /// configuration it does not convert gives a buffer left unwritten, as before.
    public static func rgb(_ ybr: UnsafePointer<UInt8>, width: Int32, height: Int32, kind: Int, planar: Int8) -> UnsafeMutablePointer<UInt8>? {
        if kind != full && planar == 1 { return nil }
        let size = Int(width) * Int(height)
        guard let rgb = malloc(Swift.max(size * 3, 0))?.assumingMemoryBound(to: UInt8.self) else { return nil }

        func fullPixel(_ y: UInt8, _ b: UInt8, _ r: UInt8, _ out: UnsafeMutablePointer<UInt8>) {
            let a = Int32(y), b = Int32(b), c = Int32(r)
            var red = 38142 &* (a &- 16) &+ 52298 &* (c &- 128)
            var green = 38142 &* (a &- 16) &- 26640 &* (c &- 128) &- 12845 &* (b &- 128)
            var blue = 38142 &* (a &- 16) &+ 66093 &* (b &- 128)
            red = (red &+ 16384) >> 15
            green = (green &+ 16384) >> 15
            blue = (blue &+ 16384) >> 15
            out[0] = UInt8(Swift.min(Swift.max(red, 0), 255))
            out[1] = UInt8(Swift.min(Swift.max(green, 0), 255))
            out[2] = UInt8(Swift.min(Swift.max(blue, 0), 255))
        }

        switch planar {
        case 0:
            switch kind {
            case full:
                for i in 0..<Swift.max(size, 0) { fullPixel(ybr[3 * i], ybr[3 * i + 1], ybr[3 * i + 2], rgb + 3 * i) }
            case full422:
                // Copied as they are: the 4:2:2 samples were never converted.
                for i in 0..<Swift.max(size, 0) {
                    rgb[3 * i] = ybr[3 * i]
                    rgb[3 * i + 1] = ybr[3 * i + 1]
                    rgb[3 * i + 2] = ybr[3 * i + 2]
                }
            case partial422:
                // Two pixels share their Cb and Cr. The C summed the terms left to
                // right with the first multiplication fused into the second addition.
                for pair in 0..<Swift.max(size / 2, 0) {
                    let source = ybr + 4 * pair
                    let b = Double(source[2]), r = Double(source[3])
                    let out = rgb + 6 * pair
                    for (n, y) in [Double(source[0]), Double(source[1])].enumerated() {
                        out[3 * n] = NonDICOMSamples.byte((0.0389 * b).addingProduct(1.1685, y).addingProduct(1.596, r))
                        out[3 * n + 1] = NonDICOMSamples.byte((-(0.401 * b)).addingProduct(1.1685, y).addingProduct(-0.813, r))
                        out[3 * n + 2] = NonDICOMSamples.byte((2.024 * b).addingProduct(1.1685, y))
                    }
                }
            default:
                break
            }
        case 1:
            let y = ybr, cb = ybr + size, cr = ybr + 2 * size
            for i in 0..<Swift.max(size, 0) { fullPixel(y[i], cb[i], cr[i], rgb + 3 * i) }
        default:
            break
        }
        return rgb
    }
}
