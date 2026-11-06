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

import Foundation

/// The ROIs a viewer makes from a buffer: brushes from a mask of labels, one
/// per label and per image, and the picture of a layer from the values inside
/// a ROI. Only the arithmetic is here; the viewer makes the ROIs from it.
public enum ROIFromMask {

    /// A colour, 16 bits per channel, as a ROI keeps it.
    public struct Colour: Equatable, Sendable {
        public let red: UInt16
        public let green: UInt16
        public let blue: UInt16

        public init(red: UInt16, green: UInt16, blue: UInt16) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The colours the regions of a mask take in turn: yellow, magenta, red,
    /// blue, green and turquoise.
    public static let palette: [Colour] = [
        Colour(red: UInt16((239.0 / 255.0) * 65535.0), green: UInt16((239.0 / 255.0) * 65535.0), blue: 37),
        Colour(red: UInt16((239.0 / 255.0) * 65535.0), green: UInt16((10.0 / 255.0) * 65535.0), blue: UInt16((239.0 / 255.0) * 65535)),
        Colour(red: 65535, green: 0, blue: 0),
        Colour(red: 0, green: 0, blue: 65535),
        Colour(red: 0, green: 65535, blue: 0),
        Colour(red: 0, green: UInt16((241.0 / 255.0) * 65535.0), blue: UInt16((220.0 / 255.0) * 65535.0)),
    ]

    /// The colour of the `index`-th region of a mask.
    public static func colour(ofRegion index: Int) -> Colour {
        palette[index % palette.count]
    }

    /// The labels of a mask: its values other than 0, each once, in the order
    /// they first appear.
    public static func labels(in mask: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var seen = [Bool](repeating: false, count: 256)
        var labels: [UInt8] = []
        for value in mask where value != 0 && !seen[Int(value)] {
            seen[Int(value)] = true
            labels.append(value)
        }
        return labels
    }

    /// The name of the brush of `label`: the name given, or "area <label>"
    /// for an empty one. No name stays none.
    public static func name(_ name: String?, label: UInt8) -> String? {
        name == "" ? String(format: "area %d", Int32(label)) : name
    }

    /// The pixels of one label in one image: their bounding box and the
    /// brush mask over it, 0xFF where the label is.
    public struct Region: Equatable, Sendable {
        /// The left and top of the box, in pixels of the image.
        public let x: Int32
        public let y: Int32
        public let width: Int32
        public let height: Int32
        /// `width` x `height` bytes, row after row.
        public let texture: [UInt8]
    }

    /// The region of `label` in `slice`, an image of `width` x `height`
    /// bytes, row after row; nil when the label is not in it.
    public static func region(of label: UInt8, in slice: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> Region? {
        var left = Int32(truncatingIfNeeded: width), top = Int32(truncatingIfNeeded: height), right: Int32 = 0, bottom: Int32 = 0
        var found = false
        for j in 0..<height {
            for i in 0..<width where slice[i + j * width] == label {
                found = true
                left = min(left, Int32(i))
                top = min(top, Int32(j))
                right = max(right, Int32(i))
                bottom = max(bottom, Int32(j))
            }
        }
        guard found else { return nil }
        let boxWidth = right &- left &+ 1, boxHeight = bottom &- top &+ 1
        var texture = [UInt8](repeating: 0, count: Int(boxWidth) * Int(boxHeight))
        for j in Int(top)...Int(bottom) {
            for i in Int(left)...Int(right) where slice[i + j * width] == label {
                texture[(i - Int(left)) + (j - Int(top)) * Int(boxWidth)] = 0xFF
            }
        }
        return Region(x: left, y: top, width: boxWidth, height: boxHeight, texture: texture)
    }

    /// The picture of a layer ROI made from the values inside a ROI: their
    /// bounds, and each value drawn at its location through the window.
    public struct Layer: Equatable, Sendable {
        public let minX: Float
        public let minY: Float
        public let maxX: Float
        public let maxY: Float
        /// The size of the picture, in pixels.
        public let width: Int32
        public let height: Int32

        /// The layer of the `count` points of `locations` (x and y
        /// interleaved); its bounds are those of the points whose coordinates
        /// are both finite. Nil when none is.
        public init?(locations: UnsafePointer<Float>, count: Int) {
            var bounds: (Float, Float, Float, Float)? = nil
            for i in 0..<max(count, 0) {
                let x = locations[2 * i], y = locations[2 * i + 1]
                if !x.isFinite || !y.isFinite { continue }
                if let b = bounds {
                    bounds = (min(b.0, x), min(b.1, y), max(b.2, x), max(b.3, y))
                } else {
                    bounds = (x, y, x, y)
                }
            }
            guard let (minX, minY, maxX, maxY) = bounds else { return nil }
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
            width = cInt32(maxX - minX + 1)
            height = cInt32(maxY - minY + 1)
        }

        /// Draws the `count` values at their `locations` into `pixels`, an
        /// RGBA picture of `width` x `height` with `bytesPerRow` bytes a row: grey
        /// through the window `windowLevel`/`windowWidth`, or the value itself
        /// for a colour image, opaque. A point outside the picture, or whose
        /// coordinates are not finite, is not drawn.
        public func draw(values: UnsafePointer<Float>, locations: UnsafePointer<Float>, count: Int,
                         windowLevel: Float, windowWidth: Float, isRGB: Bool,
                         into pixels: UnsafeMutablePointer<UInt8>, bytesPerRow: Int32) {
            let windowMax = Float(Double(windowLevel) + 0.5 * Double(windowWidth))
            let windowMin = Float(Double(windowLevel) - 0.5 * Double(windowWidth))
            // The transfer curve: grey = a * value + b.
            let a = Float(255.0 / Double(windowWidth))
            let b = -a * windowMin
            for i in 0..<max(count, 0) {
                let x = locations[2 * i] - minX
                let y = locations[2 * i + 1] - minY
                let value = values[i]
                guard x.isFinite, y.isFinite, x >= 0, y >= 0, cInt32(x) < width, cInt32(y) < height else { continue }
                let grey: UInt8
                if !isRGB {
                    if value > windowMax { grey = 255 }
                    else if value < windowMin { grey = 0 }
                    // a * value + b as one fused multiply-add, converted to an
                    // int whose low byte is kept, as the C conversion to an
                    // unsigned char did.
                    else { grey = UInt8(truncatingIfNeeded: cInt32(b.addingProduct(a, value))) }
                } else {
                    grey = UInt8(truncatingIfNeeded: cInt32(value))
                }
                let xi = cInt32(x), yi = cInt32(y)
                pixels[Int(4 &* xi &+ yi &* bytesPerRow)] = grey
                pixels[Int(4 &* xi &+ 1 &+ yi &* bytesPerRow)] = grey
                pixels[Int(4 &* xi &+ 2 &+ yi &* bytesPerRow)] = grey
                pixels[Int(4 &* xi &+ 3 &+ yi &* bytesPerRow)] = 255
            }
        }
    }
}

/// A float converted to an int as the C conversion on arm64 does: NaN is 0,
/// and a value out of range saturates, where Swift would trap.
private func cInt32(_ value: Float) -> Int32 {
    if value.isNaN { return 0 }
    if value >= Float(Int32.max) { return Int32.max }
    if value <= Float(Int32.min) { return Int32.min }
    return Int32(value)
}
