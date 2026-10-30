/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

/// The cubic spline that smooths a ROI's outline: an open or a closed polygon,
/// a pencil stroke, and the 3D outlines of the volume window.
///
/// S(x) = a x3 + b x2 + c x + d, with S, S' and S'' continuous, computed
/// separately for x and y as functions of the distance along the outline. The
/// tridiagonal system is solved as in Numerical Recipes in C. The arithmetic
/// is the one the C function `spline()` always did, to the bit, with a fused
/// multiply-add wherever the Objective-C compiler fused `a * b + c`.
public enum ROISpline {
    /// The smoothed points of the outline through `points` (the closing point
    /// repeated last for a closed one), sampled about every `scale`-th of a
    /// pixel, with the index of the segment each comes from. Empty when the
    /// outline cannot be smoothed: fewer than two points, or two consecutive
    /// points alike, which happens when the zoom is too small for smoothing
    /// to matter.
    public static func smooth(_ points: [CGPoint], scale: Double) -> (points: [CGPoint], segments: [Int]) {
        guard let pieces = pieces(points, scale: scale) else { return ([], []) }
        // The samples of each piece: at its start, then at every whole
        // distance along it.
        var count = 1
        var k = 0
        while k < pieces.count {
            let length = pieces[k].length
            count += 1 + (length >= 1 && length < 1e6 ? Int(length) : 0)
            k += 1
        }
        var smoothed: [CGPoint] = []
        var segments: [Int] = []
        smoothed.reserveCapacity(count)
        segments.reserveCapacity(count)
        k = 0
        while k < pieces.count {
            let piece = pieces[k]
            smoothed.append(CGPoint(x: piece.x.a, y: piece.y.a))
            segments.append(piece.segment)
            var j: Int64 = 1
            while Double(j) <= piece.length {
                let x = piece.x.a.addingProduct(piece.x.b, Double(j)).addingProduct(piece.x.c, Double(j &* j)).addingProduct(piece.x.d, Double(j &* j &* j))
                let y = piece.y.a.addingProduct(piece.y.b, Double(j)).addingProduct(piece.y.c, Double(j &* j)).addingProduct(piece.y.d, Double(j &* j &* j))
                smoothed.append(CGPoint(x: x, y: y))
                segments.append(piece.segment)
                j += 1
            }
            k += 1
        }
        // Integer sampling may stop before the last interval's end: the
        // physical endpoint is kept exact.
        smoothed.append(points[points.count - 1])
        segments.append(points.count - 2)
        return (smoothed, segments)
    }

    /// A cubic of the spline: S(t) = a + b t + c t2 + d t3 for x and for y,
    /// t from 0 to `length` (the segment's length times the scale) along
    /// segment `segment` of the outline.
    public struct Piece {
        public let x: (a: Double, b: Double, c: Double, d: Double)
        public let y: (a: Double, b: Double, c: Double, d: Double)
        public let length: Double
        public let segment: Int
    }

    /// The cubics of the outline through `points`, as smooth(_:scale:)
    /// samples them; nil when it cannot be smoothed.
    ///
    /// The work arrays are one block of memory read through pointers and the
    /// loops are while loops: the outline is smoothed at every frame, and in a
    /// build without optimization, Swift arrays and ranges would make it
    /// several times slower than the C function it replaced.
    public static func pieces(_ points: [CGPoint], scale: Double) -> [Piece]? {
        let tot = points.count
        var scale = scale
        if scale > 5 { scale = 5 }

        // Element 0 is not used, except for h[0].
        let nb = tot + 2
        // As the spline starts and ends with a line, a point is added at
        // each end for continuity at the starting point.
        guard nb >= 3 else { return nil }
        let work = UnsafeMutablePointer<Double>.allocate(capacity: 10 * nb)
        work.initialize(repeating: 0, count: 10 * nb)
        defer { work.deallocate() }
        let a = work, c = work + nb, cx = work + 2 * nb, cy = work + 3 * nb, d = work + 4 * nb
        let g = work + 5 * nb, gam = work + 6 * nb, h = work + 7 * nb, px = work + 8 * nb, py = work + 9 * nb
        points.withUnsafeBufferPointer { p in
            var i = 0
            while i < tot {
                px[i + 1] = p[i].x.native
                py[i + 1] = p[i].y.native
                i += 1
            }
        }
        px[0] = px[nb - 3]; px[nb - 1] = px[2]
        py[0] = py[nb - 3]; py[nb - 1] = py[2]

        // All points must be separate, or there is nothing to smooth.
        var i = 1
        while i < nb {
            if px[i] == px[i - 1] && py[i] == py[i - 1] { return nil }
            i += 1
        }

        // h[i]: the distance from point i to the next; d[i]: from the start to point i.
        i = 0
        while i < nb - 1 {
            let xi = px[i + 1] - px[i]
            let yi = py[i + 1] - py[i]
            h[i] = (yi * yi).addingProduct(xi, xi).squareRoot() * scale
            d[i + 1] = d[i] + h[i]
            i += 1
        }

        i = 2
        while i < nb - 1 {
            a[i] = 2.0 * h[i - 1] / (h[i] + h[i - 1])
            i += 1
        }
        i = 1
        while i < nb - 2 {
            c[i] = 2.0 * h[i] / (h[i] + h[i - 1])
            i += 1
        }

        // g[i] = 6 Y[h(i), h(i+1), h(i+2)], the divided difference, of x then of y.
        func solve(_ p: UnsafeMutablePointer<Double>, into u: UnsafeMutablePointer<Double>) {
            var i = 1
            while i < nb - 1 {
                g[i] = 6.0 * (((p[i - 1] - p[i]) / (d[i - 1] - d[i])) - ((p[i] - p[i + 1]) / (d[i] - d[i + 1]))) / (d[i - 1] - d[i + 1])
                i += 1
            }
            let b = 4.0
            var bet = 4.0
            u[1] = g[1] / b
            var j = 2
            while j < nb - 1 {
                gam[j] = c[j - 1] / bet
                bet = b.addingProduct(-a[j], gam[j])
                u[j] = g[j].addingProduct(-a[j], u[j - 1]) / bet
                j += 1
            }
            j = nb - 2
            while j >= 1 {
                u[j] = u[j].addingProduct(-gam[j + 1], u[j + 1])
                j -= 1
            }
        }
        solve(px, into: cx)
        solve(py, into: cy)

        // On each interval: S(x) = a + b (x - xi) + c (x - xi)2 + d (x - xi)3,
        // with d = (c(i+1) - c(i)) / 3 h(i), a = y(i) and
        // b = (a(i+1) - a(i)) / h(i) - h(i) / 3 (c(i+1) + 2 c(i)).
        var pieces: [Piece] = []
        pieces.reserveCapacity(max(0, nb - 3))
        i = 1
        while i < nb - 2 {
            let ddx = (cx[i + 1] - cx[i]) / (3.0 * h[i])
            let bbx = ((px[i + 1] - px[i]) / h[i]).addingProduct(-(h[i] / 3.0), cx[i + 1].addingProduct(2.0, cx[i]))
            let ddy = (cy[i + 1] - cy[i]) / (3.0 * h[i])
            let bby = ((py[i + 1] - py[i]) / h[i]).addingProduct(-(h[i] / 3.0), cy[i + 1].addingProduct(2.0, cy[i]))
            pieces.append(Piece(x: (px[i], bbx, cx[i], ddx), y: (py[i], bby, cy[i], ddy), length: h[i], segment: i - 1))
            i += 1
        }
        return pieces
    }
}

/// The C entry point, `int spline(NSPoint *Pt, int tot, NSPoint **newPt, long
/// **correspondingSegmentPt, double scale)`, for the volume rendering's 3D
/// outlines. `*newPt` (and `*correspondingSegmentPt` when asked) receive
/// arrays the caller frees with free(); NULL, and 0 returned, when the
/// outline cannot be smoothed.
@_cdecl("spline")
public func spline(_ pt: UnsafeMutablePointer<CGPoint>?, _ tot: Int32,
                   _ newPt: UnsafeMutablePointer<UnsafeMutablePointer<CGPoint>?>?,
                   _ correspondingSegmentPt: UnsafeMutablePointer<UnsafeMutablePointer<Int>?>?,
                   _ scale: Double) -> Int32 {
    guard let newPt else { return 0 }
    newPt.pointee = nil
    correspondingSegmentPt?.pointee = nil
    guard let pt, tot > 0 else { return 0 }
    let result = ROISpline.smooth(Array(UnsafeBufferPointer(start: pt, count: Int(tot))), scale: scale)
    guard !result.points.isEmpty,
          let points = calloc(result.points.count, MemoryLayout<CGPoint>.stride)?.assumingMemoryBound(to: CGPoint.self)
    else { return 0 }
    for (i, p) in result.points.enumerated() { points[i] = p }
    if let correspondingSegmentPt {
        guard let segments = calloc(result.segments.count, MemoryLayout<Int>.stride)?.assumingMemoryBound(to: Int.self) else {
            free(points)
            return 0
        }
        for (i, s) in result.segments.enumerated() { segments[i] = s }
        correspondingSegmentPt.pointee = segments
    }
    newPt.pointee = points
    return Int32(truncatingIfNeeded: result.points.count)
}
