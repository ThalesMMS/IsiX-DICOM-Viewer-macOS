//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The far end of a run of `stack` slices that starts at the current one, in
/// slice indices.
///
/// With the series reversed (`flippedData`) the run goes the other way, so
/// its far end is *below* the current index, not above it.
///
/// This is not the thick slab a viewer shows, which is centred on the
/// current slice and kept inside the series (IsiXImaging's `ThickSlabSpan`):
/// what a viewer tells the others of its slab, and what it draws of it,
/// comes from there. This rule remains for a caller that counts the slices
/// from the current one on.
@objc(HorosThickSlabRange)
public final class ThickSlabRange: NSObject {
    /// `-1` when there is no run: a single slice has no second end.
    /// Otherwise the index of the far end, clamped into `0..<count`, because
    /// the run may reach past either end of a series.
    @objc(farEndIndexForCurrentIndex:stack:count:flippedData:)
    public static func farEndIndex(currentIndex: Int, stack: Int, count: Int,
                                   flippedData: Bool) -> Int
    {
        guard stack > 1, count > 0 else { return -1 }
        let far = flippedData ? currentIndex - (stack - 1) : currentIndex + (stack - 1)
        return min(max(far, 0), count - 1)
    }
}
