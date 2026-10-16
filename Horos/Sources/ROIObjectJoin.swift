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

import CoreGraphics
import Foundation

/// Which object a newly drawn contour belongs to.
///
/// Volume, renaming and propagation treat the ROIs of a series that share a
/// name as one object. New ROIs get a numbered name ("Oval 1", "Oval 2"), so
/// each is an object of its own; with this option on, a contour drawn over a
/// ROI of a neighbouring image takes that ROI's name instead, and a lesion
/// outlined slice by slice comes out as one object with its own volume.
@objc(HorosROIObjectJoin)
public final class ROIObjectJoin: NSObject {
    @objc public static let preferenceKey = "ROIJoinOverlappingOnAdjacentImage"

    @objc public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// How many images before and after the new contour's image are searched,
    /// so that outlining every other slice still joins.
    @objc public static let reach = 2

    /// The share of the smaller contour's area the two must have in common.
    /// Contours that only touch at their edges stay separate objects.
    @objc public static let minimumOverlap = 0.1

    /// A name that stands for no object: such ROIs are not grouped by the
    /// user, so a rename applies to the edited ROI alone.
    @objc(isUnnamed:)
    public static func isUnnamed(_ name: String?) -> Bool {
        guard let name = name, !name.isEmpty else { return true }
        return name == "Unnamed" || name == NSLocalizedString("Unnamed", comment: "")
    }

    /// The index of the candidate the new contour joins, or -1.
    ///
    /// All contours are in the same plane coordinates (millimetres in the new
    /// contour's image plane). The nearest image wins, then the larger overlap.
    @objc(candidateForContour:candidates:imageDistances:)
    public static func candidate(for contour: [NSValue], candidates: [[NSValue]], imageDistances: [Int]) -> Int {
        let polygon = contour.map { $0.pointValue }
        var best = -1
        var bestDistance = Int.max
        var bestOverlap = 0.0

        for (index, candidate) in candidates.enumerated() where index < imageDistances.count {
            let overlap = overlapFraction(polygon, candidate.map { $0.pointValue })
            if overlap < minimumOverlap { continue }
            let distance = imageDistances[index]
            if distance < bestDistance || (distance == bestDistance && overlap > bestOverlap) {
                best = index
                bestDistance = distance
                bestOverlap = overlap
            }
        }
        return best
    }

    /// The area two closed contours have in common over the smaller one's
    /// area, sampled on a grid across the intersection of their bounds.
    static func overlapFraction(_ a: [NSPoint], _ b: [NSPoint]) -> Double {
        let smaller = min(area(a), area(b))
        guard a.count >= 3, b.count >= 3, smaller > 0 else { return 0 }

        let boundsA = bounds(a), boundsB = bounds(b)
        let common = boundsA.intersection(boundsB)
        guard !common.isNull, common.width > 0, common.height > 0 else { return 0 }

        let steps = 64
        let cellWidth = common.width / CGFloat(steps)
        let cellHeight = common.height / CGFloat(steps)
        var inside = 0
        for row in 0..<steps {
            let y = common.minY + (CGFloat(row) + 0.5) * cellHeight
            for column in 0..<steps {
                let point = NSPoint(x: common.minX + (CGFloat(column) + 0.5) * cellWidth, y: y)
                if contains(a, point) && contains(b, point) { inside += 1 }
            }
        }
        return Double(inside) * Double(cellWidth * cellHeight) / smaller
    }

    static func area(_ polygon: [NSPoint]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            sum += Double(p.x * q.y - q.x * p.y)
        }
        return abs(sum) / 2
    }

    static func bounds(_ polygon: [NSPoint]) -> NSRect {
        let xs = polygon.map { $0.x }, ys = polygon.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd rule, as the ROI masks are filled.
    static func contains(_ polygon: [NSPoint], _ point: NSPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let p = polygon[i], q = polygon[j]
            if (p.y > point.y) != (q.y > point.y),
               point.x < (q.x - p.x) * (point.y - p.y) / (q.y - p.y) + p.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
