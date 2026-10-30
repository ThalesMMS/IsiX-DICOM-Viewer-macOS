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

/// The windows an image offers before anyone has set one
/// (-[DCMPix dicomPreviewWindow], -frameRangePreviewWindow,
/// -storedRangePreviewWindow), and the size a picture is redrawn at
/// (+[DCMPix resizeIfNecessary:dcmPix:]).
public enum DisplayWindowRange {
    /// Whether the file's Window Center/Width can be used: a width of zero is
    /// the file saying nothing.
    public static func isUsableStoredWindow(level: Float, width: Float) -> Bool {
        !(width == 0 || width.isNaN || level.isNaN || width.isInfinite || level.isInfinite)
    }

    /// Whether the frame's own range can be used.
    public static func isUsableFrameRange(level: Float, width: Float) -> Bool {
        !(width <= 0 || width.isNaN || width.isInfinite || level.isNaN || level.isInfinite)
    }

    /// What the stored bits can hold, mapped through rescale: its centre and
    /// width (at least 1), or nil when that is not a number.
    public static func storedRange(bitsStored: Int, bitsAllocated: Int, isSigned: Bool, slope: Float,
                                   intercept: Float) -> (level: Float, width: Float)? {
        var bits = bitsStored
        if bits < 1 || bits > 30 {
            bits = (bitsAllocated > 0 && bitsAllocated <= 30) ? bitsAllocated : 16
        }
        let storedMinimum: Float, storedMaximum: Float
        if isSigned {
            let magnitude = Float(1 << (bits - 1))
            storedMinimum = -magnitude
            storedMaximum = magnitude - 1
        } else {
            storedMinimum = 0
            storedMaximum = Float((1 << bits) - 1)
        }
        // The C fused these multiplications into the additions.
        let first = intercept.addingProduct(storedMinimum, slope)
        let second = intercept.addingProduct(storedMaximum, slope)
        let low = first < second ? first : second
        let high = first < second ? second : first
        var range = high - low
        if range < 1 { range = 1 }
        if range.isNaN || range.isInfinite || low.isNaN || low.isInfinite { return nil }
        return (low + range / 2, range)
    }

    /// The size an image of `size` is redrawn at when it is much larger than
    /// the `pixelWidth` × `pixelHeight` pixels it shows (more than 512 on both
    /// sides, and more than the larger of 1.8 times the pixels and 1024): the
    /// same proportions; nil when it is kept as it is.
    public static func resizedSize(_ size: CGSize, pixelWidth: Int, pixelHeight: Int) -> CGSize? {
        guard size.width > 512 && size.height > 512 else { return nil }
        // The C divided long integers: by zero, arm64 gives zero.
        func divide(_ a: Int, _ b: Int) -> Int { b == 0 ? 0 : a / b }
        var maxSize: Float = 1.8
        var minWidth = ImagePlaneCoordinates.cInt(Float(pixelWidth) * maxSize)
        var minHeight = ImagePlaneCoordinates.cInt(Float(pixelHeight) * maxSize)
        if minWidth < 1024 { maxSize = Float(divide(1024, pixelWidth)) }
        if minHeight < 1024 { maxSize = Float(divide(1024, pixelHeight)) }
        minWidth = ImagePlaneCoordinates.cInt(Float(pixelWidth) * maxSize)
        minHeight = ImagePlaneCoordinates.cInt(Float(pixelHeight) * maxSize)
        guard Double(size.width) > Double(minWidth) && Double(size.height) > Double(minHeight) else { return nil }
        let ratio: Float
        if Double(size.width) / Double(pixelWidth) < Double(size.height) / Double(pixelHeight) {
            ratio = Float(Double(size.width) / Double(minWidth))
        } else {
            ratio = Float(Double(size.height) / Double(minHeight))
        }
        return CGSize(width: Double(ImagePlaneCoordinates.cInt(Double(size.width) / Double(ratio))),
                      height: Double(ImagePlaneCoordinates.cInt(Double(size.height) / Double(ratio))))
    }
}
