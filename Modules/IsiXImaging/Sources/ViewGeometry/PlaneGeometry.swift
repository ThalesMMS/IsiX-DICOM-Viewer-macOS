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

import Foundation

// The 3D intersections and rotation the viewers use for their reference
// lines, their orientation and the MPR planes.
//
// The arithmetic is the Objective-C one, bit for bit. Clang contracted its
// a * b + c expressions into fused multiply-adds (it does by default, within
// one expression, when the multiplication is an operand of the addition: the
// left one first); Swift never contracts, so each of those is written here as
// the fused operation it compiled to, and the other operations stay separate.
public enum PlaneGeometry {

    /// v1 · v2 as `v1[0]*v2[0] + v1[1]*v2[1] + v1[2]*v2[2]` compiled.
    @inline(__always)
    static func dot(_ a0: Float, _ a1: Float, _ a2: Float, _ b0: Float, _ b1: Float, _ b2: Float) -> Float {
        return (a1 * b1).addingProduct(a0, b0).addingProduct(a2, b2)
    }

    /// -(v1 · v2) as compiled: the negation went into the last fused
    /// operation (-(a * b) - c), which gives +0 where negating a +0 dot
    /// product would give -0.
    @inline(__always)
    static func negatedDot(_ a0: Float, _ a1: Float, _ a2: Float, _ b0: Float, _ b1: Float, _ b2: Float) -> Float {
        let partial = (a1 * b1).addingProduct(a0, b0)
        return (-partial).addingProduct(-a2, b2)
    }

    /// Where the segment `p0`–`p1` crosses the plane through `point` of
    /// normal `normal`: 0 when it does not (parallel, or outside the
    /// segment), 1 or 2 (the side the segment comes from) with the point in
    /// `result` when it does.
    public static func segmentPlane(_ p0: UnsafePointer<Float>, _ p1: UnsafePointer<Float>,
                                    normal: UnsafePointer<Float>, point: UnsafePointer<Float>,
                                    result: UnsafeMutablePointer<Float>) -> Int32 {
        let u0 = p1[0] - p0[0], u1 = p1[1] - p0[1], u2 = p1[2] - p0[2]
        let w0 = p0[0] - point[0], w1 = p0[1] - point[1], w2 = p0[2] - point[2]

        let d = dot(normal[0], normal[1], normal[2], u0, u1, u2)
        let n = negatedDot(normal[0], normal[1], normal[2], w0, w1, w2)

        // Parallel to the plane, in it or not.
        if abs(Double(d)) < 0.00000001 { return 0 }

        let sI = n / d
        if sI < 0 || sI > 1 { return 0 }

        result[0] = p0[0].addingProduct(sI, u0)
        result[1] = p0[1].addingProduct(sI, u1)
        result[2] = p0[2].addingProduct(sI, u2)

        return d > 0 ? 1 : 2
    }

    /// The angle, in radians, between `v1` and `v2`: 0 when both are null,
    /// π when one is.
    public static func angle(_ v1: UnsafePointer<Float>, _ v2: UnsafePointer<Float>) -> Float {
        let null1 = v1[0] == 0 && v1[1] == 0 && v1[2] == 0
        let null2 = v2[0] == 0 && v2[1] == 0 && v2[2] == 0
        if null1 && null2 { return 0 }
        if null1 || null2 { return Float(Double.pi / 180.0 * 180) }
        func dot(_ u: UnsafePointer<Float>, _ v: UnsafePointer<Float>) -> Float {
            let x = u[0] * v[0]
            let y = u[1] * v[1]
            let z = u[2] * v[2]
            return x + y + z
        }
        let cosTheta = Float(Double(dot(v1, v2)) / (Double(dot(v1, v1)).squareRoot() * Double(dot(v2, v2)).squareRoot()))
        return acosf(cosTheta)
    }

    /// The line where two planes, given by their normals `n1`, `n2` and a
    /// point each, meet: its direction in `u` and one of its points in
    /// `point`. The caller has checked that the planes are not parallel.
    public static func twoPlanesLine(n1: UnsafePointer<Float>, p1: UnsafePointer<Float>,
                                     n2: UnsafePointer<Float>, p2: UnsafePointer<Float>,
                                     u: UnsafeMutablePointer<Float>, point: UnsafeMutablePointer<Float>) {
        twoPlanesDirection(n1: n1, n2: n2, u: u)

        let ax = u[0] >= 0 ? u[0] : -u[0]
        let ay = u[1] >= 0 ? u[1] : -u[1]
        let az = u[2] >= 0 ? u[2] : -u[2]

        // The largest coordinate of the direction is set to 0, and the
        // other two solved for.
        let maxc: Int
        if ax > ay { maxc = ax > az ? 1 : 3 } else { maxc = ay > az ? 2 : 3 }

        let d1 = negatedDot(n1[0], n1[1], n1[2], p1[0], p1[1], p1[2])
        let d2 = negatedDot(n2[0], n2[1], n2[2], p2[0], p2[1], p2[2])

        switch maxc {
        case 1:
            point[0] = 0
            point[1] = (-(d1 * n2[2])).addingProduct(d2, n1[2]) / u[0]
            point[2] = (-(d2 * n1[1])).addingProduct(d1, n2[1]) / u[0]
        case 2:
            point[0] = (-(d2 * n1[2])).addingProduct(d1, n2[2]) / u[1]
            point[1] = 0
            point[2] = (-(d1 * n2[0])).addingProduct(d2, n1[0]) / u[1]
        default:
            point[0] = (-(d1 * n2[1])).addingProduct(d2, n1[1]) / u[2]
            point[1] = (-(d2 * n1[0])).addingProduct(d1, n2[0]) / u[2]
            point[2] = 0
        }
    }

    /// n1 × n2, the direction of the line where the planes meet, into `u`.
    public static func twoPlanesDirection(n1: UnsafePointer<Float>, n2: UnsafePointer<Float>,
                                          u: UnsafeMutablePointer<Float>) {
        u[0] = (-(n1[2] * n2[1])).addingProduct(n1[1], n2[2])
        u[1] = (-(n1[0] * n2[2])).addingProduct(n1[2], n2[0])
        u[2] = (-(n1[1] * n2[0])).addingProduct(n1[0], n2[1])
    }

    /// Where a plane (normal `normal`, through `point`) crosses the edges of
    /// an image `width` × `height` pixels: the two crossings, in `sft` (6
    /// values) as `toSlice` gives them, the second where the plane leaves
    /// the image; infinity in all six when it does not cross two edges.
    /// `toDICOM` places a pixel of the image in space.
    public static func sliceIntersection(width: Float, height: Float, normal: UnsafePointer<Float>, point: UnsafePointer<Float>,
                                         toDICOM: (Float, Float, UnsafeMutablePointer<Float>) -> Void,
                                         toSlice: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void,
                                         into sft: UnsafeMutablePointer<Float>) {
        func set(_ end: Int, _ value: (Float, Float, Float)) {
            sft[3 * end] = value.0
            sft[3 * end + 1] = value.1
            sft[3 * end + 2] = value.2
        }
        let none = (Float.infinity, Float.infinity, Float.infinity)
        set(0, none)
        set(1, none)

        var c1: [Float] = [0, 0, 0], c2: [Float] = [0, 0, 0], r: [Float] = [0, 0, 0], sc: [Float] = [0, 0, 0]
        var order: [Int32] = [0, 0]
        var x = 0
        // The four edges, each from one corner to the next.
        let edges: [((Float, Float), (Float, Float))] = [((0, 0), (width, 0)), ((0, height), (0, 0)),
                                                         ((width, height), (0, height)), ((width, 0), (width, height))]
        for (from, to) in edges {
            toDICOM(from.0, from.1, &c1)
            toDICOM(to.0, to.1, &c2)
            let v = segmentPlane(c1, c2, normal: normal, point: point, result: &r)
            if x < 2 && v != 0 {
                order[x] = v
                toSlice(&r, &sc)
                set(x, (sc[0], sc[1], sc[2]))
                x += 1
            }
        }

        if x != 2 {
            set(0, none)
            set(1, none)
        } else if order[0] == 1 && order[1] == 2 {
            let first = (sft[0], sft[1], sft[2])
            set(0, (sft[3], sft[4], sft[5]))
            set(1, first)
        }
    }

    /// `v` made of length 1, or 0 when it has none.
    public static func normalised(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = (v.y * v.y).addingProduct(v.x, v.x).addingProduct(v.z, v.z).squareRoot()
        if length != 0 { return SIMD3(v.x / length, v.y / length, v.z / length) }
        return SIMD3(0, 0, 0)
    }

    /// `p` turned by `theta` radians around the axis `r`.
    public static func arbitraryRotate(_ p: SIMD3<Double>, theta: Double, axis: SIMD3<Double>) -> SIMD3<Double> {
        let r = normalised(axis)
        let c = cos(theta), s = sin(theta)
        let k = 1.0 - c

        var x = 0.0, y = 0.0, z = 0.0
        x = x.addingProduct(c.addingProduct(k * r.x, r.x), p.x)
        x = x.addingProduct((-(r.z * s)).addingProduct(k * r.x, r.y), p.y)
        x = x.addingProduct((r.y * s).addingProduct(k * r.x, r.z), p.z)

        y = y.addingProduct((r.z * s).addingProduct(k * r.x, r.y), p.x)
        y = y.addingProduct(c.addingProduct(k * r.y, r.y), p.y)
        y = y.addingProduct((-(r.x * s)).addingProduct(k * r.y, r.z), p.z)

        z = z.addingProduct((-(r.y * s)).addingProduct(k * r.x, r.z), p.x)
        z = z.addingProduct((r.x * s).addingProduct(k * r.y, r.z), p.y)
        z = z.addingProduct(c.addingProduct(k * r.z, r.z), p.z)

        return SIMD3(x, y, z)
    }
}
