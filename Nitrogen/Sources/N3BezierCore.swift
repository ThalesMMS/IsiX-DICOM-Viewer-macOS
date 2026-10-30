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

// The functions of N3BezierCore.h, with their C names (@_cdecl and @implementation:
// Swift checks each one against the header's declaration and leaves it out of
// the generated header). The path is IsiXGeometry's BezierCore; a
// N3BezierCoreRef is a BezierCore retained for the caller (N3BezierCoreRetain
// and N3BezierCoreRelease retain and release it), and the iterators and random
// accessors are small classes holding one.

/// The BezierCore of a handle.
func bezierCore(_ handle: OpaquePointer?) -> BezierCore {
    Unmanaged<BezierCore>.fromOpaque(UnsafeRawPointer(handle!)).takeUnretainedValue()
}

/// A handle that owns one reference to core, for a C caller of a Create function.
func retainedHandle(_ core: BezierCore) -> OpaquePointer {
    OpaquePointer(Unmanaged.passRetained(core).toOpaque())
}

/// A handle to core that the current autorelease pool keeps.
func autoreleasedHandle(_ core: BezierCore) -> OpaquePointer {
    OpaquePointer(Unmanaged.passRetained(core).autorelease().toOpaque())
}

extension N3BezierCoreSegmentType {
    init(_ kind: BezierSegmentKind) {
        self.init(kind.rawValue)
    }

    /// The segment kind; nil for N3EndBezierCoreSegmentType.
    var kind: BezierSegmentKind? {
        BezierSegmentKind(rawValue: rawValue)
    }
}

/// Writes a segment's vectors where the C caller asked for them.
func writeSegment(_ segment: BezierSegment, _ control1: UnsafeMutablePointer<N3Vector>?, _ control2: UnsafeMutablePointer<N3Vector>?,
           _ endpoint: UnsafeMutablePointer<N3Vector>?) {
    control1?.pointee = N3Vector(segment.control1)
    control2?.pointee = N3Vector(segment.control2)
    endpoint?.pointee = N3Vector(segment.endpoint)
}

@_cdecl("N3BezierCoreCreate") @implementation
func N3BezierCoreCreate() -> OpaquePointer? {
    retainedHandle(BezierCore())
}

@_cdecl("N3BezierCoreCreateMutable") @implementation
func N3BezierCoreCreateMutable() -> OpaquePointer? {
    retainedHandle(BezierCore())
}

@_cdecl("N3BezierCoreRetain") @implementation
func N3BezierCoreRetain(_ handle: OpaquePointer?) -> UnsafeMutableRawPointer? {
    guard let handle else { return nil }
    _ = Unmanaged<BezierCore>.fromOpaque(UnsafeRawPointer(handle)).retain()
    return UnsafeMutableRawPointer(handle)
}

@_cdecl("N3BezierCoreRelease") @implementation
func N3BezierCoreRelease(_ handle: OpaquePointer?) {
    guard let handle else { return }
    Unmanaged<BezierCore>.fromOpaque(UnsafeRawPointer(handle)).release()
}

@_cdecl("N3BezierCoreEqualToBezierCore") @implementation
func N3BezierCoreEqualToBezierCore(_ handle1: OpaquePointer?, _ handle2: OpaquePointer?) -> Bool {
    handle1 == handle2 || bezierCore(handle1).isEqual(to: bezierCore(handle2))
}

@_cdecl("N3BezierCoreCopyDescription") @implementation
func N3BezierCoreCopyDescription(_ handle: OpaquePointer?) -> Unmanaged<CFString>? {
    Unmanaged.passRetained(n3DictionaryRepresentation(bezierCore(handle)).description as CFString)
}

@_cdecl("N3BezierCoreHasCurve") @implementation
func N3BezierCoreHasCurve(_ handle: OpaquePointer?) -> Bool {
    bezierCore(handle).hasCurve
}

@_cdecl("N3BezierCoreCreateCopy") @implementation
func N3BezierCoreCreateCopy(_ handle: OpaquePointer?) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).copy())
}

@_cdecl("N3BezierCoreCreateMutableCopy") @implementation
func N3BezierCoreCreateMutableCopy(_ handle: OpaquePointer?) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).copy())
}

// MARK: - Dictionary representation

private func vectorDictionary(_ vector: Vector3) -> Any {
    N3VectorCreateDictionaryRepresentation(N3Vector(vector))!.takeRetainedValue() as NSDictionary
}

/// {segments: [{segmentType: moveTo | lineTo | curveTo | close, endpoint,
/// and for a curve control1 and control2}]}, each vector a dictionary of
/// N3VectorCreateDictionaryRepresentation.
func n3DictionaryRepresentation(_ core: BezierCore) -> NSDictionary {
    let segments = core.segments.map { segment -> NSDictionary in
        switch segment.kind {
        case .moveTo:
            return n3Dictionary(["segmentType": "moveTo", "endpoint": vectorDictionary(segment.endpoint)])
        case .lineTo:
            return n3Dictionary(["segmentType": "lineTo", "endpoint": vectorDictionary(segment.endpoint)])
        case .close:
            return n3Dictionary(["segmentType": "close", "endpoint": vectorDictionary(segment.endpoint)])
        case .curveTo:
            return n3Dictionary(["segmentType": "curveTo", "control1": vectorDictionary(segment.control1),
                                 "control2": vectorDictionary(segment.control2), "endpoint": vectorDictionary(segment.endpoint)])
        }
    }
    return n3Dictionary(["segments": NSArray(array: segments)])
}

/// The path of a dictionary representation; nil without segments. A vector
/// that does not read is zero.
func makeBezierCore(dictionaryRepresentation dictionary: NSDictionary?) -> BezierCore? {
    guard let segments = dictionary?.object(forKey: "segments") as? NSArray else { return nil }
    let core = BezierCore()
    func vector(_ segment: NSDictionary, _ key: String) -> Vector3 {
        var vector = N3VectorZero
        if let value = segment.object(forKey: key) {
            // As the C did, the value is read as a dictionary whatever it is.
            _ = N3VectorMakeWithDictionaryRepresentation(unsafeBitCast(value as AnyObject, to: CFDictionary.self), &vector)
        }
        return vector.vector3
    }
    for case let segment as NSDictionary in segments {
        switch segment.object(forKey: "segmentType") as? String {
        case "moveTo":
            core.add(.moveTo, endpoint: vector(segment, "endpoint"))
        case "lineTo":
            core.add(.lineTo, endpoint: vector(segment, "endpoint"))
        case "close":
            core.add(.close, endpoint: vector(segment, "endpoint"))
        case "curveTo":
            core.add(.curveTo, control1: vector(segment, "control1"), control2: vector(segment, "control2"),
                     endpoint: vector(segment, "endpoint"))
        default:
            assertionFailure("unknown segment type")
        }
    }
    return core
}

@_cdecl("N3BezierCoreCreateDictionaryRepresentation") @implementation
func N3BezierCoreCreateDictionaryRepresentation(_ handle: OpaquePointer?) -> Unmanaged<CFDictionary>? {
    Unmanaged.passRetained(n3DictionaryRepresentation(bezierCore(handle)) as CFDictionary)
}

private func dictionary(_ dictionary: CFDictionary?) -> NSDictionary? {
    dictionary.map { $0 as NSDictionary }
}

@_cdecl("N3BezierCoreCreateWithDictionaryRepresentation") @implementation
func N3BezierCoreCreateWithDictionaryRepresentation(_ dict: CFDictionary?) -> OpaquePointer? {
    makeBezierCore(dictionaryRepresentation: dictionary(dict)).map(retainedHandle)
}

@_cdecl("N3BezierCoreCreateMutableWithDictionaryRepresentation") @implementation
func N3BezierCoreCreateMutableWithDictionaryRepresentation(_ dict: CFDictionary?) -> OpaquePointer? {
    makeBezierCore(dictionaryRepresentation: dictionary(dict)).map(retainedHandle)
}

// MARK: - Changing a path

@_cdecl("N3BezierCoreAddSegment") @implementation
func N3BezierCoreAddSegment(_ handle: OpaquePointer?, _ segmentType: N3BezierCoreSegmentType, _ control1: N3Vector,
                            _ control2: N3Vector, _ endpoint: N3Vector) {
    guard let kind = segmentType.kind else {
        assertionFailure("N3EndBezierCoreSegmentType is not a segment")
        return
    }
    bezierCore(handle).add(kind, control1: control1.vector3, control2: control2.vector3, endpoint: endpoint.vector3)
}

@_cdecl("N3BezierCoreSetVectorsForSegementAtIndex") @implementation
func N3BezierCoreSetVectorsForSegementAtIndex(_ handle: OpaquePointer?, _ index: CFIndex, _ control1: N3Vector,
                                              _ control2: N3Vector, _ endpoint: N3Vector) {
    bezierCore(handle).setVectors(at: index, control1: control1.vector3, control2: control2.vector3, endpoint: endpoint.vector3)
}

@_cdecl("N3BezierCoreFlatten") @implementation
func N3BezierCoreFlatten(_ handle: OpaquePointer?, _ flatness: CGFloat) {
    bezierCore(handle).flatten(flatness)
}

@_cdecl("N3BezierCoreSubdivide") @implementation
func N3BezierCoreSubdivide(_ handle: OpaquePointer?, _ maxSegmentLength: CGFloat) {
    bezierCore(handle).subdivide(maxSegmentLength)
}

@_cdecl("N3BezierCoreApplyTransform") @implementation
func N3BezierCoreApplyTransform(_ handle: OpaquePointer?, _ transform: N3AffineTransform) {
    bezierCore(handle).apply(transform)
}

@_cdecl("N3BezierCoreAppendBezierCore") @implementation
func N3BezierCoreAppendBezierCore(_ handle: OpaquePointer?, _ appended: OpaquePointer?, _ connectPaths: Bool) {
    bezierCore(handle).append(bezierCore(appended), connectingPaths: connectPaths)
}

@_cdecl("N3BezierCoreCreateFlattenedCopy") @implementation
func N3BezierCoreCreateFlattenedCopy(_ handle: OpaquePointer?, _ flatness: CGFloat) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).flattenedCopy(flatness))
}

@_cdecl("N3BezierCoreCreateFlattenedMutableCopy") @implementation
func N3BezierCoreCreateFlattenedMutableCopy(_ handle: OpaquePointer?, _ flatness: CGFloat) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).flattenedCopy(flatness))
}

@_cdecl("N3BezierCoreCreateSubdividedCopy") @implementation
func N3BezierCoreCreateSubdividedCopy(_ handle: OpaquePointer?, _ maxSegmentLength: CGFloat) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).subdividedCopy(maxSegmentLength))
}

@_cdecl("N3BezierCoreCreateSubdividedMutableCopy") @implementation
func N3BezierCoreCreateSubdividedMutableCopy(_ handle: OpaquePointer?, _ maxSegmentLength: CGFloat) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).subdividedCopy(maxSegmentLength))
}

@_cdecl("N3BezierCoreCreateTransformedCopy") @implementation
func N3BezierCoreCreateTransformedCopy(_ handle: OpaquePointer?, _ transform: N3AffineTransform) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).transformedCopy(transform))
}

@_cdecl("N3BezierCoreCreateTransformedMutableCopy") @implementation
func N3BezierCoreCreateTransformedMutableCopy(_ handle: OpaquePointer?, _ transform: N3AffineTransform) -> OpaquePointer? {
    retainedHandle(bezierCore(handle).transformedCopy(transform))
}

// MARK: - Reading a path

@_cdecl("N3BezierCoreSegmentCount") @implementation
func N3BezierCoreSegmentCount(_ handle: OpaquePointer?) -> CFIndex {
    bezierCore(handle).count
}

@_cdecl("N3BezierCoreSubpathCount") @implementation
func N3BezierCoreSubpathCount(_ handle: OpaquePointer?) -> CFIndex {
    bezierCore(handle).subpathCount
}

@_cdecl("N3BezierCoreLength") @implementation
func N3BezierCoreLength(_ handle: OpaquePointer?) -> CGFloat {
    bezierCore(handle).length
}

@_cdecl("N3BezierCoreGetSegmentAtIndex") @implementation
func N3BezierCoreGetSegmentAtIndex(_ handle: OpaquePointer?, _ index: CFIndex, _ control1: UnsafeMutablePointer<N3Vector>?,
                                   _ control2: UnsafeMutablePointer<N3Vector>?, _ endpoint: UnsafeMutablePointer<N3Vector>?) -> N3BezierCoreSegmentType {
    let core = bezierCore(handle)
    assert(index < core.count && index >= 0)
    let segment = core[index]
    writeSegment(segment, control1, control2, endpoint)
    return N3BezierCoreSegmentType(segment.kind)
}

@_cdecl("N3BezierCoreCheckDebug") @implementation
func N3BezierCoreCheckDebug(_ handle: OpaquePointer?) {
    bezierCore(handle).assertInvariants()
}

// MARK: - Iterator

/// Reads a path's segments in order.
final class BezierCoreIteratorState {
    let core: BezierCore
    var index = 0

    init(_ core: BezierCore) {
        self.core = core
    }
}

private func iterator(_ handle: OpaquePointer?) -> BezierCoreIteratorState {
    Unmanaged<BezierCoreIteratorState>.fromOpaque(UnsafeRawPointer(handle!)).takeUnretainedValue()
}

@_cdecl("N3BezierCoreIteratorCreateWithBezierCore") @implementation
func N3BezierCoreIteratorCreateWithBezierCore(_ handle: OpaquePointer?) -> OpaquePointer? {
    OpaquePointer(Unmanaged.passRetained(BezierCoreIteratorState(bezierCore(handle))).toOpaque())
}

@_cdecl("N3BezierCoreIteratorRetain") @implementation
func N3BezierCoreIteratorRetain(_ handle: OpaquePointer?) -> OpaquePointer? {
    guard let handle else { return nil }
    _ = Unmanaged<BezierCoreIteratorState>.fromOpaque(UnsafeRawPointer(handle)).retain()
    return handle
}

@_cdecl("N3BezierCoreIteratorRelease") @implementation
func N3BezierCoreIteratorRelease(_ handle: OpaquePointer?) {
    guard let handle else { return }
    Unmanaged<BezierCoreIteratorState>.fromOpaque(UnsafeRawPointer(handle)).release()
}

/// The next segment; at the end, N3EndBezierCoreSegmentType and zero vectors.
@_cdecl("N3BezierCoreIteratorGetNextSegment") @implementation
func N3BezierCoreIteratorGetNextSegment(_ handle: OpaquePointer?, _ control1: UnsafeMutablePointer<N3Vector>?,
                                        _ control2: UnsafeMutablePointer<N3Vector>?, _ endpoint: UnsafeMutablePointer<N3Vector>?) -> N3BezierCoreSegmentType {
    let iterator = iterator(handle)
    guard iterator.index < iterator.core.count else {
        control1?.pointee = N3VectorZero
        control2?.pointee = N3VectorZero
        endpoint?.pointee = N3VectorZero
        return N3EndBezierCoreSegmentType
    }
    let segment = iterator.core[iterator.index]
    iterator.index += 1
    writeSegment(segment, control1, control2, endpoint)
    return N3BezierCoreSegmentType(segment.kind)
}

@_cdecl("N3BezierCoreIteratorIsAtEnd") @implementation
func N3BezierCoreIteratorIsAtEnd(_ handle: OpaquePointer?) -> Bool {
    let iterator = iterator(handle)
    return iterator.index >= iterator.core.count
}

@_cdecl("N3BezierCoreIteratorIndex") @implementation
func N3BezierCoreIteratorIndex(_ handle: OpaquePointer?) -> CFIndex {
    iterator(handle).index
}

@_cdecl("N3BezierCoreIteratorSetIndex") @implementation
func N3BezierCoreIteratorSetIndex(_ handle: OpaquePointer?, _ index: CFIndex) {
    let iterator = iterator(handle)
    assert(index < iterator.core.count)
    iterator.index = index
}

@_cdecl("N3BezierCoreIteratorSegmentCount") @implementation
func N3BezierCoreIteratorSegmentCount(_ handle: OpaquePointer?) -> CFIndex {
    iterator(handle).core.count
}

// MARK: - Random accessor

/// Reads, and when made for a mutable path moves, the segments by index.
final class BezierCoreRandomAccessorState {
    let core: BezierCore
    let isMutable: Bool

    init(_ core: BezierCore, isMutable: Bool) {
        self.core = core
        self.isMutable = isMutable
    }
}

private func randomAccessor(_ handle: OpaquePointer?) -> BezierCoreRandomAccessorState {
    Unmanaged<BezierCoreRandomAccessorState>.fromOpaque(UnsafeRawPointer(handle!)).takeUnretainedValue()
}

@_cdecl("N3BezierCoreRandomAccessorCreateWithBezierCore") @implementation
func N3BezierCoreRandomAccessorCreateWithBezierCore(_ handle: OpaquePointer?) -> OpaquePointer? {
    OpaquePointer(Unmanaged.passRetained(BezierCoreRandomAccessorState(bezierCore(handle), isMutable: false)).toOpaque())
}

@_cdecl("N3BezierCoreRandomAccessorCreateWithMutableBezierCore") @implementation
func N3BezierCoreRandomAccessorCreateWithMutableBezierCore(_ handle: OpaquePointer?) -> OpaquePointer? {
    OpaquePointer(Unmanaged.passRetained(BezierCoreRandomAccessorState(bezierCore(handle), isMutable: true)).toOpaque())
}

@_cdecl("N3BezierCoreRandomAccessorRetain") @implementation
func N3BezierCoreRandomAccessorRetain(_ handle: OpaquePointer?) -> OpaquePointer? {
    guard let handle else { return nil }
    _ = Unmanaged<BezierCoreRandomAccessorState>.fromOpaque(UnsafeRawPointer(handle)).retain()
    return handle
}

@_cdecl("N3BezierCoreRandomAccessorRelease") @implementation
func N3BezierCoreRandomAccessorRelease(_ handle: OpaquePointer?) {
    guard let handle else { return }
    Unmanaged<BezierCoreRandomAccessorState>.fromOpaque(UnsafeRawPointer(handle)).release()
}

/// The segment at index; at the segment count, N3EndBezierCoreSegmentType
/// with the vectors left as they were.
@_cdecl("N3BezierCoreRandomAccessorGetSegmentAtIndex") @implementation
func N3BezierCoreRandomAccessorGetSegmentAtIndex(_ handle: OpaquePointer?, _ index: CFIndex, _ control1: UnsafeMutablePointer<N3Vector>?,
                                                 _ control2: UnsafeMutablePointer<N3Vector>?, _ endpoint: UnsafeMutablePointer<N3Vector>?) -> N3BezierCoreSegmentType {
    let core = randomAccessor(handle).core
    if index == core.count {
        return N3EndBezierCoreSegmentType
    }
    assert(index <= core.count)
    let segment = core[index]
    writeSegment(segment, control1, control2, endpoint)
    return N3BezierCoreSegmentType(segment.kind)
}

@_cdecl("N3BezierCoreRandomAccessorSetVectorsForSegementAtIndex") @implementation
func N3BezierCoreRandomAccessorSetVectorsForSegementAtIndex(_ handle: OpaquePointer?, _ index: CFIndex, _ control1: N3Vector,
                                                            _ control2: N3Vector, _ endpoint: N3Vector) {
    let accessor = randomAccessor(handle)
    assert(accessor.isMutable)
    accessor.core.setVectors(at: index, control1: control1.vector3, control2: control2.vector3, endpoint: endpoint.vector3)
}

@_cdecl("N3BezierCoreRandomAccessorSegmentCount") @implementation
func N3BezierCoreRandomAccessorSegmentCount(_ handle: OpaquePointer?) -> CFIndex {
    randomAccessor(handle).core.count
}
