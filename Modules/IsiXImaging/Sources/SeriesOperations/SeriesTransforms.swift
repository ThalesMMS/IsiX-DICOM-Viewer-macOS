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

import Accelerate
import Foundation

// The flips and rotations of a 2D viewer's data set: what they do to the
// pixels of each slice and to the slice's orientation, origin and spacing.
// The viewer reads its DCMPix and applies the answers; nothing here knows
// DCMPix or the viewer.

/// A quarter turn of a data set, clockwise, as vImageRotate90_PlanarF takes it.
public enum SeriesRotation: Sendable, Equatable {
    case clockwise90, clockwise180, clockwise270

    /// The rotation of a vImage rotation constant (kRotate90DegreesClockwise…),
    /// nil for any other.
    public init?(vImageConstant constant: Int) {
        switch constant {
        case Int(kRotate90DegreesClockwise): self = .clockwise90
        case Int(kRotate180DegreesClockwise): self = .clockwise180
        case Int(kRotate270DegreesClockwise): self = .clockwise270
        default: return nil
        }
    }

    public var degrees: Double {
        switch self {
        case .clockwise90: return 90
        case .clockwise180: return 180
        case .clockwise270: return 270
        }
    }

    /// The width and height trade places.
    public var swapsAxes: Bool { self != .clockwise180 }

    /// The pixel (x, y) of the turned slice, of `width`×`height` (after the
    /// turn), whose position is the slice's new origin.
    public func originPixel(width: Int, height: Int) -> (x: Double, y: Double) {
        switch self {
        case .clockwise90: return (Double(-width + 1), 0)
        case .clockwise180: return (Double(-width + 1), Double(height - 1))
        case .clockwise270: return (Double(width - 1), 0)
        }
    }
}

public enum SeriesTransforms {

    /// deg2rad of the viewer: a float.
    static let deg2rad = Float(Double.pi / 180.0)

    // MARK: Orientation

    /// A vertical flip reverses the columns' direction.
    public static func verticallyFlipped(_ o: [Double]) -> [Double] {
        var result = o
        result[3] *= -1
        result[4] *= -1
        result[5] *= -1
        return result
    }

    /// A horizontal flip reverses the rows' direction.
    public static func horizontallyFlipped(_ o: [Double]) -> [Double] {
        var result = o
        result[0] *= -1
        result[1] *= -1
        result[2] *= -1
        return result
    }

    /// The orientation turned by `degrees` clockwise around its normal, which
    /// is recomputed from the rows and columns first (and returned in 6…8).
    public static func rotated(_ o: [Double], degrees: Double) -> [Double] {
        var result = o
        // a*b - c*d, which clang fused into fma(a, b, -(c*d)).
        result[6] = (-(o[2] * o[4])).addingProduct(o[1], o[5])
        result[7] = (-(o[0] * o[5])).addingProduct(o[2], o[3])
        result[8] = (-(o[1] * o[3])).addingProduct(o[0], o[4])
        let axis = SIMD3(result[6], result[7], result[8])
        let theta = -degrees * Double(deg2rad)
        let row = PlaneGeometry.arbitraryRotate(SIMD3(o[0], o[1], o[2]), theta: theta, axis: axis)
        let column = PlaneGeometry.arbitraryRotate(SIMD3(o[3], o[4], o[5]), theta: theta, axis: axis)
        result[0] = row.x; result[1] = row.y; result[2] = row.z
        result[3] = column.x; result[4] = column.y; result[5] = column.z
        return result
    }

    /// The position of the pixel (x, y) of a slice of this origin,
    /// orientation and spacing: the turned slice's origin.
    public static func origin(_ origin: [Double], orientation o: [Double], spacingX: Double, spacingY: Double,
                              pixel: (x: Double, y: Double)) -> [Double] {
        // origin + y*column*spacingY + x*row*spacingX, which clang fused into
        // fma(x*row, spacingX, fma(y*column, spacingY, origin)).
        return (0..<3).map { k in
            origin[k].addingProduct(pixel.y * o[3 + k], spacingY).addingProduct(pixel.x * o[k], spacingX)
        }
    }

    /// The spacings of a slice turned a quarter: they trade places, through
    /// the floats the viewer kept them in, with the new pixel ratio.
    public static func swappedSpacing(x: Double, y: Double) -> (x: Double, y: Double, ratio: Double) {
        let fx = Float(x), fy = Float(y)
        return (Double(fy), Double(fx), Double(fx / fy))
    }

    /// The width and height of a slice turned a quarter, through the floats
    /// the viewer kept them in.
    public static func swappedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        return (cLong(Float(height)), cLong(Float(width)))
    }

    static func cLong(_ value: Float) -> Int {
        return SeriesReslicePlan.cLong(Double(value))
    }

    // MARK: Pixels

    /// Each of `count` slices of `width`×`height` floats, stored one after
    /// the other from `base`, flipped upside down. False, with nothing
    /// changed, when the temporary slice cannot be allocated.
    @discardableResult
    public static func flipSlicesVertically(_ base: UnsafeMutablePointer<Float>, width: Int, height: Int, count: Int) -> Bool {
        let bytes = height * width * 4
        guard let temporary = malloc(bytes) else { return false }
        var slice = base
        for _ in 0..<count {
            var source = vImage_Buffer(data: slice, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var destination = vImage_Buffer(data: temporary, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageVerticalReflect_PlanarF(&source, &destination, 0)
            memcpy(slice, temporary, bytes)
            slice += height * width
        }
        free(temporary)
        return true
    }

    /// The `rows` rows of `width` floats from `base` (every slice of a
    /// volume) flipped left to right, in place.
    public static func flipRowsHorizontally(_ base: UnsafeMutablePointer<Float>, width: Int, rows: Int) {
        var buffer = vImage_Buffer(data: base, height: vImagePixelCount(rows), width: vImagePixelCount(width), rowBytes: width * 4)
        var destination = buffer
        vImageHorizontalReflect_PlanarF(&buffer, &destination, 0)
    }

    /// Each of `count` slices of `width`×`height` floats, stored one after the
    /// other from `base`, turned by the vImage rotation constant (a quarter
    /// turn trades the width and height of each slice in place). False, with
    /// nothing changed, when the temporary slice cannot be allocated.
    @discardableResult
    public static func rotateSlices(_ base: UnsafeMutablePointer<Float>, width: Int, height: Int, count: Int, vImageConstant constant: UInt8) -> Bool {
        let bytes = height * width * 4
        guard let temporary = malloc(bytes) else { return false }
        let quarter = constant == UInt8(kRotate90DegreesClockwise) || constant == UInt8(kRotate270DegreesClockwise)
        var slice = base
        for _ in 0..<count {
            var source = vImage_Buffer(data: slice, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var destination = vImage_Buffer(data: temporary, height: vImagePixelCount(quarter ? width : height),
                                            width: vImagePixelCount(quarter ? height : width), rowBytes: (quarter ? height : width) * 4)
            vImageRotate90_PlanarF(&source, &destination, constant, 0, 0)
            memcpy(slice, temporary, bytes)
            slice += height * width
        }
        free(temporary)
        return true
    }
}
