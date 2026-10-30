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

/// The Iso Contour surface of an ROI volume: the voxels the ROIs of one name
/// fill, slice by slice, as a binary mask, its slices placed along the
/// series' normal, in patient millimetres times the view's factor.
public enum ROIVolumeSurface {
    /// One byte a pixel: 1 where the filled slice is above 0.
    public static func binaryMask(_ pixels: UnsafeBufferPointer<Float>) -> Data {
        var mask = Data(count: pixels.count)
        mask.withUnsafeMutableBytes { bytes in
            for index in 0..<pixels.count { bytes[index] = pixels[index] > 0 ? 1 : 0 }
        }
        return mask
    }

    /// Where a slice lies along the series' `normal`, from the first slice,
    /// times `factor`.
    public static func frameOffset(origin: SIMD3<Double>, firstOrigin: SIMD3<Double>, normal: (Float, Float, Float),
                                   factor: Float) -> Double {
        let distance = (origin.x - firstOrigin.x) * Double(normal.0)
            + (origin.y - firstOrigin.y) * Double(normal.1)
            + (origin.z - firstOrigin.z) * Double(normal.2)
        return Double(factor) * distance
    }

    /// The thickness of a mask of one slice: the larger of the slice
    /// thickness and the slice interval, times `factor`.
    public static func singleFrameThickness(factor: Float, thickness: Double, interval: Double) -> Double {
        // MAX of C, which answers the second when the first is not a number.
        let a = abs(thickness), b = abs(interval)
        return Double(factor) * (a > b ? a : b)
    }

    /// A volume measured in a scene `factor` times the patient's, back in
    /// the patient's units.
    public static func perUnitFactor(_ volume: Double, factor: Float) -> Double {
        volume / pow(Double(factor), 3)
    }
}
