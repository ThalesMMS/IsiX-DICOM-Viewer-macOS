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

/// What a segment of a path does. The raw values are those of the former C
/// enumeration.
public enum BezierSegmentKind: UInt32, Sendable {
    case moveTo = 0
    case lineTo = 1
    case curveTo = 2
    case close = 3
}

/// One segment: the controls are only meaningful for a curve, and are zero
/// for the others.
public struct BezierSegment: Sendable {
    public var kind: BezierSegmentKind
    public var control1: Vector3
    public var control2: Vector3
    public var endpoint: Vector3

    public init(_ kind: BezierSegmentKind, control1: Vector3 = .zero, control2: Vector3 = .zero, endpoint: Vector3) {
        self.kind = kind
        self.control1 = control1
        self.control2 = control2
        self.endpoint = endpoint
    }

    /// Same kind and endpoint, and for a curve the same controls.
    public func matches(_ segment: BezierSegment) -> Bool {
        guard kind == segment.kind, endpoint == segment.endpoint else { return false }
        return kind != .curveTo || (control1 == segment.control1 && control2 == segment.control2)
    }

    /// A rough length that is never shorter than the segment: the control
    /// polygon of a curve.
    func approximateLength(from start: Vector3) -> Double {
        switch kind {
        case .lineTo, .close:
            return endpoint.distance(to: start)
        case .curveTo:
            return start.distance(to: control1) + control1.distance(to: control2) + control2.distance(to: endpoint)
        case .moveTo:
            return 0.0
        }
    }

    /// How far the controls of a curve stray from its chord, along it or
    /// across it; zero for the other segments.
    func flatness(from start: Vector3) -> Double {
        guard kind == .curveTo else { return 0.0 }
        let line = endpoint - start
        let vectorToControl1 = control1 - start
        let vectorToControl2 = control2 - endpoint
        let lineLength = line.length

        let control1ScalarProjection = line.dotProduct(vectorToControl1) / lineLength
        let endFlatness1 = control1ScalarProjection * -1.0
        let flatness1 = (vectorToControl1 - line * (control1ScalarProjection / lineLength)).length

        let control2ScalarProjection = line.dotProduct(vectorToControl2) / lineLength
        let endFlatness2 = control2ScalarProjection
        let flatness2 = (vectorToControl2 - line * (control2ScalarProjection / lineLength)).length

        var maxFlatness = flatness1
        if flatness2 > maxFlatness { maxFlatness = flatness2 }
        if endFlatness1 > maxFlatness { maxFlatness = endFlatness1 }
        if endFlatness2 > maxFlatness { maxFlatness = endFlatness2 }
        return maxFlatness
    }

    /// The two halves of a line, a close (a line, then the close) or a curve
    /// (de Casteljau at t = 0.5).
    func divided(from start: Vector3) -> (BezierSegment, BezierSegment) {
        assert(kind != .moveTo)
        switch kind {
        case .curveTo:
            let q0 = (start + control1) * 0.5
            let q1 = (control1 + control2) * 0.5
            let q2 = (control2 + endpoint) * 0.5
            let r0 = (q0 + q1) * 0.5
            let r1 = (q1 + q2) * 0.5
            let b = (r0 + r1) * 0.5
            return (BezierSegment(.curveTo, control1: q0, control2: r0, endpoint: b),
                    BezierSegment(.curveTo, control1: r1, control2: q2, endpoint: endpoint))
        case .close:
            return (BezierSegment(.lineTo, endpoint: (start + endpoint) * 0.5), BezierSegment(.close, endpoint: endpoint))
        default:
            return (BezierSegment(kind, endpoint: (start + endpoint) * 0.5), BezierSegment(kind, endpoint: endpoint))
        }
    }
}

/// How the ends of a curve through nodes are shaped.
public enum BezierNodeStyle: UInt32, Sendable {
    /// The end segments point out: the CPR's paths.
    case openEnds = 0
    /// The end segments point to each other: the open ROIs.
    case endsMeet = 1
}

/// A path of segments in space: subpaths that each start with a moveTo and
/// may end with a close, whose endpoint is the subpath's moveTo.
public final class BezierCore {
    public static let defaultFlatness = 0.1
    public static let defaultSubdivideSegmentLength = 3.0

    public private(set) var segments: [BezierSegment]

    public init() {
        segments = []
    }

    public init(copying core: BezierCore) {
        segments = core.segments
    }

    public func copy() -> BezierCore {
        BezierCore(copying: self)
    }

    public var count: Int {
        segments.count
    }

    public subscript(index: Int) -> BezierSegment {
        segments[index]
    }

    /// Adds a segment. Only a curve keeps its controls; a close ends at the
    /// last moveTo, whatever the endpoint given.
    public func add(_ kind: BezierSegmentKind, control1: Vector3 = .zero, control2: Vector3 = .zero, endpoint: Vector3) {
        assert(!segments.isEmpty || kind == .moveTo)
        assert(segments.last?.kind != .close || kind == .moveTo)
        switch kind {
        case .moveTo, .lineTo:
            segments.append(BezierSegment(kind, endpoint: endpoint))
        case .curveTo:
            segments.append(BezierSegment(kind, control1: control1, control2: control2, endpoint: endpoint))
        case .close:
            segments.append(BezierSegment(kind, endpoint: lastMoveTo))
        }
    }

    public func add(_ segment: BezierSegment) {
        add(segment.kind, control1: segment.control1, control2: segment.control2, endpoint: segment.endpoint)
    }

    private var lastMoveTo: Vector3 {
        segments.last { $0.kind == .moveTo }?.endpoint ?? .zero
    }

    /// Moves the segment at index. Moving a moveTo moves the close of its
    /// subpath with it; a close does not move.
    public func setVectors(at index: Int, control1: Vector3, control2: Vector3, endpoint: Vector3) {
        assert(index < segments.count)
        switch segments[index].kind {
        case .moveTo:
            segments[index].endpoint = endpoint
            for following in segments.indices.dropFirst(index + 1) {
                if segments[following].kind == .close {
                    segments[following].endpoint = endpoint
                    break
                } else if segments[following].kind == .moveTo {
                    break
                }
            }
        case .lineTo:
            segments[index].endpoint = endpoint
        case .curveTo:
            segments[index].control1 = control1
            segments[index].control2 = control2
            segments[index].endpoint = endpoint
        case .close:
            break
        }
    }

    /// Splits the curves in halves until each one is within flatness of its
    /// chord, and makes them lines. 0 is the default flatness.
    public func flatten(_ flatness: Double) {
        guard segments.count >= 2 else { return }
        let flatness = flatness == 0.0 ? Self.defaultFlatness : flatness
        segments = splitting { segment, start in
            if segment.flatness(from: start) > flatness {
                return nil
            }
            guard segment.kind == .curveTo else { return segment }
            return BezierSegment(.lineTo, endpoint: segment.endpoint)
        }
    }

    /// Splits the segments in halves until each one is at most
    /// maxSegmentLength long (a curve, its control polygon). 0 is the default.
    public func subdivide(_ maxSegmentLength: Double) {
        guard segments.count >= 2 else { return }
        let maxSegmentLength = maxSegmentLength == 0.0 ? Self.defaultSubdivideSegmentLength : maxSegmentLength
        segments = splitting { segment, start in
            segment.approximateLength(from: start) > maxSegmentLength ? nil : segment
        }
    }

    /// The segments after the first, each split in halves while `keep` answers
    /// nil, the first half before the second; `keep` gets the segment and the
    /// endpoint before it, and answers what to keep of it.
    private func splitting(_ keep: (BezierSegment, Vector3) -> BezierSegment?) -> [BezierSegment] {
        var result = [segments[0]]
        result.reserveCapacity(segments.count * 2)
        func place(_ segment: BezierSegment) {
            let start = result[result.count - 1].endpoint
            if let kept = keep(segment, start) {
                result.append(kept)
            } else {
                let (first, second) = segment.divided(from: start)
                place(first)
                place(second)
            }
        }
        for segment in segments.dropFirst() {
            place(segment)
        }
        return result
    }

    public func apply(_ transform: CATransform3D) {
        for index in segments.indices {
            segments[index].endpoint = segments[index].endpoint.applying(transform)
            if segments[index].kind == .curveTo {
                segments[index].control1 = segments[index].control1.applying(transform)
                segments[index].control2 = segments[index].control2.applying(transform)
            }
        }
    }

    /// Adds the segments of core. Connected, the first moveTo of core is left
    /// out, and so is the close that ends this path.
    public func append(_ core: BezierCore, connectingPaths: Bool) {
        var appended = core.segments[...]
        if !appended.isEmpty && connectingPaths {
            appended = appended.dropFirst()
            if segments.last?.kind == .close {
                segments.removeLast()
            }
        }
        for segment in appended {
            add(segment)
        }
    }

    /// A curve after the first segment.
    public var hasCurve: Bool {
        segments.dropFirst().contains { $0.kind == .curveTo }
    }

    public var subpathCount: Int {
        segments.reduce(0) { $1.kind == .moveTo ? $0 + 1 : $0 }
    }

    /// The length of the lines and closes; with curves, of the path flattened
    /// at the default flatness.
    public var length: Double {
        guard let first = segments.first else { return 0.0 }
        if hasCurve {
            return flattenedCopy(Self.defaultFlatness).length
        }
        var lastPoint = first.endpoint
        var length = 0.0
        for segment in segments.dropFirst() {
            if segment.kind == .lineTo || segment.kind == .close {
                length += lastPoint.distance(to: segment.endpoint)
            }
            lastPoint = segment.endpoint
        }
        return length
    }

    public func isEqual(to core: BezierCore) -> Bool {
        if core === self { return true }
        guard segments.count == core.segments.count else { return false }
        return zip(segments, core.segments).allSatisfy { $0.matches($1) }
    }

    public func flattenedCopy(_ flatness: Double) -> BezierCore {
        let copy = copy()
        copy.flatten(flatness)
        return copy
    }

    public func subdividedCopy(_ maxSegmentLength: Double) -> BezierCore {
        let copy = copy()
        copy.subdivide(maxSegmentLength)
        return copy
    }

    public func transformedCopy(_ transform: CATransform3D) -> BezierCore {
        let copy = copy()
        copy.apply(transform)
        return copy
    }

    /// Itself when it has no curve, otherwise a copy subdivided at the default
    /// length (when `subdividing`) and flattened at the default flatness.
    func flattenedIfCurved(subdividing: Bool) -> BezierCore {
        guard hasCurve else { return self }
        let copy = copy()
        if subdividing {
            copy.subdivide(Self.defaultSubdivideSegmentLength)
        }
        copy.flatten(Self.defaultFlatness)
        return copy
    }

    /// Debug builds: the first segment is a moveTo, a close ends at its
    /// subpath's moveTo and is followed by a moveTo.
    public func assertInvariants() {
        #if DEBUG
        guard let first = segments.first else { return }
        assert(first.kind == .moveTo)
        var lastMoveTo = first.endpoint
        var needsMoveTo = false
        for segment in segments.dropFirst() {
            switch segment.kind {
            case .moveTo:
                lastMoveTo = segment.endpoint
                needsMoveTo = false
            case .lineTo, .curveTo:
                assert(!needsMoveTo)
            case .close:
                assert(!needsMoveTo)
                assert(segment.endpoint == lastMoveTo)
                needsMoveTo = true
            }
        }
        #endif
    }
}
