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

/// A byte mask of a ROI: `bytes` (malloc'd, freed by the caller with free())
/// covers `size` pixels from `origin` on the image.
public struct ROIByteMask {
    public var bytes: UnsafeMutablePointer<UInt8>
    public var size: CGSize
    public var origin: CGPoint
}

/// The masks DCMPix makes of a ROI's outline.
public enum ROIMasks {
    /// The mask of a polygon, pencil or open polygon: its vertices truncated
    /// to the pixel grid, filled as the scanline fill does, with an empty
    /// border of one pixel around it (+[DCMPix getMapFromPolygonROI:...]).
    /// Nil without vertices. The mask is allocated with room for five more
    /// rows and columns than it reports, as before; those bytes are zero.
    public static func polygonMask(_ points: [CGPoint]) -> ROIByteMask? {
        guard !points.isEmpty else { return nil }
        var vertices = points.map(ROIPixelPoint.init)
        var minX = Int32(truncatingIfNeeded: vertices[0].x), maxX = minX
        var minY = Int32(truncatingIfNeeded: vertices[0].y), maxY = minY
        for v in vertices.dropFirst() {
            if v.x < Int(minX) { minX = Int32(truncatingIfNeeded: v.x) }
            if v.x > Int(maxX) { maxX = Int32(truncatingIfNeeded: v.x) }
            if v.y < Int(minY) { minY = Int32(truncatingIfNeeded: v.y) }
            if v.y > Int(maxY) { maxY = Int32(truncatingIfNeeded: v.y) }
        }
        for i in vertices.indices {
            vertices[i].x &-= Int(minX)
            vertices[i].y &-= Int(minY)
        }
        let size = CGSize(width: Double(maxX &- minX &+ 2), height: Double(maxY &- minY &+ 2))
        let room = Int((5 + Double(size.height)) * (5 + Double(size.width)))
        guard room > 0, let map = calloc(room, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }

        // The runs the scanline fill sets to 255 inside the polygon, straight
        // into the bytes: the C filled a zeroed float image with 255 and
        // converted it, which gives the same bytes.
        let width = Int(size.width), height = Int(size.height)
        if vertices.count > 1 && width > 0 && height > 0 {
            ROIScanline.forEachRow(of: vertices, rows: height) { y, row in
                let columns = row.baseAddress!, n = row.count
                var i = 0
                while i < n {
                    let start = clamped(columns[i], 0, width)
                    let end = clamped(columns[i + 1], 0, width - 1)
                    if end >= start { memset(map + (y * width + start), 255, end - start + 1) }
                    i += 2
                }
            }
        }
        let rows = Int(ROIRasterConversion.int32(Double(size.height))), columns = Int(ROIRasterConversion.int32(Double(size.width)))
        // An empty border around the mask.
        var i = 0
        while i < columns {
            map[i] = 0
            map[(rows - 1) * columns + i] = 0
            i += 1
        }
        i = 0
        while i < rows {
            map[i * columns] = 0
            map[i * columns + columns - 1] = 0
            i += 1
        }
        return ROIByteMask(bytes: map, size: size, origin: CGPoint(x: Double(minX), y: Double(minY)))
    }

    /// The mask of an RT STRUCT contour on an image of `width` x `height`:
    /// the pixels whose centre (x + 0.5, y + 0.5) lies inside the outline by
    /// the even-odd rule, fractional vertices kept, the left edge in and the
    /// right one out, with an empty border of one pixel
    /// (+[DCMPix getMapFromRTSTRUCTROI:...]). Nil for fewer than three
    /// vertices, a vertex that is not finite or a contour off the image.
    public static func contourMask(_ vertices: [CGPoint], width imageWidth: Int32, height imageHeight: Int32) -> ROIByteMask? {
        let count = vertices.count
        guard count >= 3, imageWidth > 0, imageHeight > 0, imageWidth <= Int32.max - 2, imageHeight <= Int32.max - 2 else { return nil }
        var minX = Double(imageWidth), minY = Double(imageHeight), maxX = 0.0, maxY = 0.0
        for v in vertices {
            guard v.x.isFinite && v.y.isFinite else { return nil }
            minX = fmin(minX, v.x); maxX = fmax(maxX, v.x)
            minY = fmin(minY, v.y); maxY = fmax(maxY, v.y)
        }
        let firstX = Int(Int32(floor(fmax(0, fmin(Double(imageWidth), minX)))))
        let firstY = Int(Int32(floor(fmax(0, fmin(Double(imageHeight), minY)))))
        let lastX = Int(Int32(ceil(fmax(0, fmin(Double(imageWidth), maxX))))) - 1
        let lastY = Int(Int32(ceil(fmax(0, fmin(Double(imageHeight), maxY))))) - 1
        guard lastX >= firstX, lastY >= firstY else { return nil }
        let width = lastX - firstX + 3, height = lastY - firstY + 3
        guard let map = calloc(width, height)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let crossings = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { crossings.deallocate() }
        vertices.withUnsafeBufferPointer { buffer in
            let vertices = buffer.baseAddress!
            var y = firstY
            while y <= lastY {
                defer { y += 1 }
                let sampleY = Double(y) + 0.5
                var n = 0
                var j = count - 1, i = 0
                while i < count {
                    let a = vertices[j], b = vertices[i]
                    if (a.y > sampleY) != (b.y > sampleY) {
                        // Sorted as they come (insertion), as qsort ordered them.
                        let x = a.x.addingProduct((sampleY - a.y) / (b.y - a.y), b.x - a.x)
                        var k = n
                        while k > 0 && crossings[k - 1] > x {
                            crossings[k] = crossings[k - 1]
                            k -= 1
                        }
                        crossings[k] = x
                        n += 1
                    }
                    j = i
                    i += 1
                }
                i = 0
                while i + 1 < n {
                    let start = Int(Int32(ceil(fmax(Double(firstX), fmin(Double(lastX + 1), crossings[i] - 0.5)))))
                    let end = Int(Int32(ceil(fmax(Double(firstX), fmin(Double(lastX + 1), crossings[i + 1] - 0.5)))))
                    if end > start {
                        memset(map + (y - firstY + 1) * width + start - firstX + 1, 255, end - start)
                    }
                    i += 2
                }
            }
        }
        return ROIByteMask(bytes: map, size: CGSize(width: Double(width), height: Double(height)),
                           origin: CGPoint(x: Double(firstX - 1), y: Double(firstY - 1)))
    }
}

/// The pixels of a line ROI, from its first point to its second: Bresenham's
/// line, both ends included (BresLine of DCMPix).
public enum ROILineRaster {
    public static func pixels(fromX ax: Int32, y ay: Int32, toX bx: Int32, y by: Int32) -> (x: [Int], y: [Int]) {
        var ax = ax, ay = ay
        var xs: [Int] = [], ys: [Int] = []
        var dX = abs(bx &- ax), dY = abs(by &- ay)
        xs.reserveCapacity(Int(dX) + Int(dY) + 2)
        ys.reserveCapacity(Int(dX) + Int(dY) + 2)
        let xIncrement: Int32 = ax > bx ? -1 : 1, yIncrement: Int32 = ay > by ? -1 : 1
        if dX >= dY {
            let right = dY << 1, rightUp = right &- (dX << 1)
            var decision = right &- dX
            while dX >= 0 {
                xs.append(Int(ax)); ys.append(Int(ay))
                if decision > 0 {
                    ax &+= xIncrement; ay &+= yIncrement; decision &+= rightUp
                } else {
                    ax &+= xIncrement; decision &+= right
                }
                dX -= 1
            }
        } else {
            let right = dX << 1, rightUp = right &- (dY << 1)
            var decision = right &- dY
            while dY >= 0 {
                xs.append(Int(ax)); ys.append(Int(ay))
                if decision > 0 {
                    ax &+= xIncrement; ay &+= yIncrement; decision &+= rightUp
                } else {
                    ay &+= yIncrement; decision &+= right
                }
                dY -= 1
            }
        }
        return (xs, ys)
    }
}

/// Whether a point lies inside a polygon, by the even-odd rule (pnpoly of DCMPix).
public enum ROIPolygonContainment {
    public static func contains(_ polygon: [CGPoint], x: Float, y: Float) -> Bool {
        var inside = false
        let px = Double(x), py = Double(y)
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i], pj = polygon[j]
            if ((pi.y <= py && py < pj.y) || (pj.y <= py && py < pi.y)) &&
                px < (pj.x - pi.x) * (py - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
