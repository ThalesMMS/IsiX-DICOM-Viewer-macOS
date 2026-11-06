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
//
//  OSIPathExtrusionROI.m
//  OsiriX_Lion
//
//  Created by Joël Spaltenstein on 10/4/12.
//  Copyright (c) 2012 OsiriX Team. All rights reserved.
//

import Cocoa


/// A volume ROI made from a path extruded through a slab, with a name,
/// colours and a stroke of its own.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIPathExtrusionROI.h> are those of the former class. The hull and
/// the mask are made by OSIROIVolumeGeometry, from IsiXROI's rules.
@objc(OSIPathExtrusionROI)
public final class OSIPathExtrusionROI: OSIROI {
    private var _path: N3BezierPath?
    private var _slab = OSISlab()
    private var _name: String?
    private var _fillColor: NSColor?
    private var _strokeColor: NSColor?
    private var _strokeThickness: CGFloat = 0

    @objc(initWith:slab:homeFloatVolumeData:name:)
    public init(_ path: N3BezierPath!, slab: OSISlab, homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!, name: String!) {
        super.init()
        setHomeFloatVolumeData(floatVolumeData)
        _path = path
        _slab = slab
        _name = name
        _strokeThickness = 1
    }

    @objc(bezierPath)
    public override func bezierPath() -> N3BezierPath! {
        return _path
    }

    @objc(name)
    public override func name() -> String! {
        return _name
    }

    @objc(fillColor)
    public override func fillColor() -> NSColor! {
        return _fillColor
    }

    @objc(setFillColor:)
    public override func setFillColor(_ color: NSColor!) {
        _fillColor = color
    }

    @objc(strokeColor)
    public override func strokeColor() -> NSColor! {
        return _strokeColor
    }

    @objc(setStrokeColor:)
    public override func setStrokeColor(_ color: NSColor!) {
        _strokeColor = color
    }

    @objc(strokeThickness)
    public override func strokeThickness() -> CGFloat {
        return _strokeThickness
    }

    @objc(setStrokeThickness:)
    public override func setStrokeThickness(_ strokeThickness: CGFloat) {
        _strokeThickness = strokeThickness
    }

    /// The path's points moved half the slab's normal each way.
    @objc(convexHull)
    public override func convexHull() -> [Any]! {
        return OSIROIVolumeGeometry.extrusionHull(of: _path, normal: _slab.plane.normal).map { NSValue(n3Vector: $0) as Any }
    }

    /// The voxels inside the path on every slice of `floatVolume` the slab
    /// covers; the volume's z direction must be the slab's normal.
    @objc(ROIMaskForFloatVolumeData:)
    public override func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! { // BS Implementation, need to make this work everywhere!
        let volumeTransform = floatVolume?.volumeTransform ?? N3AffineTransform()
        // make sure floatVolume's z direction is perpendicular to the plane
        assert(N3VectorLength(N3VectorCrossProduct(OSIROIVolumeGeometry.extrusionAxis(of: _slab, volumeTransform: volumeTransform),
                                                   N3VectorMake(0, 0, 1))) < 0.01)

        guard let runs = OSIROIVolumeGeometry.extrudedRuns(of: _path, slab: _slab, volumeTransform: volumeTransform,
                                                           pixelsWide: Int(bitPattern: floatVolume?.pixelsWide ?? 0),
                                                           pixelsHigh: Int(bitPattern: floatVolume?.pixelsHigh ?? 0),
                                                           pixelsDeep: Int(bitPattern: floatVolume?.pixelsDeep ?? 0)) else {
            return OSIROIMask(maskRuns: NSArray())
        }
        let runData = runs.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<OSIROIMaskRun>.size) }
        return OSIROIMask(maskRunData: runData)
    }

    /// The path in the stroke colour and thickness, when it has both.
    @objc(drawSlab:dicomToPixTransform:)
    public override func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {
        let deviceStrokeColor = self.strokeColor()?.usingColorSpace(.genericRGB)

        if self.strokeThickness() != 0 && self.strokeColor() != nil {
            var dicomToPixGLTransform = OSIROI.openGLMatrix(dicomToPixTransform)

            ROIGL.enable(ROIGL.lineSmooth)
            ROIGL.enable(ROIGL.polygonSmooth)
            ROIGL.enable(ROIGL.blend)
            ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)

            ROIGL.lineWidth(Float(self.strokeThickness()))
            ROIGL.color4f(Float(deviceStrokeColor?.redComponent ?? 0), Float(deviceStrokeColor?.greenComponent ?? 0), Float(deviceStrokeColor?.blueComponent ?? 0), Float(deviceStrokeColor?.alphaComponent ?? 0))

            ROIGL.pushMatrix()
            ROIGL.multMatrixd(&dicomToPixGLTransform)

            OSIROI.drawLineStrip(_path)

            ROIGL.popMatrix()

            ROIGL.disable(ROIGL.lineSmooth)
            ROIGL.disable(ROIGL.polygonSmooth)
            ROIGL.disable(ROIGL.pointSmooth)
            ROIGL.disable(ROIGL.blend)
        }
    }
}
