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

/// The window an image is shown with: what a request for a level and a width
/// becomes, and the full window that shows every value it holds.
public enum ImageWindow {
    /// The window a request asks for, or nil when it asks for the full
    /// window: a width of zero (with any level), and anything that is not a
    /// number, mean automatic selection.
    ///
    /// On an image whose full width is over 256 the window is in whole values:
    /// a width under one becomes two, and a window that does not start at
    /// zero is truncated to integers. No width is under a thousandth of the
    /// rescale slope.
    public static func requested(level: Float, width: Float, fullWidth: Float, slope: Float) -> (level: Float, width: Float)? {
        if width == 0 || width.isNaN || width.isInfinite || level.isNaN || level.isInfinite { return nil }
        var level = level, width = width
        if fullWidth > 256 {
            if width < 1 { width = 2 }
            if level - width / 2 == 0 {
                level = width / 2
            } else {
                width = Float(cInt(width))
                level = Float(cInt(level))
            }
        }
        if Double(width) < 0.001 * Double(slope) { width = Float(0.001 * Double(slope)) }
        return (level, width)
    }

    /// The window that shows every value of an image: from its smallest to
    /// its largest, twenty wide when the image is flat; 0...255 for colour.
    public static func full(_ pixels: UnsafePointer<Float>, count: Int, isRGB: Bool) -> (level: Float, width: Float) {
        var low: Float, high: Float
        if isRGB {
            low = 0
            high = 255
        } else {
            low = 0
            high = 0
            vDSP_minv(pixels, 1, &low, vDSP_Length(count))
            vDSP_maxv(pixels, 1, &high, vDSP_Length(count))
            if low == high { high = low + 20 }
        }
        return (low + (high - low) / 2, high - low)
    }

    /// A float converted to a C `int` the way arm64 converts it: truncated,
    /// saturated at the ends of the range, and zero for NaN.
    static func cInt(_ value: Float) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Float(Int32.max) { return Int32.max }
        if value <= Float(Int32.min) { return Int32.min }
        return Int32(value)
    }
}
