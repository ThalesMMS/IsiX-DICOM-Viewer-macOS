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
import CoreGraphics

/// The geometry of showing a ROI drawn on one series on another series of the
/// same patient: which image of the other series it belongs on, and where its
/// points and rectangle fall there. The images are described only by numbers,
/// so the rules are checked without a viewer.
public enum ROISeriesTransfer {

    /// How a ROI keeps its rectangle.
    public enum RectKind {
        /// The ROI is its points; the rectangle is not used.
        case pointsOnly
        /// Oval: the centre and the two radii.
        case centreAndRadii
        /// Rectangle: one corner and the extent to the opposite one, which may
        /// be negative.
        case cornerAndExtent
        /// 2D point and text: a single position.
        case point
    }

    /// The image of the other series a ROI belongs on.
    ///
    /// `distances` are the millimetres from the ROI to each image's plane.
    /// Only an image within `tolerance` of the ROI is a candidate, so a ROI
    /// beyond the other series' coverage is not shown there. A series that
    /// carries several phases repeats every position, so several images can
    /// be equally near: the one nearest the image the viewer shows wins, and
    /// each viewer keeps the ROI in its own phase.
    public static func targetImage(distances: [Double], current: Int, tolerance: Double) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, signed) in distances.enumerated() {
            let distance = abs(signed)
            guard distance.isFinite, distance <= tolerance else { continue }
            if let chosen = best, abs(distance - bestDistance) <= 0.01 {
                if abs(index - current) < abs(chosen - current) {
                    best = index
                    bestDistance = min(distance, bestDistance)
                }
            } else if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// Whether every point lies on one plane parallel to the image: the ROI's
    /// points, carried into the other series, must all be at the same depth
    /// there, or the planes are not parallel and the ROI cannot be drawn flat.
    public static func isFlat(depths: [Double], tolerance: Double) -> Bool {
        guard let low = depths.min(), let high = depths.max(), low.isFinite, high.isFinite else { return false }
        return high - low <= tolerance
    }

    /// The rectangle of a ROI, carried by `map` from one image's pixels to the
    /// other's.
    public static func mapRect(_ rect: NSRect, kind: RectKind, map: (NSPoint) -> NSPoint) -> NSRect {
        switch kind {
        case .pointsOnly:
            return rect
        case .point:
            return NSRect(origin: map(rect.origin), size: rect.size)
        case .cornerAndExtent:
            let a = map(rect.origin)
            let b = map(NSPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height))
            return NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        case .centreAndRadii:
            let centre = map(rect.origin)
            let alongX = map(NSPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y))
            let alongY = map(NSPoint(x: rect.origin.x, y: rect.origin.y + rect.size.height))
            let vx = NSPoint(x: alongX.x - centre.x, y: alongX.y - centre.y)
            let vy = NSPoint(x: alongY.x - centre.x, y: alongY.y - centre.y)
            // A plane turned by a quarter turn sends one radius onto the other
            // axis: each new radius is the larger share on its axis.
            return NSRect(x: centre.x, y: centre.y,
                          width: max(abs(vx.x), abs(vy.x)), height: max(abs(vx.y), abs(vy.y)))
        }
    }
}
