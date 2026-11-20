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
import IsiXImaging

/// The slices a 2D thick slab is made of, asked by the host bridge so the rule
/// is written once and measured against `computeThickSlab` by
/// `tests/test-planar-thick-slab.py`. The rule is IsiXImaging's
/// `ThickSlabSpan`, which `computeThickSlab` asks too: `stack` slices centred
/// on the slice shown and kept inside the series.
extension PlanarThickSlab {
    /// The slices of the slab shown at `position`, that one among them, in
    /// the order the host reduces them: from the near end of the slab on,
    /// which is its last slice when `direction` is non-zero. None without a
    /// slab, or for a position outside `0..<count`.
    @objc public static func sliceIndices(position: Int, stack: Int, direction: Int, count: Int) -> [NSNumber] {
        guard stack > 1, position >= 0, position < count else { return [] }
        return ThickSlabSpan(images: stack, at: position, of: count, towardsStart: direction != 0).ordered.map { NSNumber(value: $0) }
    }

    /// The slices the volume-rendering slab composes (modes 4 and 5), in
    /// the order `-[ThickSlabVR renderSlab]` composes them. `-[DCMPix
    /// computeThickSlab]` hands it the slices of the slab shown at
    /// `position`, from the first of them in the series on. They lie in
    /// memory in index order, and `setWLWW::` reverses them unless
    /// `memoryOrder`.
    @objc public static func volumeSliceIndices(position: Int, stack: Int, direction: Int, count: Int,
                                                memoryOrder: Bool) -> [NSNumber] {
        guard position >= 0, position < count, stack >= 1 else { return [] }
        let indices = ThickSlabSpan(images: stack, at: position, of: count, towardsStart: direction != 0).indices
            .map { NSNumber(value: $0) }
        return memoryOrder ? indices : indices.reversed()
    }
}
