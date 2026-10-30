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

/// The C conversions the ROI rasterization of DCMPix made, on arm64: a float
/// to an integer truncates toward zero and saturates (NaN gives zero).
public enum ROIRasterConversion {
    /// `(long) d`.
    @inlinable
    public static func long(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= 9_223_372_036_854_775_807.0 { return Int.max }
        if d <= -9_223_372_036_854_775_808.0 { return Int.min }
        return Int(d)
    }

    /// `(long) f`.
    @inlinable
    public static func long(_ f: Float) -> Int { long(Double(f)) }

    /// `(int) d`.
    @inlinable
    public static func int32(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= 2_147_483_647.0 { return Int32.max }
        if d <= -2_147_483_648.0 { return Int32.min }
        return Int32(d)
    }

    /// `(unsigned char) f` as the Release build of the Objective-C did it: the
    /// low byte of the saturated `int`. A value past 255 keeps its low byte and
    /// a negative one wraps (-1 is 255); the Debug build saturated negatives to
    /// zero, which C leaves undefined.
    @inlinable
    public static func byte(_ f: Float) -> UInt8 {
        UInt8(truncatingIfNeeded: int32(Double(f)))
    }
}

/// A vertex of a ROI on the pixel grid: a point's coordinates truncated to
/// `long`, as DCMPix rasterized them.
public struct ROIPixelPoint: Equatable, Sendable {
    public var x: Int
    public var y: Int

    @inlinable
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// A ROI point, its coordinates truncated toward zero.
    @inlinable
    public init(_ point: CGPoint) {
        self.x = ROIRasterConversion.long(Double(point.x))
        self.y = ROIRasterConversion.long(Double(point.y))
    }
}
