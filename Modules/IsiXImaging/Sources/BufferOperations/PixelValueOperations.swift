//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import Foundation

/// A window level and width, in the units of the pixels they show.
public struct PixelWindow: Equatable, Sendable {
    public var level: Double
    public var width: Double

    public init(level: Double, width: Double) {
        self.level = level
        self.width = width
    }
}

/// 2D Viewer > Invert Pixel Values: the pixels themselves are negated, in
/// place, and the window level moves so that the inverted image shows what
/// the original showed, in negative.
///
/// A grayscale image holds modality values as floats: each value v becomes
/// -v. A colour image holds 8-bit ARGB, alpha first: each of red, green and
/// blue c becomes 255 - c, and alpha is kept. Every sample is visited, whatever
/// the image's width.
public enum PixelInversion {

    /// Negates `count` floats from `samples`.
    public static func invertGrayscale(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        vDSP_vneg(samples, 1, samples, 1, vDSP_Length(count))
    }

    /// Inverts the colour of `pixelCount` ARGB pixels from `bytes`, four bytes
    /// each with alpha first, and keeps their alpha.
    public static func invertARGB(_ bytes: UnsafeMutablePointer<UInt8>, pixelCount: Int) {
        guard pixelCount > 0 else { return }
        for pixel in 0..<pixelCount {
            let base = pixel &* 4
            bytes[base &+ 1] = 255 &- bytes[base &+ 1]
            bytes[base &+ 2] = 255 &- bytes[base &+ 2]
            bytes[base &+ 3] = 255 &- bytes[base &+ 3]
        }
    }

    /// The window of the inverted image: the level moves to the other side
    /// of zero, or of the middle of the 8-bit range for colour; the width
    /// stays.
    public static func window(_ window: PixelWindow, colour: Bool) -> PixelWindow {
        PixelWindow(level: colour ? 255 - window.level : -window.level, width: window.width)
    }
}

/// ROI > Normalize Series by ROI Mean…: every pixel of the series is divided
/// by the mean of a ROI and multiplied by a value the user chooses, in place,
/// so the ROI's mean becomes that value. Grayscale only: the pixels are
/// modality values, and 8-bit colour has no room for the result.
public enum ROIMeanNormalization {

    /// Why a normalization cannot be done.
    public enum Refusal: Error, Equatable, Sendable {
        /// The ROI's mean is zero, so nothing can be divided by it.
        case zeroMean
        /// The ROI's mean is not a number, or infinite.
        case undefinedMean
        /// The multiplier is zero, not a number or infinite.
        case invalidMultiplier
        /// The factor overflows a float.
        case outOfRange
    }

    /// What each pixel is multiplied by: `multiplier / mean`.
    public static func factor(mean: Double, multiplier: Double) -> Result<Float, Refusal> {
        guard mean.isFinite else { return .failure(.undefinedMean) }
        guard mean != 0 else { return .failure(.zeroMean) }
        guard multiplier.isFinite, multiplier != 0 else { return .failure(.invalidMultiplier) }
        let factor = multiplier / mean
        guard factor.isFinite, factor != 0, abs(factor) <= Double(Float.greatestFiniteMagnitude) else { return .failure(.outOfRange) }
        return .success(Float(factor))
    }

    /// Multiplies `count` floats from `samples` by `factor`.
    public static func scale(_ samples: UnsafeMutablePointer<Float>, count: Int, by factor: Float) {
        guard count > 0 else { return }
        var factor = factor
        vDSP_vsmul(samples, 1, &factor, samples, 1, vDSP_Length(count))
    }

    /// The window that shows the scaled pixels as the original window showed
    /// the original ones: the level follows the pixels, and the width keeps
    /// its sign, scaled by the size of the factor.
    public static func window(_ window: PixelWindow, factor: Float) -> PixelWindow {
        PixelWindow(level: window.level * Double(factor), width: window.width * abs(Double(factor)))
    }
}
