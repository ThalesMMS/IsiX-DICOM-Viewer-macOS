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

/// Pictures drawn into DCMPix's colour layout: four bytes a pixel, alpha first,
/// big-endian, rows `width` * 4 bytes apart.
public enum ARGBImages {
    /// Draws `image` into `argb` (`width` x `height`), alpha premultiplied, copying
    /// rather than blending; false when no context could be made.
    public static func draw(_ image: CGImage, width: Int, height: Int, into argb: UnsafeMutableRawPointer) -> Bool {
        let bytesPerRow = width * 4
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: argb, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: space, bitmapInfo: info) else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    /// `height` rows of four-byte pixels (RGB and one more, `bytesPerRow` apart)
    /// as ARGB: the colours after the first byte of each pixel, which is left as it is.
    public static func argb(rgbx source: UnsafePointer<UInt8>, bytesPerRow: Int, width: Int, height: Int, into argb: UnsafeMutablePointer<UInt8>) {
        var out = argb
        for y in 0..<Swift.max(height, 0) {
            var pixel = source + y * bytesPerRow
            for _ in 0..<Swift.max(width, 0) {
                out += 1
                out[0] = pixel[0]
                out[1] = pixel[1]
                out[2] = pixel[2]
                out += 3
                pixel += 4
            }
        }
    }
}
