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
import IsiXGeometry

// The C functions of N2Operators.h and N2Alignment.h, with their C names:
// plugins built for Horos or OsiriX call them without being rebuilt, and look
// the names up in the application. @usableFromInline gives each symbol public
// linkage, which a Release build otherwise denies an internal declaration.

/// -1 for a negative number, 1 for any other.
@_cdecl("NSSign") @implementation @usableFromInline
func NSSign(_ f: CGFloat) -> CGFloat {
    f < 0 ? -1 : 1
}

/// `v` kept between `min` and `max`.
@_cdecl("NSLimit") @implementation @usableFromInline
func NSLimit(_ v: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
    if v < min { return min }
    if v > max { return max }
    return v
}

/// Each dimension rounded half up.
@_cdecl("NSRoundSize") @implementation @usableFromInline
func NSRoundSize(_ s: NSSize) -> NSSize {
    NSSize(width: (s.width + 0.5).rounded(.down), height: (s.height + 0.5).rounded(.down))
}

/// `s` scaled, in both dimensions, to fit in `t`.
@_cdecl("N2ProportionallyScaleSize") @implementation @usableFromInline
func N2ProportionallyScaleSize(_ s: NSSize, _ t: NSSize) -> NSSize {
    s.scaledProportionally(toFit: t)
}

/// `frame` with its origin measured from the other edge of `bounds`.
@_cdecl("N2FlipRect") @implementation @usableFromInline
func N2FlipRect(_ frame: NSRect, _ bounds: NSRect) -> NSRect {
    frame.flipped(in: bounds)
}

/// A rectangle of the size of `smallRect`, centered in a rectangle of the
/// size of `bigRect` whose origin is zero: the origin of `bigRect` is not added.
@_cdecl("NSRectCenteredInRect") @implementation @usableFromInline
func NSRectCenteredInRect(_ smallRect: NSRect, _ bigRect: NSRect) -> NSRect {
    NSRect(x: (bigRect.size.width - smallRect.size.width) / 2.0, y: (bigRect.size.height - smallRect.size.height) / 2.0,
           width: smallRect.size.width, height: smallRect.size.height)
}
