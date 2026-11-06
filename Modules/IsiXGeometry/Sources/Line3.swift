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

/// An infinite line through space. It is valid when its direction is not zero.
public struct Line3: Equatable, Sendable {
    public var point: Vector3
    public var direction: Vector3

    public init(point: Vector3, direction: Vector3) {
        self.point = point
        self.direction = direction
    }

    /// The line from point1 towards point2, with a unit direction.
    public init(from point1: Vector3, to point2: Vector3) {
        self.init(point: point1, direction: (point2 - point1).normalized)
    }

    public static let xAxis = Line3(point: .zero, direction: Vector3(1, 0, 0))
    public static let yAxis = Line3(point: .zero, direction: Vector3(0, 1, 0))
    public static let zAxis = Line3(point: .zero, direction: Vector3(0, 0, 1))
    public static let invalid = Line3(point: .zero, direction: .zero)

    public var isValid: Bool {
        direction.length > Geometry.smallNumber
    }

    public func isParallel(to line: Line3) -> Bool {
        direction.crossProduct(line.direction).length < Geometry.smallNumber
    }

    /// The same line in space, to a small amount of round-off.
    public func isCoincident(with line: Line3) -> Bool {
        isParallel(to: line) && point.isOn(line)
    }

    public func isOn(_ plane: Plane3) -> Bool {
        point.isOn(plane) && Geometry.absolute(direction.dotProduct(plane.normal)) < Geometry.smallNumber
    }

    public func intersects(_ plane: Plane3) -> Bool {
        if Geometry.absolute(plane.normal.dotProduct(direction)) < Geometry.smallNumber {
            return point.isOn(plane)
        }
        return true
    }

    /// Where the line crosses the plane. A line parallel to the plane gives a
    /// point far along the line, on the plane's side, or its own point when it
    /// lies on the plane.
    public func intersection(with plane: Plane3) -> Vector3 {
        let planeNormal = plane.normal.normalized
        let lineDirection = direction.normalized
        let numerator = planeNormal.dotProduct(plane.point - point)
        let denominator = planeNormal.dotProduct(lineDirection)
        if Geometry.absolute(denominator) < Geometry.smallNumber {
            if numerator < 0.0 {
                return point + lineDirection * -(Double.greatestFiniteMagnitude / 1.0e10)
            } else if numerator > 0.0 {
                return point + lineDirection * (Double.greatestFiniteMagnitude / 1.0e10)
            }
            return point
        }
        return point + lineDirection * (numerator / denominator)
    }

    public func pointClosest(to vector: Vector3) -> Vector3 {
        (vector - point).projected(onto: direction) + point
    }

    public func applying(_ transform: CATransform3D) -> Line3 {
        let line = Line3(point: point.applying(transform), direction: direction.applyingToDirection(transform).normalized)
        assert(line.isValid)
        return line
    }

    /// The points of the two lines that are closest to each other, and their
    /// distance. Parallel lines (and lines so close to parallel that the
    /// solution divides by zero) give the distance alone: their points are nil.
    public func closestPoints(to line: Line3) -> (distance: Double, onSelf: Vector3?, onLine: Vector3?) {
        assert(isValid && line.isValid)
        let parallelDistance = {
            point.distance(to: line.point + (line.point - point).projected(onto: line.direction))
        }
        if isParallel(to: line) {
            return (parallelDistance(), nil, nil)
        }
        let p13 = point - line.point
        let p21 = direction
        let p43 = line.direction

        let d1343 = p13.dotProduct(p43)
        let d4321 = p43.dotProduct(p21)
        let d1321 = p13.dotProduct(p21)
        let d4343 = p43.dotProduct(p43)
        let d2121 = p21.dotProduct(p21)

        let numerator = (-(d1321 * d4343)).addingProduct(d1343, d4321)
        let denominator = (-(d4321 * d4321)).addingProduct(d2121, d4343)
        if denominator == 0.0 {
            return (parallelDistance(), nil, nil)
        }
        let mua = numerator / denominator
        assert(d4343 != 0)
        let mub = d1343.addingProduct(d4321, mua) / d4343

        let pa = point + p21 * mua
        let pb = line.point + p43 * mub
        return (pa.distance(to: pb), pa, pb)
    }
}
