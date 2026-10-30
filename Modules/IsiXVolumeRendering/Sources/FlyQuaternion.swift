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

//
//  The quaternion the fly-through assistant turns its view directions with,
//  once a C++ class (Quaternion.mm, by Benoit Deville, 2012, OsiriX Team).

import Foundation

/// A quaternion x i + y j + z k + w in single precision. The fly-through
/// assistant uses unit ones: every construction from an axis normalizes.
///
/// The arithmetic is the C++ class's, rounding included: clang fused each
/// multiplication into the addition or subtraction that used it (one rounding,
/// as `fma`), so the same sums are written here with `addingProduct`.
public struct FlyQuaternion: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init() {
        x = 0; y = 0; z = 0; w = 0
    }

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    /// The rotation of `degrees` about `axis`; the axis need not be a unit vector.
    public init(axis: SIMD3<Double>, degrees: Float) {
        self.init()
        set(axisX: Float(axis.x), y: Float(axis.y), z: Float(axis.z), degrees: degrees)
    }

    /// x² + y² + z² + w², summed as the C++ class did, and its square root.
    public var length: Float {
        let sum = (y * y).addingProduct(x, x).addingProduct(z, z).addingProduct(w, w)
        return sum.squareRoot()
    }

    public var conjugate: FlyQuaternion {
        FlyQuaternion(x: -x, y: -y, z: -z, w: w)
    }

    /// Scaled to length 1; a quaternion of length 0 is left as it is (dividing
    /// would give NaN).
    public mutating func normalize() {
        let l = length
        if l == 0 { return }
        x /= l; y /= l; z /= l; w /= l
    }

    /// The rotation of `degrees` about (x, y, z). Degrees become radians in
    /// double precision, as `theta * M_PI / 180` did, and the axis is made a
    /// unit vector first: scaling it by sin(theta / 2) at another length and
    /// normalizing afterwards gives another angle. An axis of length 0 stays 0.
    public mutating func set(axisX ax: Float, y ay: Float, z az: Float, degrees theta: Float) {
        let radians = Float(Double(theta) * Double.pi / 180)
        let sinAngle = sinf(radians / 2)
        var axisLength = (ay * ay).addingProduct(ax, ax).addingProduct(az, az).squareRoot()
        if axisLength == 0 { axisLength = 1 }
        x = ax / axisLength * sinAngle
        y = ay / axisLength * sinAngle
        z = az / axisLength * sinAngle
        w = cosf(radians / 2)
        normalize()
    }

    /// The Hamilton product self × q.
    public static func * (p: FlyQuaternion, q: FlyQuaternion) -> FlyQuaternion {
        let x = (p.x * q.w).addingProduct(p.w, q.x).addingProduct(p.y, q.z).addingProduct(-p.z, q.y)
        let y = (-(p.x * q.z)).addingProduct(p.w, q.y).addingProduct(p.y, q.w).addingProduct(p.z, q.x)
        let z = (p.x * q.y).addingProduct(p.w, q.z).addingProduct(-p.y, q.x).addingProduct(p.z, q.w)
        let w = (-(p.x * q.x)).addingProduct(p.w, q.w).addingProduct(-p.y, q.y).addingProduct(-p.z, q.z)
        return FlyQuaternion(x: x, y: y, z: z, w: w)
    }

    /// `v` turned by this quaternion: self × (v, 0) × conjugate, with v's
    /// components rounded to single precision and the result's widened back.
    public func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let vq = FlyQuaternion(x: Float(v.x), y: Float(v.y), z: Float(v.z), w: 0)
        let rq = (self * vq) * conjugate
        return SIMD3(Double(rq.x), Double(rq.y), Double(rq.z))
    }

    /// `v` turned by this quaternion, in single precision.
    public func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let vq = FlyQuaternion(x: v.x, y: v.y, z: v.z, w: 0)
        let rq = (self * vq) * conjugate
        return SIMD3(rq.x, rq.y, rq.z)
    }
}
