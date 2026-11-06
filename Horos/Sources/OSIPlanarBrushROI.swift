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
//  OSIPlanarBrushROI.m
//  OsiriX_Lion
//
//  Created by Joël Spaltenstein on 9/26/11.
//  Copyright 2011 OsiriX Team. All rights reserved.
//

import Cocoa
import IsiXROI


/// The volume ROI of a brush ROI (tPlain): its texture as a one-slice float
/// volume on the plane of the slice it was painted on.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIPlanarBrushROI.h> are those of the former class.
@objc(OSIPlanarBrushROI)
public final class OSIPlanarBrushROI: OSIROI {
    private let _osiriXROI: ROI?
    private var _brushMask: OSIFloatVolumeData?
    private let _plane: N3Plane
    private var _convexHull: [Any]?

    /// The ROI of the brush ROI `roi`, painted on the slice whose pix space
    /// `pixToDICOMTransfrom` carries to patient space; nil for another tool.
    @objc(initWithOsiriXROI:pixToDICOMTransfrom:homeFloatVolumeData:)
    public init?(osiriXROI roi: ROI!, pixToDICOMTransfrom: N3AffineTransform, homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!) {
        _osiriXROI = roi
        _plane = OSIROIVolumeGeometry.roiPlane(pixToDICOM: pixToDICOMTransfrom)
        super.init()
        setHomeFloatVolumeData(floatVolumeData)

        guard let roi, roi.type == .tPlain else {
            return nil
        }
        _convexHull = OSIROIVolumeGeometry.brushHull(left: roi.textureUpLeftCornerX, top: roi.textureUpLeftCornerY,
                                                     right: roi.textureDownRightCornerX, bottom: roi.textureDownRightCornerY,
                                                     pixToDICOM: pixToDICOMTransfrom).map { NSValue(n3Vector: $0) as Any }

        let width = Int(roi.textureWidth), height = Int(roi.textureHeight)
        let byteCount = width * height * MemoryLayout<Float>.size
        let mask = malloc(byteCount)?.assumingMemoryBound(to: Float.self)
        if let mask {
            memset(mask, 0, byteCount)
            VolumeROIMaskVolume.brushIntensities(roi.textureBuffer, width: width, height: height, into: mask)
        }
        let volumeTransform = OSIROIVolumeGeometry.brushVolumeTransform(left: roi.textureUpLeftCornerX, top: roi.textureUpLeftCornerY,
                                                                        pixToDICOM: pixToDICOMTransfrom)
        _brushMask = OSIFloatVolumeData(floatBytesNoCopy: UnsafePointer(mask), pixelsWide: UInt(bitPattern: width), pixelsHigh: UInt(bitPattern: height),
                                        pixelsDeep: 1, volumeTransform: volumeTransform, outOfBoundsValue: 0, freeWhenDone: true)
    }

    @objc(name)
    public override func name() -> String! {
        return _osiriXROI?.name
    }

    @objc(convexHull)
    public override func convexHull() -> [Any]! {
        return _convexHull
    }

    /// The painted voxels in `floatVolume`, whose z direction must be
    /// perpendicular to the ROI's plane: the texture resampled to the slice
    /// the ROI lies on, nearest neighbour.
    @objc(ROIMaskForFloatVolumeData:)
    public override func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! {
        let volumeTransform = floatVolume?.volumeTransform ?? N3AffineTransform()
        // make sure floatVolume's z direction is perpendicular to the plane
        assert(OSIROIVolumeGeometry.isParallelToSlices(_plane, volumeTransform: volumeTransform, tolerance: 0.0001))

        let slice = OSIROIVolumeGeometry.planeSlice(_plane, volumeTransform: volumeTransform)

        let request = CPRObliqueSliceGeneratorRequest()
        request.sliceToDicomTransform = slice.sliceToDicomTransform
        request.pixelsWide = floatVolume?.pixelsWide ?? 0
        request.pixelsHigh = floatVolume?.pixelsHigh ?? 0
        request.interpolationMode = CPRInterpolationMode(CPRInterpolationModeNearestNeighbor.rawValue)

        let volume = CPRGenerator.synchronousRequestVolume(request, volumeData: _brushMask)
        let roiMask = OSIROI.roiMask(fromResampled: volume)

        return roiMask?.roiMaskByTranslatingBy(x: 0, y: 0, z: volumeROIIndex(Double(slice.planePixelPoint.z).rounded()))
    }

    /// The mask's rows in the fill colour, when the slab holds the ROI's plane.
    @objc(drawSlab:dicomToPixTransform:)
    public override func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {
        if OSISlabContainsPlane(slab, _plane) == false {
            return // this ROI does not live on this slice
        }

        var dicomToPixGLTransform = OSIROI.openGLMatrix(dicomToPixTransform)

        ROIGL.pushMatrix()
        ROIGL.multMatrixd(&dicomToPixGLTransform)

        ROIGL.lineWidth(3.0)
        guard let drawColor = self.fillColor()?.usingColorSpace(.genericRGB) else {
            ROIGL.popMatrix()
            return
        }
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)

        // let's try drawing some the mask
        let inverseVolumeTransform = inverseHomeVolumeTransform()
        let mask = roiMask(forFloatVolumeData: homeFloatVolumeData())

        ROIGL.color4f(Float(drawColor.redComponent), Float(drawColor.greenComponent), Float(drawColor.blueComponent), Float(drawColor.alphaComponent))
        OSIROI.drawMaskRunLines(mask?.maskRuns(), inverseVolumeTransform: inverseVolumeTransform)
        ROIGL.disable(ROIGL.blend)

        ROIGL.popMatrix()
    }

    @objc(osiriXROIs)
    public override func osiriXROIs() -> NSSet! {
        return NSSet(object: _osiriXROI!)
    }
}
