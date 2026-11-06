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

/// Evenly spaced points of a path, with the tangent and the normal at each.
public struct BezierSamples: Sendable {
    public var vectors: [Vector3] = []
    public var tangents: [Vector3] = []
    public var normals: [Vector3] = []
    /// Projected sampling: the position of each point along the path, in [0, 1].
    public var relativePositions: [Double] = []
    /// The points taken, whichever of their outputs are kept.
    public internal(set) var count = 0
}

/// Reads the endpoints of a path one after the other, as the former C
/// iterator did.
struct EndpointCursor {
    let segments: [BezierSegment]
    var index = 0

    init(_ core: BezierCore) {
        segments = core.segments
    }

    var isAtEnd: Bool {
        index >= segments.count
    }

    /// The next segment; past the end, a moveTo to zero.
    mutating func next() -> BezierSegment {
        guard !isAtEnd else { return BezierSegment(.moveTo, endpoint: .zero) }
        defer { index += 1 }
        return segments[index]
    }
}

public extension BezierCore {

    var vectorAtStart: Vector3 {
        segments.first?.endpoint ?? .zero
    }

    var vectorAtEnd: Vector3 {
        segments.last?.endpoint ?? .zero
    }

    var tangentAtStart: Vector3 {
        guard segments.count >= 2 else { return .zero }
        let second = segments[1]
        return (second.endpoint - (second.kind == .curveTo ? second.control1 : segments[0].endpoint)).normalized
    }

    var tangentAtEnd: Vector3 {
        guard segments.count >= 2 else { return .zero }
        let last = segments[segments.count - 1]
        return (last.endpoint - (last.kind == .curveTo ? last.control2 : segments[segments.count - 2].endpoint)).normalized
    }

    /// The normal at the start, made normal to the first segment; an axis
    /// crossed with it when initialNormal is along it.
    private static func startNormal(_ initialNormal: Vector3, along direction: Vector3) -> Vector3 {
        var normal = (initialNormal - initialNormal.projected(onto: direction)).normalized
        if normal == .zero {
            normal = Vector3(-1.0, 0.0, 0.0).crossProduct(direction).normalized
            if normal == .zero {
                normal = Vector3(0.0, 1.0, 0.0).crossProduct(direction).normalized
            }
        }
        return normal
    }

    /// initialNormal carried along the path, bent at each corner and kept
    /// normal to the segment, up to the end.
    func normalAtEnd(initialNormal: Vector3) -> Vector3 {
        assert(subpathCount == 1)
        guard segments.count >= 2 else { return initialNormal }
        var cursor = EndpointCursor(flattenedIfCurved(subdividing: false))
        var start = cursor.next().endpoint
        var end = cursor.next().endpoint
        var previousSegment = end - start
        var normal = Self.startNormal(initialNormal, along: previousSegment)
        while !cursor.isAtEnd {
            start = end
            end = cursor.next().endpoint
            let segment = end - start
            normal = normal.bent(from: previousSegment, to: segment)
            normal = (normal - normal.projected(onto: segment)).normalized
            previousSegment = segment
        }
        return normal
    }

    /// Up to `count` points every `spacing` along the path, the first at
    /// `startingDistance`, with the tangents and the normals (initialNormal
    /// carried along the path) blended between the segments. Curves are
    /// subdivided and flattened first. Only the outputs asked for are kept.
    func samples(spacing: Double, startingDistance: Double, initialNormal: Vector3, count: Int,
                 vectors wantsVectors: Bool, tangents wantsTangents: Bool, normals wantsNormals: Bool) -> BezierSamples {
        var samples = BezierSamples()
        if count == 0 || segments.count < 2 {
            return samples
        }
        assert(subpathCount == 1)

        var cursor = EndpointCursor(flattenedIfCurved(subdividing: true))
        var extraDistance = startingDistance
        var startVector = cursor.next().endpoint
        var endVector = cursor.next().endpoint
        var segmentDirection = (endVector - startVector).normalized
        var segmentLength = endVector.distance(to: startVector)

        var normalVector = Self.startNormal(initialNormal, along: segmentDirection)
        var previousNormalVector = normalVector
        var tangentVector = segmentDirection
        var previousTangentVector = tangentVector
        var done = false

        while !done {
            var distanceTraveled = extraDistance
            let nextNormalVector: Vector3, nextTangentVector: Vector3, nextVector: Vector3
            var nextSegmentDirection = segmentDirection
            if cursor.isAtEnd {
                nextNormalVector = normalVector
                nextTangentVector = tangentVector
                nextVector = endVector
                done = true
            } else {
                nextVector = cursor.next().endpoint
                nextSegmentDirection = (nextVector - endVector).normalized
                var bent = normalVector.bent(from: segmentDirection, to: nextSegmentDirection)
                bent = bent - bent.projected(onto: nextSegmentDirection)
                nextNormalVector = bent.normalized
                nextTangentVector = nextSegmentDirection
            }
            let startNormalVector = previousNormalVector.interpolated(to: normalVector, at: 0.5).normalized
            let endNormalVector = nextNormalVector.interpolated(to: normalVector, at: 0.5).normalized
            let startTangentVector = previousTangentVector.interpolated(to: tangentVector, at: 0.5).normalized
            let endTangentVector = nextTangentVector.interpolated(to: tangentVector, at: 0.5).normalized

            while distanceTraveled < segmentLength {
                if wantsVectors {
                    samples.vectors.append(startVector + segmentDirection * distanceTraveled)
                }
                if wantsTangents {
                    samples.tangents.append(startTangentVector.interpolated(to: endTangentVector, at: distanceTraveled / segmentLength).normalized)
                }
                if wantsNormals {
                    samples.normals.append(startNormalVector.interpolated(to: endNormalVector, at: distanceTraveled / segmentLength).normalized)
                }
                samples.count += 1
                if samples.count >= count {
                    return samples
                }
                distanceTraveled += spacing
            }

            extraDistance = distanceTraveled - segmentLength
            previousNormalVector = normalVector
            normalVector = nextNormalVector
            previousTangentVector = tangentVector
            tangentVector = nextTangentVector
            segmentDirection = nextSegmentDirection
            startVector = endVector
            endVector = nextVector
            segmentLength = startVector.distance(to: endVector)
        }
        return samples
    }

    /// For the stretched CPR: points spaced by `spacing` once the path is
    /// projected along projectionDirection, on the path itself, with their
    /// relative positions; the normals are normal to the projection direction.
    func projectedSamples(spacing: Double, startingDistance: Double, projectionDirection: Vector3, count: Int,
                          vectors wantsVectors: Bool, tangents wantsTangents: Bool, normals wantsNormals: Bool,
                          relativePositions wantsRelativePositions: Bool) -> BezierSamples {
        var samples = BezierSamples()
        if count == 0 || segments.count < 2 {
            return samples
        }
        assert(subpathCount == 1)

        let flattened = flattenedIfCurved(subdividing: true)
        let bezierLength = flattened.length
        var cursor = EndpointCursor(flattened)
        var projectedCursor = EndpointCursor(flattened.projected(onto: Plane3(point: .zero, normal: projectionDirection)))

        func normal(along projectedDirection: Vector3) -> Vector3 {
            let normal = projectedDirection.crossProduct(projectionDirection).normalized
            return normal.isZero ? projectionDirection.anyNormal : normal
        }

        var extraDistance = startingDistance
        var totalDistanceTraveled = startingDistance
        var startVector = cursor.next().endpoint
        var startProjectedVector = projectedCursor.next().endpoint
        var endVector = cursor.next().endpoint
        var endProjectedVector = projectedCursor.next().endpoint
        var segmentDirection = (endVector - startVector).normalized
        let projectedSegmentDirection = (endProjectedVector - startProjectedVector).normalized
        var segmentLength = endVector.distance(to: startVector)
        var projectedSegmentLength = endProjectedVector.distance(to: startProjectedVector)

        var normalVector = normal(along: projectedSegmentDirection)
        var previousNormalVector = normalVector
        var tangentVector = segmentDirection
        var previousTangentVector = tangentVector
        var done = false

        while !done {
            var distanceTraveled = extraDistance
            let nextNormalVector: Vector3, nextTangentVector: Vector3, nextVector: Vector3
            var nextProjectedVector = endProjectedVector
            var nextSegmentDirection = segmentDirection
            if cursor.isAtEnd {
                nextNormalVector = normalVector
                nextTangentVector = tangentVector
                nextVector = endVector
                done = true
            } else {
                nextVector = cursor.next().endpoint
                nextProjectedVector = projectedCursor.next().endpoint
                nextSegmentDirection = (nextVector - endVector).normalized
                nextNormalVector = normal(along: (nextProjectedVector - endProjectedVector).normalized)
                nextTangentVector = nextSegmentDirection
            }
            let startNormalVector = previousNormalVector.interpolated(to: normalVector, at: 0.5).normalized
            let endNormalVector = nextNormalVector.interpolated(to: normalVector, at: 0.5).normalized
            let startTangentVector = previousTangentVector.interpolated(to: tangentVector, at: 0.5).normalized
            let endTangentVector = nextTangentVector.interpolated(to: tangentVector, at: 0.5).normalized

            while distanceTraveled < projectedSegmentLength {
                let segmentDistanceTraveled = distanceTraveled * (segmentLength / projectedSegmentLength)
                if wantsVectors {
                    samples.vectors.append(startVector + segmentDirection * segmentDistanceTraveled)
                }
                if wantsTangents {
                    samples.tangents.append(startTangentVector.interpolated(to: endTangentVector, at: distanceTraveled / projectedSegmentLength).normalized)
                }
                if wantsNormals {
                    samples.normals.append(startNormalVector.interpolated(to: endNormalVector, at: distanceTraveled / projectedSegmentLength).normalized)
                }
                if wantsRelativePositions {
                    samples.relativePositions.append((totalDistanceTraveled + segmentDistanceTraveled) / bezierLength)
                }
                samples.count += 1
                if samples.count >= count {
                    return samples
                }
                distanceTraveled += spacing
            }

            extraDistance = distanceTraveled - projectedSegmentLength
            totalDistanceTraveled += segmentLength
            previousNormalVector = normalVector
            normalVector = nextNormalVector
            previousTangentVector = tangentVector
            tangentVector = nextTangentVector
            segmentDirection = nextSegmentDirection
            startVector = endVector
            endVector = nextVector
            startProjectedVector = endProjectedVector
            endProjectedVector = nextProjectedVector
            segmentLength = endVector.distance(to: startVector)
            projectedSegmentLength = endProjectedVector.distance(to: startProjectedVector)
        }
        return samples
    }

    /// Two lines either side of the path, at `distance` along the normals that
    /// carry initialNormal along it, sampled every `spacing`. Nil for a path
    /// of fewer than two segments, or no longer than twice the spacing.
    func outline(distance: Double, spacing: Double, initialNormal: Vector3) -> BezierCore? {
        outline(distance: distance, spacing: spacing) { flattened, count in
            let samples = flattened.samples(spacing: spacing, startingDistance: 0, initialNormal: initialNormal, count: count,
                                            vectors: true, tangents: false, normals: true)
            guard let lastNormal = samples.normals.last else { return nil }
            let endpointNormal = (lastNormal - lastNormal.projected(onto: flattened.tangentAtEnd)).normalized * distance
            return (samples.vectors, samples.normals, endpointNormal)
        }
    }

    /// The outline whose sides are normal to projectionNormal.
    func outline(distance: Double, spacing: Double, projectionNormal: Vector3) -> BezierCore? {
        outline(distance: distance, spacing: spacing) { flattened, count in
            let samples = flattened.samples(spacing: spacing, startingDistance: 0, initialNormal: .zero, count: count,
                                            vectors: true, tangents: true, normals: false)
            let endpointNormal = projectionNormal.crossProduct(flattened.tangentAtEnd).normalized * distance
            return (samples.vectors, samples.tangents.map { projectionNormal.crossProduct($0).normalized }, endpointNormal)
        }
    }

    /// The two sides: `sample` answers the points, the unit normals and the
    /// offset at the endpoint, for the flattened path and the number of points.
    private func outline(distance: Double, spacing: Double,
                         sample: (BezierCore, Int) -> (vectors: [Vector3], normals: [Vector3], endpointNormal: Vector3)?) -> BezierCore? {
        assert(subpathCount == 1)
        guard segments.count >= 2 else { return nil }
        let flattened = flattenedIfCurved(subdividing: true)
        let length = flattened.length
        if spacing * 2 >= length {
            return nil
        }
        let numVectors = length / spacing + 1.0
        guard numVectors.isFinite, numVectors >= 1, let (vectors, normals, endpointNormal) = sample(flattened, Int(numVectors)),
              !vectors.isEmpty else {
            return nil
        }
        let endpoint = flattened.vectorAtEnd
        let outline = BezierCore()
        for (side, offset) in [(distance, endpointNormal), (-distance, endpointNormal.inverted)] {
            for (index, (vector, normal)) in zip(vectors, normals).enumerated() {
                outline.add(index == 0 ? .moveTo : .lineTo, endpoint: vector + normal * side)
            }
            outline.add(.lineTo, endpoint: endpoint + offset)
        }
        return outline
    }
}
