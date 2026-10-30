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

// The functions of N3BezierCoreAdditions.h, with their C names (@_cdecl
// and @implementation: Swift checks each one against the header's declaration and
// leaves it out of the generated header), over IsiXGeometry's BezierCore.

private func vectors(_ pointer: UnsafeMutablePointer<N3Vector>?, _ count: CFIndex) -> [Vector3] {
    (0..<max(count, 0)).map { pointer![$0].vector3 }
}

private func copy(_ vectors: [Vector3], to pointer: UnsafeMutablePointer<N3Vector>?) {
    guard let pointer else { return }
    for (i, vector) in vectors.enumerated() {
        pointer[i] = N3Vector(vector)
    }
}

private func style(_ style: N3BezierNodeStyle) -> BezierNodeStyle {
    BezierNodeStyle(rawValue: style.rawValue) ?? .openEnds
}

@_cdecl("N3BezierCoreCreateCurveWithNodes") @implementation
func N3BezierCoreCreateCurveWithNodes(_ nodes: N3VectorArray?, _ numVectors: CFIndex, _ nodeStyle: N3BezierNodeStyle) -> OpaquePointer? {
    retainedHandle(BezierCore.curve(through: vectors(nodes, numVectors), style: style(nodeStyle)))
}

@_cdecl("N3BezierCoreCreateMutableCurveWithNodes") @implementation
func N3BezierCoreCreateMutableCurveWithNodes(_ nodes: N3VectorArray?, _ numVectors: CFIndex, _ nodeStyle: N3BezierNodeStyle) -> OpaquePointer? {
    retainedHandle(BezierCore.curve(through: vectors(nodes, numVectors), style: style(nodeStyle)))
}

@_cdecl("N3BezierCoreVectorAtStart") @implementation
func N3BezierCoreVectorAtStart(_ handle: OpaquePointer?) -> N3Vector {
    N3Vector(bezierCore(handle).vectorAtStart)
}

@_cdecl("N3BezierCoreVectorAtEnd") @implementation
func N3BezierCoreVectorAtEnd(_ handle: OpaquePointer?) -> N3Vector {
    N3Vector(bezierCore(handle).vectorAtEnd)
}

@_cdecl("N3BezierCoreTangentAtStart") @implementation
func N3BezierCoreTangentAtStart(_ handle: OpaquePointer?) -> N3Vector {
    N3Vector(bezierCore(handle).tangentAtStart)
}

@_cdecl("N3BezierCoreTangentAtEnd") @implementation
func N3BezierCoreTangentAtEnd(_ handle: OpaquePointer?) -> N3Vector {
    N3Vector(bezierCore(handle).tangentAtEnd)
}

@_cdecl("N3BezierCoreNormalAtEndWithInitialNormal") @implementation
func N3BezierCoreNormalAtEndWithInitialNormal(_ handle: OpaquePointer?, _ initialNormal: N3Vector) -> N3Vector {
    N3Vector(bezierCore(handle).normalAtEnd(initialNormal: initialNormal.vector3))
}

/// A path of fewer than two segments gives 0 and leaves the pointers alone.
private func write(_ closest: BezierClosestPoint?, _ closestVector: UnsafeMutablePointer<N3Vector>?,
                   _ distance: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
    guard let closest else { return 0.0 }
    distance?.pointee = closest.distance
    closestVector?.pointee = N3Vector(closest.vector)
    return closest.relativePosition
}

@_cdecl("N3BezierCoreRelativePositionClosestToVector") @implementation
func N3BezierCoreRelativePositionClosestToVector(_ handle: OpaquePointer?, _ vector: N3Vector, _ closestVector: UnsafeMutablePointer<N3Vector>?,
                                                 _ distance: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
    write(bezierCore(handle).closestPoint(to: vector.vector3), closestVector, distance)
}

@_cdecl("N3BezierCoreRelativePositionClosestToLine") @implementation
func N3BezierCoreRelativePositionClosestToLine(_ handle: OpaquePointer?, _ line: N3Line, _ closestVector: UnsafeMutablePointer<N3Vector>?,
                                               _ distance: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
    write(bezierCore(handle).closestPoint(to: line.line3), closestVector, distance)
}

@_cdecl("N3BezierCoreGetVectorInfo") @implementation
func N3BezierCoreGetVectorInfo(_ handle: OpaquePointer?, _ spacing: CGFloat, _ startingDistance: CGFloat, _ initialNormal: N3Vector,
                               _ vectors: UnsafeMutablePointer<N3Vector>?, _ tangents: UnsafeMutablePointer<N3Vector>?,
                               _ normals: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) -> CFIndex {
    let samples = bezierCore(handle).samples(spacing: spacing, startingDistance: startingDistance, initialNormal: initialNormal.vector3,
                                             count: numVectors, vectors: vectors != nil, tangents: tangents != nil, normals: normals != nil)
    copy(samples.vectors, to: vectors)
    copy(samples.tangents, to: tangents)
    copy(samples.normals, to: normals)
    return samples.count
}

@_cdecl("N3BezierCoreGetProjectedVectorInfo") @implementation
func N3BezierCoreGetProjectedVectorInfo(_ handle: OpaquePointer?, _ spacing: CGFloat, _ startingDistance: CGFloat, _ projectionDirection: N3Vector,
                                        _ vectors: UnsafeMutablePointer<N3Vector>?, _ tangents: UnsafeMutablePointer<N3Vector>?,
                                        _ normals: UnsafeMutablePointer<N3Vector>?, _ relativePositions: UnsafeMutablePointer<CGFloat>?,
                                        _ numVectors: CFIndex) -> CFIndex {
    let samples = bezierCore(handle).projectedSamples(spacing: spacing, startingDistance: startingDistance,
                                                      projectionDirection: projectionDirection.vector3, count: numVectors,
                                                      vectors: vectors != nil, tangents: tangents != nil, normals: normals != nil,
                                                      relativePositions: relativePositions != nil)
    copy(samples.vectors, to: vectors)
    copy(samples.tangents, to: tangents)
    copy(samples.normals, to: normals)
    if let relativePositions {
        for (i, position) in samples.relativePositions.enumerated() {
            relativePositions[i] = position
        }
    }
    return samples.count
}

@_cdecl("N3BezierCoreCreateOutline") @implementation
func N3BezierCoreCreateOutline(_ handle: OpaquePointer?, _ distance: CGFloat, _ spacing: CGFloat, _ initialNormal: N3Vector) -> OpaquePointer? {
    bezierCore(handle).outline(distance: distance, spacing: spacing, initialNormal: initialNormal.vector3).map(retainedHandle)
}

@_cdecl("N3BezierCoreCreateMutableOutline") @implementation
func N3BezierCoreCreateMutableOutline(_ handle: OpaquePointer?, _ distance: CGFloat, _ spacing: CGFloat, _ initialNormal: N3Vector) -> OpaquePointer? {
    bezierCore(handle).outline(distance: distance, spacing: spacing, initialNormal: initialNormal.vector3).map(retainedHandle)
}

@_cdecl("N3BezierCoreCreateOutlineWithNormal") @implementation
func N3BezierCoreCreateOutlineWithNormal(_ handle: OpaquePointer?, _ distance: CGFloat, _ spacing: CGFloat, _ projectionNormal: N3Vector) -> OpaquePointer? {
    bezierCore(handle).outline(distance: distance, spacing: spacing, projectionNormal: projectionNormal.vector3).map(retainedHandle)
}

@_cdecl("N3BezierCoreCreateMutableOutlineWithNormal") @implementation
func N3BezierCoreCreateMutableOutlineWithNormal(_ handle: OpaquePointer?, _ distance: CGFloat, _ spacing: CGFloat, _ projectionNormal: N3Vector) -> OpaquePointer? {
    bezierCore(handle).outline(distance: distance, spacing: spacing, projectionNormal: projectionNormal.vector3).map(retainedHandle)
}

@_cdecl("N3BezierCoreLengthToSegmentAtIndex") @implementation
func N3BezierCoreLengthToSegmentAtIndex(_ handle: OpaquePointer?, _ index: CFIndex, _ flatness: CGFloat) -> CGFloat {
    bezierCore(handle).length(throughSegmentAt: index, flatness: flatness)
}

@_cdecl("N3BezierCoreSegmentLengths") @implementation
func N3BezierCoreSegmentLengths(_ handle: OpaquePointer?, _ lengths: UnsafeMutablePointer<CGFloat>?, _ numLengths: CFIndex, _ flatness: CGFloat) -> CFIndex {
    let segmentLengths = bezierCore(handle).segmentLengths(count: numLengths, flatness: flatness)
    for (i, length) in segmentLengths.enumerated() {
        lengths![i] = length
    }
    return segmentLengths.count
}

@_cdecl("N3BezierCoreCountIntersectionsWithPlane") @implementation
func N3BezierCoreCountIntersectionsWithPlane(_ handle: OpaquePointer?, _ plane: N3Plane) -> CFIndex {
    bezierCore(handle).intersectionCount(with: plane.plane3)
}

@_cdecl("N3BezierCoreIntersectionsWithPlane") @implementation
func N3BezierCoreIntersectionsWithPlane(_ handle: OpaquePointer?, _ plane: N3Plane, _ intersections: UnsafeMutablePointer<N3Vector>?,
                                        _ relativePositions: UnsafeMutablePointer<CGFloat>?, _ numVectors: CFIndex) -> CFIndex {
    let found = bezierCore(handle).intersections(with: plane.plane3, count: numVectors)
    for (i, intersection) in found.enumerated() {
        intersections?[i] = N3Vector(intersection.vector)
        relativePositions?[i] = intersection.relativePosition
    }
    return found.count
}

@_cdecl("N3BezierCoreCreateMutableCopyWithEndpointsAtPlaneIntersections") @implementation
func N3BezierCoreCreateMutableCopyWithEndpointsAtPlaneIntersections(_ handle: OpaquePointer?, _ plane: N3Plane) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).addingEndpoints(atIntersectionsWith: plane.plane3))
}

@_cdecl("N3BezierCoreCreateCopyProjectedToPlane") @implementation
func N3BezierCoreCreateCopyProjectedToPlane(_ handle: OpaquePointer?, _ plane: N3Plane) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).projected(onto: plane.plane3))
}

@_cdecl("N3BezierCoreCreateMutableCopyProjectedToPlane") @implementation
func N3BezierCoreCreateMutableCopyProjectedToPlane(_ handle: OpaquePointer?, _ plane: N3Plane) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).projected(onto: plane.plane3))
}

@_cdecl("N3BezierCoreLeastSquaresPlane") @implementation
func N3BezierCoreLeastSquaresPlane(_ handle: OpaquePointer?) -> N3Plane {
    N3Plane(bezierCore(handle).leastSquaresPlane)
}

@_cdecl("N3BezierCoreMeanDistanceToPlane") @implementation
func N3BezierCoreMeanDistanceToPlane(_ handle: OpaquePointer?, _ plane: N3Plane) -> CGFloat {
    bezierCore(handle).meanDistance(to: plane.plane3)
}

@_cdecl("N3BezierCoreIsPlanar") @implementation
func N3BezierCoreIsPlanar(_ handle: OpaquePointer?, _ bezierCorePlane: UnsafeMutablePointer<N3Plane>?) -> Bool {
    guard let plane = bezierCore(handle).plane else { return false }
    bezierCorePlane?.pointee = N3Plane(plane)
    return true
}

@_cdecl("N3BezierCoreGetBoundingPlanesForNormal") @implementation
func N3BezierCoreGetBoundingPlanesForNormal(_ handle: OpaquePointer?, _ normal: N3Vector, _ topPlane: UnsafeMutablePointer<N3Plane>?,
                                            _ bottomPlane: UnsafeMutablePointer<N3Plane>?) -> Bool {
    let planes = bezierCore(handle).boundingPlanes(normal: normal.vector3)
    topPlane?.pointee = N3Plane(planes.top)
    bottomPlane?.pointee = N3Plane(planes.bottom)
    return true
}

@_cdecl("N3BezierCoreCreateCopyByReversing") @implementation
func N3BezierCoreCreateCopyByReversing(_ handle: OpaquePointer?) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).reversed())
}

@_cdecl("N3BezierCoreCreateMutableCopyByReversing") @implementation
func N3BezierCoreCreateMutableCopyByReversing(_ handle: OpaquePointer?) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).reversed())
}

/// A CFArray of N3BezierCoreRefs, which it retains.
@_cdecl("N3BezierCoreCopySubpaths") @implementation
func N3BezierCoreCopySubpaths(_ handle: OpaquePointer?) -> Unmanaged<CFArray>? {
    var callBacks = CFArrayCallBacks(
        version: 0,
        retain: { _, value in UnsafeRawPointer(N3BezierCoreRetain(OpaquePointer(value))) },
        release: { _, value in N3BezierCoreRelease(OpaquePointer(value)) },
        copyDescription: { value in N3BezierCoreCopyDescription(OpaquePointer(value)) },
        equal: { value1, value2 in DarwinBoolean(N3BezierCoreEqualToBezierCore(OpaquePointer(value1), OpaquePointer(value2))) })
    let subpaths = CFArrayCreateMutable(nil, 0, &callBacks)!
    for subpath in bezierCore(handle).subpaths() {
        let subpathHandle = retainedHandle(subpath)
        CFArrayAppendValue(subpaths, UnsafeRawPointer(subpathHandle))
        N3BezierCoreRelease(subpathHandle)
    }
    return Unmanaged.passRetained(subpaths)
}

@_cdecl("N3BezierCoreCreateCopyByClipping") @implementation
func N3BezierCoreCreateCopyByClipping(_ handle: OpaquePointer?, _ startRelativePosition: CGFloat, _ endRelativePosition: CGFloat) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).clipped(from: startRelativePosition, to: endRelativePosition))
}

@_cdecl("N3BezierCoreCreateMutableCopyByClipping") @implementation
func N3BezierCoreCreateMutableCopyByClipping(_ handle: OpaquePointer?, _ startRelativePosition: CGFloat, _ endRelativePosition: CGFloat) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).clipped(from: startRelativePosition, to: endRelativePosition))
}

@_cdecl("N3BezierCoreSignedAreaUsingNormal") @implementation
func N3BezierCoreSignedAreaUsingNormal(_ handle: OpaquePointer?, _ normal: N3Vector) -> CGFloat {
    bezierCore(handle).signedArea(normal: normal.vector3)
}
