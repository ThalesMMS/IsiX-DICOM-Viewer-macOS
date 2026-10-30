/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Accelerate
import Foundation

// The reslice of a 2D viewer's stack along its rows (X) or its columns (Y):
// the dimensions and spacings of the new slices, their orientation, and the
// pixel loops that gather them from the stack. The viewer reads its DCMPix,
// allocates the new volume and applies the answers; nothing here knows DCMPix
// or the viewer.

/// What a reslice of a stack makes.
public struct SeriesReslicePlan: Equatable, Sendable {
    /// How many slices the reslice makes: the height of the stack's slices
    /// for an X reslice, their width for a Y reslice.
    public let sliceCount: Int
    /// The width of the new slices (even).
    public let width: Int
    /// The height of the new slices (even): one row per slice of the stack,
    /// or more when the rows are scaled to square pixels.
    public let height: Int
    public let spacingX: Double
    public let spacingY: Double
    /// The rows gathered from the stack are scaled to `height` rows.
    public let square: Bool
    /// A small stack would have been squared, but the scaled slices would
    /// not have had more rows than the stack has slices.
    public let squareAbandoned: Bool

    /// The reslice of `count` slices of `width`×`height` pixels along their
    /// rows (direction 0) or their columns (any other direction). A stack of
    /// fewer than 100 slices of at most 256×256 is squared: its rows are
    /// scaled to the slice interval, unless that would not add rows.
    public init(direction: Int, sliceCount count: Int, width: Int, height: Int,
                spacingX: Double, spacingY: Double, sliceInterval: Double) {
        var square = count < 100 && height <= 256 && width <= 256
        var abandoned = false
        let rows = direction == 0
        let spacing = rows ? spacingX : spacingY
        var newY = 0
        var xSpace = 0.0, ySpace = 0.0

        if square {
            xSpace = spacing
            ySpace = spacing
            newY = SeriesReslicePlan.cLong((Double(count) * abs(sliceInterval)) / spacing)
            // In C: int even = newY / 2; even *= 2; compared with the unsigned count.
            let even = Int32(truncatingIfNeeded: newY / 2) &* 2
            if UInt(bitPattern: Int(even)) <= UInt(bitPattern: count) {
                abandoned = true
                square = false
            }
        }
        if !square {
            xSpace = spacing
            ySpace = abs(sliceInterval)
            newY = count
        }

        sliceCount = rows ? height : width
        self.width = ((rows ? width : height) / 2) * 2
        self.height = (newY / 2) * 2
        self.spacingX = xSpace
        self.spacingY = ySpace
        self.square = square
        squareAbandoned = abandoned
    }

    /// The ratio of the new slices' pixels.
    public var pixelRatio: Double { spacingY / spacingX }

    /// The slice of the stack the new slices take their geometry from: the
    /// last of an even number of slices.
    public static func referenceSliceIndex(sliceCount count: Int) -> Int {
        return (count / 2) * 2 - 1
    }

    /// A double converted to a C long as arm64 does: saturated, NaN to 0.
    static func cLong(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= 9223372036854775807.0 { return Int.max }
        if value <= -9223372036854775808.0 { return Int.min }
        return Int(value)
    }
}

public enum SeriesReslice {

    /// The orientation of the new slices, from the nine values of the stack's
    /// reference slice: a Y reslice takes the stack's columns as its rows;
    /// both take the stack's normal, times -sign, as their columns. The normal
    /// (6…8) is left as it was: the slice recomputes it.
    public static func orientation(direction: Int, reference o: [Double], sign: Double) -> [Double] {
        var result = o
        if direction != 0 {
            result[0] = o[3]
            result[1] = o[4]
            result[2] = o[5]
        }
        result[3] = o[6] * -sign
        result[4] = o[7] * -sign
        result[5] = o[8] * -sign
        return result
    }

    /// X reslice: row `row` (of `sourceWidth` floats) of each of the `count`
    /// slices gives `width` floats of a row of `destination`; with a positive
    /// sign the first slice gives the last row.
    public static func gatherRows(_ slices: [UnsafePointer<Float>], row: Int, sourceWidth: Int, width: Int,
                                  into destination: UnsafeMutablePointer<Float>, sign: Double) {
        let count = slices.count
        for y in 0..<count {
            let target = sign > 0 ? destination + (count - y - 1) * width : destination + y * width
            target.update(from: slices[y] + row * sourceWidth, count: width)
        }
    }

    /// Y reslice: column `column` of `count` slices stored one after the other
    /// (`sliceFloatCount` floats each, rows of `rowFloats`) gives `width`
    /// floats of a row of `destination`. `source` is the last slice with a
    /// positive sign, read backwards, else the first.
    public static func gatherColumns(_ source: UnsafePointer<Float>, column: Int, count: Int,
                                     sliceFloatCount: Int, rowFloats: Int, width: Int,
                                     into destination: UnsafeMutablePointer<Float>, sign: Double) {
        let start = source + column
        var x = count
        while x > 0 {
            x -= 1
            var from = sign > 0 ? start - x * sliceFloatCount : start + x * sliceFloatCount
            var target = destination + x * width
            var y = width
            while y > 0 {
                y -= 1
                target.pointee = from.pointee
                target += 1
                from += rowFloats
            }
        }
    }

    /// The first `rows` rows of `buffer` (`width` floats each) scaled in place
    /// to `newRows` rows, in high quality.
    public static func scaleRows(_ buffer: UnsafeMutablePointer<Float>, rows: Int, newRows: Int, width: Int) {
        var source = vImage_Buffer(data: buffer, height: vImagePixelCount(rows), width: vImagePixelCount(width), rowBytes: width * 4)
        var destination = vImage_Buffer(data: buffer, height: vImagePixelCount(newRows), width: vImagePixelCount(width), rowBytes: width * 4)
        vImageScale_PlanarF(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
    }
}
