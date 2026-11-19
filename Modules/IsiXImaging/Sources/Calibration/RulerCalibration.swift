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

/// The pixel spacing a ruler of a known length gives an image.
///
/// The user draws a length over something whose size is known and enters that
/// size. The ruler was measured, in centimetres, with the spacing the image
/// had, and that measure is also told as a number of pixels along X: its
/// millimetres over the X spacing, or its length in pixels on an image with
/// no spacing. The entered length over that number is the new X spacing, and
/// Y keeps its proportion to X, so that a ruler in any direction, on pixels
/// that are not square, reads the length entered.
public enum RulerCalibration {
    /// The new X spacing, in mm: `requestedCentimetres` over `pixels`, the
    /// ruler told as pixels along X.
    public static func resolution(requestedCentimetres: Double, pixels: Double) -> Double {
        requestedCentimetres * 10.0 / pixels
    }

    /// The new Y spacing, in mm, of an image whose spacing was `previousX`
    /// by `previousY`: in the same proportion to `resolution`, and equal to
    /// it for an image that had none.
    public static func verticalSpacing(previousX: Double, previousY: Double, resolution: Double) -> Double {
        previousX == 0 ? resolution : previousY * resolution / previousX
    }

    /// By how much what was measured grows: the length entered over the
    /// length the ruler read, both in centimetres. nil when the ruler read
    /// nothing or either is not a positive finite number. What has a scale
    /// of its own beside the image's, as the 2D regions of an ultrasound
    /// image, is scaled by it.
    public static func factor(requestedCentimetres: Double, measuredCentimetres: Double) -> Double? {
        let factor = requestedCentimetres / measuredCentimetres
        guard requestedCentimetres > 0, measuredCentimetres > 0, factor.isFinite, factor > 0 else { return nil }
        return factor
    }
}
