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

import CoreGraphics
import Foundation

/// The arithmetic of DCMView's drawing that needs neither the view nor
/// AppKit: where a string of the annotations goes, where the overlay puts a
/// point, the reference lines and their slab, the 2D point marker, the
/// repulsor's circle, the magnifier's outlines and the patient crosshair.
/// The Objective-C was compiled with floating-point contraction: the
/// multiply-adds the compiler fused are fused here (`addingProduct`), in the
/// same order, for the same bits.
public enum DrawingGeometry {

    // MARK: - Conversions as the arm64 code of the C did

    /// A double converted to long (fcvtzs): toward zero, saturated, NaN to 0.
    public static func cLong(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        if x >= 9223372036854775807.0 { return Int.max }
        if x <= -9223372036854775808.0 { return Int.min }
        return Int(x)
    }

    /// A float converted to long, the same way.
    public static func cLong(_ x: Float) -> Int {
        return cLong(Double(x))
    }

    /// A float converted to int (fcvtzs to a 32-bit register): toward zero,
    /// saturated, NaN to 0.
    public static func cInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        if x >= 2147483648.0 { return Int32.max }
        if x <= -2147483648.0 { return Int32.min }
        return Int32(x)
    }

    /// The 2/size scale and -size/2 translation that map backing pixels to the
    /// canvas's -1...1 range, computed in double from a float literal and
    /// passed as float, as the C did.
    public static func pixelGrid(width: CGFloat, height: CGFloat) -> (scaleX: Float, scaleY: Float, translateX: Float, translateY: Float) {
        return (Float(2.0 / Double(width)), Float(-2.0 / Double(height)), Float(-Double(width) / 2.0), Float(-Double(height) / 2.0))
    }

    // MARK: - Annotation overlay

    /// A coordinate of the overlay, in backing pixels, kept to 1/1024 of a
    /// pixel (C round: half away from zero).
    public static func overlayPixel(_ value: CGFloat) -> CGFloat {
        return (value * 1024).rounded(.toNearestOrAwayFromZero) / 1024
    }

    /// The rectangle with corners `a` and `b`, as MIN and fabs made it.
    public static func overlayRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        return CGRect(x: a.x < b.x ? a.x : b.x, y: a.y < b.y ? a.y : b.y, width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Text alignment: DCMViewTextAlignLeft, Center, Right.
    public enum TextAlignment: Int, Sendable {
        case left = 0, center = 1, right = 2
    }

    /// Where a string drawn as a texture goes: `x` moved by the alignment
    /// (right: the bitmap's width; centre: half of it; left: five points), the
    /// bitmap's top left corner, and the rectangle it occupies from the
    /// frame's centre (`frame`), which the ROI labels keep away from.
    public static func texturedText(x: Int, y: Int, align: TextAlignment, pixelWidth: Int, pixelHeight: Int,
                                    scale sf: Float, frame: CGSize) -> (left: Double, top: Double, occupied: CGRect) {
        var x = x
        switch align {
        case .right: x -= pixelWidth
        case .center: x = cLong(Double(x) - Double(pixelWidth) / 2.0)
        case .left: x = cLong(Float(x).addingProduct(-5, sf))
        }
        let xc = x + 2
        let yc = y + 1 - pixelHeight
        let occupied = CGRect(x: CGFloat(xc) - frame.width / 2, y: CGFloat(yc) - frame.height / 2,
                              width: CGFloat(pixelWidth + 1), height: CGFloat(pixelHeight + 1))
        return (Double(xc), Double(yc), occupied)
    }

    /// Where a string drawn as glyphs on its line goes: the line started at
    /// `x` and sat on `y`; the bitmap is moved by its own width for the
    /// alignment, four points left, and down by the margin under the line.
    public static func glyphText(x: Int, y: Int, align: TextAlignment, labelFont: Bool, stringWidth: CGFloat,
                                 lineBottom: CGFloat, pixelHeight: Int, scale sf: Float) -> (left: Double, top: Double) {
        var x = x
        switch align {
        case .right: x = cLong(Double(x) - (Double(stringWidth) + Double(labelFont ? 2 * sf : 2)))
        case .center: x = cLong(Double(x) - (Double(stringWidth) / 2.0 + Double(2 * sf)))
        case .left: break
        }
        let left = Double(Float(x).addingProduct(-4, sf))
        let top = Double(y) + Double(lineBottom) - Double(pixelHeight)
        return (left, top)
    }

    // MARK: - Reference lines

    /// A reference line `c` (x0, y0, z0, x1, y1, z1) moved by `shift` across
    /// itself, and its unit normal (a0, a1); the line as it was and (0, 0)
    /// without a shift or a perpendicular.
    public static func shiftedCrossLine(_ sft: [Float], perpendicular: Bool, shift: Double) -> (line: [Float], a0: Float, a1: Float) {
        var c = sft
        var a1: Float = 0, a0: Float = 0
        if perpendicular || shift != 0 {
            a1 = c[0] - c[3]
            a0 = c[1] - c[4]
            let t = Double((a0 * a0).addingProduct(a1, a1)).squareRoot()
            a0 = Float(Double(a0) / t)
            a1 = Float(Double(a1) / t)
            c[0] = Float(Double(c[0]).addingProduct(Double(a0), shift))
            c[1] = Float(Double(c[1]).addingProduct(-Double(a1), shift))
            c[3] = Float(Double(c[3]).addingProduct(Double(a0), shift))
            c[4] = Float(Double(c[4]).addingProduct(-Double(a1), shift))
        }
        return (c, a0, a1)
    }

    /// The middle of a reference line, where its point is drawn.
    public static func crossLineMiddle(_ c: [Float]) -> (x: Float, y: Float) {
        return (Float(Double(c[0] + c[3]) / 2.0), Float(Double(c[1] + c[4]) / 2.0))
    }

    /// An end (`x`, `y`) of a reference line moved by half the slab
    /// `thickness` along the normal (a0, a1), on the side `sign` (1 or -1).
    public static func slabEdge(x: Float, y: Float, a0: Float, a1: Float, thickness: Float, sign: Double) -> (x: Float, y: Float) {
        return (Float(Double(x) + sign * (Double(a0 * thickness) / 2.0)), Float(Double(y) - sign * (Double(a1 * thickness) / 2.0)))
    }

    /// The 3D point in the image's grid, from the image's centre, in pixels.
    public static func slicePoint(_ point: (Float, Float), pixelSpacingX: Double, pixelSpacingY: Double,
                                  width: Int, height: Int) -> (x: Float, y: Float) {
        var x = Float(Double(point.0) / pixelSpacingX)
        var y = Float(Double(point.1) / pixelSpacingY)
        x = x.addingProduct(-Float(width), 0.5)
        y = y.addingProduct(-Float(height), 0.5)
        return (x, y)
    }

    /// The unit normal of the reference line (x0, y0) - (x1, y1).
    public static func crossLineNormal(x0: Float, y0: Float, x1: Float, y1: Float) -> (a0: Float, a1: Float) {
        let a1 = x0 - x1
        let a0 = y0 - y1
        let t = Double((a0 * a0).addingProduct(a1, a1)).squareRoot()
        return (Float(Double(a0) / t), Float(Double(a1) / t))
    }

    // MARK: - Markers

    /// The blue cross of the 3D panel's point (`point`, in the image's pixels):
    /// four segments, from 5 to 40 pixels around it, at `scale`.
    public static func pointMarker(_ point: CGPoint, width: Int, height: Int, scale: Float) -> [(Float, Float)] {
        let crossx = Float(Double(point.x) - Double(width) / 2.0)
        let crossy = Float(Double(point.y) - Double(height) / 2.0)
        return [(scale * (crossx - 40), scale * crossy), (scale * (crossx - 5), scale * crossy),
                (scale * (crossx + 40), scale * crossy), (scale * (crossx + 5), scale * crossy),
                (scale * crossx, scale * (crossy - 40)), (scale * crossx, scale * (crossy - 5)),
                (scale * crossx, scale * (crossy + 5)), (scale * crossx, scale * (crossy + 40))]
    }

    /// The repulsor's circle: as many points as its radius asks for, around
    /// `center` (backing pixels), at `scale`.
    public static func repulsorCircle(center: CGPoint, radius: Int, scale: Float) -> [(Float, Float)] {
        var resolution = 20
        resolution = radius > 5 ? 30 : resolution
        resolution = radius > 10 ? 40 : resolution
        resolution = radius > 50 ? 60 : resolution
        resolution = radius > 70 ? 80 : resolution
        var points: [(Float, Float)] = []
        for i in 0..<resolution {
            let alpha = Float(Double(i * 2) * Double.pi / Double(resolution))
            let x = Double(center.x).addingProduct(Double(radius) * cos(Double(alpha)), Double(scale))
            let y = Double(center.y).addingProduct(Double(radius) * sin(Double(alpha)), Double(scale))
            points.append((Float(x), Float(y)))
        }
        return points
    }

    /// The repulsor's alpha one step further, bouncing between 0.1 and 0.4.
    public static func repulsorAlphaStep(alpha: Float, sign: Float) -> (alpha: Float, sign: Float) {
        var sign = sign
        if Double(alpha) >= 0.4 { sign = -1.0 } else if Double(alpha) <= 0.1 { sign = 1.0 }
        return (Float(Double(alpha).addingProduct(Double(sign), 0.02)), sign)
    }

    // MARK: - Magnifier

    /// A point of the view (`point`) in the magnifier's picture, `side`
    /// pixels wide, centred on `cursor` and `magnification` times larger.
    public static func magnifierPoint(_ point: CGPoint, cursor: CGPoint, side: Int, magnification: Float, scale sf: Float) -> CGPoint {
        let half = Double(Float(side) / 2.0)
        return CGPoint(x: half.addingProduct((Double(point.x) - Double(cursor.x)) * Double(magnification), Double(sf)),
                       y: half.addingProduct(-((Double(point.y) - Double(cursor.y)) * Double(magnification)), Double(sf)))
    }

    /// The magnifier's magnification for the lens's zoom factor.
    public static func magnification(zoomFactor: Float) -> Float {
        return 4.0 / ((zoomFactor < 2.2 ? 2.2 : zoomFactor) - 2.0)
    }

    // MARK: - Patient crosshair

    /// The patient-space marker's offset from the image's centre, at `zoom`:
    /// `slice` (mm) over the spacing, less half the image.
    public static func patientCrosshair(slice: Float, pixelSpacing: Double, size: Int, zoom: Float) -> Float {
        return Float(Double(zoom) * (Double(slice) / pixelSpacing).addingProduct(-Double(size), 0.5))
    }
}
