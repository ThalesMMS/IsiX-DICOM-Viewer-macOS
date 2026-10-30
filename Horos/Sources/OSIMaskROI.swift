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
//  OSIMaskROI.m
//  OsiriX_Lion
//
//  Created by Joël Spaltenstein on 9/26/12.
//  Copyright (c) 2012 OsiriX Team. All rights reserved.
//

import Cocoa


/// A volume ROI made from a mask of its home volume, with a name and a fill
/// colour of its own.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIMaskROI.h> are those of the former class.
@objc(OSIMaskROI)
public final class OSIMaskROI: OSIROI {
    private var _mask: OSIROIMask?
    private var _name: String?
    private var _fillColor: NSColor?

    @objc(initWithROIMask:homeFloatVolumeData:name:)
    public init(roiMask mask: OSIROIMask!, homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!, name: String!) {
        super.init()
        setHomeFloatVolumeData(floatVolumeData)
        _mask = mask
        _name = name
    }

    /// The voxels of the ROI in its home volume.
    @objc(mask)
    public var mask: OSIROIMask! {
        return _mask
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

    /// The corners of the mask's box in patient space, as every OSIROI gives
    /// its hull: a group of ROIs builds the box it merges them in from it.
    @objc(convexHull)
    public override func convexHull() -> [Any]! {
        guard let corners = mask?.convexHull() as? [NSValue] else { return nil }
        return OSIROIVolumeGeometry.maskHull(corners.map { $0.n3VectorValue() },
                                             inverseVolumeTransform: inverseHomeVolumeTransform()).map { NSValue(n3Vector: $0)! as Any }
    }

    /// The mask in `floatVolume`. It belongs to the home volume, and is the
    /// answer for it. A volume on the same grid, whole voxels away, such as the
    /// box a group of ROIs is merged in, gets its voxels at the same places,
    /// cut to its extent. The mask cannot be resampled to a volume on any other
    /// grid, which gets an empty mask.
    @objc(ROIMaskForFloatVolumeData:)
    public override func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! {
        guard let floatVolume, let home = homeFloatVolumeData(), floatVolume !== home else {
            return mask
        }
        let runs = (mask?.maskRuns() as? [NSValue] ?? []).map { $0.osiroiMaskRun() }
        let moved = OSIROIVolumeGeometry.maskRuns(runs, from: home.volumeTransform, to: floatVolume.volumeTransform,
                                                  width: Int(floatVolume.pixelsWide), height: Int(floatVolume.pixelsHigh),
                                                  depth: Int(floatVolume.pixelsDeep)) ?? []
        return OSIROIMask(maskRuns: moved.map { NSValue(osiroiMaskRun: $0)! } as NSArray)
    }

    /// Each voxel row of the mask the slab holds, filled in the fill colour.
    @objc(drawSlab:dicomToPixTransform:)
    public override func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {
        if self.fillColor() == nil {
            return
        }

        let deviceColor = self.fillColor().usingColorSpace(.genericRGB)

        var dicomToPixGLTransform = OSIROI.openGLMatrix(dicomToPixTransform)

        ROIGL.enable(ROIGL.pointSmooth)
        ROIGL.enable(ROIGL.lineSmooth)
        ROIGL.enable(ROIGL.polygonSmooth)
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)

        ROIGL.pushMatrix()
        ROIGL.multMatrixd(&dicomToPixGLTransform)

        ROIGL.lineWidth(3.0)

        // let's try drawing the mask
        let inverseVolumeTransform = inverseHomeVolumeTransform()
        let mask = roiMask(forFloatVolumeData: homeFloatVolumeData())

        ROIGL.color4f(Float(deviceColor?.redComponent ?? 0), Float(deviceColor?.greenComponent ?? 0), Float(deviceColor?.blueComponent ?? 0), Float(deviceColor?.alphaComponent ?? 0))
        for case let maskRunValue as NSValue in mask?.maskRuns() ?? NSArray() {
            let maskRun = maskRunValue.osiroiMaskRun()
            let left = CGFloat(maskRun.widthRange.location), right = CGFloat(NSMaxRange(maskRun.widthRange))
            let row = CGFloat(maskRun.heightIndex), slice = CGFloat(maskRun.depthIndex)

            let quad1 = N3VectorApplyTransform(N3VectorMake(left, row, slice), inverseVolumeTransform)
            let quad2 = N3VectorApplyTransform(N3VectorMake(left, row + 1.0, slice), inverseVolumeTransform)
            let quad3 = N3VectorApplyTransform(N3VectorMake(right, row, slice), inverseVolumeTransform)
            let quad4 = N3VectorApplyTransform(N3VectorMake(right, row + 1.0, slice), inverseVolumeTransform)

            if OSISlabContainsVector(slab, quad1) && OSISlabContainsVector(slab, quad2) && OSISlabContainsVector(slab, quad3) && OSISlabContainsVector(slab, quad4) {
                ROIGL.begin(ROIGL.triangleStrip)
                ROIGL.vertex3d(Double(quad1.x), Double(quad1.y), Double(quad1.z))
                ROIGL.vertex3d(Double(quad2.x), Double(quad2.y), Double(quad2.z))
                ROIGL.vertex3d(Double(quad3.x), Double(quad3.y), Double(quad3.z))
                ROIGL.vertex3d(Double(quad4.x), Double(quad4.y), Double(quad4.z))
                ROIGL.end()
            }
        }

        ROIGL.popMatrix()

        ROIGL.disable(ROIGL.lineSmooth)
        ROIGL.disable(ROIGL.polygonSmooth)
        ROIGL.disable(ROIGL.pointSmooth)
        ROIGL.disable(ROIGL.blend)
    }
}
