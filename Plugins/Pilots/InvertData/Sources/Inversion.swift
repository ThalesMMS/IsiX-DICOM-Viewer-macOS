//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import IsiXPluginKit

/// The inversion itself, apart from the viewer: every sample, whatever the
/// image's width (no sample is left out when the pixel count is not a multiple
/// of anything), and the window level that shows the inverted image as the
/// original one was shown.
enum Inversion {
    /// Grayscale: each modality value v becomes -v.
    static func inverted(_ pixels: IsiXPixelBuffer<Float>) -> IsiXPixelBuffer<Float> {
        var result = pixels
        result.withUnsafeMutableBufferPointer { samples in
            for index in samples.indices { samples[index] = -samples[index] }
        }
        return result
    }

    /// Colour: each of red, green and blue c becomes 255 - c; alpha is kept.
    static func inverted(_ pixels: IsiXPixelBuffer<UInt8>) -> IsiXPixelBuffer<UInt8> {
        var result = pixels
        let channels = pixels.channels
        result.withUnsafeMutableBufferPointer { samples in
            for index in samples.indices where index % channels != 3 {
                samples[index] = 255 - samples[index]
            }
        }
        return result
    }

    static func inverted(_ pixels: IsiXPixelData) -> IsiXPixelData {
        switch pixels {
        case .float32(let buffer): return .float32(inverted(buffer))
        case .rgba8(let buffer): return .rgba8(inverted(buffer))
        @unknown default: return pixels
        }
    }

    /// The level moves to the other side of zero, or of the middle of the
    /// 8-bit range for colour; the width stays.
    static func windowLevel(_ level: IsiXWindowLevel, colour: Bool) -> IsiXWindowLevel {
        IsiXWindowLevel(center: colour ? 255 - level.center : -level.center, width: level.width)
    }
}
