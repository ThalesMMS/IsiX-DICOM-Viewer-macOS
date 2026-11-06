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

/// A window/level drag: the window the image had when the button went down,
/// and the window each move of the mouse gives it.
///
/// The mouse moves the window by a step proportional to the starting width.
/// An image that is not PET-like (PT, or NM when the preference says so) moves
/// its level with the vertical distance and its width with the horizontal one.
/// A PET-like image follows the PETWindowingMode preference:
/// - 0: the same, with a width of at least 0.1;
/// - 1: the vertical distance moves the top of the range, whose bottom stays
///   where it started; the level is then raised by the PETMinimumValue
///   preference;
/// - 2: the vertical distance moves the top of the range and the horizontal one
///   its bottom, which stays at 0 or above.
/// In modes 1 and 2 the width is at least 0.1 and the range does not go below 0.
public struct WindowLevelDrag: Sendable, Equatable {

    /// The three views that drag a window, which differ in their step and in
    /// what an unknown PETWindowingMode gives.
    public enum Variant: Sendable, Equatable {
        /// The image of an image view: a step of width / 80, at least 0.001
        /// times the image's rescale slope; an unknown mode gives level and
        /// width 0.
        case image
        /// The fused image of an image view, dragged with the blended tool: a
        /// step of width / 100, at least 0.001 times the slope of the view's
        /// own image; an unknown mode gives level and width 0.
        case fused
        /// The orthogonal MPR views: a step of width / 100, at least 0.001; an
        /// unknown mode gives level and width 5.
        case orthogonalMPR
    }

    public var variant: Variant
    public var level: Float
    public var width: Float
    /// The bottom and the top of the starting range.
    public var minimum: Float
    public var maximum: Float

    public init(variant: Variant, level: Float, width: Float, minimum: Float, maximum: Float) {
        self.variant = variant
        self.level = level
        self.width = width
        self.minimum = minimum
        self.maximum = maximum
    }

    /// A drag from the window `level`, `width`, whose range is level ∓ width / 2.
    public init(variant: Variant, level: Float, width: Float) {
        self.init(variant: variant, level: level, width: width, minimum: level - width / 2, maximum: level + width / 2)
    }

    /// How far the window moves for one point of the mouse.
    public func step(slope: Float) -> Float {
        switch variant {
        case .image:
            let step = Float(Double(width) / 80.00)
            return Double(step) < 0.001 * Double(slope) ? Float(0.001 * Double(slope)) : step
        case .fused:
            let step = Float(Double(width) / 100.0)
            return Double(step) < 0.001 * Double(slope) ? Float(0.001 * Double(slope)) : step
        case .orthogonalMPR:
            let step = Float(Double(width) / 100.0)
            return Double(step) < 0.001 ? Float(0.001) : step
        }
    }

    /// The window after the mouse moved by `delta` (view points: x to the
    /// right, y up) from where the drag started. `mode` is the PETWindowingMode
    /// preference for a PET-like image and nil for any other; `petMinimum` is the
    /// PETMinimumValue preference; `slope` the rescale slope of the image the
    /// step is floored with.
    public func window(delta: CGVector, mode: Int?, petMinimum: Int, slope: Float) -> (level: Float, width: Float) {
        let step = Double(self.step(slope: slope))
        guard let mode else {
            return (Float(Double(level) + Double(delta.dy) * step), Float(Double(width) + Double(delta.dx) * step))
        }
        switch mode {
        case 0:
            let newLevel = Float(Double(level) + Double(delta.dy) * step)
            var newWidth = Float(Double(width) + Double(delta.dx) * step)
            if Double(newWidth) < 0.1 { newWidth = Float(0.1) }
            return (newLevel, newWidth)
        case 1:
            let top = Float(Double(maximum) + Double(delta.dy) * step)
            var newLevel = (top - minimum) / 2 + Float(petMinimum)
            var newWidth = top - minimum
            if Double(newWidth) < 0.1 { newWidth = Float(0.1) }
            if newLevel - newWidth / 2 < 0 { newLevel = newWidth / 2 }
            return (newLevel, newWidth)
        case 2:
            let top = Float(Double(maximum) + Double(delta.dy) * step)
            var bottom = Float(Double(minimum) + Double(delta.dx) * step)
            if bottom < 0 { bottom = 0 }
            var newLevel = bottom + (top - bottom) / 2
            var newWidth = top - bottom
            if Double(newWidth) < 0.1 { newWidth = Float(0.1) }
            if newLevel - newWidth / 2 < 0 { newLevel = newWidth / 2 }
            return (newLevel, newWidth)
        default:
            switch variant {
            case .image, .fused: return (0, 0)
            case .orthogonalMPR: return (5, 5)
            }
        }
    }
}
