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

/// An overlay plane's bitmap, placed on the image: one byte a pixel, non-zero
/// where the overlay is set, `origin` the image pixel of its first one.
public struct OverlayBitmap {
    public let pixels: UnsafePointer<UInt8>
    public let rows: Int32
    public let columns: Int32
    public let originX: Int32
    public let originY: Int32

    public init(pixels: UnsafePointer<UInt8>, rows: Int32, columns: Int32, originX: Int32, originY: Int32) {
        self.pixels = pixels
        self.rows = rows
        self.columns = columns
        self.originX = originX
        self.originY = originY
    }

    /// Every image pixel the overlay sets, inside an image of this size.
    func forEachSetPixel(width: Int, height: Int, _ body: (Int) -> Void) {
        var y: Int32 = 0
        while y < rows {
            var x: Int32 = 0
            while x < columns {
                if pixels[Int(y &* columns &+ x)] != 0 {
                    let column = Int(x &+ originX), row = Int(y &+ originY)
                    if column >= 0 && column < width && row >= 0 && row < height {
                        body(row &* width &+ column)
                    }
                }
                x &+= 1
            }
            y &+= 1
        }
    }
}

/// Overlays drawn into the image's own pixels, when the preference to show
/// DICOM overlays is on: the brightest value of a grey image, or white in a
/// colour one.
enum OverlayBurnIn {
    static func burn(_ overlays: [OverlayBitmap], into image: UnsafeMutablePointer<Float>, width: Int, height: Int, value: Float) {
        for overlay in overlays {
            overlay.forEachSetPixel(width: width, height: height) { image[$0] = value }
        }
    }

    static func burn(_ overlays: [OverlayBitmap], intoARGB image: UnsafeMutableRawPointer, width: Int, height: Int) {
        let bytes = image.assumingMemoryBound(to: UInt8.self)
        for overlay in overlays {
            overlay.forEachSetPixel(width: width, height: height) { pixel in
                bytes[pixel &* 4 &+ 1] = 0xFF
                bytes[pixel &* 4 &+ 2] = 0xFF
                bytes[pixel &* 4 &+ 3] = 0xFF
            }
        }
    }

    /// The value an overlay takes in a grey image: the top of the stored
    /// range after the modality LUT, or the offset when MONOCHROME1 shows
    /// that as white. Each step is rounded to float, as it was.
    static func greyValue(bitsStored: Int16, slope: Float, offset: Float, inverts: Bool) -> Float {
        if inverts { return offset }
        var value = Float(pow(2, Double(bitsStored)))
        value *= slope
        value += offset
        return value
    }
}
