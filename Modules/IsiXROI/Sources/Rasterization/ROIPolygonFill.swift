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

/// A plane of an image or of a volume that a ROI is drawn on, over the float
/// buffer DCMPix holds (an ARGB pixel takes the place of a float).
///
/// Orientation 2 is the image itself; 0 and 1 cut a contiguous volume of
/// `sliceCount` images of `width` x `height`: 0 at column `stackNo` (the
/// plane's columns are the image rows, its rows the slices), 1 at row
/// `stackNo` (columns are the image columns, rows the slices).
public struct ROIPlane {
    public var pixels: UnsafeMutablePointer<Float>
    public var width: Int
    public var height: Int
    public var sliceCount: Int
    public var orientation: Int
    public var stackNo: Int
    public var isRGB: Bool

    public init(pixels: UnsafeMutablePointer<Float>, width: Int, height: Int, sliceCount: Int,
                orientation: Int, stackNo: Int, isRGB: Bool) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.sliceCount = sliceCount
        self.orientation = orientation
        self.stackNo = stackNo
        self.isRGB = isRGB
    }

    /// The columns of a row of the plane.
    public var rowLength: Int { orientation == 0 ? height : width }

    /// The rows of the plane the scanline fill walks.
    public var rowCount: Int { orientation == 2 ? height : sliceCount }

    /// Whether the plane is one of the volume: the C drew nothing otherwise.
    public var isValid: Bool {
        guard (0...2).contains(orientation), width > 0, height > 0, sliceCount > 0, rowLength > 0 else { return false }
        switch orientation {
        case 0: return stackNo >= 0 && stackNo < width
        case 1: return stackNo >= 0 && stackNo < height
        default: return stackNo >= 0 && stackNo < sliceCount
        }
    }

    /// Where column `x` of row `y` lies in the buffer, and the step to the next column.
    @inline(__always)
    public func offset(row y: Int, column x: Int) -> (start: Int, step: Int) {
        let slab = width &* height
        switch orientation {
        case 0: return (y &* slab &+ x &* width &+ stackNo, width)
        case 1: return (y &* slab &+ x &+ stackNo &* width, 1)
        default: return (y &* width &+ x, 1)
        }
    }

    /// Where column `x` of row `y` lies in the image a restore copy holds (one slice).
    @inline(__always)
    func restoreOffset(row y: Int, column x: Int) -> Int {
        switch orientation {
        case 0: return x &* width &+ stackNo
        case 1: return x &+ stackNo &* width
        default: return y &* width &+ x
        }
    }

    /// Sets (or adds to) the pixels of `count` columns from `start` of row `y`
    /// whose value is within `minimum`...`maximum`. An ARGB pixel is three
    /// bytes, each tested and converted on its own.
    @inline(__always)
    public func paint(row y: Int, from start: Int, count: Int, minimum: Float, maximum: Float, value: Float, addition: Bool) {
        if count <= 0 { return }
        let (index, step) = offset(row: y, column: start)
        ROIPlane.paint(pixels, isRGB: isRGB, from: index, step: step, count: count,
                       minimum: minimum, maximum: maximum, value: value, addition: addition)
    }

    /// Sets (or adds to) `count` pixels of `pixels` from `index`, `step` apart,
    /// whose value is within `minimum`...`maximum`.
    @inline(__always)
    static func paint(_ pixels: UnsafeMutablePointer<Float>, isRGB: Bool, from index: Int, step: Int, count: Int,
                      minimum: Float, maximum: Float, value: Float, addition: Bool) {
        if count <= 0 { return }
        var index = index, left = count
        if isRGB {
            let bytes = UnsafeMutableRawPointer(pixels).assumingMemoryBound(to: UInt8.self)
            @inline(__always) func channel(_ pixel: UnsafeMutablePointer<UInt8>) {
                let current = Float(pixel.pointee)
                if current >= minimum && current <= maximum {
                    pixel.pointee = ROIRasterConversion.byte(addition ? current + value : value)
                }
            }
            while left > 0 {
                let pixel = bytes + index &* 4
                channel(pixel + 1)
                channel(pixel + 2)
                channel(pixel + 3)
                index &+= step
                left &-= 1
            }
        } else if addition {
            while left > 0 {
                let current = pixels[index]
                if current >= minimum { if current <= maximum { pixels[index] = current + value } }
                index &+= step
                left &-= 1
            }
        } else {
            // Four pixels a turn: without optimization (Debug) the loop itself
            // costs as much as the test; each pixel is still tested on its own.
            let step2 = step &* 2, step3 = step &* 3, step4 = step &* 4
            while left >= 4 {
                let a = pixels[index], b = pixels[index &+ step], c = pixels[index &+ step2], d = pixels[index &+ step3]
                if a >= minimum { if a <= maximum { pixels[index] = value } }
                if b >= minimum { if b <= maximum { pixels[index &+ step] = value } }
                if c >= minimum { if c <= maximum { pixels[index &+ step2] = value } }
                if d >= minimum { if d <= maximum { pixels[index &+ step3] = value } }
                index &+= step4
                left &-= 4
            }
            while left > 0 {
                let current = pixels[index]
                if current >= minimum { if current <= maximum { pixels[index] = value } }
                index &+= step
                left &-= 1
            }
        }
    }
}

/// `value` within `low`...`high` (`low` when they cross), without the generic
/// `min`/`max`, which a build without optimization calls through.
@inline(__always)
func clamped(_ value: Int, _ low: Int, _ high: Int) -> Int {
    var result = value
    if result > high { result = high }
    if result < low { result = low }
    return result
}

/// The scanline fill of a polygon on a plane: inside or outside it, with a
/// threshold, a value set or added, or the pixels a restore copy holds.
public enum ROIPolygonFill {
    /// Fills `polygon` on `plane`, as -[DCMPix fillROI:...] did through
    /// ras_FillPolygon. With `restore`, the pixels inside come back from the
    /// copy `restoreImage` gives for a slice (a slice for an axial plane, the
    /// plane's row otherwise); a row without one is left as it is.
    public static func fill(_ polygon: [ROIPixelPoint], on plane: ROIPlane,
                            minimum: Float, maximum: Float, outside: Bool, value: Float, addition: Bool,
                            restore: Bool, restoreImage: (Int) -> UnsafeMutablePointer<Float>?,
                            outOfRange: (Int, Int) -> Void = { _, _ in }) {
        guard plane.isValid else { return }
        let limit = plane.rowLength
        ROIScanline.forEachRow(of: polygon, rows: plane.rowCount, outOfRange: outOfRange) { y, row in
            let columns = row.baseAddress!, n = row.count
            if outside {
                var i = 0
                while i < n {
                    var start: Int, end: Int
                    if i == 0 {
                        start = 0
                        end = clamped(columns[0], 0, limit)
                        i = -1
                    } else {
                        start = clamped(columns[i] &+ 1, 0, limit)
                        end = i == n - 1 ? limit : columns[i + 1]
                        end = clamped(end, 0, limit)
                    }
                    plane.paint(row: y, from: start, count: end - start, minimum: minimum, maximum: maximum, value: value, addition: addition)
                    i += 2
                }
                return
            }
            var i = 0
            while i < n {
                defer { i += 2 }
                let start = clamped(columns[i], 0, limit)
                let end = clamped(columns[i + 1], 0, limit - 1)  // inclusive: never into the next row
                var source: UnsafeMutablePointer<Float>?
                if restore {
                    let slice = plane.orientation == 2 ? plane.stackNo : y
                    guard slice >= 0 && slice < plane.sliceCount, let copy = restoreImage(slice) else { continue }
                    source = copy
                }
                var left = end - start + 1
                if left <= 0 { continue }
                guard let source else {
                    plane.paint(row: y, from: start, count: left, minimum: minimum, maximum: maximum, value: value, addition: addition)
                    continue
                }
                var (index, step) = plane.offset(row: y, column: start)
                var from = plane.restoreOffset(row: y, column: start)
                if plane.isRGB {
                    // An ARGB pixel takes the place of a float in the copy too:
                    // its three colour bytes come back as they were.
                    let bytes = UnsafeMutableRawPointer(plane.pixels).assumingMemoryBound(to: UInt8.self)
                    let original = UnsafeMutableRawPointer(source).assumingMemoryBound(to: UInt8.self)
                    while left > 0 {
                        let pixel = bytes + index &* 4, kept = original + from &* 4
                        pixel[1] = kept[1]
                        pixel[2] = kept[2]
                        pixel[3] = kept[3]
                        index &+= step
                        from &+= step
                        left &-= 1
                    }
                } else if step == 1 {
                    (plane.pixels + index).update(from: source + from, count: left)
                } else {
                    while left > 0 {
                        plane.pixels[index] = source[from]
                        index &+= step
                        from &+= step
                        left &-= 1
                    }
                }
            }
        }
    }

    /// The values and locations of the pixels inside `polygon` on an image
    /// (orientation 2), row by row, into buffers of `capacity` pixels; an
    /// ARGB pixel counts as the mean of its three colours. Answers how many
    /// were written.
    public static func sample(_ polygon: [ROIPixelPoint], image: UnsafePointer<Float>, width: Int, height: Int, isRGB: Bool,
                              values: UnsafeMutablePointer<Float>, locations: UnsafeMutablePointer<Float>?, capacity: Int,
                              outOfRange: (Int, Int) -> Void = { _, _ in }) -> Int {
        guard width > 0, height > 0 else { return 0 }
        var count = 0
        let bytes = UnsafeRawPointer(image).assumingMemoryBound(to: UInt8.self)
        ROIScanline.forEachRow(of: polygon, rows: height, outOfRange: outOfRange) { y, row in
            let columns = row.baseAddress!, n = row.count
            var i = 0
            while i < n {
                let start = clamped(columns[i], 0, width)
                let end = clamped(columns[i + 1], 0, width - 1)
                i += 2
                if end < start { continue }
                let run = end - start + 1
                if count + run > capacity { return }
                let first = y &* width &+ start
                if isRGB {
                    var k = 0
                    while k < run {
                        let pixel = bytes + (first &+ k) &* 4
                        values[count &+ k] = Float(Double(Int(pixel[1]) + Int(pixel[2]) + Int(pixel[3])) / 3.0)
                        k &+= 1
                    }
                } else {
                    (values + count).update(from: image + first, count: run)
                }
                if let locations {
                    let row = Float(y)
                    var k = 0, at = count &* 2
                    while k < run {
                        locations[at] = Float(start &+ k)
                        locations[at &+ 1] = row
                        k &+= 1
                        at &+= 2
                    }
                }
                count &+= run
            }
        }
        return count
    }
}
