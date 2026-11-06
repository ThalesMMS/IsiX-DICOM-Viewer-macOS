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
import IsiXGeometry

// N3BezierPath and N3MutableBezierPath are implemented in Swift under the
// interface that N3BezierPath.h declares (@objc @implementation), over
// IsiXGeometry's BezierCore: an immutable path never changes its core, a
// mutable one changes it in place. The core is the path's own; -N3BezierCore
// gives a copy that the autorelease pool keeps.

@objc @implementation extension N3BezierPath {

    /// The path's segments.
    final var core = BezierCore()
    /// The length, measured on first use; 0 until then and after each change.
    final var measuredLength: CGFloat = 0
    final let lengthLock = NSLock()
    /// Counts the changes of a mutable path, for the mutation check of fast
    /// enumeration.
    final let mutations: UnsafeMutablePointer<UInt> = {
        let mutations = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
        mutations.initialize(to: 0)
        return mutations
    }()

    deinit {
        mutations.deallocate()
    }

    override init() {
        super.init()
    }

    convenience init!(bezierPath: N3BezierPath!) {
        self.init()
        core = bezierPath.core.copy()
        measuredLength = bezierPath.lengthLock.withLock { bezierPath.measuredLength }
    }

    convenience init!(dictionaryRepresentation dict: [AnyHashable: Any]!) {
        guard let core = makeBezierCore(dictionaryRepresentation: dict as NSDictionary?) else { return nil }
        self.init()
        self.core = core
    }

    convenience init!(n3BezierCore handle: N3BezierCoreRef!) {
        self.init()
        core = bezierCore(handle).copy()
    }

    /// Through the NSValues of N3Vectors: a curve through three nodes or more,
    /// a line through two, a lone moveTo for one, and nothing for none.
    convenience init!(nodeArray nodes: [Any]!, style: N3BezierNodeStyle) {
        self.init()
        let vectors = (nodes ?? []).map { ($0 as! NSValue).makeN3Vector().vector3 }
        if vectors.count >= 2 {
            core = BezierCore.curve(through: vectors, style: BezierNodeStyle(rawValue: style.rawValue) ?? .openEnds)
        } else if let first = vectors.first {
            core.add(.moveTo, endpoint: first)
        }
    }

    // A CPR path file holds one, and comes from anywhere.
    class var supportsSecureCoding: Bool {
        true
    }

    public required convenience init?(coder decoder: NSCoder) {
        // The dictionary representation: arrays and dictionaries of numbers and strings.
        let dictionary = decoder.decodeObject(of: [NSDictionary.self, NSArray.self, NSNumber.self, NSString.self],
                                              forKey: "bezierPathDictionaryRepresentation") as? NSDictionary
        guard let core = makeBezierCore(dictionaryRepresentation: dictionary) else { return nil }
        self.init()
        self.core = core
    }

    @objc(encodeWithCoder:)
    func encode(with encoder: NSCoder) {
        encoder.encode(dictionaryRepresentation(), forKey: "bezierPathDictionaryRepresentation")
    }

    @objc(copyWithZone:)
    func copy(with zone: NSZone? = nil) -> Any {
        N3MutableBezierPath(bezierPath: self)!
    }

    @objc(mutableCopyWithZone:)
    func mutableCopy(with zone: NSZone? = nil) -> Any {
        N3MutableBezierPath(bezierPath: self)!
    }

    class func bezierPath() -> Any! {
        (self as NSObject.Type).init()
    }

    @objc(bezierPathWithBezierPath:)
    class func bezierPath(with bezierPath: N3BezierPath!) -> Any! {
        let path = (self as NSObject.Type).init() as! Self
        path.core = bezierPath.core.copy()
        path.measuredLength = bezierPath.lengthLock.withLock { bezierPath.measuredLength }
        return path
    }

    @objc(bezierPathN3BezierCore:)
    class func bezierPathN3BezierCore(_ handle: N3BezierCoreRef!) -> Any! {
        let path = (self as NSObject.Type).init() as! Self
        path.core = bezierCore(handle).copy()
        return path
    }

    /// Four curves, a quarter circle each, in the plane normal to normal.
    @objc(bezierPathCircleWithCenter:radius:normal:)
    class func bezierPathCircle(withCenter center: N3Vector, radius: CGFloat, normal: N3Vector) -> Any! {
        let planeVector = N3VectorANormalVector(normal)
        let planeVector2 = N3VectorCrossProduct(normal, planeVector)
        let path = N3MutableBezierPath()
        func offset(_ vector: N3Vector, _ direction: N3Vector, _ scale: CGFloat) -> N3Vector {
            N3VectorAdd(vector, N3VectorScalarMultiply(direction, scale))
        }
        let corner1 = offset(center, planeVector, radius)
        let corner2 = offset(center, planeVector2, radius)
        let corner3 = offset(center, planeVector, -radius)
        let corner4 = offset(center, planeVector2, -radius)
        let control = radius * 0.551784
        let negativeControl = radius * -0.551784
        path.move(to: corner1)
        path.curve(to: corner2, controlVector1: offset(corner1, planeVector2, control), controlVector2: offset(corner2, planeVector, control))
        path.curve(to: corner3, controlVector1: offset(corner2, planeVector, negativeControl), controlVector2: offset(corner3, planeVector2, control))
        path.curve(to: corner4, controlVector1: offset(corner3, planeVector2, negativeControl), controlVector2: offset(corner4, planeVector, negativeControl))
        path.curve(to: corner1, controlVector1: offset(corner4, planeVector, control), controlVector2: offset(corner1, planeVector2, negativeControl))
        path.close()
        return path
    }

    @objc(isEqualToBezierPath:)
    func isEqual(to bezierPath: N3BezierPath!) -> Bool {
        self === bezierPath || core.isEqual(to: bezierPath.core)
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let bezierPath = object as? N3BezierPath else { return false }
        return isEqual(to: bezierPath)
    }

    override public var hash: Int {
        core.count
    }

    override public var description: String {
        n3DictionaryRepresentation(core).description
    }

    /// The endpoints, as NSValues of N3Vectors, one at a time.
    @objc(countByEnumeratingWithState:objects:count:)
    func countByEnumerating(with state: UnsafeMutablePointer<NSFastEnumerationState>,
                            objects buffer: AutoreleasingUnsafeMutablePointer<AnyObject?>, count len: UInt) -> UInt {
        if state.pointee.state == 0 {
            state.pointee.mutationsPtr = mutations
        }
        guard state.pointee.state < UInt(core.count) else { return 0 }
        buffer.pointee = NSValue.makeValue(n3Vector: N3Vector(core[Int(state.pointee.state)].endpoint))
        state.pointee.itemsPtr = buffer
        state.pointee.state += 1
        return 1
    }

    // MARK: - New paths

    /// A mutable copy, changed by `change`.
    final func changedCopy(_ change: (N3MutableBezierPath) -> Void) -> N3BezierPath {
        let path = N3MutableBezierPath(bezierPath: self)!
        change(path)
        return path
    }

    @objc(bezierPathByFlattening:)
    func flattening(_ flatness: CGFloat) -> N3BezierPath! {
        changedCopy { $0.flatten(flatness) }
    }

    @objc(bezierPathBySubdividing:)
    func subdividing(_ maxSegmentLength: CGFloat) -> N3BezierPath! {
        changedCopy { $0.subdivide(maxSegmentLength) }
    }

    @objc(bezierPathByApplyingTransform:)
    func applying(_ transform: N3AffineTransform) -> N3BezierPath! {
        changedCopy { $0.applyAffineTransform(transform) }
    }

    @objc(bezierPathByAppendingBezierPath:connectPaths:)
    func appending(_ bezierPath: N3BezierPath!, connectPaths: Bool) -> N3BezierPath! {
        changedCopy { $0.append(bezierPath, connectPaths: connectPaths) }
    }

    @objc(bezierPathByAddingEndpointsAtIntersectionsWithPlane:)
    func addingEndpointsAtIntersections(with plane: N3Plane) -> N3BezierPath! {
        changedCopy { $0.addEndpointsAtIntersections(with: plane) }
    }

    @objc(bezierPathByProjectingToPlane:)
    func projecting(to plane: N3Plane) -> N3BezierPath! {
        changedCopy { $0.project(to: plane) }
    }

    /// Nil unless the path is one subpath, and when it is too short (the
    /// former code crashed then).
    @objc(outlineBezierPathAtDistance:initialNormal:spacing:)
    func outlineBezierPath(atDistance distance: CGFloat, initialNormal: N3Vector, spacing: CGFloat) -> N3BezierPath! {
        guard core.subpathCount == 1 else { return nil }
        return core.outline(distance: distance, spacing: spacing, initialNormal: initialNormal.vector3).map(N3BezierPath.make)
    }

    @objc(outlineBezierPathAtDistance:projectionNormal:spacing:)
    func outlineBezierPath(atDistance distance: CGFloat, projectionNormal: N3Vector, spacing: CGFloat) -> N3BezierPath! {
        guard core.subpathCount == 1 else { return nil }
        return core.outline(distance: distance, spacing: spacing, projectionNormal: projectionNormal.vector3).map(N3BezierPath.make)
    }

    // MARK: - Reading the path

    func elementCount() -> Int {
        core.count
    }

    func length() -> CGFloat {
        lengthLock.withLock {
            if measuredLength == 0.0 {
                measuredLength = core.length
            }
            return measuredLength
        }
    }

    @objc(lengthThroughElementAtIndex:)
    func lengthThroughElement(at element: Int) -> CGFloat {
        core.length(throughSegmentAt: element, flatness: N3BezierDefaultFlatness)
    }

    @objc(N3BezierCore)
    func n3BezierCore() -> N3BezierCoreRef! {
        autoreleasedHandle(core.copy())
    }

    func dictionaryRepresentation() -> [AnyHashable: Any]! {
        n3DictionaryRepresentation(core) as? [AnyHashable: Any]
    }

    func vectorAtStart() -> N3Vector {
        N3Vector(core.vectorAtStart)
    }

    func vectorAtEnd() -> N3Vector {
        N3Vector(core.vectorAtEnd)
    }

    func tangentAtStart() -> N3Vector {
        N3Vector(core.tangentAtStart)
    }

    func tangentAtEnd() -> N3Vector {
        N3Vector(core.tangentAtEnd)
    }

    @objc(normalAtEndWithInitialNormal:)
    func normalAtEnd(withInitialNormal initialNormal: N3Vector) -> N3Vector {
        guard core.subpathCount == 1 else { return N3VectorZero }
        return N3Vector(core.normalAtEnd(initialNormal: initialNormal.vector3))
    }

    func isPlanar() -> Bool {
        core.plane != nil
    }

    func leastSquaresPlane() -> N3Plane {
        N3Plane(core.leastSquaresPlane)
    }

    @objc(topBoundingPlaneForNormal:)
    func topBoundingPlane(forNormal normal: N3Vector) -> N3Plane {
        N3Plane(core.boundingPlanes(normal: normal.vector3).top)
    }

    @objc(bottomBoundingPlaneForNormal:)
    func bottomBoundingPlane(forNormal normal: N3Vector) -> N3Plane {
        N3Plane(core.boundingPlanes(normal: normal.vector3).bottom)
    }

    @objc(elementAtIndex:)
    func element(at index: Int) -> N3BezierPathElement {
        element(at: index, control1: nil, control2: nil, endpoint: nil)
    }

    /// Unlike NSBezierPath, control2 is not the endpoint. A moveTo, a line or a
    /// close only sets endpoint. At the element count, a moveTo that sets nothing.
    @objc(elementAtIndex:control1:control2:endpoint:)
    func element(at index: Int, control1: N3VectorPointer!, control2: N3VectorPointer!, endpoint: N3VectorPointer!) -> N3BezierPathElement {
        guard index != core.count else {
            assertionFailure("no element at the element count")
            return N3BezierPathElement(N3MoveToBezierPathElement.rawValue)
        }
        let segment = core[index]
        endpoint?.pointee = N3Vector(segment.endpoint)
        switch segment.kind {
        case .moveTo:
            return N3BezierPathElement(N3MoveToBezierPathElement.rawValue)
        case .lineTo:
            return N3BezierPathElement(N3LineToBezierPathElement.rawValue)
        case .curveTo:
            control1?.pointee = N3Vector(segment.control1)
            control2?.pointee = N3Vector(segment.control2)
            return N3BezierPathElement(N3CurveToBezierPathElement.rawValue)
        case .close:
            return N3BezierPathElement(N3CloseBezierPathElement.rawValue)
        }
    }

    /// The first point of a sampling that starts at relativePosition, or the end.
    @objc(vectorAtRelativePosition:)
    func vector(atRelativePosition relativePosition: CGFloat) -> N3Vector {
        let samples = core.samples(spacing: 0, startingDistance: relativePosition * length(), initialNormal: .zero, count: 1,
                                   vectors: true, tangents: false, normals: false)
        return samples.count > 0 ? N3Vector(samples.vectors[0]) : vectorAtEnd()
    }

    @objc(tangentAtRelativePosition:)
    func tangent(atRelativePosition relativePosition: CGFloat) -> N3Vector {
        let samples = core.samples(spacing: 0, startingDistance: relativePosition * length(), initialNormal: .zero, count: 1,
                                   vectors: false, tangents: true, normals: false)
        return samples.count > 0 ? N3Vector(samples.tangents[0]) : tangentAtEnd()
    }

    @objc(normalAtRelativePosition:initialNormal:)
    func normal(atRelativePosition relativePosition: CGFloat, initialNormal: N3Vector) -> N3Vector {
        guard core.subpathCount == 1 else { return N3VectorZero }
        let samples = core.samples(spacing: 0, startingDistance: relativePosition * length(), initialNormal: initialNormal.vector3,
                                   count: 1, vectors: false, tangents: false, normals: true)
        return samples.count > 0 ? N3Vector(samples.normals[0]) : normalAtEnd(withInitialNormal: initialNormal)
    }

    @objc(relativePositionClosestToVector:)
    func relativePositionClosest(to vector: N3Vector) -> CGFloat {
        core.closestPoint(to: vector.vector3)?.relativePosition ?? 0.0
    }

    @objc(relativePositionClosestToLine:)
    func relativePositionClosest(to line: N3Line) -> CGFloat {
        core.closestPoint(to: line.line3)?.relativePosition ?? 0.0
    }

    @objc(relativePositionClosestToLine:closestVector:)
    func relativePositionClosest(to line: N3Line, closestVector vectorPointer: N3VectorPointer!) -> CGFloat {
        guard let closest = core.closestPoint(to: line.line3) else { return 0.0 }
        vectorPointer?.pointee = N3Vector(closest.vector)
        return closest.relativePosition
    }

    @objc(bezierPathByCollapsingZ)
    func collapsingZ() -> N3BezierPath! {
        var collapse = N3AffineTransformIdentity
        collapse.m33 = 0.0
        return changedCopy { $0.applyAffineTransform(collapse) }
    }

    @objc(bezierPathByReversing)
    func reversing() -> N3BezierPath! {
        N3MutableBezierPath.make(core.reversed())
    }

    @objc(intersectionsWithPlane:)
    func intersections(with plane: N3Plane) -> [Any]! {
        intersections(with: plane, relativePositions: nil)
    }

    /// NSValues of the N3Vectors where the path (curves subdivided and
    /// flattened) crosses the plane, and NSNumbers of their relative positions.
    @objc(intersectionsWithPlane:relativePositions:)
    func intersections(with plane: N3Plane, relativePositions returnedRelativePositions: AutoreleasingUnsafeMutablePointer<NSArray?>!) -> [Any]! {
        let crossings = core.intersections(with: plane.plane3, count: Int.max)
        returnedRelativePositions?.pointee = crossings.map { NSNumber(value: $0.relativePosition) } as NSArray
        return crossings.map { NSValue.makeValue(n3Vector: N3Vector($0.vector)) }
    }

    func subPaths() -> [Any]! {
        core.subpaths().map(N3BezierPath.make)
    }

    @objc(bezierPathByClippingFromRelativePosition:toRelativePosition:)
    func clipping(fromRelativePosition startRelativePosition: CGFloat, toRelativePosition endRelativePosition: CGFloat) -> N3BezierPath! {
        N3MutableBezierPath.make(core.clipped(from: startRelativePosition, to: endRelativePosition))
    }

    @objc(signedAreaUsingNormal:)
    func signedArea(usingNormal normal: N3Vector) -> CGFloat {
        core.signedArea(normal: normal.vector3)
    }
}

@objc @implementation extension N3MutableBezierPath {

    // Swift gives the subclass its own -initWithCoder: (the inherited
    // required initializer), and NSKeyedArchiver then refuses it unless the
    // subclass says again that it supports secure coding.
    public override class var supportsSecureCoding: Bool {
        true
    }

    /// A change of the path: the measured length goes, fast enumeration
    /// sees the change.
    final func changing(_ change: () -> Void) {
        change()
        lengthLock.withLock { measuredLength = 0.0 }
        mutations.pointee &+= 1
    }

    @objc(moveToVector:)
    func move(to vector: N3Vector) {
        changing { core.add(.moveTo, endpoint: vector.vector3) }
    }

    @objc(lineToVector:)
    func line(to vector: N3Vector) {
        changing { core.add(.lineTo, endpoint: vector.vector3) }
    }

    @objc(curveToVector:controlVector1:controlVector2:)
    func curve(to vector: N3Vector, controlVector1: N3Vector, controlVector2: N3Vector) {
        changing { core.add(.curveTo, control1: controlVector1.vector3, control2: controlVector2.vector3, endpoint: vector.vector3) }
    }

    func close() {
        changing { core.add(.close, endpoint: .zero) }
    }

    func flatten(_ flatness: CGFloat) {
        changing { core.flatten(flatness) }
    }

    func subdivide(_ maxSegmentLength: CGFloat) {
        changing { core.subdivide(maxSegmentLength) }
    }

    @objc(applyAffineTransform:)
    func applyAffineTransform(_ transform: N3AffineTransform) {
        changing { core.apply(transform) }
    }

    @objc(projectToPlane:)
    func project(to plane: N3Plane) {
        changing { core = core.projected(onto: plane.plane3) }
    }

    @objc(appendBezierPath:connectPaths:)
    func append(_ bezierPath: N3BezierPath!, connectPaths: Bool) {
        changing { core.append(bezierPath.core.copy(), connectingPaths: connectPaths) }
    }

    @objc(addEndpointsAtIntersectionsWithPlane:)
    func addEndpointsAtIntersections(with plane: N3Plane) {
        changing { core = core.addingEndpoints(atIntersectionsWith: plane.plane3) }
    }

    /// Moves the element; the measured length stays, as it always did.
    @objc(setVectorsForElementAtIndex:control1:control2:endpoint:)
    func setVectorsForElementAt(_ index: Int, control1: N3Vector, control2: N3Vector, endpoint: N3Vector) {
        core.setVectors(at: index, control1: control1.vector3, control2: control2.vector3, endpoint: endpoint.vector3)
    }
}

extension N3BezierPath {
    /// A path of this class whose segments are core's.
    @nonobjc static func make(_ core: BezierCore) -> Self {
        let path = (self as NSObject.Type).init() as! Self
        path.core = core
        return path
    }
}
