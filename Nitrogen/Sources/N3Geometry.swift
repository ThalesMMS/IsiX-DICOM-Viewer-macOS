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
import QuartzCore

// The functions of N3Geometry.h, with their C names (@_cdecl and @implementation: Swift
// checks each one against the header's declaration and leaves it out of the
// generated header), for the Objective-C, the Objective-C++ and the Swift that
// call them. The geometry is IsiXGeometry's, on simd vectors; this file
// converts N3Vector, N3Line and N3Plane to its types and back.
//
// Except for the functions of one vector operation (make, compare, add,
// subtract, scale, dot, cross, length, distance, normalize, project, invert,
// interpolate, transform), which are written here on the three fields: the
// CPR fills call them for every pixel, and in a Debug build, whose Swift is not
// optimized, a call through simd costs about ten times the Objective-C one.
// They fuse the products as IsiXGeometry does (see Geometry there), so both
// give the bits of the former C.

extension N3Vector {
    init(_ vector: Vector3) {
        self.init(x: vector.x, y: vector.y, z: vector.z)
    }

    var vector3: Vector3 {
        Vector3(x, y, z)
    }
}

extension N3Line {
    init(_ line: Line3) {
        self.init(point: N3Vector(line.point), vector: N3Vector(line.direction))
    }

    var line3: Line3 {
        Line3(point: point.vector3, direction: vector.vector3)
    }
}

extension N3Plane {
    init(_ plane: Plane3) {
        self.init(point: N3Vector(plane.point), normal: N3Vector(plane.normal))
    }

    var plane3: Plane3 {
        Plane3(point: point.vector3, normal: normal.vector3)
    }
}

// MARK: - One vector operation, on the fields

private func dot(_ a: N3Vector, _ b: N3Vector) -> CGFloat {
    (a.y * b.y).addingProduct(a.x, b.x).addingProduct(a.z, b.z)
}

private func cross(_ a: N3Vector, _ b: N3Vector) -> N3Vector {
    N3Vector(x: (-(a.z * b.y)).addingProduct(a.y, b.z),
             y: (-(a.x * b.z)).addingProduct(a.z, b.x),
             z: (-(a.y * b.x)).addingProduct(a.x, b.y))
}

private func scale(_ v: N3Vector, _ scalar: CGFloat) -> N3Vector {
    N3Vector(x: v.x * scalar, y: v.y * scalar, z: v.z * scalar)
}

private func subtract(_ a: N3Vector, _ b: N3Vector) -> N3Vector {
    N3Vector(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
}

private func add(_ a: N3Vector, _ b: N3Vector) -> N3Vector {
    N3Vector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
}

private func length(_ v: N3Vector) -> CGFloat {
    dot(v, v).squareRoot()
}

private func normalize(_ v: N3Vector) -> N3Vector {
    let length = length(v)
    return length == 0.0 ? N3VectorZero : scale(v, 1.0 / length)
}

/// The direction transformed without the translation.
private func applyToDirection(_ v: N3Vector, _ t: N3AffineTransform) -> N3Vector {
    assert(t.isAffine)
    return N3Vector(x: (v.y * t.m21).addingProduct(v.x, t.m11).addingProduct(v.z, t.m31),
                    y: (v.y * t.m22).addingProduct(v.x, t.m12).addingProduct(v.z, t.m32),
                    z: (v.y * t.m23).addingProduct(v.x, t.m13).addingProduct(v.z, t.m33))
}

@_cdecl("N3VectorMake") @implementation
func N3VectorMake(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> N3Vector {
    N3Vector(x: x, y: y, z: z)
}

@_cdecl("N3VectorEqualToVector") @implementation
func N3VectorEqualToVector(_ vector1: N3Vector, _ vector2: N3Vector) -> Bool {
    vector1.x == vector2.x && vector1.y == vector2.y && vector1.z == vector2.z
}

@_cdecl("N3VectorIsZero") @implementation
func N3VectorIsZero(_ vector: N3Vector) -> Bool {
    vector.x == 0.0 && vector.y == 0.0 && vector.z == 0.0
}

@_cdecl("N3VectorAdd") @implementation
func N3VectorAdd(_ vector1: N3Vector, _ vector2: N3Vector) -> N3Vector {
    add(vector1, vector2)
}

@_cdecl("N3VectorSubtract") @implementation
func N3VectorSubtract(_ vector1: N3Vector, _ vector2: N3Vector) -> N3Vector {
    subtract(vector1, vector2)
}

@_cdecl("N3VectorScalarMultiply") @implementation
func N3VectorScalarMultiply(_ vector: N3Vector, _ scalar: CGFloat) -> N3Vector {
    scale(vector, scalar)
}

@_cdecl("N3VectorDistance") @implementation
func N3VectorDistance(_ vector1: N3Vector, _ vector2: N3Vector) -> CGFloat {
    length(subtract(vector1, vector2))
}

@_cdecl("N3VectorDotProduct") @implementation
func N3VectorDotProduct(_ vector1: N3Vector, _ vector2: N3Vector) -> CGFloat {
    dot(vector1, vector2)
}

@_cdecl("N3VectorCrossProduct") @implementation
func N3VectorCrossProduct(_ vector1: N3Vector, _ vector2: N3Vector) -> N3Vector {
    cross(vector1, vector2)
}

@_cdecl("N3VectorLerp") @implementation
func N3VectorLerp(_ vector1: N3Vector, _ vector2: N3Vector, _ t: CGFloat) -> N3Vector {
    add(scale(vector1, 1.0 - t), scale(vector2, t))
}

@_cdecl("N3VectorLength") @implementation
func N3VectorLength(_ vector: N3Vector) -> CGFloat {
    length(vector)
}

@_cdecl("N3VectorNormalize") @implementation
func N3VectorNormalize(_ vector: N3Vector) -> N3Vector {
    normalize(vector)
}

@_cdecl("N3VectorProject") @implementation
func N3VectorProject(_ vector1: N3Vector, _ vector2: N3Vector) -> N3Vector {
    let length = length(vector2)
    return length != 0.0 ? scale(vector2, dot(vector1, vector2) / length) : N3VectorZero
}

@_cdecl("N3VectorInvert") @implementation
func N3VectorInvert(_ vector: N3Vector) -> N3Vector {
    subtract(N3VectorZero, vector)
}

@_cdecl("N3VectorApplyTransform") @implementation
func N3VectorApplyTransform(_ vector: N3Vector, _ transform: N3AffineTransform) -> N3Vector {
    add(applyToDirection(vector, transform), N3Vector(x: transform.m41, y: transform.m42, z: transform.m43))
}

@_cdecl("N3VectorApplyTransformToDirectionalVector") @implementation
func N3VectorApplyTransformToDirectionalVector(_ vector: N3Vector, _ transform: N3AffineTransform) -> N3Vector {
    applyToDirection(vector, transform)
}

// MARK: - Vectors, lines and planes

@_cdecl("N3VectorIsCoincidentToVector") @implementation
func N3VectorIsCoincidentToVector(_ vector1: N3Vector, _ vector2: N3Vector) -> Bool {
    vector1.vector3.isCoincident(with: vector2.vector3)
}

@_cdecl("N3VectorANormalVector") @implementation
func N3VectorANormalVector(_ vector: N3Vector) -> N3Vector {
    N3Vector(vector.vector3.anyNormal)
}

@_cdecl("N3VectorAngleBetweenVectorsAroundVector") @implementation
func N3VectorAngleBetweenVectorsAroundVector(_ vector1: N3Vector, _ vector2: N3Vector, _ aroundVector: N3Vector) -> CGFloat {
    vector1.vector3.angle(to: vector2.vector3, around: aroundVector.vector3)
}

@_cdecl("N3VectorBend") @implementation
func N3VectorBend(_ vectorToBend: N3Vector, _ originalDirection: N3Vector, _ newDirection: N3Vector) -> N3Vector {
    N3Vector(vectorToBend.vector3.bent(from: originalDirection.vector3, to: newDirection.vector3))
}

@_cdecl("N3VectorIsOnLine") @implementation
func N3VectorIsOnLine(_ vector: N3Vector, _ line: N3Line) -> Bool {
    vector.vector3.isOn(line.line3)
}

@_cdecl("N3VectorIsOnPlane") @implementation
func N3VectorIsOnPlane(_ vector: N3Vector, _ plane: N3Plane) -> Bool {
    vector.vector3.isOn(plane.plane3)
}

@_cdecl("N3VectorDistanceToLine") @implementation
func N3VectorDistanceToLine(_ vector: N3Vector, _ line: N3Line) -> CGFloat {
    vector.vector3.distance(to: line.line3)
}

@_cdecl("N3VectorDistanceToPlane") @implementation
func N3VectorDistanceToPlane(_ vector: N3Vector, _ plane: N3Plane) -> CGFloat {
    vector.vector3.distance(to: plane.plane3)
}

@_cdecl("N3LineMake") @implementation
func N3LineMake(_ point: N3Vector, _ vector: N3Vector) -> N3Line {
    let line = N3Line(point: point, vector: vector)
    assert(line.line3.isValid)
    return line
}

@_cdecl("N3LineMakeFromPoints") @implementation
func N3LineMakeFromPoints(_ point1: N3Vector, _ point2: N3Vector) -> N3Line {
    let line = Line3(from: point1.vector3, to: point2.vector3)
    assert(line.isValid)
    return N3Line(line)
}

@_cdecl("N3LineEqualToLine") @implementation
func N3LineEqualToLine(_ line1: N3Line, _ line2: N3Line) -> Bool {
    N3VectorEqualToVector(line1.point, line2.point) && N3VectorEqualToVector(line1.vector, line2.vector)
}

@_cdecl("N3LineIsCoincidentToLine") @implementation
func N3LineIsCoincidentToLine(_ line1: N3Line, _ line2: N3Line) -> Bool {
    line1.line3.isCoincident(with: line2.line3)
}

@_cdecl("N3LineIsOnPlane") @implementation
func N3LineIsOnPlane(_ line: N3Line, _ plane: N3Plane) -> Bool {
    line.line3.isOn(plane.plane3)
}

@_cdecl("N3LineIsParallelToLine") @implementation
func N3LineIsParallelToLine(_ line1: N3Line, _ line2: N3Line) -> Bool {
    line1.line3.isParallel(to: line2.line3)
}

@_cdecl("N3LineIsValid") @implementation
func N3LineIsValid(_ line: N3Line) -> Bool {
    line.line3.isValid
}

@_cdecl("N3LineIntersectsPlane") @implementation
func N3LineIntersectsPlane(_ line: N3Line, _ plane: N3Plane) -> Bool {
    line.line3.intersects(plane.plane3)
}

@_cdecl("N3LineIntersectionWithPlane") @implementation
func N3LineIntersectionWithPlane(_ line: N3Line, _ plane: N3Plane) -> N3Vector {
    N3Vector(line.line3.intersection(with: plane.plane3))
}

@_cdecl("N3LinePointClosestToVector") @implementation
func N3LinePointClosestToVector(_ line: N3Line, _ vector: N3Vector) -> N3Vector {
    N3Vector(line.line3.pointClosest(to: vector.vector3))
}

@_cdecl("N3LineApplyTransform") @implementation
func N3LineApplyTransform(_ line: N3Line, _ transform: N3AffineTransform) -> N3Line {
    N3Line(line.line3.applying(transform))
}

/// Parallel lines leave the points as they were.
@_cdecl("N3LineClosestPoints") @implementation
func N3LineClosestPoints(_ line1: N3Line, _ line2: N3Line, _ line1PointPtr: UnsafeMutablePointer<N3Vector>?,
                         _ line2PointPtr: UnsafeMutablePointer<N3Vector>?) -> CGFloat {
    let closest = line1.line3.closestPoints(to: line2.line3)
    if let point = closest.onSelf {
        line1PointPtr?.pointee = N3Vector(point)
    }
    if let point = closest.onLine {
        line2PointPtr?.pointee = N3Vector(point)
    }
    return closest.distance
}

@_cdecl("N3PlaneMake") @implementation
func N3PlaneMake(_ point: N3Vector, _ normal: N3Vector) -> N3Plane {
    N3Plane(point: point, normal: normal)
}

@_cdecl("N3PlaneEqualToPlane") @implementation
func N3PlaneEqualToPlane(_ plane1: N3Plane, _ plane2: N3Plane) -> Bool {
    N3VectorEqualToVector(plane1.point, plane2.point) && N3VectorEqualToVector(plane1.normal, plane2.normal)
}

@_cdecl("N3PlaneIsCoincidentToPlane") @implementation
func N3PlaneIsCoincidentToPlane(_ plane1: N3Plane, _ plane2: N3Plane) -> Bool {
    plane1.plane3.isCoincident(with: plane2.plane3)
}

@_cdecl("N3PlaneIsValid") @implementation
func N3PlaneIsValid(_ plane: N3Plane) -> Bool {
    plane.plane3.isValid
}

@_cdecl("N3PlanePointClosestToVector") @implementation
func N3PlanePointClosestToVector(_ plane: N3Plane, _ vector: N3Vector) -> N3Vector {
    N3Vector(plane.plane3.pointClosest(to: vector.vector3))
}

@_cdecl("N3PlaneIsParallelToPlane") @implementation
func N3PlaneIsParallelToPlane(_ plane1: N3Plane, _ plane2: N3Plane) -> Bool {
    plane1.plane3.isParallel(to: plane2.plane3)
}

@_cdecl("N3PlaneIsBetweenVectors") @implementation
func N3PlaneIsBetweenVectors(_ plane: N3Plane, _ vector1: N3Vector, _ vector2: N3Vector) -> Bool {
    plane.plane3.isBetween(vector1.vector3, vector2.vector3)
}

@_cdecl("N3PlaneIntersectionWithPlane") @implementation
func N3PlaneIntersectionWithPlane(_ plane1: N3Plane, _ plane2: N3Plane) -> N3Line {
    N3Line(plane1.plane3.intersection(with: plane2.plane3))
}

@_cdecl("N3PlaneLeastSquaresPlaneFromPoints") @implementation
func N3PlaneLeastSquaresPlaneFromPoints(_ vectors: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) -> N3Plane {
    let points = (0..<max(numVectors, 0)).map { vectors![$0].vector3 }
    return N3Plane(Plane3.leastSquares(through: points))
}

@_cdecl("N3PlaneApplyTransform") @implementation
func N3PlaneApplyTransform(_ plane: N3Plane, _ transform: N3AffineTransform) -> N3Plane {
    N3Plane(plane.plane3.applying(transform))
}

// MARK: - Arrays of vectors, in place

/// The x, y, z doubles of the vectors.
private func packed(_ vectors: UnsafeMutablePointer<N3Vector>) -> UnsafeMutablePointer<Double> {
    UnsafeMutableRawPointer(vectors).assumingMemoryBound(to: Double.self)
}

@_cdecl("N3VectorScalarMultiplyVectors") @implementation
func N3VectorScalarMultiplyVectors(_ scalar: CGFloat, _ vectors: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) {
    guard let vectors, numVectors > 0 else { return }
    PackedVectors.scale(packed(vectors), count: numVectors, by: scalar)
}

@_cdecl("N3VectorCrossProductVectors") @implementation
func N3VectorCrossProductVectors(_ vector: N3Vector, _ vectors: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) {
    for i in 0..<max(numVectors, 0) {
        vectors![i] = cross(vector, vectors![i])
    }
}

@_cdecl("N3VectorAddVectors") @implementation
func N3VectorAddVectors(_ vectors1: UnsafeMutablePointer<N3Vector>?, _ vectors2: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) {
    guard let vectors1, let vectors2, numVectors > 0 else { return }
    PackedVectors.add(packed(vectors2), to: packed(vectors1), count: numVectors)
}

@_cdecl("N3VectorApplyTransformToVectors") @implementation
func N3VectorApplyTransformToVectors(_ transform: N3AffineTransform, _ vectors: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) {
    guard let vectors, numVectors > 0 else { return }
    PackedVectors.apply(transform, to: packed(vectors), count: numVectors)
}

@_cdecl("N3VectorCrossProductWithVectors") @implementation
func N3VectorCrossProductWithVectors(_ vectors1: UnsafeMutablePointer<N3Vector>?, _ vectors2: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) {
    for i in 0..<max(numVectors, 0) {
        vectors1![i] = cross(vectors1![i], vectors2![i])
    }
}

@_cdecl("N3VectorNormalizeVectors") @implementation
func N3VectorNormalizeVectors(_ vectors: UnsafeMutablePointer<N3Vector>?, _ numVectors: CFIndex) {
    for i in 0..<max(numVectors, 0) {
        vectors![i] = normalize(vectors![i])
    }
}

// MARK: - Transforms

@_cdecl("N3AffineTransformIsRectilinear") @implementation
func N3AffineTransformIsRectilinear(_ transform: N3AffineTransform) -> Bool {
    transform.isRectilinear
}

@_cdecl("N3AffineTransformTranspose") @implementation
func N3AffineTransformTranspose(_ transform: N3AffineTransform) -> N3AffineTransform {
    transform.transposed
}

@_cdecl("N3AffineTransformDeterminant") @implementation
func N3AffineTransformDeterminant(_ transform: N3AffineTransform) -> CGFloat {
    transform.determinant
}

@_cdecl("N3AffineTransformInvert") @implementation
func N3AffineTransformInvert(_ transform: N3AffineTransform) -> N3AffineTransform {
    transform.inverted
}

@_cdecl("N3AffineTransformConcat") @implementation
func N3AffineTransformConcat(_ a: N3AffineTransform, _ b: N3AffineTransform) -> N3AffineTransform {
    a.concatenating(b)
}

/// The sixteen values in OpenGL's column-major order, which is the order of
/// the fields.
private func openGLValues(_ t: N3AffineTransform) -> [CGFloat] {
    [t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24, t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44]
}

private func makeTransform(openGLValues d: (Int) -> CGFloat) -> N3AffineTransform {
    N3AffineTransform(m11: d(0), m12: d(1), m13: d(2), m14: d(3), m21: d(4), m22: d(5), m23: d(6), m24: d(7),
                      m31: d(8), m32: d(9), m33: d(10), m34: d(11), m41: d(12), m42: d(13), m43: d(14), m44: d(15))
}

@_cdecl("N3AffineTransformGetOpenGLMatrixd") @implementation
func N3AffineTransformGetOpenGLMatrixd(_ transform: N3AffineTransform, _ d: UnsafeMutablePointer<Double>?) {
    for (i, value) in openGLValues(transform).enumerated() {
        d![i] = value
    }
}

@_cdecl("N3AffineTransformGetOpenGLMatrixf") @implementation
func N3AffineTransformGetOpenGLMatrixf(_ transform: N3AffineTransform, _ f: UnsafeMutablePointer<Float>?) {
    for (i, value) in openGLValues(transform).enumerated() {
        f![i] = Float(value)
    }
}

@_cdecl("N3AffineTransformMakeFromOpenGLMatrixd") @implementation
func N3AffineTransformMakeFromOpenGLMatrixd(_ d: UnsafeMutablePointer<Double>?) -> N3AffineTransform {
    makeTransform { CGFloat(d![$0]) }
}

@_cdecl("N3AffineTransformMakeFromOpenGLMatrixf") @implementation
func N3AffineTransformMakeFromOpenGLMatrixf(_ f: UnsafeMutablePointer<Float>?) -> N3AffineTransform {
    makeTransform { CGFloat(f![$0]) }
}

// MARK: - Dictionaries and strings

/// An immutable NSDictionary of the pairs, as CFDictionaryCreate made them.
func n3Dictionary(_ pairs: KeyValuePairs<String, Any>) -> NSDictionary {
    NSDictionary(objects: pairs.map(\.value), forKeys: pairs.map { $0.key as NSString })
}

/// A +1 CFDictionary for a C caller of a Create function.
private func created(_ dictionary: NSDictionary) -> Unmanaged<CFDictionary>? {
    Unmanaged.passRetained(dictionary as CFDictionary)
}

/// The dictionary a C caller passed, or nil.
private func dictionary(_ dictionary: CFDictionary?) -> NSDictionary? {
    dictionary.map { $0 as NSDictionary }
}

private func vectorDictionary(_ vector: N3Vector) -> NSDictionary {
    func number(_ value: CGFloat) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .cgFloatType, &value)
    }
    return n3Dictionary(["x": number(vector.x), "y": number(vector.y), "z": number(vector.z)])
}

/// The vector of {x, y, z} numbers; a number that a CGFloat cannot hold
/// exactly is still taken, as an approximation.
private func vector(_ dictionary: NSDictionary?) -> N3Vector? {
    guard let dictionary else { return nil }
    var values: [CGFloat] = []
    for key in ["x", "y", "z"] {
        guard let value = dictionary.object(forKey: key), CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID() else {
            return nil
        }
        var number: CGFloat = 0
        CFNumberGetValue((value as! CFNumber), .cgFloatType, &number)
        values.append(number)
    }
    return N3Vector(x: values[0], y: values[1], z: values[2])
}

/// The two vectors of a line's or a plane's dictionary.
private func vectors(_ dictionary: NSDictionary?, _ key1: String, _ key2: String) -> (N3Vector, N3Vector)? {
    guard let dictionary else { return nil }
    func subdictionary(_ key: String) -> NSDictionary? {
        guard let value = dictionary.object(forKey: key), CFGetTypeID(value as CFTypeRef) == CFDictionaryGetTypeID() else {
            return nil
        }
        return (value as! NSDictionary)
    }
    guard let first = subdictionary(key1), let second = subdictionary(key2), let vector1 = vector(first),
          let vector2 = vector(second) else {
        return nil
    }
    return (vector1, vector2)
}

@_cdecl("N3VectorCreateDictionaryRepresentation") @implementation
func N3VectorCreateDictionaryRepresentation(_ vector: N3Vector) -> Unmanaged<CFDictionary>? {
    created(vectorDictionary(vector))
}

@_cdecl("N3LineCreateDictionaryRepresentation") @implementation
func N3LineCreateDictionaryRepresentation(_ line: N3Line) -> Unmanaged<CFDictionary>? {
    created(n3Dictionary(["point": vectorDictionary(line.point), "vector": vectorDictionary(line.vector)]))
}

@_cdecl("N3PlaneCreateDictionaryRepresentation") @implementation
func N3PlaneCreateDictionaryRepresentation(_ plane: N3Plane) -> Unmanaged<CFDictionary>? {
    created(n3Dictionary(["point": vectorDictionary(plane.point), "normal": vectorDictionary(plane.normal)]))
}

@_cdecl("N3VectorMakeWithDictionaryRepresentation") @implementation
func N3VectorMakeWithDictionaryRepresentation(_ dict: CFDictionary?, _ vectorPointer: UnsafeMutablePointer<N3Vector>?) -> Bool {
    guard let vector = vector(dictionary(dict)) else { return false }
    vectorPointer?.pointee = vector
    return true
}

@_cdecl("N3LineMakeWithDictionaryRepresentation") @implementation
func N3LineMakeWithDictionaryRepresentation(_ dict: CFDictionary?, _ line: UnsafeMutablePointer<N3Line>?) -> Bool {
    guard let (point, vector) = vectors(dictionary(dict), "point", "vector") else { return false }
    line?.pointee = N3Line(point: point, vector: vector)
    return true
}

@_cdecl("N3PlaneMakeWithDictionaryRepresentation") @implementation
func N3PlaneMakeWithDictionaryRepresentation(_ dict: CFDictionary?, _ plane: UnsafeMutablePointer<N3Plane>?) -> Bool {
    guard let (point, normal) = vectors(dictionary(dict), "point", "normal") else { return false }
    plane?.pointee = N3Plane(point: point, normal: normal)
    return true
}

private func describe(_ vector: N3Vector) -> String {
    String(format: "{%f, %f, %f}", vector.x, vector.y, vector.z)
}

@_cdecl("NSStringFromN3AffineTransform") @implementation
func NSStringFromN3AffineTransform(_ t: N3AffineTransform) -> String? {
    String(format: "{{%8.2f, %8.2f, %8.2f, %8.2f}\n {%8.2f, %8.2f, %8.2f, %8.2f}\n {%8.2f, %8.2f, %8.2f, %8.2f}\n {%8.2f, %8.2f, %8.2f, %8.2f}}",
           t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24, t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44)
}

@_cdecl("NSStringFromN3Vector") @implementation
func NSStringFromN3Vector(_ vector: N3Vector) -> String? {
    describe(vector)
}

@_cdecl("NSStringFromN3Line") @implementation
func NSStringFromN3Line(_ line: N3Line) -> String? {
    "{\(describe(line.point)), \(describe(line.vector))}"
}

@_cdecl("NSStringFromN3Plane") @implementation
func NSStringFromN3Plane(_ plane: N3Plane) -> String? {
    "{\(describe(plane.point)), \(describe(plane.normal))}"
}

// MARK: - NSValue

/// @encode of the types, which Swift cannot spell.
private enum N3ObjCType {
    static let vector = "{N3Vector=ddd}"
    static let line = "{N3Line={N3Vector=ddd}{N3Vector=ddd}}"
    static let plane = "{N3Plane={N3Vector=ddd}{N3Vector=ddd}}"
    static let affineTransform = "{CATransform3D=dddddddddddddddd}"
}

private func contents<T>(of value: NSValue, _ objCType: String, empty: T) -> T {
    assert(String(cString: value.objCType) == objCType)
    var contents = empty
    withUnsafeMutableBytes(of: &contents) { value.getValue($0.baseAddress!, size: $0.count) }
    return contents
}

// NSValue (N3GeometryAdditions), which N3Geometry.h declares. The factory
// methods cannot be an @implementation (Swift sees them as initializers), so
// the category is a plain extension with the header's selectors; Swift calls
// them through the header's declarations, NSValue(n3Vector:) and the others.
extension NSValue {

    @objc(valueWithN3Vector:)
    class func makeValue(n3Vector vector: N3Vector) -> NSValue {
        var vector = vector
        return NSValue(bytes: &vector, objCType: N3ObjCType.vector)
    }

    @objc(N3VectorValue)
    func makeN3Vector() -> N3Vector {
        contents(of: self, N3ObjCType.vector, empty: N3VectorZero)
    }

    @objc(valueWithN3Line:)
    class func makeValue(n3Line line: N3Line) -> NSValue {
        var line = line
        return NSValue(bytes: &line, objCType: N3ObjCType.line)
    }

    @objc(N3LineValue)
    func makeN3Line() -> N3Line {
        contents(of: self, N3ObjCType.line, empty: N3LineInvalid)
    }

    @objc(valueWithN3Plane:)
    class func makeValue(n3Plane plane: N3Plane) -> NSValue {
        var plane = plane
        return NSValue(bytes: &plane, objCType: N3ObjCType.plane)
    }

    @objc(N3PlaneValue)
    func makeN3Plane() -> N3Plane {
        contents(of: self, N3ObjCType.plane, empty: N3PlaneInvalid)
    }

    @objc(valueWithN3AffineTransform:)
    class func makeValue(n3AffineTransform transform: N3AffineTransform) -> NSValue {
        var transform = transform
        return NSValue(bytes: &transform, objCType: N3ObjCType.affineTransform)
    }

    @objc(N3AffineTransformValue)
    func makeN3AffineTransform() -> N3AffineTransform {
        contents(of: self, N3ObjCType.affineTransform, empty: N3AffineTransformIdentity)
    }
}
