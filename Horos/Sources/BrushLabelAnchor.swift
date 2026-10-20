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

/// Where the label of a brush ROI points: inside its largest piece.
///
/// A brush label hung from the lower right corner of the texture's bounding
/// box, with its leader line to the box's centre. For an organ that is curved
/// or in several pieces, such as a kidney cut through its hilum or the colon,
/// both points can fall outside the organ. The largest 4-connected piece of
/// the texture is found, and its centroid is used when it lies inside that
/// piece; otherwise the piece's pixel nearest to the centroid.
@objc(HorosBrushLabelAnchor)
public final class BrushLabelAnchor: NSObject {

    /// The anchor in texture pixels (x right, y down, pixel centres at +0.5),
    /// or nil when the texture has nothing in it.
    @objc(anchorOfTexture:width:height:)
    public static func anchor(of texture: UnsafePointer<UInt8>?, width: Int, height: Int) -> NSValue? {
        guard let texture, width > 0, height > 0 else { return nil }
        guard let point = anchor(UnsafeBufferPointer(start: texture, count: width * height), width: width, height: height)
        else { return nil }
        return NSValue(point: point)
    }

    static func anchor(_ texture: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> CGPoint? {
        let count = width * height
        guard texture.count >= count else { return nil }
        var label = [Int32](repeating: 0, count: count)
        var stack: [Int] = []
        var best: (label: Int32, size: Int, sumX: Int, sumY: Int) = (0, 0, 0, 0)
        var next: Int32 = 0
        for start in 0..<count where texture[start] != 0 && label[start] == 0 {
            next += 1
            label[start] = next
            stack.append(start)
            var size = 0, sumX = 0, sumY = 0
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                size += 1; sumX += x; sumY += y
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let neighbour = ny * width + nx
                    if texture[neighbour] != 0 && label[neighbour] == 0 {
                        label[neighbour] = next
                        stack.append(neighbour)
                    }
                }
            }
            if size > best.size { best = (next, size, sumX, sumY) }
        }
        guard best.size > 0 else { return nil }
        let cx = Double(best.sumX) / Double(best.size), cy = Double(best.sumY) / Double(best.size)
        let ix = Int(cx.rounded()), iy = Int(cy.rounded())
        if ix >= 0, iy >= 0, ix < width, iy < height, label[iy * width + ix] == best.label {
            return CGPoint(x: cx + 0.5, y: cy + 0.5)
        }
        var nearest = 0, distance = Double.infinity
        for index in 0..<count where label[index] == best.label {
            let dx = Double(index % width) - cx, dy = Double(index / width) - cy
            let d = dx * dx + dy * dy
            if d < distance { distance = d; nearest = index }
        }
        return CGPoint(x: Double(nearest % width) + 0.5, y: Double(nearest / width) + 0.5)
    }
}
