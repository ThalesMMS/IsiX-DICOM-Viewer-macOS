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

/// Linear interpolation for FlyThru: a piecewise linear function on each
/// coordinate, VTK's, through its adapter (IsiXVTKCurve3D). The Objective-C
/// name and selectors are those of the former class.
@objc(Piecewise3D)
public final class Piecewise3D: NSObject, Interpolation3D {
    private let curve = IsiXVTKCurve3D(kind: .piecewiseLinear)

    @objc public override init() {
        super.init()
    }

    @objc(addPoint::)
    public func addPoint(_ t: Float, _ p: Point3D!) {
        do {
            try curve.addPoint(at: Double(t), x: Double(p?.x ?? 0), y: Double(p?.y ?? 0), z: Double(p?.z ?? 0))
        } catch {
            NSLog("Piecewise3D: %@", error.localizedDescription)
        }
    }

    @objc(evaluateAt:)
    public func evaluate(at t: Float) -> Point3D! {
        var point = [Double](repeating: 0, count: 3)
        do {
            try curve.evaluate(at: Double(t), point: &point)
        } catch {
            NSLog("Piecewise3D: %@", error.localizedDescription)
        }
        return Point3D(x: Float(point[0]), y: Float(point[1]), z: Float(point[2]))
    }
}
