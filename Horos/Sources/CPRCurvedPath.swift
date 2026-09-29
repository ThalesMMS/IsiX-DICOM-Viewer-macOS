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

import Cocoa

private let _CPRCurvedPathNodeSpacingThreshold: CGFloat = 1e-10

// CPRCurvedPathControlTokenNone = -1 is in CPRCurvedPath+CAPI.m.
private let CPRCurvedPathControlTokenTransverseSection: CPRCurvedPathControlToken = 1
private let CPRCurvedPathControlTokenTransverseSpacing: CPRCurvedPathControlToken = 2

private func _isElementControlToken(_ token: CPRCurvedPathControlToken) -> Bool {
    return (token & 3) == 0
}

private func _elementForControlToken(_ token: CPRCurvedPathControlToken) -> Int {
    if _isElementControlToken(token) {
        return Int(token >> 2)
    } else {
        return -1
    }
}

private func _controlTokenForElement(_ element: Int) -> CPRCurvedPathControlToken {
    // (int32_t)(element << 2), as an unsigned token.
    return CPRCurvedPathControlToken(truncatingIfNeeded: element &<< 2)
}

/// A double converted to NSInteger as arm64 does it (fcvtzs): NaN gives 0,
/// values past either end give that end.
private func integerTruncating(_ value: CGFloat) -> Int {
    if value.isNaN {
        return 0
    }
    if value >= 9223372036854775808.0 {
        return Int.max
    }
    if value < -9223372036854775808.0 {
        return Int.min
    }
    return Int(value)
}

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
}

// CPRCurved path is all the data related to a CPR. All the transitory UI stuff is in CPRDisplayInfo

/// All points in the CurvedPath live in patient space. In order to avoid
/// confusion about what coordinate space things are in, all methods take points
/// in an arbitrary coordinate space and take the transform from that space to
/// the patient space.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors, the
/// archived keys and <Horos/CPRCurvedPath.h> are those of the former class.
@objc(CPRCurvedPath)
public final class CPRCurvedPath: NSObject, NSCopying, NSSecureCoding {
    /// Always an N3MutableBezierPath, as the header types it: -initWithCoder:
    /// keeps a mutable copy of the N3BezierPath that -encodeWithCoder: wrote,
    /// which the former class held as it was (#773).
    private var _bezierPath: N3MutableBezierPath?
    private var _nodes = NSMutableArray()
    private var _nodeRelativePositions: NSArray? // NSNumbers with a cache of the nodes' relative positions;

    private var _baseDirection = N3Vector()
    private var _angle: CGFloat = 0
    private var _thickness: CGFloat = 0
    private var _transverseSectionSpacing: CGFloat = 0
    private var _transverseSectionPosition: CGFloat = 0

    @objc(controlTokenIsNode:)
    public static func controlTokenIsNode(_ token: CPRCurvedPathControlToken) -> Bool {
        return _isElementControlToken(token)
    }

    @objc(nodeIndexForToken:)
    public static func nodeIndexForToken(_ token: CPRCurvedPathControlToken) -> Int {
        return _elementForControlToken(token)
    }

    @objc(controlTokenForNodeIndex:)
    public static func controlTokenForNodeIndex(_ nodeIndex: Int) -> CPRCurvedPathControlToken {
        return _controlTokenForElement(nodeIndex)
    }

    @objc public override init() {
        _bezierPath = N3MutableBezierPath()
        _nodes = NSMutableArray()
        _nodeRelativePositions = NSMutableArray()
        _transverseSectionPosition = 0.5
        _transverseSectionSpacing = 2
        super.init()
    }

    /// A path file comes from anywhere (the CPR's Load Path), so it is read
    /// with secure coding: the path, its N3BezierPath, and property-list
    /// values under every other key.
    public static var supportsSecureCoding: Bool { true }

    /// The classes of the values archived under every key but "bezierPath".
    private static let archivedValueClasses: [AnyClass] = [NSArray.self, NSDictionary.self, NSNumber.self, NSString.self]

    @objc(initWithCoder:)
    public required init?(coder decoder: NSCoder) {
        super.init()

        let nodes = NSMutableArray()
        var initialNormal = N3Vector()
        let nodesAsDictionaries = decoder.decodeObject(of: Self.archivedValueClasses, forKey: "nodesAsDictionaries") as? NSArray
        for nodeDictionary in nodesAsDictionaries ?? [] {
            var node = N3VectorZero
            N3VectorMakeWithDictionaryRepresentation((nodeDictionary as? NSDictionary).map { $0 as CFDictionary }, &node)
            nodes.add(NSValue(n3Vector: node)!)
        }

        _bezierPath = (decoder.decodeObject(of: [N3BezierPath.self, N3MutableBezierPath.self], forKey: "bezierPath") as? N3BezierPath)?.mutableCopy() as? N3MutableBezierPath
        _nodes = nodes
        _nodeRelativePositions = decoder.decodeObject(of: Self.archivedValueClasses, forKey: "nodeRelativePositions") as? NSArray

        if decoder.containsValue(forKey: "initialNormalDictionary") { // older versions saved this out
            initialNormal = N3VectorZero
            N3VectorMakeWithDictionaryRepresentation(decoder.decodeObject(of: Self.archivedValueClasses, forKey: "initialNormalDictionary").flatMap { $0 as? NSDictionary }.map { $0 as CFDictionary }, &initialNormal)
            setInitialNormal(initialNormal)
        }

        if decoder.containsValue(forKey: "baseDirectionDictionary") {
            // Into the base direction itself: the former class read it into
            // initialNormal, and every decoded path had a zero base direction,
            // hence a zero initial normal (#773).
            var baseDirection = N3VectorZero
            N3VectorMakeWithDictionaryRepresentation(decoder.decodeObject(of: Self.archivedValueClasses, forKey: "baseDirectionDictionary").flatMap { $0 as? NSDictionary }.map { $0 as CFDictionary }, &baseDirection)
            _baseDirection = baseDirection
        }

        if decoder.containsValue(forKey: "angle") {
            _angle = CGFloat(decoder.decodeDouble(forKey: "angle"))
        }

        _thickness = CGFloat(decoder.decodeDouble(forKey: "thickness"))
        _transverseSectionSpacing = CGFloat(decoder.decodeDouble(forKey: "transverseSectionSpacing"))
        _transverseSectionPosition = CGFloat(decoder.decodeDouble(forKey: "transverseSectionPosition"))
    }

    private init(curvedPath: CPRCurvedPath) {
        _bezierPath = curvedPath._bezierPath?.mutableCopy() as? N3MutableBezierPath
        _nodes = curvedPath._nodes.mutableCopy() as! NSMutableArray
        _nodeRelativePositions = curvedPath._nodeRelativePositions?.mutableCopy() as? NSArray
        _baseDirection = curvedPath._baseDirection
        _angle = curvedPath._angle
        _thickness = curvedPath._thickness
        _transverseSectionSpacing = curvedPath._transverseSectionSpacing
        _transverseSectionPosition = curvedPath._transverseSectionPosition
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        return CPRCurvedPath(curvedPath: self)
    }

    /// Readonly in the header. The setter, private to the former class, resets
    /// the nodes' relative positions when the path changes.
    @objc public internal(set) dynamic var bezierPath: N3MutableBezierPath? {
        get {
            return _bezierPath
        }
        set {
            if _bezierPath?.isEqual(to: newValue) ?? false == false {
                _bezierPath = newValue
                _resetNodeRelativePositions()
            }
        }
    }

    /// The private nodeRelativePositions property of the former class.
    @objc var nodeRelativePositions: NSArray? {
        get { return _nodeRelativePositions }
        set { _nodeRelativePositions = newValue }
    }

    public func encode(with encoder: NSCoder) {
        let nodeVectorsAsDictionaries = NSMutableArray()
        for case let value as NSValue in _nodes {
            nodeVectorsAsDictionaries.add(N3VectorCreateDictionaryRepresentation(value.n3VectorValue()).takeRetainedValue())
        }

        encoder.encode(N3BezierPath(bezierPath: _bezierPath), forKey: "bezierPath")
        encoder.encode(nodeVectorsAsDictionaries, forKey: "nodesAsDictionaries")
        encoder.encode(_nodeRelativePositions, forKey: "nodeRelativePositions")

        encoder.encode(N3VectorCreateDictionaryRepresentation(_baseDirection).takeRetainedValue(), forKey: "baseDirectionDictionary")
        encoder.encode(Double(_angle), forKey: "angle")
        encoder.encode(Double(_thickness), forKey: "thickness")
        encoder.encode(Double(_transverseSectionSpacing), forKey: "transverseSectionSpacing")
        encoder.encode(Double(_transverseSectionPosition), forKey: "transverseSectionPosition")
    }

    @objc public dynamic var thickness: CGFloat {
        get { return _thickness }
        set { _thickness = newValue }
    }

    @objc public dynamic var baseDirection: N3Vector { // a base direction from which to define things such as the initial normal
        get { return _baseDirection }
        set { _baseDirection = newValue }
    }

    @objc public dynamic var angle: CGFloat {
        get { return _angle }
        set { _angle = newValue }
    }

    @objc public dynamic var initialNormal: N3Vector {
        get {
            let tangentAtStart = _bezierPath?.tangentAtStart() ?? N3Vector()
            let baseNormal = N3VectorNormalize(N3VectorCrossProduct(_baseDirection, tangentAtStart))
            let initialNormal = N3VectorApplyTransform(baseNormal, N3AffineTransformMakeRotationAroundVector(_angle, tangentAtStart))

            return initialNormal
        }
        set {
            setInitialNormal(newValue)
        }
    }

    private func setInitialNormal(_ initialNormal: N3Vector) {
        // set the angle if it is possible, set it to 0 if not;
        if N3VectorIsZero(_baseDirection) {
            _baseDirection = N3VectorANormalVector(_bezierPath?.tangentAtStart() ?? N3Vector())
        }

        let tangentAtStart = _bezierPath?.tangentAtStart() ?? N3Vector()
        let baseNormal = N3VectorNormalize(N3VectorCrossProduct(_baseDirection, tangentAtStart))
        _angle = N3VectorAngleBetweenVectorsAroundVector(baseNormal, initialNormal, tangentAtStart)
    }

    @objc public dynamic var transverseSectionSpacing: CGFloat { // in mm
        get { return _transverseSectionSpacing }
        set { _transverseSectionSpacing = newValue }
    }

    @objc public dynamic var transverseSectionPosition: CGFloat { // as a relative position [0, 1] pass -1 if you don't want the trasvers section to appear
        get { return _transverseSectionPosition }
        set { _transverseSectionPosition = newValue }
    }

    /// The node array itself, as the former synthesized getter returned it.
    @objc public var nodes: NSArray { // N3Vectors stored in NSValues
        return _nodes
    }

    /// The path rebuilt from the nodes, as each edit of the former class did.
    private func _pathFromNodes() -> N3MutableBezierPath? {
        if _nodes.count >= 2 {
            return N3MutableBezierPath(nodeArray: _nodes as? [Any], style: N3BezierNodeOpenEndsStyle)
        } else {
            return N3MutableBezierPath()
        }
    }

    /// Adds the point to z = 0 in the arbitrary coordinate space.
    @objc(addNode:transform:)
    public func addNode(_ point: NSPoint, transform: N3AffineTransform) {
        var node = N3VectorMake(point.x, point.y, 0)
        node = N3VectorApplyTransform(node, transform)

        if !node.x.isFinite || !node.y.isFinite || !node.z.isFinite {
            NSLog("Warning, CPRCurvedPath refusing a non-finite node")
            return
        }

        if _nodes.count > 0 && N3VectorDistance((_nodes.lastObject as! NSValue).n3VectorValue(), node) < _CPRCurvedPathNodeSpacingThreshold {
            NSLog("Warning, CPRCurvedPath trying to add a node too close to the last node")
            return // don't bother adding the point if it is already the last point
        }

        _nodes.add(NSValue(n3Vector: node)!)

        self.bezierPath = _pathFromNodes()
    }

    /// Adds the point to z = 0 in the arbitrary coordinate space to a given index.
    @objc(insertPatientNode:atIndex:)
    public func insertPatientNode(_ node: N3Vector, at index: UInt) {
        // assert(index >= 0) of the former code: always true for an NSUInteger.
        if !node.x.isFinite || !node.y.isFinite || !node.z.isFinite {
            NSLog("Warning, CPRCurvedPath refusing a non-finite node")
            return
        }
        if _nodes.count > 0 && N3VectorDistance((_nodes.lastObject as! NSValue).n3VectorValue(), node) < _CPRCurvedPathNodeSpacingThreshold {
            NSLog("Warning, CPRCurvedPath trying to add a node too close to the last node")
            return // don't bother adding the point if it is already the last point
        }

        if index < UInt(_nodes.count) {
            _nodes.insert(NSValue(n3Vector: node)!, at: Int(index))
        } else {
            _nodes.add(NSValue(n3Vector: node)!)
        }

        _nodesDidChange()
    }

    @objc(addPatientNode:)
    public func addPatientNode(_ node: N3Vector) {
        if !node.x.isFinite || !node.y.isFinite || !node.z.isFinite {
            NSLog("Warning, CPRCurvedPath refusing a non-finite node")
            return
        }
        if _nodes.count > 0 && N3VectorDistance((_nodes.lastObject as! NSValue).n3VectorValue(), node) < _CPRCurvedPathNodeSpacingThreshold {
            NSLog("Warning, CPRCurvedPath trying to add a node too close to the last node")
            return // don't bother adding the point if it is already the last point
        }

        _nodes.add(NSValue(n3Vector: node)!)

        self.bezierPath = _pathFromNodes()
    }

    /// Returns the node index of the inserted node.
    @objc(insertNodeAtRelativePosition:)
    public func insertNode(atRelativePosition relativePosition: CGFloat) -> Int {
        if _nodes.count < 2 {
            NSLog("Warning, CPRCurvedPath trying to insert a node into a path that on has %d nodes", Int32(truncatingIfNeeded: _nodes.count))
            return -1
        }

        var insertIndex = 0
        while insertIndex < _nodes.count {
            if relativePositionForNode(at: UInt(insertIndex)) > relativePosition {
                break
            }
            insertIndex += 1
        }

        if insertIndex == _nodes.count {
            insertIndex = _nodes.count - 1
        }

        let vectorAtRelativePosition = _bezierPath?.vector(atRelativePosition: relativePosition) ?? N3Vector()

        if insertIndex > 0 && N3VectorDistance((_nodes.object(at: insertIndex - 1) as! NSValue).n3VectorValue(), vectorAtRelativePosition) < _CPRCurvedPathNodeSpacingThreshold {
            NSLog("Warning, CPRCurvedPath trying to insert a node too close the the previous node")
            return -1
        }
        if insertIndex <= _nodes.count - 1 && N3VectorDistance((_nodes.object(at: insertIndex) as! NSValue).n3VectorValue(), vectorAtRelativePosition) < _CPRCurvedPathNodeSpacingThreshold {
            NSLog("Warning, CPRCurvedPath trying to insert a node too close the the next node")
            return -1
        }

        _nodes.insert(NSValue(n3Vector: vectorAtRelativePosition)!, at: insertIndex)

        self.bezierPath = N3MutableBezierPath(nodeArray: _nodes as? [Any], style: N3BezierNodeOpenEndsStyle)
        return insertIndex
    }

    @objc(removeNodeAtIndex:)
    public func removeNode(at index: Int) {
        debugAssert(index >= 0)
        debugAssert(UInt(bitPattern: index) < UInt(_nodes.count))
        _nodes.removeObject(at: index)

        _nodesDidChange()
    }

    /// Nonzero inside withPathRebuiltOnce(_:).
    private var _deferredPathRebuilds = 0
    private var _pathNeedsRebuild = false

    /// The path rebuilt from the nodes after removeNode(at:) or
    /// insertPatientNode(_:at:), or, inside withPathRebuiltOnce(_:), once at
    /// its end.
    private func _nodesDidChange() {
        if _deferredPathRebuilds > 0 {
            _pathNeedsRebuild = true
        } else {
            self.bezierPath = _pathFromNodes()
        }
    }

    /// Runs `edits`, in which removeNode(at:) and insertPatientNode(_:at:)
    /// change the nodes only, then rebuilds the path from the nodes once: the
    /// path and the nodes' relative positions are those the last edit would
    /// have given. Each rebuild measures the path up to every node, so the
    /// Path Assistant's simplification slider, which removes or restores a
    /// node at a time, rebuilt a path of 200 nodes up to 200 times (#925).
    /// The path is not rebuilt inside `edits`: only the nodes may be read.
    /// An exception `edits` raises goes on once the path is rebuilt.
    func withPathRebuiltOnce(_ edits: () -> Void) {
        _deferredPathRebuilds += 1
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform { edits() }
        } catch {
            raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        _deferredPathRebuilds -= 1
        if _deferredPathRebuilds == 0 && _pathNeedsRebuild {
            _pathNeedsRebuild = false
            self.bezierPath = _pathFromNodes()
        }
        raised?.raise()
    }

    @objc public func clearPath() {
        _bezierPath = N3MutableBezierPath()
        _nodes = NSMutableArray()
        _nodeRelativePositions = NSMutableArray()
        _transverseSectionPosition = 0.5
        _transverseSectionSpacing = 2
    }

    /// Resets Z by default.
    @objc(moveControlToken:toPoint:transform:)
    public func moveControlToken(_ token: CPRCurvedPathControlToken, to point: NSPoint, transform: N3AffineTransform) {
        var node = N3VectorMake(point.x, point.y, 0)
        node = N3VectorApplyTransform(node, transform)

        if _isElementControlToken(token) {
            // An NSUInteger in the former code: element - 1 wraps at 0.
            let element = UInt(bitPattern: _elementForControlToken(token))
            let count = UInt(_nodes.count)
            if count > element &- 1 && N3VectorDistance((_nodes.object(at: Int(bitPattern: element &- 1)) as! NSValue).n3VectorValue(), node) < _CPRCurvedPathNodeSpacingThreshold {
                NSLog("Warning, CPRCurvedPath trying to move a node too close the the previous node")
                return //refuse to move a node right on top the the previous node
            }
            if count > element &+ 1 && N3VectorDistance((_nodes.object(at: Int(bitPattern: element &+ 1)) as! NSValue).n3VectorValue(), node) < _CPRCurvedPathNodeSpacingThreshold {
                NSLog("Warning, CPRCurvedPath trying to move a node too close the the next node]")
                return //refuse to move a node right on top the the next node
            }

            _nodes.replaceObject(at: Int(bitPattern: element), with: NSValue(n3Vector: node)!)

            self.bezierPath = _pathFromNodes()
        } else if token == CPRCurvedPathControlTokenTransverseSection {
            _transverseSectionPosition = relativePosition(for: point, transform: transform)
        } else if token == CPRCurvedPathControlTokenTransverseSpacing {
            let relativePosition = relativePosition(for: point, transform: transform)
            // ABS() of Foundation: -0.0 stays -0.0.
            let difference = _transverseSectionPosition - relativePosition
            _transverseSectionSpacing = (difference < 0 ? -difference : difference) * (_bezierPath?.length() ?? 0)
        }
    }

    /// For this exceptional method, the vector is given in patient space.
    @objc(moveNodeAtIndex:toVector:)
    public func moveNode(at index: Int, to vector: N3Vector) {
        // hacky implementation, but why not....
        moveControlToken(CPRCurvedPath.controlTokenForNodeIndex(index), to: NSPointFromN3Vector(vector), transform: N3AffineTransformMakeTranslation(0, 0, vector.z))
    }

    @objc(controlTokenNearPoint:transform:)
    public func controlTokenNear(_ point: NSPoint, transform: N3AffineTransform) -> CPRCurvedPathControlToken {
        var i = 0
        while i < _nodes.count {
            var nodeVector = (_nodes.object(at: i) as! NSValue).n3VectorValue()
            nodeVector = N3VectorApplyTransform(nodeVector, N3AffineTransformInvert(transform))
            nodeVector.z = 0.0

            if N3VectorDistance(N3VectorMakeFromNSPoint(point), nodeVector) <= 5.0 {
                return _controlTokenForElement(i)
            }
            i += 1
        }
        return CPRCurvedPathControlToken(bitPattern: CPRCurvedPathControlTokenNone)
    }

    @objc(relativePositionForPoint:transform:)
    public func relativePosition(for point: NSPoint, transform: N3AffineTransform) -> CGFloat {
        let clickRay = N3LineApplyTransform(N3LineMake(N3VectorMakeFromNSPoint(point), N3VectorMake(0, 0, 1)), transform)
        return _bezierPath?.relativePositionClosest(to: clickRay) ?? 0
    }

    /// Returns the distance in the coordinate space of point (screen coordinates).
    @objc(relativePositionForPoint:transform:distanceToPoint:)
    public func relativePosition(for point: NSPoint, transform: N3AffineTransform, distanceToPoint distance: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
        if N3AffineTransformIsAffine(transform) == false {
            return 0
        }

        let clickRay = N3LineApplyTransform(N3LineMake(N3VectorMakeFromNSPoint(point), N3VectorMake(0, 0, 1)), transform)
        let inverseTransform = N3AffineTransformInvert(transform)

        var closestVector = N3Vector()
        let relativePosition = _bezierPath?.relativePositionClosest(to: clickRay, closestVector: &closestVector) ?? 0
        var closestLineVector = N3LinePointClosestToVector(clickRay, closestVector)

        closestVector = N3VectorApplyTransform(closestVector, inverseTransform)
        closestVector.z = 0.0
        closestLineVector = N3VectorApplyTransform(closestLineVector, inverseTransform)
        closestLineVector.z = 0.0

        distance?.pointee = N3VectorDistance(closestVector, closestLineVector)

        return relativePosition
    }

    @objc(relativePositionForControlToken:)
    public func relativePosition(forControlToken token: CPRCurvedPathControlToken) -> CGFloat {
        if _isElementControlToken(token) {
            let element = UInt(bitPattern: _elementForControlToken(token))
            return relativePositionForNode(at: element)
        } else if token == CPRCurvedPathControlTokenTransverseSection {
            return _transverseSectionPosition
        } else if token == CPRCurvedPathControlTokenTransverseSpacing {
            return 0.0
        }
        return 0.0
    }

    @objc(relativePositionForNodeAtIndex:)
    public func relativePositionForNode(at nodeIndex: UInt) -> CGFloat {
        guard let nodeRelativePositions = _nodeRelativePositions else {
            return 0
        }
        return CGFloat((nodeRelativePositions.object(at: Int(bitPattern: nodeIndex)) as AnyObject).doubleValue ?? 0)
    }

    /// mmWide is the how wide in patient coordinates the transverse slice should be.
    @objc(transverseSliceRequestsForSpacing:outputWidth:outputHeight:mmWide:)
    public func transverseSliceRequests(forSpacing spacing: CGFloat, outputWidth width: UInt, outputHeight height: UInt, mmWide: CGFloat) -> NSArray {
        let requests = NSMutableArray()

        let flattenedPath = _bezierPath?.mutableCopy() as? N3MutableBezierPath
        flattenedPath?.subdivide(N3BezierDefaultSubdivideSegmentLength)
        flattenedPath?.flatten(N3BezierDefaultFlatness)

        let curveLength = flattenedPath?.length() ?? 0
        var requestCount = integerTruncating(curveLength / spacing)
        requestCount &+= 1

        if requestCount < 2 {
            return requests
        }

        let vectorBytes = Int(bitPattern: UInt(bitPattern: requestCount) &* UInt(MemoryLayout<N3Vector>.size))
        let normals = malloc(vectorBytes)!.assumingMemoryBound(to: N3Vector.self)
        memset(normals, 0, vectorBytes)

        let vectors = malloc(vectorBytes)!.assumingMemoryBound(to: N3Vector.self)
        memset(vectors, 0, vectorBytes)

        let tangents = malloc(vectorBytes)!.assumingMemoryBound(to: N3Vector.self)
        memset(tangents, 0, vectorBytes)

        // curveLength - (requestCount-1) * spacing: clang fuses the multiply and
        // the subtraction into one rounding, as addingProduct does.
        var startingDistance = Float(curveLength.addingProduct(-CGFloat(requestCount &- 1), spacing))
        startingDistance /= 2

        requestCount = N3BezierCoreGetVectorInfo(flattenedPath?.n3BezierCore(), spacing, CGFloat(startingDistance), self.initialNormal, vectors, tangents, normals, requestCount)

        let mmPerPixel = mmWide / CGFloat(width)

        // Unchecked pointer access: the arrays hold requestCount vectors.
        for i in 0..<max(requestCount, 0) {
            let cross = N3VectorNormalize(N3VectorCrossProduct(tangents[i], normals[i]))

            let request = CPRObliqueSliceGeneratorRequest(center: vectors[i], pixelsWide: width, pixelsHigh: height,
                                                          xBasis: N3VectorScalarMultiply(cross, mmPerPixel),
                                                          yBasis: N3VectorScalarMultiply(normals[i], mmPerPixel))

            requests.add(request)
        }

        free(normals)
        free(vectors)
        free(tangents)

        return requests
    }

    /// Bad name, but if this is true, we will let folks make measurements on the generated plane.
    @objc public func isPlaneMeasurable() -> Bool {
        if self.bezierPath?.isPlanar() ?? false {
            let plane = self.bezierPath?.leastSquaresPlane() ?? N3Plane()
            // ABS() of Foundation.
            let dot = N3VectorDotProduct(N3VectorNormalize(self.initialNormal), N3VectorNormalize(plane.normal))
            if (dot < 0 ? -dot : dot) > 0.9999 /*~cos(1deg)*/ {
                return true
            }
        }
        return false
    }

    @objc public var leftTransverseSectionPosition: CGFloat {
        // MAX() of Foundation: (a < b) ? b : a.
        let position = _transverseSectionPosition - _transverseSectionSpacing / (_bezierPath?.length() ?? 0)
        return position < 0.0 ? 0.0 : position
    }

    @objc public var rightTransverseSectionPosition: CGFloat {
        // MIN() of Foundation: (a < b) ? a : b.
        let position = _transverseSectionPosition + _transverseSectionSpacing / (_bezierPath?.length() ?? 0)
        return position < 1.0 ? position : 1.0
    }

    /// Whether the transverse sections of both paths are the same planes:
    /// the same curve, base direction and angle (the initial normal), and the
    /// same section position and spacing. The thickness and the nodes are not
    /// compared; the nodes lie on the curve. A transverse view holds a copy of
    /// the path and compares it with the one it is given (#854).
    func hasSameTransverseSections(as other: CPRCurvedPath) -> Bool {
        if other === self {
            return true
        }
        let sameCurve: Bool
        if let bezierPath = _bezierPath, let otherBezierPath = other._bezierPath {
            sameCurve = bezierPath.isEqual(to: otherBezierPath)
        } else {
            sameCurve = _bezierPath == nil && other._bezierPath == nil
        }
        return sameCurve &&
            N3VectorEqualToVector(_baseDirection, other._baseDirection) &&
            _angle == other._angle &&
            _transverseSectionSpacing == other._transverseSectionSpacing &&
            _transverseSectionPosition == other._transverseSectionPosition
    }

    private func _resetNodeRelativePositions() {
        let curveLength = _bezierPath?.length() ?? 0

        let nodeRelativePositions = NSMutableArray()

        if curveLength > 0 {
            #if !DEBUG
            // The former Release build (-ffast-math) divided by multiplying with
            // the reciprocal, hoisted out of the loop.
            let reciprocal = 1.0 / curveLength
            #endif
            for i in 0..<_nodes.count {
                // MIN() of Foundation: (a < b) ? a : b.
                #if DEBUG
                let relativePosition = (_bezierPath?.lengthThroughElement(at: i) ?? 0) / curveLength
                #else
                let relativePosition = (_bezierPath?.lengthThroughElement(at: i) ?? 0) * reciprocal
                #endif
                nodeRelativePositions.add(NSNumber(value: Double(relativePosition < 1.0 ? relativePosition : 1.0)))
            }
        } else {
            for _ in 0..<_nodes.count {
                nodeRelativePositions.add(NSNumber(value: 0.0))
            }
        }
        self.nodeRelativePositions = nodeRelativePositions
    }

    @objc public func stretchedProjectionNormal() -> N3Vector {
        let curveDirection = N3VectorSubtract(_bezierPath?.vectorAtEnd() ?? N3Vector(), _bezierPath?.vectorAtStart() ?? N3Vector())
        let baseNormal = N3VectorNormalize(N3VectorCrossProduct(_baseDirection, curveDirection))
        return N3VectorApplyTransform(baseNormal, N3AffineTransformMakeRotationAroundVector(_angle, curveDirection))
    }
}
