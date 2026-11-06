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

// The arithmetic of a viewer's presentation: its orientation once turned and
// flipped, the scale that fits an image, the opening framing, the pan of a
// shutter, the window sizes, the fusion's alpha ramp, the scale saved with a
// series, SUV. The view (DCMView+Geometry.swift, in the app) reads its state
// and applies the results; these functions only compute, exactly as the
// Objective-C methods did, including the fused multiply-adds clang made of
// their expressions (see PlaneGeometry).
public enum ViewTransform {

    // MARK: - Orientation

    /// The image's orientation (row, column, normal) as the view shows it:
    /// turned by `rotation` degrees and flipped. `orientation` is the
    /// image's own, 9 values.
    public static func correctedOrientation(_ orientation: [Float], rotation: Float, xFlipped: Bool, yFlipped: Bool,
                                            deg2rad: Double) -> [Float] {
        var o = orientation
        var yRot: Float = -1, xRot: Float = -1
        var rot = rotation

        if yFlipped && xFlipped {
            rot = rot + 180
        } else {
            if yFlipped {
                xRot *= -1
                yRot *= -1
                o[3] *= -1
                o[4] *= -1
                o[5] *= -1
            }
            if xFlipped {
                xRot *= -1
                yRot *= -1
                o[0] *= -1
                o[1] *= -1
                o[2] *= -1
            }
        }

        normal(&o)

        let axis = SIMD3(Double(o[6]), Double(o[7]), Double(o[8]))
        var vector = PlaneGeometry.arbitraryRotate(SIMD3(Double(o[0]), Double(o[1]), Double(o[2])),
                                                   theta: Double(xRot * rot) * deg2rad, axis: axis)
        o[0] = Float(vector.x)
        o[1] = Float(vector.y)
        o[2] = Float(vector.z)

        vector = PlaneGeometry.arbitraryRotate(SIMD3(Double(o[3]), Double(o[4]), Double(o[5])),
                                               theta: Double(yRot * rot) * deg2rad, axis: axis)
        o[3] = Float(vector.x)
        o[4] = Float(vector.y)
        o[5] = Float(vector.z)

        normal(&o)

        for start in [0, 3, 6] {
            let length = Double((o[start + 1] * o[start + 1]).addingProduct(o[start], o[start])
                .addingProduct(o[start + 2], o[start + 2])).squareRoot()
            if length != 0 {
                o[start] = Float(Double(o[start]) / length)
                o[start + 1] = Float(Double(o[start + 1]) / length)
                o[start + 2] = Float(Double(o[start + 2]) / length)
            }
        }
        return o
    }

    /// The normal o[6...8] = row × column.
    static func normal(_ o: inout [Float]) {
        o[6] = (-(o[2] * o[4])).addingProduct(o[1], o[5])
        o[7] = (-(o[0] * o[5])).addingProduct(o[2], o[3])
        o[8] = (-(o[1] * o[3])).addingProduct(o[0], o[4])
    }

    // MARK: - Fitting

    /// The extent of a `width` × `height` image turned by `rotation` degrees.
    static func rotatedExtent(width w: Double, height h: Double, rotation: Float) -> (width: Double, height: Double) {
        let radians = Double(rotation) * Double.pi / 180.0
        let c = abs(cos(radians)), s = abs(sin(radians))
        return ((s * h).addingProduct(c, w), (c * h).addingProduct(s, w))
    }

    /// The scale at which an image of `width` × `height` pixels, of pixel
    /// ratio `pixelRatio`, turned by `rotation` degrees, fits a view of
    /// `viewSize` backing pixels; `fallback` when either has no size.
    public static func fitScale(viewSize: CGSize, width: Double, height: Double, pixelRatio: Double,
                                rotation: Float, fallback: Float) -> Float {
        let rotated = rotatedExtent(width: width, height: height * pixelRatio, rotation: rotation)
        if !rotated.width.isFinite || !rotated.height.isFinite || rotated.width <= 0 || rotated.height <= 0
            || viewSize.width <= 0 || viewSize.height <= 0 {
            return fallback
        }
        let a = viewSize.width / rotated.width, b = viewSize.height / rotated.height
        return Float(a < b ? a : b)
    }

    /// The scale that frames `content` (the part of the image with
    /// something in it) when a series opens, or nil when the whole image is
    /// fitted instead: an empty content, a framing no larger than 5 % over
    /// the full fit (`fullFit`), or none at all. Never more than three
    /// times the full fit.
    public static func openingScale(content: CGRect, viewport: CGSize, pixelRatio: Double, rotation: Float,
                                    fullFit: Double) -> Double? {
        let rotated = rotatedExtent(width: content.size.width, height: content.size.height * pixelRatio, rotation: rotation)
        var zoom = fmin(viewport.width / rotated.width, viewport.height / rotated.height)
        zoom = fmin(zoom, fullFit * 3)
        if !zoom.isFinite || rotated.width <= 0 || rotated.height <= 0 || zoom <= fullFit * 1.05 { return nil }
        return zoom
    }

    /// The pan that centres `content` of an image `width` × `height` at
    /// `scale`.
    public static func openingOrigin(content: CGRect, width: Int, height: Int, scale: Float,
                                     pixelRatio: Double) -> (x: Float, y: Float) {
        let midX = content.origin.x.addingProduct(content.size.width, 0.5)
        let midY = content.origin.y.addingProduct(content.size.height, 0.5)
        let x = (-midX).addingProduct(Double(width), 0.5) * Double(scale)
        let y = midY.addingProduct(-Double(height), 0.5) * Double(scale) * pixelRatio
        return (Float(x), Float(y))
    }

    /// The pan that centres the shutter `shutter` of an image `width` ×
    /// `height` at `scale`; the vertical one is multiplied by `pixelRatio`
    /// when given.
    public static func shutterOrigin(width: Int, height: Int, shutter: CGRect, scale: Float,
                                     pixelRatio: Double?) -> CGPoint {
        let x = (Double(Float(width) * 0.5) - shutter.origin.x.addingProduct(shutter.size.width, 0.5)) * Double(scale)
        var y = -(Double(Float(height) * 0.5) - shutter.origin.y.addingProduct(shutter.size.height, 0.5)) * Double(scale)
        if let pixelRatio { y *= pixelRatio }
        return CGPoint(x: x, y: y)
    }

    /// The pan (`x`, `y`) given in the image's axes, turned into the view's
    /// by `rotation` degrees. The vertical value is computed from the turned
    /// horizontal one, as it always was.
    public static func rotatedOrigin(x: Float, y: Float, rotation: Float, deg2rad: Double) -> (x: Float, y: Float) {
        let angle = Double(rotation) * deg2rad
        let newX = Float((Double(y) * sin(angle)).addingProduct(Double(x), cos(angle)))
        let newY = Float((-(Double(y) * cos(angle))).addingProduct(Double(newX), sin(angle)))
        return (newX, newY)
    }

    /// How much a view's scale changes when it goes from `previous` to
    /// `size`: the square root of the area ratio, 0.01 when out of reach.
    public static func resizeFactor(from previous: CGSize, to size: CGSize) -> Float {
        let factor = Float(((size.height / previous.height) * (size.width / previous.width)).squareRoot())
        if Double(factor) > 0.01 && Double(factor) < 1000 { return factor }
        return Float(0.01)
    }

    /// The frame of tile `tag` in a grid of `rows` × `columns` filling
    /// `superSize`, rows from the bottom.
    public static func tileFrame(superSize: CGSize, rows: Int, columns: Int, tag: Int) -> CGRect {
        let width = Int32(superSize.width / CGFloat(columns))
        let height = Int32(superSize.height / CGFloat(rows))
        let y = height * Int32(truncatingIfNeeded: tag / columns)
        let x = width * Int32(truncatingIfNeeded: tag % columns)
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    // MARK: - Window size

    /// The scale of the "Resize Window" menu item of tag `tag`, for an image
    /// `width` × `height`: 25 %, 50 %, 100 %, 200 %, 300 %, or 320 pixels on
    /// its longer side; 1 for an unknown tag.
    public static func windowResizeScale(tag: Int, width: Int, height: Int) -> Float {
        let widthRatio = Float(320.0 / Double(Float(width)))
        let heightRatio = Float(320.0 / Double(Float(height)))
        switch tag {
        case 0: return 0.25
        case 1: return 0.5
        case 2: return 1.0
        case 3: return 2.0
        case 4: return 3.0
        case 5: return widthRatio <= heightRatio ? widthRatio : heightRatio
        default: return 1.0
        }
    }

    /// The window frame that shows an image `width` × `height` at `scale` in
    /// each of its `rows` × `columns` views of `viewSize`, kept centred and
    /// within the screen it is on (`screens`: each screen's frame and its
    /// usable part).
    public static func windowFrame(_ window: CGRect, viewSize: CGSize, width: Int, height: Int, scale: Float,
                                   rows: Int, columns: Int, screens: [(frame: CGRect, usable: CGRect)]) -> CGRect {
        let imageWidth = Float(width) * scale
        let imageHeight = Float(height) * scale
        let frameWidth = Float(viewSize.width)
        let frameHeight = Float(viewSize.height)
        var newWidth = Float(window.size.width - Double((frameWidth - imageWidth) * Float(columns)))
        var newHeight = Float(window.size.height - Double((frameHeight - imageHeight) * Float(rows)))
        var center = CGPoint(x: window.origin.x + window.size.width / 2.0, y: window.origin.y + window.size.height / 2.0)

        for screen in screens where NSPointInRect(center, screen.frame) {
            let usable = screen.usable
            if Double(newHeight) > usable.size.height { newHeight = Float(usable.size.height) }
            if Double(newWidth) > usable.size.width { newWidth = Float(usable.size.width) }
            if center.y + Double(newHeight) / 2.0 > usable.size.height {
                center.y = usable.size.height / 2.0
            }
        }

        var frame = window
        frame.size.height = CGFloat(newHeight)
        frame.size.width = CGFloat(newWidth)
        frame.origin.y = center.y - Double(newHeight) / 2.0
        frame.origin.x = center.x - Double(newWidth) / 2.0
        return frame
    }

    // MARK: - Fusion

    /// The 256 alpha values of a fused image for blending factor `alpha`
    /// (-256 to 256) and blending mode `mode`: linear, high-low-high,
    /// low-high-low, log, inverse log, flat.
    public static func alphaTable(mode: Int, alpha: Float) -> [UInt8] {
        var src = [Float](repeating: 0, count: 256)
        switch mode {
        case 0:
            for i in 0..<256 { src[i] = Float(i) }
        case 1:
            for i in 0..<128 { src[i] = Float((127 - i) * 2) }
            for i in 128..<256 { src[i] = Float((i - 127) * 2) }
        case 2:
            for i in 0..<128 { src[i] = Float(i * 2) }
            for i in 128..<256 { src[i] = Float(256 - (i - 127) * 2) }
        case 3:
            for i in 0..<256 { src[i] = Float(255.0 * log10(1.0.addingProduct(Double(i) / 255.0, 9.0))) }
        case 4:
            for i in 0..<256 { src[i] = Float(255.0 * (1.0 - log10(1.0.addingProduct(Double(255 - i) / 255.0, 9.0)))) }
        case 5:
            for i in 0..<256 { src[i] = 128 }
        default:
            break
        }

        var table = [UInt8](repeating: 0, count: 256)
        var a = alpha
        if a <= 0 {
            a += 256
            for i in 0..<256 {
                table[i] = clampedByte(Float(Double(a * src[i]) / 256.0))
            }
        } else if a == 256 {
            for i in 0..<256 { table[i] = 255 }
        } else {
            for i in 0..<256 {
                table[i] = clampedByte(Float((256.0 * Double(src[i])) / Double(256 - a)))
            }
        }
        return table
    }

    /// `value` limited to 0...255 and truncated, as stored in an unsigned char.
    static func clampedByte(_ value: Float) -> UInt8 {
        var v = value
        if v > 255 { v = 255 }
        if v < 0 { v = 0 }
        return v.isNaN ? 0 : UInt8(v)
    }

    // MARK: - Presentation state

    /// The scale saved with a series, for a view of `frameSize`: relative to
    /// the view's size, so that another window size shows the same framing.
    public static func seriesScale(_ scale: Float, frameSize: CGSize) -> Float {
        return Float(Double(scale) / (frameSize.height * frameSize.width).squareRoot())
    }

    /// The scale restored from a series' saved `scale` and its display style:
    /// 3 relative to the view's area, 2 to its width, otherwise absolute.
    public static func restoredScale(_ scale: Float, displayStyle: Int, frameSize: CGSize) -> Float {
        switch displayStyle {
        case 3: return Float(Double(scale) * (frameSize.height * frameSize.width).squareRoot())
        case 2: return Float(Double(scale) * frameSize.width)
        default: return scale
        }
    }

    /// The window of a PET series that shows `from` to `to`: width and level.
    public static func window(from: Float, to: Float) -> (width: Float, level: Float) {
        let width = to - from
        return (width, Float(Double(from) + Double(width) / 2.0))
    }

    /// `percent` % of the series maximum, as the PET window preferences give
    /// their bounds.
    public static func percentOfMaximum(_ maximum: Float, _ percent: Float) -> Float {
        return Float(Double(maximum * percent) / 100.0)
    }

    // MARK: - SUV

    /// The SUV of `value` (Bq/ml) for a patient of `weight` kg given `dose`
    /// Bq, decayed by `decay`.
    public static func suv(_ value: Float, weight: Float, dose: Float, decay: Float) -> Float {
        return value * weight * 1000.0 / (dose * decay)
    }

    /// The same for the fused image, as its formula was written: in double
    /// precision after the first product.
    public static func blendedSUV(_ value: Float, weight: Float, dose: Float, decay: Float) -> Float {
        return Float(Double(value * weight) * 1000.0 / Double(dose * decay))
    }
}
