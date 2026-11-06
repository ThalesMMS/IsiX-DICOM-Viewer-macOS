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

import QuartzCore

/// A point or a direction in space, in double precision.
public typealias Vector3 = SIMD3<Double>

/// The rounding the geometry keeps.
///
/// The geometry was C, which clang compiles with -ffp-contract=on: a product
/// added to or subtracted from another value in the same expression is fused
/// with that sum (one rounding), and every other operation rounds on its own.
/// The functions of this module fuse the same products, so that they give the
/// bits the C gave: `(y * v.y).addingProduct(x, v.x)` is the C `x*v.x + y*v.y`.
public enum Geometry {
    /// Below this a length counts as zero (CGFLOAT_MIN * 1E5).
    public static let smallNumber = Double.leastNormalMagnitude * 1e5

    /// The C ABS(): keeps the sign of -0.0, which magnitude would clear.
    @inlinable
    public static func absolute(_ value: Double) -> Double {
        value < 0 ? -value : value
    }

    /// The C MIN(): the second value when the first one is NaN.
    @inlinable
    public static func minimum(_ a: Double, _ b: Double) -> Double {
        a < b ? a : b
    }
}

public extension SIMD3 where Scalar == Double {

    /// x*v.x + y*v.y + z*v.z.
    @inlinable
    func dotProduct(_ v: Self) -> Double {
        (y * v.y).addingProduct(x, v.x).addingProduct(z, v.z)
    }

    @inlinable
    func crossProduct(_ v: Self) -> Self {
        let subtracted = Self(z, x, y) * Self(v.y, v.z, v.x)
        return (-subtracted).addingProduct(Self(y, z, x), Self(v.z, v.x, v.y))
    }

    @inlinable
    var length: Double {
        dotProduct(self).squareRoot()
    }

    /// The unit vector of the same direction; zero for zero.
    @inlinable
    var normalized: Self {
        let length = length
        return length == 0 ? .zero : self * (1.0 / length)
    }

    /// zero - self: unlike negation, zero stays positive.
    @inlinable
    var inverted: Self {
        Self(repeating: 0) - self
    }

    @inlinable
    var isZero: Bool {
        self == .zero
    }

    @inlinable
    func distance(to v: Self) -> Double {
        (self - v).length
    }

    /// Within Geometry.smallNumber of v.
    @inlinable
    func isCoincident(with v: Self) -> Bool {
        distance(to: v) < Geometry.smallNumber
    }

    /// direction scaled by (self·direction)/|direction|, as N3VectorProject
    /// always did; zero when direction is zero. It is the projection only for a
    /// unit direction, which is how the geometry uses it.
    @inlinable
    func projected(onto direction: Self) -> Self {
        let length = direction.length
        return length != 0 ? direction * (dotProduct(direction) / length) : .zero
    }

    /// self at t == 0, v at t == 1.
    @inlinable
    func interpolated(to v: Self, at t: Double) -> Self {
        self * (1.0 - t) + v * t
    }

    /// A unit vector normal to this one, from the longest of three candidates.
    var anyNormal: Self {
        let normal1 = Self(-y, x, 0.0)
        let normal2 = Self(-z, 0.0, x)
        let normal3 = Self(0.0, -z, y)
        let length1 = normal1.length, length2 = normal2.length, length3 = normal3.length
        if length1 > length2 {
            return (length1 > length3 ? normal1 : normal3).normalized
        }
        return (length2 > length3 ? normal2 : normal3).normalized
    }

    /// The angle from self to v around axis, in [0, 2π).
    func angle(to v: Self, around axis: Self) -> Double {
        let axis = axis.normalized
        let vector1 = (projected(onto: axis) - self).normalized
        let vector2 = (v.projected(onto: axis) - v).normalized
        let crossProduct = vector1.crossProduct(vector2)
        var angle = asin(Geometry.minimum(crossProduct.length, 1.0))
        if vector1.dotProduct(vector2) < 0.0 {
            angle = .pi - angle
        }
        if crossProduct.dotProduct(axis) < 0.0 {
            angle = .pi * 2 - angle
        }
        return angle
    }

    /// Self turned by the rotation that takes originalDirection to newDirection.
    func bent(from originalDirection: Self, to newDirection: Self) -> Self {
        let rotationAxis = originalDirection.normalized.crossProduct(newDirection.normalized)
        var angle = asin(Geometry.minimum(rotationAxis.length, 1.0))
        if originalDirection.dotProduct(newDirection) < 0.0 {
            angle = .pi - angle
        }
        let rotation = CATransform3DMakeRotation(angle, rotationAxis.x, rotationAxis.y, rotationAxis.z)
        return applying(rotation)
    }

    /// The point transformed by an affine transform, as a row vector
    /// (x y z 1) times the matrix.
    @inlinable
    func applying(_ transform: CATransform3D) -> Self {
        assert(transform.isAffine)
        return applyingToDirection(transform) + Self(transform.m41, transform.m42, transform.m43)
    }

    /// The direction transformed without the translation.
    @inlinable
    func applyingToDirection(_ transform: CATransform3D) -> Self {
        assert(transform.isAffine)
        let row1 = Self(transform.m11, transform.m12, transform.m13)
        let row2 = Self(transform.m21, transform.m22, transform.m23)
        let row3 = Self(transform.m31, transform.m32, transform.m33)
        return (row2 * y).addingProduct(row1, x).addingProduct(row3, z)
    }

    func distance(to line: Line3) -> Double {
        assert(line.isValid)
        let translated = self - line.point
        return (translated - translated.projected(onto: line.direction)).length
    }

    func distance(to plane: Plane3) -> Double {
        Geometry.absolute((self - plane.point).dotProduct(plane.normal.normalized))
    }

    func isOn(_ line: Line3) -> Bool {
        distance(to: line) < Geometry.smallNumber
    }

    func isOn(_ plane: Plane3) -> Bool {
        Geometry.absolute(plane.normal.normalized.dotProduct(self - plane.point)) < Geometry.smallNumber
    }
}
