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

/// A plane through a point. It is valid when its normal is not zero.
public struct Plane3: Equatable, Sendable {
    public var point: Vector3
    public var normal: Vector3

    public init(point: Vector3, normal: Vector3) {
        self.point = point
        self.normal = normal
    }

    public static let xZero = Plane3(point: .zero, normal: Vector3(1, 0, 0))
    public static let yZero = Plane3(point: .zero, normal: Vector3(0, 1, 0))
    public static let zZero = Plane3(point: .zero, normal: Vector3(0, 0, 1))
    public static let invalid = Plane3(point: .zero, normal: .zero)

    public var isValid: Bool {
        normal.length > Geometry.smallNumber
    }

    public func isCoincident(with plane: Plane3) -> Bool {
        if normal.crossProduct(plane.normal).length > Geometry.smallNumber {
            return false
        }
        return point.isOn(plane)
    }

    public func isParallel(to plane: Plane3) -> Bool {
        normal.crossProduct(plane.normal).length <= Geometry.smallNumber
    }

    /// The two points are on different sides of the plane.
    public func isBetween(_ vector1: Vector3, _ vector2: Vector3) -> Bool {
        (normal.dotProduct(vector2 - point) < 0.0) != (normal.dotProduct(vector1 - point) < 0.0)
    }

    public func pointClosest(to vector: Vector3) -> Vector3 {
        let planeNormal = normal.normalized
        return vector + planeNormal * planeNormal.dotProduct(point - vector)
    }

    /// The line where the planes meet. Parallel planes give a line on the first
    /// plane, which is all that callers expect of them.
    public func intersection(with plane: Plane3) -> Line3 {
        var line = Line3(point: .zero, direction: normal.crossProduct(plane.normal).normalized)
        if line.direction.isZero {
            line.direction = normal.crossProduct(Vector3(1.0, 0.0, 0.0)).normalized
            if line.direction.isZero {
                line.direction = normal.crossProduct(Vector3(0.0, 1.0, 0.0)).normalized
            }
            line.point = point
            return line
        }
        let towardsPlane = Line3(point: point, direction: (plane.normal - plane.normal.projected(onto: normal)).normalized)
        line.point = towardsPlane.intersection(with: plane)
        return line
    }

    /// The plane of the first three points; invalid with three points or
    /// fewer, or when they are on a line. It is not a least squares fit.
    public static func leastSquares(through points: [Vector3]) -> Plane3 {
        if points.count <= 3 {
            return .invalid
        }
        let plane = Plane3(point: points[0], normal: (points[1] - points[0]).crossProduct(points[2] - points[0]).normalized)
        return plane.normal.isZero ? .invalid : plane
    }

    /// The point is transformed, the normal by the inverse transpose of the
    /// transform without its translation.
    public func applying(_ transform: CATransform3D) -> Plane3 {
        var normalTransform = transform
        normalTransform.m41 = 0.0
        normalTransform.m42 = 0.0
        normalTransform.m43 = 0.0
        let plane = Plane3(point: point.applying(transform),
                           normal: normal.applying(normalTransform.inverted.transposed).normalized)
        assert(plane.isValid)
        return plane
    }
}
