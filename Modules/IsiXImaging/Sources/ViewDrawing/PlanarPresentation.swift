//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation

// The decisions and tables of a 2D view's planar snapshot: what the Metal
// picture is drawn from (the image's floats, the host's 8-bit bytes, a thick
// slab, the volume-rendering slab), the window it is drawn with, the tables
// the host's scalar and colour programs used, and where a fused series' pixel
// falls in the image's view. The view (DCMView+PlanarSnapshot.swift, in the
// app) gathers its state, asks these, and assembles the snapshot. The
// arithmetic is the Objective-C one, including the fused multiply-adds clang
// made of its expressions (see PlaneGeometry).
public enum PlanarPresentation {

    // MARK: - Limits

    /// DICOM's rows and columns stop at 65535.
    public static let maximumSide = 65535
    /// The float plane is copied on every draw: at most 2 GiB of it.
    public static let maximumPlaneBytes = 2048 * 1024 * 1024
    /// The largest texture of these GPUs. An image as wide or tall turns the
    /// host's 32-bit pipeline off: it draws its 8-bit representation instead.
    public static let largestTextureSide = 16384

    /// Whether the host draws a stack mode at all: the thick slab reductions
    /// it has (0 to 5). Another one is refused, as the host refuses it.
    public static func drawsStackMode(_ mode: Int) -> Bool {
        return mode >= 0 && mode <= 5
    }

    /// Whether a `width` × `height` image, whose float plane is `planeBytes`
    /// long, can be drawn.
    public static func accepts(width: Int, height: Int, planeBytes: Int) -> Bool {
        return width > 0 && height > 0 && width <= maximumSide && height <= maximumSide && planeBytes <= maximumPlaneBytes
    }

    /// Whether the host's 8-bit representation is what is drawn: an image as
    /// wide or tall as the largest texture.
    public static func drawsEightBitRepresentation(width: Int, height: Int) -> Bool {
        return width >= largestTextureSide || height >= largestTextureSide
    }

    // MARK: - Source

    /// What a frame is drawn from.
    public struct Source: Equatable, Sendable {
        /// ARGB bytes: a colour image, or the 12-bit LUT mode's packed buffer.
        public let colourBytes: Bool
        /// The volume-rendering slab (stack modes 4 and 5), composed from the
        /// series' slices into colour bytes.
        public let volumeSlab: Bool
        /// The host's own bytes stand in for the floats: colour bytes, a
        /// subtraction, a DICOM shutter, or an image too large for a texture.
        /// Not under the volume-rendering slab, which has its own.
        public let hostBytes: Bool
        /// A thick slab reduces the stack: the image's own samples are not
        /// what is drawn.
        public let stackReduced: Bool
        /// The mean, maximum or minimum slab the Metal path reduces itself,
        /// over the floats.
        public let scalarSlab: Bool

        public init(stackMode: Int, stack: Int, seriesCount: Int, isRGB: Bool, packed: Bool, subtracted: Bool,
                    shutter: Bool, eightBit: Bool) {
            let colour = isRGB || packed
            colourBytes = colour
            volumeSlab = !colour && (stackMode == 4 || stackMode == 5) && stack >= 1 && seriesCount > 1
            hostBytes = !volumeSlab && (colour || subtracted || shutter || eightBit)
            stackReduced = stackMode >= 1 && stack > 1
            scalarSlab = !colour && !eightBit && stackMode >= 1 && stackMode <= 3 && stack > 1 && seriesCount > 1
        }

        /// Whether the picture is colour bytes rather than floats.
        public var isColour: Bool { colourBytes || volumeSlab }

        /// Whether the MPR's cubic display plane may stand in for the samples:
        /// floats of the image itself, not a slab's.
        public var takesDisplayPlane: Bool { !colourBytes && !volumeSlab && !stackReduced }

        /// Whether the image's floats are what is drawn, copied once and kept
        /// while they do not change.
        public var drawsOwnSamples: Bool { !colourBytes && !volumeSlab && !hostBytes && !stackReduced }

        /// Whether the bytes carry their own alpha in their fourth byte.
        public func bytesCarryAlpha(packed: Bool) -> Bool { packed || volumeSlab }
    }

    // MARK: - Window

    /// The window a frame is drawn with: the fixed 127/256 window when the
    /// view does not scale (or the image's presentation fixes it), otherwise
    /// the given one; the width's sign carries the polarity.
    public static func window(level: Float, width: Float, fixed: Bool, inverted: Bool) -> (level: Float, width: Float) {
        return (fixed ? 127 : level, Float(inverted ? -1 : 1) * (fixed ? 256 : width))
    }

    /// The host's software enlargement: three times for an image up to 256
    /// pixels wide, twice above, once when off.
    public static func softwareScale(interpolates: Bool, width: Int) -> Int {
        return interpolates ? (width <= 256 ? 3 : 2) : 1
    }

    // MARK: - Fusion

    /// Whether the series fused over a view is drawn: where drawRect: drew
    /// it, in the key view of a 2D viewer and in every orthogonal view, while
    /// the two series' locations are in sync.
    public static func drawsFusion(hasFusedSeries: Bool, locationsInSync: Bool, isKeyView: Bool, is2DViewer: Bool) -> Bool {
        return hasFusedSeries && locationsInSync && (isKeyView || !is2DViewer)
    }

    /// Whether the image is drawn white under its fused series: the host adds
    /// it to the clear colour (GL_ONE, GL_ONE), white under the B/W Inverse
    /// CLUT, so that only the fused series shows.
    public static func whitensImageUnderFusion(hasFusedSeries: Bool, locationsInSync: Bool, whiteBackground: Bool) -> Bool {
        return hasFusedSeries && locationsInSync && whiteBackground
    }

    // MARK: - Tables

    /// The table of the scalar CLUT program, RGBA for each of the 256
    /// entries: the colours times the view's channel factors, clamped to a
    /// byte, and the alpha table, opaque when there is none.
    public static func scalarTable(red: UnsafePointer<UInt8>, green: UnsafePointer<UInt8>, blue: UnsafePointer<UInt8>,
                                   alpha: UnsafePointer<UInt8>?, redFactor: Float, greenFactor: Float,
                                   blueFactor: Float) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 1024)
        for i in 0..<256 {
            table[4 * i] = UInt8(fminf(255, fmaxf(0, Float(red[i]) * redFactor)))
            table[4 * i + 1] = UInt8(fminf(255, fmaxf(0, Float(green[i]) * greenFactor)))
            table[4 * i + 2] = UInt8(fminf(255, fmaxf(0, Float(blue[i]) * blueFactor)))
            table[4 * i + 3] = alpha.map { $0[i] } ?? 255
        }
        return table
    }

    /// Whether a colour image's bytes are tabled before they are
    /// interpolated: a fused colour series always is (blending), the image
    /// itself under a colour transfer or channel factors.
    public static func tablesColourBytes(isRGB: Bool, packed: Bool, fused: Bool, colorTransfer: Bool,
                                         redFactor: Float, greenFactor: Float, blueFactor: Float) -> Bool {
        return isRGB && !packed && (fused || colorTransfer || redFactor != 1.0 || greenFactor != 1.0 || blueFactor != 1.0)
    }

    /// The four tables a colour image's bytes are looked up in, alpha, red,
    /// green and blue, 256 entries each: the alpha table (the fusion's, or
    /// opaque), and the colours, times the channel factors when any is not 1,
    /// converted to bytes as C converts them, unclamped.
    public static func colourTable(red: UnsafePointer<UInt8>, green: UnsafePointer<UInt8>, blue: UnsafePointer<UInt8>,
                                   alpha: UnsafePointer<UInt8>?, redFactor: Float, greenFactor: Float,
                                   blueFactor: Float) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 1024)
        let scaled = redFactor != 1.0 || greenFactor != 1.0 || blueFactor != 1.0
        for i in 0..<256 {
            table[i] = alpha.map { $0[i] } ?? 0xFF
            if scaled {
                table[256 + i] = convertedByte(Float(red[i]) * redFactor)
                table[512 + i] = convertedByte(Float(green[i]) * greenFactor)
                table[768 + i] = convertedByte(Float(blue[i]) * blueFactor)
            } else {
                table[256 + i] = red[i]
                table[512 + i] = green[i]
                table[768 + i] = blue[i]
            }
        }
        return table
    }

    /// A float stored into an unsigned char, as the optimised C of the
    /// released app stored it: converted toward zero to a signed 32-bit
    /// integer, saturating (0 for NaN), then its low byte. C leaves a value
    /// outside 0...255 undefined; only a negative factor or one past 2^31
    /// reaches that, and the unoptimised build of the same C gave 0 for a
    /// negative product instead.
    static func convertedByte(_ value: Float) -> UInt8 {
        if value.isNaN { return 0 }
        let integer: Int32 = value >= 2_147_483_648 ? .max : value < -2_147_483_648 ? .min : Int32(value)
        return UInt8(truncatingIfNeeded: integer)
    }

    // MARK: - Mapping

    /// The pixel of a fused series' image under a point of the view it is
    /// fused over, as drawRectIn: draws it: the fused view's own flips, scale,
    /// rotation, pan and pixel ratio, in the frame of the view it is drawn in.
    /// `backing` is the point in that view's backing pixels, `frame` that
    /// view's drawing frame; `image` the fused view's current image, if any.
    /// This is ConvertFromUpLeftView2GL: with the other view's frame.
    public static func fusedImagePixel(backing: CGPoint, frame: CGSize, xFlipped: Bool, yFlipped: Bool, scale: Float,
                                       rotation: Float, origin: CGPoint,
                                       image: (width: Int, height: Int, pixelRatio: Double)?) -> CGPoint {
        let deg2rad = Double.pi / 180.0
        let scaleValue = CGFloat(scale)
        var a = backing
        a.y = frame.height - a.y
        if xFlipped { a.x = frame.width - a.x }
        if yFlipped { a.y = frame.height - a.y }
        a.x -= frame.width / 2
        a.x /= scaleValue
        a.y -= frame.height / 2
        a.y /= scaleValue
        let angle = Double(rotation) * deg2rad
        let xx = Float((a.y * sin(angle)).addingProduct(a.x, cos(angle)))
        let yy = Float((a.y * cos(angle)).addingProduct(-a.x, sin(angle)))
        a.y = CGFloat(yy)
        a.x = CGFloat(xx)
        a.x -= origin.x / scaleValue
        a.y += origin.y / scaleValue
        if let image {
            a.x += CGFloat(Float(image.width) * 0.5)
            a.y = a.y.addingProduct(Double(image.height) * image.pixelRatio, 0.5)
            a.y /= image.pixelRatio
        }
        return a
    }
}
