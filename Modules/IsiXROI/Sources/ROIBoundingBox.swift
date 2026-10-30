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

/// How a rectangle and an oval ROI keep their extent in `ROI.rect`, from and
/// to the two opposite corners of their bounding box.
///
/// The two tools store it differently: a rectangle as its origin and size, an
/// oval as its centre and its two radii (the drawing, the hit test and the
/// statistics all read the oval that way). Treating an oval's rect as a
/// rectangle's puts its centre on the first corner and doubles its size.
public enum ROIBoundingBox {
    /// The `ROI.rect` of a rectangle or an oval whose bounding box has these
    /// opposite corners, in any order.
    public static func rect(corner a: CGPoint, corner b: CGPoint, oval: Bool) -> CGRect {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        let width = abs(b.x - a.x), height = abs(b.y - a.y)
        guard oval else { return CGRect(x: minX, y: minY, width: width, height: height) }
        return CGRect(x: minX + width / 2, y: minY + height / 2, width: width / 2, height: height / 2)
    }

    /// The bounding box's lower and upper corners of a rectangle's or an
    /// oval's `ROI.rect`.
    public static func corners(of rect: CGRect, oval: Bool) -> (lower: CGPoint, upper: CGPoint) {
        guard oval else { return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)) }
        let radiusX = abs(rect.size.width), radiusY = abs(rect.size.height)
        return (CGPoint(x: rect.origin.x - radiusX, y: rect.origin.y - radiusY),
                CGPoint(x: rect.origin.x + radiusX, y: rect.origin.y + radiusY))
    }
}
