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

/// The settings of a DSA mask subtraction, which every image of the series
/// carries: how much of the mask is taken away, and the gamma curve and zero
/// that bring the difference to 8 bits.
public struct SubtractionSliders: Equatable, Sendable {
    /// The share of the mask that is subtracted.
    public var percent: Float
    /// The zero the window asked for, before the share moves it.
    public var z: Float
    /// Where a difference of zero lands, in the normalized result.
    public var zero: Float
    public var gamma: Float

    public init(percent: Float, gamma: Float, zero z: Float) {
        self.percent = percent
        self.z = z
        // In double precision, with one rounding for p × 0.8 added to z - 0.8,
        // as the Objective-C expression compiled.
        self.zero = Float((Double(z) - 0.8).addingProduct(Double(percent), 0.8))
        self.gamma = gamma
    }

    /// The window of a subtracted image, held to 2...512, and the gamma and
    /// zero it stands for: the width sets the contrast, the level the zero.
    public static func window(level: Float, width: Float) -> (level: Float, width: Float, gamma: Float, zero: Float) {
        let level = min(max(level, 2), 512)
        let width = min(max(width, 2), 512)
        let gamma = Float(2.0 * (Double(width) / 256.0))
        let zero = Float(1.6.addingProduct(-0.8, Double(level) / 128.0))
        return (level, width, gamma, zero)
    }
}

/// DSA: a frame minus a share of its mask, normalized for the gamma curve
/// that brings it to 8 bits.
public enum MaskSubtractionImage {
    /// The darkest and brightest of `frame - mask`, with no shift: the range
    /// every image of the series is normalized by.
    public static func range(frame: UnsafePointer<Float>, mask: UnsafePointer<Float>, count: Int) -> CGPoint {
        guard let difference = malloc(count &* MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else {
            return .zero
        }
        defer { free(difference) }
        var low: Float = 0, high: Float = 0
        vDSP_vsub(mask, 1, frame, 1, difference, 1, vDSP_Length(count))
        vDSP_minv(difference, 1, &low, vDSP_Length(count))
        vDSP_maxv(difference, 1, &high, vDSP_Length(count))
        return CGPoint(x: CGFloat(low), y: CGFloat(high))
    }

    /// `(frame - percent × shifted mask) / range + zero`, in a new buffer the
    /// caller frees; nil when there is no memory for it. Where the shifted
    /// mask has no pixel the difference is zero.
    public static func subtract(frame: UnsafePointer<Float>, mask: UnsafePointer<Float>, width: Int, height: Int,
                                offset: CGPoint, sliders: SubtractionSliders, range: CGPoint) -> UnsafeMutablePointer<Float>? {
        let count = width &* height
        guard let result = malloc(count &* MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { return nil }
        let (dx, dy) = ImageArithmetic.wholePixels(offset)
        let firstColumn = max(0, dx), lastColumn = min(width, width + dx)
        let firstRow = max(0, -dy), lastRow = min(height, height - dy)
        var percent = sliders.percent
        vDSP_vclr(result, 1, vDSP_Length(count))
        if firstColumn < lastColumn {
            var y = firstRow
            while y < lastRow {
                let difference = result + (y * width + firstColumn)
                let length = vDSP_Length(lastColumn - firstColumn)
                vDSP_vsmul(mask + ((y + dy) * width + (firstColumn - dx)), 1, &percent, difference, 1, length)
                vDSP_vsub(difference, 1, frame + (y * width + firstColumn), 1, difference, 1, length)
                y += 1
            }
        }
        // The largest difference without the shift, which normalizes the result to -1...1.
        var ratio = Float(abs(Double(range.y) - Double(range.x)))
        if ratio == 0 { ratio = 1 }
        var zero = sliders.zero
        vDSP_vsdiv(result, 1, &ratio, result, 1, vDSP_Length(count))
        vDSP_vsadd(result, 1, &zero, result, 1, vDSP_Length(count))
        return result
    }
}
