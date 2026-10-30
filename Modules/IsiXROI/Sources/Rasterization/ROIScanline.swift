/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The rows a polygon covers and, on each, the columns where it enters and
/// leaves: the edge-table scanline fill of DCMPix (ras_FillPolygon).
///
/// Every non-horizontal edge is entered at the row of its upper end, with its
/// `x` stepped by whole pixels and a remainder (Bresenham-like integer
/// arithmetic); an edge is shortened by a row where it continues into the next
/// one in the same vertical direction, so that a vertex is counted once. A row
/// gives the `x` of its active edges, sorted, then each edge steps to the next
/// row; an odd count repeats the last one (a degenerate polygon). The rows run
/// from the first that has an edge until none is active.
public enum ROIScanline {
    /// The edge table has this many rows: an edge with an end outside it is
    /// left out, as `outOfRange` reports.
    public static let maximumRows = 100_000

    private struct Edge {
        var yTop: Int, yBottom: Int
        var x: Int, numerator: Int, denominator: Int, direction: Int, step: Int

        @inline(__always)
        mutating func advance() {
            numerator &+= step
            while numerator >= denominator {
                x &+= direction
                numerator &-= denominator
            }
        }
    }

    @inline(__always)
    private static func sign(_ x: Int) -> Int { x > 0 ? 1 : x < 0 ? -1 : 0 }

    /// Calls `row` with each row below `rows` the polygon covers and the
    /// columns there (an even count, ascending, valid during the call only).
    /// Rows at or past `rows` are skipped but still walked, as the C did.
    ///
    /// The tables are raw buffers walked with `while` loops, so that a build
    /// without optimization (Debug) stays close to the C: generic collection
    /// calls there cost more than the row itself.
    public static func forEachRow(of polygon: [ROIPixelPoint], rows: Int,
                                  outOfRange: (_ y1: Int, _ y2: Int) -> Void = { _, _ in },
                                  _ row: (_ y: Int, _ columns: UnsafeBufferPointer<Int>) -> Void) {
        let n = polygon.count
        guard n > 0 else { return }
        // The edge table: every edge, by the row it starts on. The order of the
        // edges that start on one row does not matter, their columns are sorted.
        let pending = UnsafeMutablePointer<Edge>.allocate(capacity: n)
        let table = UnsafeMutablePointer<Edge>.allocate(capacity: n)
        let active = UnsafeMutablePointer<Edge>.allocate(capacity: n)
        let columns = UnsafeMutablePointer<Int>.allocate(capacity: n + 1)
        defer {
            pending.deallocate()
            table.deallocate()
            active.deallocate()
            columns.deallocate()
        }
        var edges = 0, firstRow = 0, lastRow = 0
        polygon.withUnsafeBufferPointer { buffer in
            let vertices = buffer.baseAddress!
            var i = 0
            while i < n {
                defer { i += 1 }
                let p1 = vertices[i], p2 = vertices[i + 1 == n ? 0 : i + 1]
                if p1.y == p2.y { continue }  // horizontal edges
                if p1.y < 0 || p2.y < 0 || p1.y >= maximumRows || p2.y >= maximumRows {
                    outOfRange(p1.y, p2.y)
                    continue
                }
                // The next vertex not level with p2.
                var j = (i + 2) % n
                while vertices[j].y == p2.y { j = (j + 1) % n }
                let p3 = vertices[j]

                var e: Edge
                let step = abs(p1.x &- p2.x)
                if p2.y > p1.y {
                    e = Edge(yTop: p1.y, yBottom: p2.y, x: p1.x, numerator: 0, denominator: p2.y - p1.y,
                             direction: sign(p2.x &- p1.x), step: step)
                    e.numerator = e.denominator >> 1
                    if p3.y > p2.y { e.yBottom -= 1 }
                } else {
                    e = Edge(yTop: p2.y, yBottom: p1.y, x: p2.x, numerator: 0, denominator: p1.y - p2.y,
                             direction: sign(p1.x &- p2.x), step: step)
                    e.numerator = e.denominator >> 1
                    if p3.y < p2.y {
                        e.yTop += 1
                        e.advance()
                    }
                }
                pending[edges] = e
                if edges == 0 || e.yTop < firstRow { firstRow = e.yTop }
                if edges == 0 || e.yTop > lastRow { lastRow = e.yTop }
                edges += 1
            }
        }
        guard edges > 0 else { return }
        // By first row (a counting sort: the rows are bounded by the table).
        let starts = UnsafeMutablePointer<Int>.allocate(capacity: lastRow - firstRow + 2)
        defer { starts.deallocate() }
        starts.initialize(repeating: 0, count: lastRow - firstRow + 2)
        var k = 0
        while k < edges {
            starts[pending[k].yTop - firstRow + 1] += 1
            k += 1
        }
        k = 1
        while k <= lastRow - firstRow {
            starts[k] += starts[k - 1]
            k += 1
        }
        k = 0
        while k < edges {
            let slot = pending[k].yTop - firstRow
            table[starts[slot]] = pending[k]
            starts[slot] += 1
            k += 1
        }

        var y = table[0].yTop
        var next = 0, count = 0
        while true {
            // The edges that ended above this row leave; those that start on it come in.
            var kept = 0
            k = 0
            while k < count {
                if active[k].yBottom >= y {
                    active[kept] = active[k]
                    kept += 1
                }
                k += 1
            }
            count = kept
            while next < edges && table[next].yTop == y {
                active[count] = table[next]
                count += 1
                next += 1
            }
            if count == 0 { return }
            if y < rows {
                var m = 0
                k = 0
                while k < count {
                    let x = active[k].x
                    var j = m
                    while j > 0 && columns[j - 1] > x {
                        columns[j] = columns[j - 1]
                        j -= 1
                    }
                    columns[j] = x
                    m += 1
                    active[k].advance()
                    k += 1
                }
                if m % 2 == 1 {
                    columns[m] = columns[m - 1]
                    m += 1
                }
                row(y, UnsafeBufferPointer(start: columns, count: m))
            }
            y += 1
        }
    }
}
