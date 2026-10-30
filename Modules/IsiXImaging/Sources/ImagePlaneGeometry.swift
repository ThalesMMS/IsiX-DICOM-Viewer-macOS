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

import Foundation

/// Where an image lies in the patient: its origin, the direction cosines of its
/// rows and columns and the normal they make, the size of its pixels and the
/// slice it belongs to.
///
/// The arithmetic is written with fused multiply-adds where the Objective-C it
/// replaces was compiled into them (clang contracts `a * b + c` within an
/// expression on arm64), so that every value is the one the app computed
/// before, to the last bit.
public struct ImagePlaneGeometry: Equatable, Sendable {
    public var originX = 0.0
    public var originY = 0.0
    public var originZ = 0.0
    public var isOriginDefined = false
    /// Row cosines (0-2), column cosines (3-5) and the normal (6-8).
    public var orientation = [Double](repeating: 0, count: 9)
    public var pixelSpacingX = 0.0
    public var pixelSpacingY = 0.0
    public var pixelRatio = 0.0
    public var estimatedRadiographicMagnificationFactor = 0.0
    public var pixelSpacingFromUltrasoundRegions = false
    public var sliceThickness = 0.0
    public var spacingBetweenSlices = 0.0
    public var sliceLocation = 0.0

    public init() {}

    /// Rows along x, columns along y: an axial image, until a file says otherwise.
    public static let identityOrientation: [Double] = {
        var orientation: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 0]
        computeNormal(&orientation)
        return orientation
    }()

    /// The normal is the cross product of the row and the column cosines.
    public static func computeNormal(_ o: inout [Double]) {
        o[6] = (-(o[2] * o[4])).addingProduct(o[1], o[5])
        o[7] = (-(o[0] * o[5])).addingProduct(o[2], o[3])
        o[8] = (-(o[1] * o[3])).addingProduct(o[0], o[4])
    }

    public mutating func computeNormal() {
        Self.computeNormal(&orientation)
    }

    /// A plane with a normal is placed by its cosines; one without, read from a
    /// file that gave none, is laid flat at its origin.
    public var is3DPlane: Bool {
        orientation[6] != 0 || orientation[7] != 0 || orientation[8] != 0
    }

    /// The patient coordinates of a pixel, in single precision, as the slice
    /// location has always been computed (`-convertPixX:pixY:toDICOMCoords:`).
    func singlePrecisionPatientPoint(x: Float, y: Float, pixelCenter: Bool) -> (Float, Float, Float) {
        var x = x, y = y
        if pixelCenter {
            x = Float(Double(x) - 0.5)
            y = Float(Double(y) - 0.5)
        }
        let o = orientation
        if is3DPlane {
            return (Float(originX.addingProduct(Double(y) * o[3], pixelSpacingY).addingProduct(Double(x) * o[0], pixelSpacingX)),
                    Float(originY.addingProduct(Double(y) * o[4], pixelSpacingY).addingProduct(Double(x) * o[1], pixelSpacingX)),
                    Float(originZ.addingProduct(Double(y) * o[5], pixelSpacingY).addingProduct(Double(x) * o[2], pixelSpacingX)))
        }
        return (Float(originX.addingProduct(Double(x), pixelSpacingX)),
                Float(originY.addingProduct(Double(y), pixelSpacingY)),
                Float(originZ))
    }

    /// The slice location is the coordinate of the image's centre along the
    /// axis the normal points to most; with no dominant axis it is left as it was.
    public mutating func computeSliceLocation(width: Int, height: Int) {
        let center = singlePrecisionPatientPoint(x: Float(width / 2), y: Float(height / 2), pixelCenter: true)
        let o = orientation
        if abs(o[6]) > abs(o[7]) && abs(o[6]) > abs(o[8]) { sliceLocation = Double(center.0) }
        if abs(o[7]) > abs(o[6]) && abs(o[7]) > abs(o[8]) { sliceLocation = Double(center.1) }
        if abs(o[8]) > abs(o[6]) && abs(o[8]) > abs(o[7]) { sliceLocation = Double(center.2) }
    }

    /// Takes six direction cosines, scales each vector to unit length and
    /// computes the unit normal (`-setOrientationDouble:`).
    public static func normalizedOrientation(_ cosines: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for i in 0..<6 { o[i] = cosines[i] }
        var length = sqrt(length2(o[0], o[1], o[2]))
        if length != 0 {
            o[0] = o[0] / length; o[1] = o[1] / length; o[2] = o[2] / length
        }
        length = sqrt(length2(o[3], o[4], o[5]))
        if length != 0 {
            o[3] = o[3] / length; o[4] = o[4] / length; o[5] = o[5] / length
        }
        computeNormal(&o)
        length = sqrt(length2(o[6], o[7], o[8]))
        if length != 0 {
            o[6] = o[6] / length; o[7] = o[7] / length; o[8] = o[8] / length
        }
        return o
    }

    private static func length2(_ a: Double, _ b: Double, _ c: Double) -> Double {
        (b * b).addingProduct(a, a).addingProduct(c, c)
    }

    /// The spacing a loaded image keeps: an absurd aspect is replaced by square
    /// pixels, a negative spacing loses its sign, a radiograph's spacing is
    /// brought back to the patient by its magnification, and the aspect ratio
    /// follows.
    public mutating func settlePixelSpacing() {
        if pixelSpacingY != 0 {
            let aspect = abs(pixelSpacingX) / abs(pixelSpacingY)
            if aspect > 10000 || aspect < 0.0001 {
                pixelSpacingX = 1
                pixelSpacingY = 1
            }
        }
        if pixelSpacingX < 0 { pixelSpacingX = -pixelSpacingX }
        if pixelSpacingY < 0 { pixelSpacingY = -pixelSpacingY }
        if pixelSpacingY != 0 && pixelSpacingX != 0 {
            if estimatedRadiographicMagnificationFactor != 0 {
                pixelSpacingX /= estimatedRadiographicMagnificationFactor
                pixelSpacingY /= estimatedRadiographicMagnificationFactor
            }
            pixelRatio = pixelSpacingY / pixelSpacingX
        }
    }
}

/// The plane computations, for the Objective-C image object that keeps its
/// geometry in C arrays: each call reads and writes the caller's own storage,
/// with no object made.
@objc(IsiXImagePlaneGeometry)
public final class ImagePlaneGeometryFunctions: NSObject {
    /// Writes the axial orientation and its normal into nine doubles.
    @objc(setIdentityOrientation:)
    public static func setIdentityOrientation(_ orientation: UnsafeMutablePointer<Double>) {
        for i in 0..<9 { orientation[i] = ImagePlaneGeometry.identityOrientation[i] }
    }

    /// Takes the first six doubles of `cosines` and writes the unit row and
    /// column cosines and their unit normal into the nine of `orientation`.
    @objc(setOrientation:fromCosines:)
    public static func setOrientation(_ orientation: UnsafeMutablePointer<Double>, fromCosines cosines: UnsafePointer<Double>) {
        let normalized = ImagePlaneGeometry.normalizedOrientation((0..<6).map { cosines[$0] })
        for i in 0..<9 { orientation[i] = normalized[i] }
    }

    /// The slice location of an image with this geometry; `current` when no
    /// axis dominates the normal (`ImagePlaneGeometry.computeSliceLocation`).
    @objc(sliceLocationWithOrientation:originX:originY:originZ:spacingX:spacingY:width:height:current:)
    public static func sliceLocation(orientation: UnsafePointer<Double>, originX: Double, originY: Double, originZ: Double,
                                     spacingX: Double, spacingY: Double, width: Int, height: Int, current: Double) -> Double {
        var geometry = ImagePlaneGeometry()
        geometry.orientation = (0..<9).map { orientation[$0] }
        geometry.originX = originX
        geometry.originY = originY
        geometry.originZ = originZ
        geometry.pixelSpacingX = spacingX
        geometry.pixelSpacingY = spacingY
        geometry.sliceLocation = current
        geometry.computeSliceLocation(width: width, height: height)
        return geometry.sliceLocation
    }

    /// Settles the spacing of a loaded image in place; see
    /// `ImagePlaneGeometry.settlePixelSpacing()`.
    @objc(settlePixelSpacingX:y:ratio:magnification:)
    public static func settlePixelSpacing(x: UnsafeMutablePointer<Double>, y: UnsafeMutablePointer<Double>,
                                          ratio: UnsafeMutablePointer<Double>, magnification: Double) {
        var geometry = ImagePlaneGeometry()
        geometry.pixelSpacingX = x.pointee
        geometry.pixelSpacingY = y.pointee
        geometry.pixelRatio = ratio.pointee
        geometry.estimatedRadiographicMagnificationFactor = magnification
        geometry.settlePixelSpacing()
        x.pointee = geometry.pixelSpacingX
        y.pointee = geometry.pixelSpacingY
        ratio.pointee = geometry.pixelRatio
    }
}
