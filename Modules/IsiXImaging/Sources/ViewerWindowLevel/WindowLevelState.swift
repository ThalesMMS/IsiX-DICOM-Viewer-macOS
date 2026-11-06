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

/// The window an image view keeps: the level and width it last applied, and
/// the SUV conversion they were set in with the factor that converts them.
///
/// The image (DCMPix) owns the window it is drawn with; the view keeps this
/// copy to carry the window to the next image it shows, to draw the colour
/// bar and to answer `curWL`/`curWW`. The image changes first and the view
/// mirrors it, never the other way round.
public struct WindowLevelState: Sendable, Equatable {
    public var level: Float
    public var width: Float
    /// Whether `level` and `width` are SUV values.
    public var suvConverted: Bool
    /// What converts the window between the image's values and SUV: the 2D
    /// viewer's PET-to-SUV factor while `suvConverted`, 1 otherwise; 0 for a
    /// view that never mirrored an image.
    public var suvFactor: Float

    public init(level: Float = 0, width: Float = 0, suvConverted: Bool = false, suvFactor: Float = 0) {
        self.level = level
        self.width = width
        self.suvConverted = suvConverted
        self.suvFactor = suvFactor
    }

    /// Takes the window an image now has. `suvFactor` is asked only when the
    /// image's values are SUV, and answers the 2D viewer's factor, or 1 in
    /// another viewer.
    public mutating func mirror(level: Float, width: Float, suvConverted: Bool, suvFactor: () -> Float) {
        self.level = level
        self.width = width
        self.suvConverted = suvConverted
        self.suvFactor = suvConverted ? suvFactor() : 1
    }

    /// Takes a window set while no image is shown: it is in the image's values.
    /// The factor stays what it was.
    public mutating func mirrorWithoutImage(level: Float, width: Float) {
        self.level = level
        self.width = width
        self.suvConverted = false
    }

    /// The window to apply to an image whose values are SUV or not
    /// (`imageSUVConverted`). A window kept in SUV goes back to the image's
    /// values when the image is not converted; a window in the image's values
    /// is applied as it is to a converted image. Either way the window then
    /// counts in the image's conversion, with the factor `suvFactor` answers
    /// (asked only for a converted image). An empty window, or one already in
    /// the image's conversion, is applied as it is.
    public mutating func reapply(imageSUVConverted: Bool, suvFactor: () -> Float) {
        guard level != 0 && width != 0 && suvConverted != imageSUVConverted else { return }
        if self.suvFactor > 0 && suvConverted {
            level /= self.suvFactor
            width /= self.suvFactor
        }
        suvConverted = imageSUVConverted
        self.suvFactor = imageSUVConverted ? suvFactor() : 1
    }
}
