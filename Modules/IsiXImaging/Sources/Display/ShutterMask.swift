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

/// The shutter of an image's 8-bit picture (-[DCMPix applyShutter]): what is
/// outside the rectangle, the circle and the polygon becomes the black index
/// (a grey picture) or zero (a colour one).
///
/// The rectangle is held inside the picture and rounded first; the offsets
/// are computed in double precision as the Objective-C computed them, with the
/// multiplication fused into the addition (`y * width + x`).
public enum ShutterMask {
    /// `rect` held inside a picture of `width` × `height` and rounded, as
    /// -applyShutter keeps it.
    public static func heldRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        var r = rect
        if r.origin.x < 0 { r.size.width += r.origin.x; r.origin.x = 0 }
        if r.origin.y < 0 { r.size.height += r.origin.y; r.origin.y = 0 }
        if r.size.width + r.origin.x > CGFloat(width) { r.size.width = CGFloat(width) - r.origin.x }
        if r.size.height + r.origin.y > CGFloat(height) { r.size.height = CGFloat(height) - r.origin.y }
        r.origin.y = CGFloat(Float(r.origin.y).rounded())
        r.origin.x = CGFloat(Float(r.origin.x).rounded())
        r.size.width = CGFloat(Float(r.size.width).rounded())
        r.size.height = CGFloat(Float(r.size.height).rounded())
        return r
    }

    /// A grey picture shuttered: `black` outside `rect` (held), outside the
    /// circle when `circleRadius` is not zero, and outside the polygon when
    /// there is one.
    public static func maskGrey(_ picture: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rect: CGRect, black: UInt8,
                                circleCentre: CGPoint, circleRadius: Int, polygon: UnsafePointer<CGPoint>?, polygonCount: Int) {
        let count = height &* width
        guard let temp = malloc(count)?.assumingMemoryBound(to: UInt8.self) else { return }
        defer { free(temp) }
        memset(temp, Int32(black), count)

        let offset = ImagePlaneCoordinates.cLong(Double(rect.origin.x).addingProduct(Double(rect.origin.y), Double(width)))
        let rowBytes = Int(ImagePlaneCoordinates.cUnsignedLong(Double(rect.size.width)))
        var rows = ImagePlaneCoordinates.cInt(Double(rect.size.height))
        var source = picture + offset, destination = temp + offset
        while rows > 0 {
            rows -= 1
            memcpy(destination, source, rowBytes)
            destination += width
            source += width
        }

        if circleRadius != 0 {
            eraseOutsideCircle(temp, width: Int32(truncatingIfNeeded: width), height: Int32(truncatingIfNeeded: height),
                               cx: ImagePlaneCoordinates.cInt(Double(circleCentre.x)), cy: ImagePlaneCoordinates.cInt(Double(circleCentre.y)),
                               radius: Int32(truncatingIfNeeded: circleRadius), black: black)
        }

        if let polygon {
            for y in 0..<max(height, 0) {
                for x in 0..<max(width, 0) where !contains(polygon, count: polygonCount, x: Float(x), y: Float(y)) {
                    temp[x + y * width] = black
                }
            }
        }

        memcpy(picture, temp, count)
    }

    /// A colour picture (four bytes a pixel) shuttered: zero outside `rect` (held).
    public static func maskColour(_ picture: UnsafeMutableRawPointer, width: Int, height: Int, rect: CGRect) {
        let count = height &* width &* 4
        guard let temp = calloc(1, count) else { return }
        defer { free(temp) }

        let offset = ImagePlaneCoordinates.cLong((Double(rect.origin.x) * 4).addingProduct(Double(rect.origin.y) * Double(width), 4))
        let rowBytes = Int(ImagePlaneCoordinates.cUnsignedLong(Double(rect.size.width) * 4))
        var rows = ImagePlaneCoordinates.cInt(Double(rect.size.height))
        var source = picture + offset, destination = temp + offset
        while rows > 0 {
            rows -= 1
            memcpy(destination, source, rowBytes)
            destination += width * 4
            source += width * 4
        }

        memcpy(picture, temp, count)
    }

    /// Whether (x, y) is inside the polygon of `count` points (even-odd rule;
    /// a point on a left or bottom edge is inside, on a right or top one outside).
    public static func contains(_ p: UnsafePointer<CGPoint>, count: Int, x: Float, y: Float) -> Bool {
        var inside = false
        let px = Double(x), py = Double(y)
        var i = 0, j = Int(Int32(truncatingIfNeeded: count) &- 1)
        while i < count {
            let a = p[i], b = p[j]
            if ((a.y <= py && py < b.y) || (b.y <= py && py < a.y)) && px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
            i += 1
        }
        return inside
    }

    /// `black` outside the circle of `radius` around (cx, cy); nothing when the
    /// centre is outside the picture.
    public static func eraseOutsideCircle(_ buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, cx: Int32, cy: Int32,
                                          radius rad: Int32, black: UInt8) {
        let inw = rad &* 2
        let radsqr = (inw &* inw) / 4
        if cx < 0 || cx >= width { return }
        if cy < 0 || cy >= height { return }
        let left = cx &- rad, top = cy &- rad

        func set(_ x: Int32, _ y: Int32) { buffer[Int(x &+ y &* width)] = black }

        // top
        var y: Int32 = 0
        while y <= top {
            var x: Int32 = 0
            while x < width {
                if y >= 0 && y < height { set(x, y) }
                x &+= 1
            }
            y &+= 1
        }
        // bottom
        y = top &+ inw
        while y < height {
            var x: Int32 = 0
            while x < width {
                if y >= 0 && y < height { set(x, y) }
                x &+= 1
            }
            y &+= 1
        }
        // left and right
        y = top
        while y < top &+ inw {
            var x: Int32 = 0
            while x <= left {
                if x < width && y >= 0 && y < height { set(x, y) }
                x &+= 1
            }
            x = left &+ inw
            while x < width {
                if x >= 0 && y >= 0 && y < height { set(x, y) }
                x &+= 1
            }
            y &+= 1
        }
        // the corners of the square around the circle
        var x: Int32 = 0
        while x < rad {
            let xsqr = x &* x
            var dy: Int32 = 0
            while dy < rad {
                if xsqr &+ dy &* dy >= radsqr {
                    for (xx, yy) in [(rad &+ x &+ left, rad &+ dy &+ top), (rad &- x &+ left, rad &+ dy &+ top),
                                     (rad &+ x &+ left, rad &- dy &+ top), (rad &- x &+ left, rad &- dy &+ top)]
                    where xx >= 0 && xx < width && yy >= 0 && yy < height {
                        set(xx, yy)
                    }
                }
                dy &+= 1
            }
            x &+= 1
        }
    }
}
