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
import CoreGraphics
import Foundation

/// The product or the difference of two images of the same size, pixel by
/// pixel, the second shifted by a whole number of pixels.
///
/// The shifted image lies under pixel (x, y) at (x - dx, y + dy), the way the
/// DSA mask is read; where it has no pixel the result is zero, instead of
/// memory nothing had written.
public enum ImageArithmetic {
    /// `input × other`, in a new buffer the caller frees.
    public static func product(_ input: UnsafePointer<Float>, _ other: UnsafePointer<Float>,
                               width: Int, height: Int, offset: CGPoint) -> UnsafeMutablePointer<Float>? {
        combine(input, other, width: width, height: height, offset: offset) { a, b, result, count in
            vDSP_vmul(a, 1, b, 1, result, 1, vDSP_Length(count))
        }
    }

    /// `input - other`, or its absolute value, in a new buffer the caller frees.
    public static func difference(_ input: UnsafePointer<Float>, _ other: UnsafePointer<Float>,
                                  width: Int, height: Int, offset: CGPoint, absolute: Bool) -> UnsafeMutablePointer<Float>? {
        combine(input, other, width: width, height: height, offset: offset) { a, b, result, count in
            vDSP_vsub(b, 1, a, 1, result, 1, vDSP_Length(count))
            if absolute { vDSP_vabs(result, 1, result, 1, vDSP_Length(count)) }
        }
    }

    /// The whole pixels of a shift, rounded half away from zero.
    static func wholePixels(_ offset: CGPoint) -> (dx: Int, dy: Int) {
        (lround(Double(offset.x)), lround(Double(offset.y)))
    }

    private static func combine(_ input: UnsafePointer<Float>, _ other: UnsafePointer<Float>, width: Int, height: Int,
                                offset: CGPoint,
                                _ operation: (UnsafePointer<Float>, UnsafePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void)
        -> UnsafeMutablePointer<Float>? {
        let count = width &* height
        if offset.x == 0 && offset.y == 0 {
            guard let result = malloc(count &* MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { return nil }
            if count > 0 { operation(input, other, result, count) }
            return result
        }
        guard let result = calloc(count, MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { return nil }
        let (dx, dy) = wholePixels(offset)
        let firstColumn = max(0, dx), lastColumn = min(width, width + dx)
        let firstRow = max(0, -dy), lastRow = min(height, height - dy)
        guard firstColumn < lastColumn else { return result }
        var y = firstRow
        while y < lastRow {
            operation(input + (y * width + firstColumn), other + ((y + dy) * width + (firstColumn - dx)),
                      result + (y * width + firstColumn), lastColumn - firstColumn)
            y += 1
        }
        return result
    }
}
