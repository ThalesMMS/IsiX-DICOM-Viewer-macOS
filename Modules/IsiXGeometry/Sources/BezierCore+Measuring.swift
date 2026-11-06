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

/// A point of a path closest to something, and where it is.
public struct BezierClosestPoint: Sendable {
    /// Along the path, in [0, 1].
    public var relativePosition: Double
    public var vector: Vector3
    public var distance: Double
}

/// Where a path crosses a plane.
public struct BezierPlaneIntersection: Sendable {
    public var vector: Vector3
    /// Along the path, in [0, 1].
    public var relativePosition: Double
}

public extension BezierCore {

    /// The point of the path (curves flattened) closest to vector; nil for a
    /// path of fewer than two segments.
    func closestPoint(to vector: Vector3) -> BezierClosestPoint? {
        guard segments.count >= 2 else { return nil }
        let flattened = flattenedIfCurved(subdividing: false)
        var cursor = EndpointCursor(flattened)
        var bestDistance = Double.greatestFiniteMagnitude
        var bestRelativePosition = 0.0
        var bestVector = Vector3.zero
        var traveledDistance = 0.0

        var end = cursor.next().endpoint
        while !cursor.isAtEnd {
            let start = end
            let segment = cursor.next()
            end = segment.endpoint

            let segmentVector = end - start
            let translatedVector = vector - start
            let segmentLength = segmentVector.length
            let segmentDirection = segmentVector * (1.0 / segmentLength)
            let projectedDistance = translatedVector.dotProduct(segmentDirection)

            guard segment.kind != .moveTo else { continue }
            if projectedDistance >= 0 && projectedDistance <= segmentLength {
                let distance = (translatedVector - segmentDirection * projectedDistance).length
                if distance < bestDistance {
                    bestDistance = distance
                    bestRelativePosition = traveledDistance + projectedDistance
                    bestVector = start + segmentDirection * projectedDistance
                }
            } else if projectedDistance < 0 {
                let distance = start.distance(to: vector)
                if distance < bestDistance {
                    bestDistance = distance
                    bestRelativePosition = traveledDistance
                    bestVector = start
                }
            } else {
                let distance = end.distance(to: vector)
                if distance < bestDistance {
                    bestDistance = distance
                    bestRelativePosition = traveledDistance + segmentLength
                    bestVector = end
                }
            }
            traveledDistance += segmentLength
        }
        return BezierClosestPoint(relativePosition: bestRelativePosition / flattened.length, vector: bestVector, distance: bestDistance)
    }

    /// The point of the path (curves flattened) closest to line; nil for a
    /// path of fewer than two segments.
    func closestPoint(to line: Line3) -> BezierClosestPoint? {
        guard segments.count >= 2 else { return nil }
        let flattened = flattenedIfCurved(subdividing: false)
        var cursor = EndpointCursor(flattened)
        var bestDistance = Double.greatestFiniteMagnitude
        var bestRelativePosition = 0.0
        var traveledDistance = 0.0
        // A segment parallel to the line leaves the closest point of the
        // segment before it, as the former code did.
        var closestPoint = Vector3.zero

        var end = cursor.next().endpoint
        var bestVector = end
        while !cursor.isAtEnd {
            let start = end
            let segment = cursor.next()
            end = segment.endpoint
            let segmentLength = start.distance(to: end)
            guard segmentLength > 0.0 && segment.kind != .moveTo else { continue }

            let closest = Line3(from: start, to: end).closestPoints(to: line)
            if let onSegment = closest.onSelf {
                closestPoint = onSegment
            }
            if closest.distance < bestDistance {
                let mu = (end - start).dotProduct(closestPoint - start) / (segmentLength * segmentLength)
                if mu < 0.0 {
                    let distance = start.distance(to: line)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestRelativePosition = traveledDistance
                        bestVector = start
                    }
                } else if mu > 1.0 {
                    let distance = end.distance(to: line)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestRelativePosition = traveledDistance + segmentLength
                        bestVector = end
                    }
                } else {
                    bestDistance = closest.distance
                    bestRelativePosition = traveledDistance.addingProduct(segmentLength, mu)
                    bestVector = closestPoint
                }
            }
            traveledDistance += segmentLength
        }
        return BezierClosestPoint(relativePosition: bestRelativePosition / flattened.length, vector: bestVector, distance: bestDistance)
    }

    /// The length of the path up to and including the segment at index,
    /// flattened at flatness.
    func length(throughSegmentAt index: Int, flatness: Double) -> Double {
        assert(index < segments.count)
        let start = BezierCore()
        for segment in segments.prefix(index + 1) {
            start.add(segment)
        }
        return start.flattenedCopy(flatness).length
    }

    /// For each of the first `count` segments, the length (flattened at
    /// flatness) of that segment drawn from the path's first point, as the
    /// former code measured it; the first one, a moveTo, is 0.
    func segmentLengths(count: Int, flatness: Double) -> [Double] {
        guard count > 0, let start = segments.first?.endpoint else { return [] }
        var lengths = [0.0]
        for index in 1..<max(1, min(count, segments.count)) {
            let segment = BezierCore()
            segment.add(.moveTo, endpoint: start)
            segment.add(segments[index])
            lengths.append(segment.flattenedCopy(flatness).length)
        }
        return lengths
    }

    /// How many times the path (curves subdivided and flattened) crosses the plane.
    func intersectionCount(with plane: Plane3) -> Int {
        guard segments.count >= 2 else { return 0 }
        var cursor = EndpointCursor(flattenedIfCurved(subdividing: true))
        var count = 0
        var previousEndpoint = cursor.next().endpoint
        while !cursor.isAtEnd {
            let segment = cursor.next()
            if segment.kind != .moveTo && plane.isBetween(segment.endpoint, previousEndpoint) {
                count += 1
            }
            previousEndpoint = segment.endpoint
        }
        return count
    }

    /// Up to `count` crossings of the plane (curves subdivided and flattened).
    func intersections(with plane: Plane3, count: Int) -> [BezierPlaneIntersection] {
        guard segments.count >= 2 else { return [] }
        let flattened = flattenedIfCurved(subdividing: true)
        let length = flattened.length
        var cursor = EndpointCursor(flattened)
        var intersections: [BezierPlaneIntersection] = []
        var distance = 0.0
        var previousEndpoint = cursor.next().endpoint
        while !cursor.isAtEnd && intersections.count < count {
            let segment = cursor.next()
            if plane.isBetween(segment.endpoint, previousEndpoint) && segment.kind != .moveTo {
                let intersection = Line3(from: previousEndpoint, to: segment.endpoint).intersection(with: plane)
                intersections.append(BezierPlaneIntersection(vector: intersection,
                                                             relativePosition: (distance + previousEndpoint.distance(to: intersection)) / length))
            }
            distance += previousEndpoint.distance(to: segment.endpoint)
            previousEndpoint = segment.endpoint
        }
        return intersections
    }

    /// A copy (curves flattened) with an endpoint wherever the path crosses the plane.
    func addingEndpoints(atIntersectionsWith plane: Plane3) -> BezierCore {
        guard segments.count >= 2 else { return copy() }
        var cursor = EndpointCursor(flattenedIfCurved(subdividing: false))
        let core = BezierCore()
        var previousEndpoint = cursor.next().endpoint
        core.add(.moveTo, endpoint: previousEndpoint)
        while !cursor.isAtEnd {
            let segment = cursor.next()
            if segment.kind != .moveTo && plane.isBetween(segment.endpoint, previousEndpoint) {
                core.add(.lineTo, endpoint: Line3(from: previousEndpoint, to: segment.endpoint).intersection(with: plane))
            }
            core.add(segment.kind, endpoint: segment.endpoint)
            previousEndpoint = segment.endpoint
        }
        return core
    }

    /// Every point moved along the plane's normal onto the plane.
    func projected(onto plane: Plane3) -> BezierCore {
        let core = BezierCore()
        func project(_ vector: Vector3) -> Vector3 {
            let line = Line3(point: vector, direction: plane.normal)
            assert(line.isValid)
            return line.intersection(with: plane)
        }
        for segment in segments {
            core.add(segment.kind, control1: project(segment.control1), control2: project(segment.control2),
                     endpoint: project(segment.endpoint))
        }
        return core
    }

    /// The plane of the path's first endpoints (curves flattened); see
    /// Plane3.leastSquares.
    var leastSquaresPlane: Plane3 {
        Plane3.leastSquares(through: flattenedIfCurved(subdividing: false).segments.map(\.endpoint))
    }

    /// The mean distance of the endpoints (curves flattened) to the plane.
    func meanDistance(to plane: Plane3) -> Double {
        let flattened = flattenedIfCurved(subdividing: false)
        var totalDistance = 0.0
        for segment in flattened.segments {
            totalDistance += segment.endpoint.distance(to: plane)
        }
        return totalDistance / Double(flattened.segments.count)
    }

    /// The path's plane, when its endpoints are within 1 of it on average.
    var plane: Plane3? {
        let plane = leastSquaresPlane
        return meanDistance(to: plane) < 1.0 ? plane : nil
    }

    /// The planes of the given normal through the highest and the lowest
    /// endpoints (curves flattened) along it.
    func boundingPlanes(normal: Vector3) -> (top: Plane3, bottom: Plane3) {
        assert(!normal.isZero)
        var minZ = Double.greatestFiniteMagnitude
        var maxZ = -Double.greatestFiniteMagnitude
        var top = Plane3(point: .zero, normal: normal.normalized)
        var bottom = Plane3(point: .zero, normal: top.normal)
        for segment in flattenedIfCurved(subdividing: false).segments {
            let z = segment.endpoint.dotProduct(normal)
            if z < minZ {
                minZ = z
                bottom.point = segment.endpoint
            }
            if z > maxZ {
                maxZ = z
                top.point = segment.endpoint
            }
        }
        return (top, bottom)
    }
}
