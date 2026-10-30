/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

/// The coordinates of an image's plane (-[DCMPix convertPixX:...],
/// -convertDICOMCoords:..., +originDeltaBetween:And:, +rotatePoint:..., the
/// rectangle a rotated image needs and its corrected orientation): the
/// arithmetic, given the image's origin, direction cosines and pixel size.
///
/// The Objective-C was compiled with floating-point contraction: where clang
/// fused a multiplication into the addition it fed (`a * b + c`, the left
/// product first), this fuses it too (`addingProduct`), in the same order;
/// single-precision values are rounded where the C stored them in floats.
public enum ImagePlaneCoordinates {
    /// Degrees to radians in single precision, as the C kept it (`M_PI / 180.0` in a float).
    public static let degreesToRadians = Float(Double.pi / 180.0)

    /// Whether `orientation` has a normal: a plane placed by its cosines;
    /// without one, read from a file that gave none, it lies flat at its origin.
    @inline(__always)
    static func is3D(_ o: UnsafePointer<Double>) -> Bool {
        o[6] != 0 || o[7] != 0 || o[8] != 0
    }

    // MARK: - Pixel to patient

    /// The patient coordinates (mm) of pixel (x, y), in single precision. With
    /// `pixelCenter`, (x, y) is a pixel's centre and the origin its corner.
    public static func patientPoint(x: Float, y: Float, pixelCenter: Bool, originX: Double, originY: Double, originZ: Double,
                                    orientation o: UnsafePointer<Double>, spacingX: Double, spacingY: Double) -> SIMD3<Float> {
        var x = x, y = y
        if pixelCenter {
            x = Float(Double(x) - 0.5)
            y = Float(Double(y) - 0.5)
        }
        let dx = Double(x), dy = Double(y)
        if is3D(o) {
            return SIMD3(Float(originX.addingProduct(dy * o[3], spacingY).addingProduct(dx * o[0], spacingX)),
                         Float(originY.addingProduct(dy * o[4], spacingY).addingProduct(dx * o[1], spacingX)),
                         Float(originZ.addingProduct(dy * o[5], spacingY).addingProduct(dx * o[2], spacingX)))
        }
        return SIMD3(Float(originX.addingProduct(dx, spacingX)), Float(originY.addingProduct(dy, spacingY)), Float(originZ))
    }

    /// The patient coordinates (mm) of pixel (x, y), in double precision.
    public static func patientPoint(x: Double, y: Double, pixelCenter: Bool, originX: Double, originY: Double, originZ: Double,
                                    orientation o: UnsafePointer<Double>, spacingX: Double, spacingY: Double) -> SIMD3<Double> {
        var x = x, y = y
        if pixelCenter {
            x -= 0.5
            y -= 0.5
        }
        if is3D(o) {
            return SIMD3(originX.addingProduct(y * o[3], spacingY).addingProduct(x * o[0], spacingX),
                         originY.addingProduct(y * o[4], spacingY).addingProduct(x * o[1], spacingX),
                         originZ.addingProduct(y * o[5], spacingY).addingProduct(x * o[2], spacingX))
        }
        return SIMD3(originX.addingProduct(x, spacingX), originY.addingProduct(y, spacingY), originZ)
    }

    // MARK: - Patient to slice

    /// A patient point (mm) in the slice's own axes: along its rows, its
    /// columns and its normal, from its origin, in single precision. With
    /// `pixelCenter`, measured from the first pixel's corner.
    public static func slicePoint(_ p: SIMD3<Float>, pixelCenter: Bool, originX: Double, originY: Double, originZ: Double,
                                  orientation o: UnsafePointer<Double>, spacingX: Double, spacingY: Double) -> SIMD3<Float> {
        let t0 = Double(Float(Double(p.x) - originX))
        let t1 = Double(Float(Double(p.y) - originY))
        let t2 = Double(Float(Double(p.z) - originZ))
        var s = SIMD3(Float((t1 * o[1]).addingProduct(t0, o[0]).addingProduct(t2, o[2])),
                      Float((t1 * o[4]).addingProduct(t0, o[3]).addingProduct(t2, o[5])),
                      Float((t1 * o[7]).addingProduct(t0, o[6]).addingProduct(t2, o[8])))
        if pixelCenter {
            s.x = Float(Double(s.x) + spacingX / 2)
            s.y = Float(Double(s.y) + spacingY / 2)
        }
        return s
    }

    /// A patient point (mm) in the slice's own axes, in double precision.
    public static func slicePoint(_ p: SIMD3<Double>, pixelCenter: Bool, originX: Double, originY: Double, originZ: Double,
                                  orientation o: UnsafePointer<Double>, spacingX: Double, spacingY: Double) -> SIMD3<Double> {
        let t0 = p.x - originX, t1 = p.y - originY, t2 = p.z - originZ
        var s = SIMD3((t1 * o[1]).addingProduct(t0, o[0]).addingProduct(t2, o[2]),
                      (t1 * o[4]).addingProduct(t0, o[3]).addingProduct(t2, o[5]),
                      (t1 * o[7]).addingProduct(t0, o[6]).addingProduct(t2, o[8]))
        if pixelCenter {
            s.x += spacingX / 2
            s.y += spacingY / 2
        }
        return s
    }

    // MARK: - Origins

    /// An origin projected on the row and column cosines of `o`.
    static func projected(_ x: Double, _ y: Double, _ z: Double, _ o: UnsafePointer<Double>) -> (Double, Double) {
        ((y * o[1]).addingProduct(x, o[0]).addingProduct(z, o[2]),
         (y * o[4]).addingProduct(x, o[3]).addingProduct(z, o[5]))
    }

    /// An image's origin projected on its own row and column cosines.
    public static func correctedOrigin(originX: Double, originY: Double, originZ: Double, orientation o: UnsafePointer<Double>) -> CGPoint {
        let (x, y) = projected(originX, originY, originZ, o)
        return CGPoint(x: x, y: y)
    }

    /// One image of a pair `originDelta` compares.
    public struct Plane {
        public var originX, originY, originZ: Double
        public var spacingX, spacingY: Double
        public var width, height: Int
        public var orientation: UnsafePointer<Double>
        public init(originX: Double, originY: Double, originZ: Double, spacingX: Double, spacingY: Double,
                    width: Int, height: Int, orientation: UnsafePointer<Double>) {
            self.originX = originX; self.originY = originY; self.originZ = originZ
            self.spacingX = spacingX; self.spacingY = spacingY
            self.width = width; self.height = height
            self.orientation = orientation
        }
    }

    /// The shift, in pixels of `sender`, between the centres of two images,
    /// each origin taken at its first pixel's corner and projected on its own
    /// cosines; zero when either has pixels of no size. `senderRatio` is the
    /// sender's pixel aspect, which the vertical shift is scaled by.
    public static func originDelta(destination d: Plane, sender s: Plane, senderRatio: Double) -> CGPoint {
        // DICOM Origin is the CENTER of the first pixel.
        let destOrigin = projected(d.originX - d.spacingX / 2, d.originY - d.spacingY / 2, d.originZ, d.orientation)
        let senderOrigin = projected(s.originX - s.spacingX / 2, s.originY - s.spacingY / 2, s.originZ, s.orientation)
        var x = destOrigin.0 + d.spacingX * Double(d.width) / 2 - (senderOrigin.0 + s.spacingX * Double(s.width) / 2)
        var y = destOrigin.1 + d.spacingY * Double(d.height) / 2 - (senderOrigin.1 + s.spacingY * Double(s.height) / 2)
        x /= s.spacingX
        y /= s.spacingY
        y *= senderRatio
        return CGPoint(x: x, y: y)
    }

    // MARK: - Rotations

    /// `point` turned by `angle` radians around `center`.
    public static func rotate(_ point: CGPoint, around center: CGPoint, angle: Float) -> CGPoint {
        let x = point.x - center.x, y = point.y - center.y
        let c = cos(Double(angle)), s = sin(Double(angle))
        return CGPoint(x: (-(s * y)).addingProduct(c, x) + center.x, y: (c * y).addingProduct(s, x) + center.y)
    }

    /// The pixel size of an image scaled by `scale`, its height also by its
    /// pixel aspect: what -renderWithRotation:... draws before turning it.
    public static func scaledSize(width: Int, height: Int, scale: Float, pixelRatio: Double) -> (width: Int32, height: Int32) {
        (cInt(Float(width) * scale), cInt(Double(Float(height) * scale) * pixelRatio))
    }

    /// The bounds of an image of that scaled size turned by `rotation` degrees
    /// around its centre, as single-precision corners.
    public static func usefulRect(width: Int, height: Int, scale: Float, pixelRatio: Double, rotation: Float) -> CGRect {
        let angle = rotation * degreesToRadians
        let size = scaledSize(width: width, height: height, scale: scale, pixelRatio: pixelRatio)
        let w = Double(size.width), h = Double(size.height)
        let center = CGPoint(x: w / 2, y: h / 2)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 0 + w, y: 0), CGPoint(x: 0 + w, y: 0 + h), CGPoint(x: 0, y: 0 + h)]
            .map { rotate($0, around: center, angle: angle) }
        var minX = Float(corners[0].x), maxX = minX
        var minY = Float(corners[0].y), maxY = minY
        for p in corners {
            if Double(minX) > p.x { minX = Float(p.x) }
            if Double(maxX) < p.x { maxX = Float(p.x) }
            if Double(minY) > p.y { minY = Float(p.y) }
            if Double(maxY) < p.y { maxY = Float(p.y) }
        }
        return CGRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
    }

    /// The orientation of an image flipped and turned in the view by
    /// `rotation` degrees: the row and column cosines turned around the normal
    /// (the turn reversed by one flip, half a turn added by both), in single
    /// precision, with the normal made again.
    public static func correctedOrientation(_ orientation: [Float], rotation: Float, xFlipped: Bool, yFlipped: Bool) -> [Float] {
        var o = orientation
        var yRot: Float = -1, xRot: Float = -1
        var rot = rotation
        if yFlipped && xFlipped {
            rot = rot + 180
        } else {
            if yFlipped {
                xRot *= -1; yRot *= -1
                o[3] *= -1; o[4] *= -1; o[5] *= -1
            }
            if xFlipped {
                xRot *= -1; yRot *= -1
                o[0] *= -1; o[1] *= -1; o[2] *= -1
            }
        }
        computeNormal(&o)
        let axis = SIMD3(Double(o[6]), Double(o[7]), Double(o[8]))
        let row = PlaneGeometry.arbitraryRotate(SIMD3(Double(o[0]), Double(o[1]), Double(o[2])),
                                                theta: Double(xRot * rot * degreesToRadians), axis: axis)
        o[0] = Float(row.x); o[1] = Float(row.y); o[2] = Float(row.z)
        let column = PlaneGeometry.arbitraryRotate(SIMD3(Double(o[3]), Double(o[4]), Double(o[5])),
                                                   theta: Double(yRot * rot * degreesToRadians), axis: axis)
        o[3] = Float(column.x); o[4] = Float(column.y); o[5] = Float(column.z)
        computeNormal(&o)
        return o
    }

    /// The single-precision normal: the cross product of the row and the column cosines.
    static func computeNormal(_ o: inout [Float]) {
        o[6] = (-(o[2] * o[4])).addingProduct(o[1], o[5])
        o[7] = (-(o[0] * o[5])).addingProduct(o[2], o[3])
        o[8] = (-(o[1] * o[3])).addingProduct(o[0], o[4])
    }

    // MARK: - Conversions as arm64 made them

    /// A float to a C `int` (fcvtzs): toward zero, saturated, NaN to 0.
    public static func cInt(_ x: Float) -> Int32 { cInt(Double(x)) }

    /// A double to a C `int` (fcvtzs): toward zero, saturated, NaN to 0.
    public static func cInt(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        if x >= 2147483647 { return Int32.max }
        if x <= -2147483648 { return Int32.min }
        return Int32(x)
    }

    /// A double to a C `long` (fcvtzs): toward zero, saturated, NaN to 0.
    public static func cLong(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        if x >= 9223372036854775807.0 { return Int.max }
        if x <= -9223372036854775808.0 { return Int.min }
        return Int(x)
    }

    /// A double to a C `unsigned long` (fcvtzu): toward zero, saturated, negative and NaN to 0.
    public static func cUnsignedLong(_ x: Double) -> UInt {
        if x.isNaN || x <= 0 { return 0 }
        if x >= 18446744073709551615.0 { return UInt.max }
        return UInt(x)
    }
}
