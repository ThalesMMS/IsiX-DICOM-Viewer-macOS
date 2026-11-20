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

/// The images a thick slab fuses at the image a view shows.
///
/// A slab of N images is centred on the image shown: ⌊(N − 1) / 2⌋ images
/// before it and the rest after it, in the slab's direction, which is that of
/// the series, or the other one when the data is flipped. With N even the
/// image more is therefore on the side the slab goes.
///
/// At either end of the series the slab is pulled back inside it and keeps
/// its N images: 0 … N − 1 on the first image, count − N … count − 1 on the
/// last. So a slab is as thick on every image of the series, the images
/// within half a slab of an end show the same slab, and only a series of
/// fewer than N images gives fewer, all of them.
///
/// Everything that says which images a slab is made of asks here: the
/// reduction and its Metal counterpart, the slab's thickness and location,
/// the image numbers of the annotations, the mark of the navigation strip,
/// the reference lines of the other viewers and the scale of the slider.
public struct ThickSlabSpan: Sendable, Equatable {
    /// The first image fused, in the order of the series.
    public let first: Int
    /// The last image fused, in the order of the series.
    public let last: Int
    /// Whether the slab goes towards the start of the series (flipped data).
    public let towardsStart: Bool

    /// The slab of `images` images at image `current` of a series of `count`.
    /// One image or none asked for, and an image that is not of the series,
    /// give that image alone.
    public init(images: Int, at current: Int, of count: Int, towardsStart: Bool) {
        self.towardsStart = towardsStart
        guard images > 1, current >= 0, current < count else {
            first = current
            last = current
            return
        }
        let fused = min(images, count)
        let before = (fused - 1) / 2
        // In the order of the series the images before the one shown are the
        // rest of the slab when it goes towards the start.
        let centred = current - (towardsStart ? fused - 1 - before : before)
        first = min(max(centred, 0), count - fused)
        last = first + fused - 1
    }

    /// The images fused.
    public var count: Int { last - first + 1 }

    /// The images fused, in the order of the series.
    public var indices: ClosedRange<Int> { first...last }

    /// The end the slab starts at, in its direction.
    public var nearEnd: Int { towardsStart ? last : first }

    /// The end the slab goes to.
    public var farEnd: Int { towardsStart ? first : last }

    /// From an image fused to the next one, in the slab's direction.
    public var step: Int { towardsStart ? -1 : 1 }

    /// The image in the middle of the slab, with the image more of an even
    /// slab after it in the slab's direction: the image shown, unless the
    /// slab was pulled back from an end of the series, where it is the image
    /// the same slab is centred on. It stands for the slab wherever one
    /// image has to: the plane another viewer follows, the plane a point of
    /// the slab is told on.
    public var middle: Int { towardsStart ? last - (count - 1) / 2 : first + (count - 1) / 2 }

    /// The images fused in the slab's direction, from its near end: the order
    /// they are reduced in. It does not depend on which of them is shown, so
    /// two images that show the same slab show the same pixels, also for a
    /// mean, whose rounding follows the order of its sum.
    public var ordered: [Int] { towardsStart ? Array(indices.reversed()) : Array(indices) }

    /// The images fused as the user counts them, from 0: from the other end
    /// of a series of `count` when the data is flipped, which is when the
    /// slab goes towards the start. There the slab always goes on from its
    /// near end.
    public func userIndices(of count: Int) -> ClosedRange<Int> {
        towardsStart ? (count - 1 - last)...(count - 1 - first) : indices
    }
}
