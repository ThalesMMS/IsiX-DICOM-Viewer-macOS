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
import IsiXVolumeRendering

/// Spline interpolation for FlyThru: a cardinal spline on each coordinate,
/// VTK's, through its adapter (IsiXVTKCurve3D). The coefficients are computed
/// at the first evaluation, or by `compute`. The Objective-C name and
/// selectors are those of the former class.
@objc(Spline3D)
public final class Spline3D: NSObject, Interpolation3D, FlyPathSpline {
    private let curve = IsiXVTKCurve3D(kind: .cardinalSpline)
    private var computed = false

    @objc public override init() {
        super.init()
    }

    @objc(addPoint::)
    public func addPoint(_ t: Float, _ p: Point3D!) {
        add(t, p?.x ?? 0, p?.y ?? 0, p?.z ?? 0)
    }

    @objc public func compute() {
        do {
            try curve.compute()
        } catch {
            NSLog("Spline3D: %@", error.localizedDescription)
        }
        computed = true
    }

    @objc(evaluateAt:)
    public func evaluate(at t: Float) -> Point3D! {
        let p = value(t)
        return Point3D(x: p.x, y: p.y, z: p.z)
    }

    // The endoscopy's centerline (FlyPathSpline).
    public func addPoint(_ t: Float, _ point: SIMD3<Float>) {
        add(t, point.x, point.y, point.z)
    }

    public func evaluate(_ t: Float) -> SIMD3<Float> {
        value(t)
    }

    private func add(_ t: Float, _ x: Float, _ y: Float, _ z: Float) {
        do {
            try curve.addPoint(at: Double(t), x: Double(x), y: Double(y), z: Double(z))
        } catch {
            NSLog("Spline3D: %@", error.localizedDescription)
        }
    }

    /// The spline at t, each coordinate rounded to float as the former class did.
    private func value(_ t: Float) -> SIMD3<Float> {
        if !computed { compute() }
        var point = [Double](repeating: 0, count: 3)
        do {
            try curve.evaluate(at: Double(t), point: &point)
        } catch {
            NSLog("Spline3D: %@", error.localizedDescription)
        }
        return SIMD3(Float(point[0]), Float(point[1]), Float(point[2]))
    }
}
