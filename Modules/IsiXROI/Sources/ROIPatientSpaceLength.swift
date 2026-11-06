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

/// The plane of one image in patient space: where its first pixel lies, the
/// directions of its rows and columns, and its pixel spacing, in millimetres.
@objc(IsiXROIImagePlane)
public final class ROIImagePlane: NSObject {
    public let origin: (x: Double, y: Double, z: Double)
    /// Image Orientation (Patient): the row direction, then the column direction.
    public let orientation: [Double]
    public let spacingX: Double
    public let spacingY: Double
    public let hasFrameOfReference: Bool

    /// `orientation` holds nine values, of which the first six are the row and
    /// column directions; nil stands for an unknown orientation.
    @objc(initWithOriginX:y:z:orientation:spacingX:spacingY:hasFrameOfReference:)
    public init(originX: Double, y originY: Double, z originZ: Double, orientation: UnsafePointer<Double>?,
                spacingX: Double, spacingY: Double, hasFrameOfReference: Bool) {
        self.origin = (originX, originY, originZ)
        self.orientation = orientation.map { Array(UnsafeBufferPointer(start: $0, count: 9)) } ?? Array(repeating: .nan, count: 9)
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.hasFrameOfReference = hasFrameOfReference
    }

    /// Whether a length can be measured on it: a positive finite spacing, a
    /// frame of reference, orthonormal row and column directions, a finite origin.
    @objc public var isValid: Bool {
        guard spacingX.isFinite, spacingY.isFinite, spacingX > 0, spacingY > 0, hasFrameOfReference else { return false }
        let o = orientation
        guard o.allSatisfy({ $0.isFinite }) else { return false }
        var row = 0.0, column = 0.0, dot = 0.0
        for i in 0..<3 {
            row = row.addingProduct(o[i], o[i])
            column = column.addingProduct(o[i + 3], o[i + 3])
            dot = dot.addingProduct(o[i], o[i + 3])
        }
        return abs(row - 1) < 1e-4 && abs(column - 1) < 1e-4 && abs(dot) < 1e-4
            && origin.x.isFinite && origin.y.isFinite && origin.z.isFinite
    }

    /// The patient-space position, x y z in millimetres, of an image point in
    /// pixels; nil on an invalid plane or a point that is not finite.
    @objc(patientPointOf:)
    public func patientPoint(of point: CGPoint) -> [NSNumber]? {
        guard isValid, point.x.isFinite, point.y.isFinite else { return nil }
        let o = orientation
        let u = point.x * spacingX, v = point.y * spacingY
        return [NSNumber(value: origin.x.addingProduct(u, o[0]).addingProduct(v, o[3])),
                NSNumber(value: origin.y.addingProduct(u, o[1]).addingProduct(v, o[4])),
                NSNumber(value: origin.z.addingProduct(u, o[2]).addingProduct(v, o[5]))]
    }

    /// The image point, in pixels, a patient-space position projects on, and
    /// in `depth` its signed distance from the plane in millimetres. The normal
    /// is derived from the orientation, not from a cached normal.
    @objc(projectPatientPoint:depth:)
    public func project(_ patient: NSArray, depth: UnsafeMutablePointer<Double>?) -> CGPoint {
        let o = orientation
        let d = [ROIImagePlane.coordinate(patient, 0) - origin.x, ROIImagePlane.coordinate(patient, 1) - origin.y,
                 ROIImagePlane.coordinate(patient, 2) - origin.z]
        let n = [(-(o[2] * o[4])).addingProduct(o[1], o[5]),
                 (-(o[0] * o[5])).addingProduct(o[2], o[3]),
                 (-(o[1] * o[3])).addingProduct(o[0], o[4])]
        depth?.pointee = ROIImagePlane.dot(d, n[0], n[1], n[2])
        return CGPoint(x: ROIImagePlane.dot(d, o[0], o[1], o[2]) / spacingX,
                       y: ROIImagePlane.dot(d, o[3], o[4], o[5]) / spacingY)
    }

    /// `-doubleValue` of a number or a string at `i`; 0 for anything else.
    static func coordinate(_ values: NSArray?, _ i: Int) -> Double {
        guard let values, i < values.count else { return 0 }
        return (values[i] as? NSNumber)?.doubleValue ?? (values[i] as? NSString)?.doubleValue ?? 0
    }

    /// `d[0]*a + d[1]*b + d[2]*c`, fused as the Objective-C compiler fused it.
    private static func dot(_ d: [Double], _ a: Double, _ b: Double, _ c: Double) -> Double {
        (d[1] * b).addingProduct(d[0], a).addingProduct(d[2], c)
    }
}

/// How a patient-space line shows on an image: where its ends project, which
/// of them lie on the image's slab and can be dragged, and where it crosses
/// the image plane.
@objc(IsiXROIPlaneCrossing)
@objcMembers
public final class ROIPlaneCrossing: NSObject {
    public private(set) var visible = false
    public private(set) var a = CGPoint.zero
    public private(set) var b = CGPoint.zero
    public private(set) var intersection = CGPoint.zero
    public private(set) var handleA = false
    public private(set) var handleB = false
    public private(set) var crossesPlane = false

    /// The ends `a` and `b` project at depths `depthA` and `depthB`; the slab
    /// shown runs from `lower` to `upper`, and a single slice is `half` thick
    /// on each side. A thick slab (`stacked`) clips the line to it and has no
    /// handles. Nothing is visible when the line misses the slab.
    @objc(initWithA:b:depthA:depthB:half:lower:upper:stacked:)
    public init(a: CGPoint, b: CGPoint, depthA: Double, depthB: Double, half: Double, lower: Double, upper: Double, stacked: Bool) {
        super.init()
        if max(depthA, depthB) < lower || min(depthA, depthB) > upper { return }
        visible = true
        self.a = a
        self.b = b
        handleA = !stacked && abs(depthA) <= half
        handleB = !stacked && abs(depthB) <= half
        let span = depthB - depthA
        if abs(span) > 1e-9 {
            let t = -depthA / span
            crossesPlane = t >= 0 && t <= 1
            intersection = ROIPlaneCrossing.point(a, b, t)
            if stacked {
                let t0 = (lower - depthA) / span, t1 = (upper - depthA) / span
                let start = max(0, min(t0, t1)), end = min(1, max(t0, t1))
                self.a = ROIPlaneCrossing.point(a, b, start)
                self.b = ROIPlaneCrossing.point(a, b, end)
            }
        }
    }

    private static func point(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x.addingProduct(t, b.x - a.x), y: a.y.addingProduct(t, b.y - a.y))
    }
}

/// The persisted form of a length measured in patient space, across slices:
/// `{version: 1, id, series, frameOfReference, a: [x, y, z], b: [x, y, z], ...}`
/// in millimetres, as ROI archives and the JSON interchange carry it.
@objc(IsiXROIPatientSpaceLength)
public final class ROIPatientSpaceLength: NSObject {
    /// Whether `payload` is a version 1 length with its identifiers and two
    /// distinct finite ends.
    @objc(isValidPayload:)
    public static func isValid(payload: Any?) -> Bool {
        guard let payload = payload as? NSDictionary, integer(payload["version"]) == 1 else { return false }
        for key in ["id", "series", "frameOfReference"] {
            guard let value = payload[key] as? NSString, value.length > 0 else { return false }
        }
        for key in ["a", "b"] {
            guard let end = payload[key] as? NSArray, end.count == 3 else { return false }
            for value in end {
                guard let number = value as? NSNumber, number.doubleValue.isFinite else { return false }
            }
        }
        let sum = squaredDistance(payload)
        return sum.isFinite && sum > 1e-12
    }

    /// The distance between the ends, in millimetres.
    @objc(distanceOfPayload:)
    public static func distance(ofPayload payload: NSDictionary) -> Double {
        squaredDistance(payload).squareRoot()
    }

    private static func squaredDistance(_ payload: NSDictionary) -> Double {
        let a = payload["a"] as? NSArray, b = payload["b"] as? NSArray
        var sum = 0.0
        for i in 0..<3 {
            let d = ROIImagePlane.coordinate(a, i) - ROIImagePlane.coordinate(b, i)
            sum = sum.addingProduct(d, d)
        }
        return sum
    }

    /// `-integerValue` of a number or a string; 0 for anything else.
    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? (value as? NSString)?.integerValue ?? 0
    }
}
