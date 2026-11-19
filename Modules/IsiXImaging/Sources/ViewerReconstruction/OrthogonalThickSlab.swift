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

/// The orthogonal MPR's rules for its thick slab: where the slab of the
/// original view starts for a crossing of the reformatted ones and back, how
/// a row of a reformatted view names an image of the series, and how many
/// rows or columns of a reformatted view make the slab's thickness.
///
/// The slab of the original view goes one way, from its first image `s`
/// through the images after it, and stops where the series does. A crossing
/// at image `c` puts it at `s = c - N / 2` for a request of `N` images, kept
/// inside the series; nothing is centred on what is fused.
public enum OrthogonalThickSlab {
    /// The first image of the slab for a crossing at image `crossIndex`.
    public static func firstImage(crossIndex: Int, requestedSlices: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(crossIndex - max(requestedSlices, 0) / 2, 0), count - 1)
    }

    /// The image the reformatted views cross at for a slab that starts at
    /// `firstImage`: half the request further, inside the series, so the
    /// crossing never leaves the image nor the images fused.
    public static func crossIndex(firstImage: Int, requestedSlices: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(firstImage + max(requestedSlices, 0) / 2, 0), count - 1)
    }

    /// The image a row of a reformatted view shows: the series runs up the
    /// view when its slices ascend.
    public static func index(row: Int, count: Int, ascending: Bool) -> Int {
        ascending ? count - 1 - row : row
    }

    /// The row of a reformatted view that shows an image.
    public static func row(index: Int, count: Int, ascending: Bool) -> Int {
        ascending ? count - 1 - index : index
    }

    /// The rows or columns of `pixelSpacing` nearest to `thickness`: one at
    /// least, and one, no slab, where either is not a positive number.
    public static func reslicedCount(thickness: Double, pixelSpacing: Double) -> Int {
        guard thickness.isFinite, pixelSpacing.isFinite, thickness > 0, pixelSpacing > 0 else { return 1 }
        return Int(min(max((thickness / pixelSpacing).rounded(), 1), Double(Int16.max)))
    }
}
