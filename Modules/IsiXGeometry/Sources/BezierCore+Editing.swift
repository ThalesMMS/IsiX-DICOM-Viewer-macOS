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

public extension BezierCore {

    /// The same path run backwards: each subpath from its last point to its
    /// moveTo, still closed if it was.
    func reversed() -> BezierCore {
        let reversed = BezierCore()
        guard let last = segments.last else { return reversed }
        if segments.count == 1 {
            assert(last.kind == .moveTo)
            reversed.add(.moveTo, endpoint: last.endpoint)
            return reversed
        }
        var needsClose = false
        var needsMove = true
        var previous = last
        for index in stride(from: segments.count - 2, through: 0, by: -1) {
            let segment = segments[index]
            if needsMove && previous.kind != .close {
                reversed.add(.moveTo, endpoint: previous.endpoint)
                needsMove = false
            }
            switch previous.kind {
            case .close:
                needsClose = true
            case .lineTo:
                reversed.add(.lineTo, endpoint: segment.endpoint)
            case .curveTo:
                reversed.add(.curveTo, control1: previous.control2, control2: previous.control1, endpoint: segment.endpoint)
            case .moveTo:
                if needsClose {
                    reversed.add(.close, endpoint: .zero)
                }
                reversed.add(.moveTo, endpoint: segment.endpoint)
                needsClose = false
                needsMove = true
            }
            previous = segment
        }
        assert(previous.kind == .moveTo)
        return reversed
    }

    /// A path for each moveTo.
    func subpaths() -> [BezierCore] {
        var subpaths: [BezierCore] = []
        for segment in segments {
            if segment.kind == .moveTo {
                subpaths.append(BezierCore())
            }
            subpaths.last?.add(segment)
        }
        return subpaths
    }

    /// The part of the path (curves flattened) between two relative positions
    /// in [0, 1]. A start after the end goes round through the path's end and
    /// its start.
    func clipped(from startRelativePosition: Double, to endRelativePosition: Double) -> BezierCore {
        assert(startRelativePosition >= 0.0 && startRelativePosition <= 1.0)
        assert(endRelativePosition >= 0.0 && endRelativePosition <= 1.0)
        if (startRelativePosition == 0 && endRelativePosition == 1.0) || (endRelativePosition == 0 && startRelativePosition == 1.0)
            || startRelativePosition == endRelativePosition || segments.count < 2 {
            return copy()
        }

        let flattened = flattenedIfCurved(subdividing: false)
        let length = flattened.length
        let startPosition = startRelativePosition * length
        let endPosition = endRelativePosition * length
        var cursor = EndpointCursor(flattened)
        let clipped = BezierCore()
        var distanceTraveled = 0.0
        var segmentLength = 0.0
        var segmentKind = BezierSegmentKind.moveTo
        var endpoint = Vector3.zero

        var previousEndpoint = cursor.next().endpoint
        while !cursor.isAtEnd { // find the start
            let segment = cursor.next()
            (segmentKind, endpoint) = (segment.kind, segment.endpoint)
            if segmentKind == .lineTo || segmentKind == .close {
                segmentLength = endpoint.distance(to: previousEndpoint)
                if segmentLength != 0 && distanceTraveled + segmentLength > startPosition {
                    clipped.add(.moveTo, endpoint: previousEndpoint.interpolated(to: endpoint, at: (startPosition - distanceTraveled) / segmentLength))
                    break
                }
                distanceTraveled += segmentLength
            }
            previousEndpoint = endpoint
        }

        if clipped.count < 1 && startPosition < endPosition { // no start was found: the last point
            clipped.add(.moveTo, endpoint: endpoint)
        }

        if startPosition > endPosition { // go all the way around
            if clipped.count == 1 {
                clipped.add(.lineTo, endpoint: endpoint)
            }
            var needsMoveTo = true
            while !cursor.isAtEnd {
                let segment = cursor.next()
                (segmentKind, endpoint) = (segment.kind, segment.endpoint)
                if cursor.isAtEnd && segmentKind == .close {
                    clipped.add(.lineTo, endpoint: endpoint)
                    needsMoveTo = false
                } else {
                    clipped.add(segmentKind, endpoint: endpoint)
                }
                previousEndpoint = endpoint
            }
            cursor = EndpointCursor(flattened)
            previousEndpoint = cursor.next().endpoint
            if needsMoveTo {
                clipped.add(.moveTo, endpoint: previousEndpoint)
            }
            let segment = cursor.next()
            (segmentKind, endpoint) = (segment.kind, segment.endpoint)
            segmentLength = endpoint.distance(to: previousEndpoint)
            distanceTraveled = 0
        }

        if segmentLength != 0 && distanceTraveled + segmentLength > endPosition { // the end is on this segment
            clipped.add(.lineTo, endpoint: previousEndpoint.interpolated(to: endpoint, at: (endPosition - distanceTraveled) / segmentLength))
            return clipped
        }
        clipped.add(segmentKind, endpoint: endpoint)
        while !cursor.isAtEnd { // find the end
            let segment = cursor.next()
            (segmentKind, endpoint) = (segment.kind, segment.endpoint)
            if segmentKind == .lineTo || segmentKind == .close {
                segmentLength = endpoint.distance(to: previousEndpoint)
                if segmentLength != 0 && distanceTraveled + segmentLength > endPosition {
                    clipped.add(.lineTo, endpoint: previousEndpoint.interpolated(to: endpoint, at: (endPosition - distanceTraveled) / segmentLength))
                    break
                }
                clipped.add(segmentKind, endpoint: endpoint)
                distanceTraveled += segmentLength
            } else {
                clipped.add(segmentKind, endpoint: endpoint)
            }
            previousEndpoint = endpoint
        }
        return clipped
    }

    /// The area of the closed subpaths (curves flattened), signed by their
    /// direction around normal.
    func signedArea(normal: Vector3) -> Double {
        let normal = normal.normalized
        var signedArea = 0.0
        for subpath in subpaths() where subpath.segments.last?.kind == .close {
            var cursor = EndpointCursor(subpath.flattenedIfCurved(subdividing: false))
            let first = cursor.next()
            assert(first.kind == .moveTo)
            var previousEndpoint = first.endpoint
            while !cursor.isAtEnd {
                let endpoint = cursor.next().endpoint
                signedArea += previousEndpoint.crossProduct(endpoint).dotProduct(normal)
                previousEndpoint = endpoint
            }
        }
        return signedArea * 0.5
    }
}
