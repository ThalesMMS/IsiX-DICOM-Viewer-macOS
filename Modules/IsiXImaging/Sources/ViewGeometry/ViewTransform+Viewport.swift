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

import CoreGraphics
import Foundation

// The conversions between a view's coordinates and its image's, the plane
// arithmetic of synchronization, the drawing's transform and the thick slab,
// over the viewport (ViewportState). The view (DCMView+WindowLevel+Coordinates
// and DCMView+Geometry, in the app) reads its sizes and applies the results;
// these functions compute exactly as its own code did, in the same order and
// precision (no fused multiply-adds: that code was Swift already).
extension ViewTransform {

    /// The image a conversion places: its size in pixels and its pixel ratio.
    public struct ImageExtent: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var pixelRatio: Double

        public init(width: Int, height: Int, pixelRatio: Double) {
            self.width = width
            self.height = height
            self.pixelRatio = pixelRatio
        }
    }

    // MARK: - Conversions

    /// A point of the view (`frameSize`, origin at its lower left) in the
    /// image's pixels, turned and flipped as the view shows it, without the
    /// scale (-rotatePoint:).
    public static func rotatedPoint(_ point: CGPoint, viewport: ViewportState, frameSize: CGSize, imageWidth: Int,
                                    imageHeight: Int, deg2rad: Double) -> CGPoint {
        var a = point
        if viewport.xFlipped { a.x = frameSize.width - a.x }
        if viewport.yFlipped { a.y = frameSize.height - a.y }

        a.x -= frameSize.width / 2
        a.y -= frameSize.height / 2

        let angle = Double(viewport.rotation) * deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))

        a.y = CGFloat(yy)
        a.x = CGFloat(xx)

        a.x -= viewport.origin.x
        a.y += viewport.origin.y

        a.x += CGFloat(Double(imageWidth) / 2.0)
        a.y += CGFloat(Double(imageHeight) / 2.0)
        return a
    }

    /// A point of the image (slice coordinates) in the view's drawing of
    /// `drawingSize`, from its centre (-ConvertFromGL2View:). `image` is nil
    /// when the view shows none.
    public static func imageToView(_ point: CGPoint, viewport: ViewportState, drawingSize size: CGSize,
                                   image: ImageExtent?, deg2rad: Double) -> CGPoint {
        var a = point
        if let image {
            a.y *= CGFloat(image.pixelRatio)
            a.y -= CGFloat(Double(image.height) * image.pixelRatio * 0.5)
            a.x -= CGFloat(Float(image.width) * 0.5)
        }

        let scaleValue = CGFloat(viewport.scale)
        let origin = viewport.origin
        a.y -= (origin.y) / scaleValue
        a.x += (origin.x) / scaleValue

        let angle = Double(-viewport.rotation) * deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))

        a.y = CGFloat(yy)
        a.x = CGFloat(xx)

        a.y *= scaleValue
        a.y += size.height / 2.0

        a.x *= scaleValue
        a.x += size.width / 2.0

        if viewport.xFlipped { a.x = size.width - a.x }
        if viewport.yFlipped { a.y = size.height - a.y }

        a.x -= size.width / 2.0
        a.y -= size.height / 2.0
        return a
    }

    /// A point of the view's drawing of `drawingSize`, from its upper left
    /// corner, in the image (slice coordinates) (-ConvertFromUpLeftView2GL:).
    /// `image` is nil when the view shows none.
    public static func upLeftViewToImage(_ point: CGPoint, viewport: ViewportState, drawingSize size: CGSize,
                                         image: ImageExtent?, deg2rad: Double) -> CGPoint {
        var a = point
        let scaleValue = CGFloat(viewport.scale)

        if viewport.xFlipped { a.x = size.width - a.x }
        if viewport.yFlipped { a.y = size.height - a.y }

        a.x -= size.width / 2
        a.x /= scaleValue

        a.y -= size.height / 2
        a.y /= scaleValue

        let angle = Double(viewport.rotation) * deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))

        a.y = CGFloat(yy)
        a.x = CGFloat(xx)

        let origin = viewport.origin
        a.x -= (origin.x) / scaleValue
        a.y += (origin.y) / scaleValue

        if let image {
            a.x += CGFloat(Float(image.width) * 0.5)
            a.y += CGFloat(Double(image.height) * image.pixelRatio * 0.5)
            a.y /= CGFloat(image.pixelRatio)
        }
        return a
    }

    /// A point of the view, at `scale`, panned by `origin` and turned by
    /// `rotation` degrees, put back where it is without the rotation, for
    /// pixels of spacing `pixelSpacingX` × `pixelSpacingY`
    /// (-positionWithoutRotation:).
    public static func positionWithoutRotation(_ point: CGPoint, scale: Float, origin: CGPoint, rotation: Float,
                                               pixelSpacingX: Double, pixelSpacingY: Double, deg2rad: Double) -> CGPoint {
        var tPt = point
        let scaleValue = CGFloat(scale)
        var unrotatedRect = CGRect(x: tPt.x / scaleValue, y: tPt.y / scaleValue, width: 1, height: 1)
        var centeredRect = unrotatedRect

        var ratio: Float = 1

        if pixelSpacingX != 0 && pixelSpacingY != 0 {
            ratio = Float(pixelSpacingX / pixelSpacingY)
        }

        centeredRect.origin.y -= origin.y * CGFloat(ratio) / scaleValue
        centeredRect.origin.x -= -origin.x / scaleValue

        unrotatedRect.origin.x = centeredRect.origin.x * CGFloat(cos(Double(-rotation) * deg2rad)) + centeredRect.origin.y * CGFloat(sin(Double(-rotation) * deg2rad)) / CGFloat(ratio)
        unrotatedRect.origin.y = -centeredRect.origin.x * CGFloat(sin(Double(-rotation) * deg2rad)) + centeredRect.origin.y * CGFloat(cos(Double(-rotation) * deg2rad)) / CGFloat(ratio)

        unrotatedRect.origin.y *= CGFloat(ratio)

        unrotatedRect.origin.y += origin.y * CGFloat(ratio) / scaleValue
        unrotatedRect.origin.x += -origin.x / scaleValue

        tPt = CGPoint(x: unrotatedRect.origin.x, y: unrotatedRect.origin.y)
        tPt.x = (tPt.x) * scaleValue - unrotatedRect.size.width / 2
        tPt.y = (tPt.y) / CGFloat(ratio) * scaleValue - unrotatedRect.size.height / 2 / CGFloat(ratio)
        return tPt
    }

    /// The affine map from the view's points to the image's that three
    /// converted points give: the origin and the images of the unit vectors
    /// (-viewToPixTransform): m11, m12, m21, m22, m41, m42.
    public static func basisTransform(origin: CGPoint, xBasis: CGPoint, yBasis: CGPoint)
        -> (m11: CGFloat, m12: CGFloat, m21: CGFloat, m22: CGFloat, m41: CGFloat, m42: CGFloat) {
        return (xBasis.x - origin.x, xBasis.y - origin.y, yBasis.x - origin.x, yBasis.y - origin.y, origin.x, origin.y)
    }

    // MARK: - Drawing

    /// The transform the ROIs of a view are drawn with, in the order the
    /// canvas applies it: a scale by (`scaleX`, `scaleY`), a rotation of
    /// `rotation` degrees, a translation by (`translateX`, `translateY`) and
    /// a vertical scale by `pixelRatio` (-applyImageTransformation).
    public struct CanvasTransform: Sendable, Equatable {
        public var scaleX, scaleY, rotation, translateX, translateY, pixelRatio: Double
    }

    public static func canvasTransform(viewport: ViewportState, drawingSize size: CGSize, pixelRatio: Double) -> CanvasTransform {
        return CanvasTransform(scaleX: Double(Float(2.0 / (viewport.xFlipped ? -size.width : size.width))),
                               scaleY: Double(Float(-2.0 / (viewport.yFlipped ? -size.height : size.height))),
                               rotation: Double(viewport.rotation),
                               translateX: Double(Float(viewport.origin.x)), translateY: Double(Float(-viewport.origin.y)),
                               pixelRatio: Double(Float(pixelRatio)))
    }

    // MARK: - Planes

    // Copyright 2001, softSurfer (www.softsurfer.com)
    // This code may be freely used and modified for any purpose
    // providing that this copyright notice is included with it.
    // SoftSurfer makes no warranty for this code, and cannot be held
    // liable for any real or imagined damage resulting from its use.
    // Users of this code must verify correctness for their application.
    //
    // pbase_Plane(): get base of perpendicular from point to a plane
    //    Input:  P = a 3D point
    //            PL = a plane with point V0 and normal n
    //    Output: *B = base point on PL of perpendicular from P
    //    Return: the distance from P to the plane PL
    // (the dot and norm macros of the C: norm = length of vector, the square
    // root of the float dot product computed in double)

    /// The foot of the perpendicular from `point` to the plane through
    /// `planeOrigin` of normal `planeVector`, in `projection`; the distance
    /// from the point to the plane (+pbase_Plane::::).
    public static func planeBase(_ point: UnsafePointer<Float>, _ planeOrigin: UnsafePointer<Float>,
                                 _ planeVector: UnsafePointer<Float>, _ projection: UnsafeMutablePointer<Float>) -> Float {
        var sub = SIMD3<Float>(point[0] - planeOrigin[0], point[1] - planeOrigin[1], point[2] - planeOrigin[2])

        let sn = -(planeVector[0] * sub.x + planeVector[1] * sub.y + planeVector[2] * sub.z)
        let sd = planeVector[0] * planeVector[0] + planeVector[1] * planeVector[1] + planeVector[2] * planeVector[2]
        let sb = sn / sd

        projection[0] = point[0] + sb * planeVector[0]
        projection[1] = point[1] + sb * planeVector[1]
        projection[2] = point[2] + sb * planeVector[2]

        sub = SIMD3(point[0] - projection[0], point[1] - projection[1], point[2] - projection[2])
        return Float(sqrt(Double(sub.x * sub.x + sub.y * sub.y + sub.z * sub.z)))
    }

    /// The angle between two vectors in double precision, in radians; 180°
    /// when only one of them is null, 0 when both are.
    public static func angle(_ v1: UnsafePointer<Double>, _ v2: UnsafePointer<Double>, deg2rad: Double) -> Double {
        if v1[0] == 0 && v1[1] == 0 && v1[2] == 0 && v2[0] == 0 && v2[1] == 0 && v2[2] == 0 {
            return 0
        }
        if v1[0] == 0 && v1[1] == 0 && v1[2] == 0 {
            return deg2rad * 180
        }
        if v2[0] == 0 && v2[1] == 0 && v2[2] == 0 {
            return deg2rad * 180
        }
        func dot(_ u: UnsafePointer<Double>, _ v: UnsafePointer<Double>) -> Double { u[0] * v[0] + u[1] * v[1] + u[2] * v[2] }
        let cosTheta = dot(v1, v2) / (sqrt(dot(v1, v1)) * sqrt(dot(v2, v2)))
        return acos(cosTheta)
    }

    /// Which images a view synchronizes with when they are of several types
    /// (`types`, one per image): those of every type with at least half as
    /// many images as the most common one; nil when there is one type or
    /// none, and every image is kept.
    public static func imagesKeptByType<Type: Hashable>(_ types: [Type]) -> [Bool]? {
        var counts: [Type: Int] = [:]
        for type in types { counts[type, default: 0] += 1 }
        guard counts.count > 1, let maxCount = counts.values.max() else { return nil }
        return types.map { counts[$0, default: 0] >= maxCount / 2 }
    }

    // MARK: - Thick slab

    /// The last image of a thick slab of `stack` images from `current` in a
    /// series of `count`, towards the start when the data is flipped: the
    /// slab stops at the series' end.
    public static func thickSlabLastIndex(current: Int, count: Int, stack: Int, flipped: Bool) -> Int {
        let available = flipped ? current + 1 : count - current
        let slab = stack < available ? stack : available
        return current + (flipped ? -1 : 1) * (slab - 1)
    }

    /// The thickness and the location of a thick slab whose first image is
    /// `thickness` thick at `location` and whose last one is at
    /// `endLocation`: both ends included, the location in the middle. Kept
    /// as they are when a location is not finite.
    public static func thickSlab(thickness: Float, location: Float, endLocation: Double) -> (thickness: Float, location: Float) {
        guard location.isFinite && endLocation.isFinite else { return (thickness, location) }
        return (Float(Double(thickness) + fabs(endLocation - Double(location))), Float((Double(location) + endLocation) / 2.0))
    }
}
