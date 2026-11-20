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

/// The orthogonal MPR's rules for its thick slab: the image of the original
/// view the reformatted ones cross at, how a row of a reformatted view names
/// an image of the series, and how many rows or columns of a reformatted view
/// make the slab's thickness.
///
/// The slab of the original view is the 2D viewer's (ThickSlabSpan): centred
/// on the image the view shows and pulled back inside the series at either
/// end. So the reformatted views cross at the image shown itself, which is
/// always one of the images fused, and a crossing put on a row shows the
/// image of that row.
public enum OrthogonalThickSlab {
    /// The image the reformatted views cross at while the original view
    /// shows `image`, and the image the original view shows for a crossing
    /// there: the same one, inside the series.
    public static func crossIndex(image: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(image, 0), count - 1)
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
