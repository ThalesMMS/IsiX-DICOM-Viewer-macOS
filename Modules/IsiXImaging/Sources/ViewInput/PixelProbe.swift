//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The pixel a 2D view reads under the pointer: whether an image location is
/// on an image of `width` × `height`, the pixel it falls in, and where the
/// red, green and blue of that pixel are in a colour image's 8-bit ARGB
/// buffer. The view reads the value there, or asks the slice for the value
/// of a grey pixel.
public struct PixelProbe: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The pixel under the image location `location`, nil off the image. The
    /// location is on the image from 0 to below the width and the height; the
    /// pixel is the location as the view keeps it (a Float), truncated toward
    /// zero to 32 bits.
    public func pixel(at location: CGPoint) -> (x: Int, y: Int)? {
        guard location.x >= 0, location.x < CGFloat(width), location.y >= 0, location.y < CGFloat(height) else { return nil }
        return (Int(Int32(Float(location.x))), Int(Int32(Float(location.y))))
    }

    /// The offsets of the red, green and blue bytes of pixel (x, y) in an ARGB
    /// buffer of four bytes a pixel, row after row.
    public func rgbOffsets(x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        let base = 4 * (x + y * width)
        return (base + 1, base + 2, base + 3)
    }

    /// The red, green and blue of pixel (x, y) of an ARGB buffer.
    public func rgb(x: Int, y: Int, in argb: UnsafePointer<UInt8>) -> (red: Int, green: Int, blue: Int) {
        let offsets = rgbOffsets(x: x, y: y)
        return (Int(argb[offsets.red]), Int(argb[offsets.green]), Int(argb[offsets.blue]))
    }
}
