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

import Cocoa
import IsiXROI


/// The volume ROI of an outlined 2D ROI (a measure, a polygon, an oval, a
/// pencil or a traced ROI): its outline on the plane of the slice it was
/// drawn on, in patient space.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIPlanarPathROI.h> are those of the former class. The outline and
/// its mask are made by OSIROIVolumeGeometry, from IsiXROI's rules.
@objc(OSIPlanarPathROI)
public final class OSIPlanarPathROI: OSIROI {
    private let _osiriXROI: ROI?
    private var _bezierPath: N3MutableBezierPath?
    private let _plane: N3Plane

    /// The ROI of `roi`, an outlined 2D ROI drawn on the slice whose pix
    /// space `pixToDICOMTransfrom` carries to patient space; nil for another
    /// tool, a measure of fewer than two points or an empty traced ROI.
    @objc(initWithOsiriXROI:pixToDICOMTransfrom:homeFloatVolumeData:)
    public init?(osiriXROI roi: ROI!, pixToDICOMTransfrom: N3AffineTransform, homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!) {
        _osiriXROI = roi
        _plane = OSIROIVolumeGeometry.roiPlane(pixToDICOM: pixToDICOMTransfrom)
        super.init()
        setHomeFloatVolumeData(floatVolumeData)

        let points = (roi?.points as? [MyPoint] ?? []).map { $0.point }
        let kind: VolumeROIOutline.Kind
        switch roi?.type {
        case .tMesure?: kind = .measure
        case .tOPolygon?: kind = .openPolygon
        case .tCPolygon?: kind = .closedPolygon
        case .tOval?: kind = .oval
        case .tPencil?: kind = .pencil
        case .tROI?: kind = .traced
        default: kind = .other
        }
        // An oval whose first two points are one is a one-pixel square.
        let firstTwoCoincide = kind == .oval && points.count >= 2 && (roi.points[0] as! MyPoint).isEqual(to: points[1])
        guard let path = OSIROIVolumeGeometry.planarOutline(kind: kind, points: points, firstTwoCoincide: firstTwoCoincide,
                                                           pixToDICOM: pixToDICOMTransfrom) else {
            return nil
        }
        _bezierPath = path
    }

    @objc(name)
    public override func name() -> String! {
        return _osiriXROI?.name
    }

    @objc(convexHull)
    public override func convexHull() -> [Any]! {
        return OSIROIVolumeGeometry.hull(of: _bezierPath).map { NSValue(n3Vector: $0) as Any }
    }

    /// The voxels inside the outline in `floatVolume`, whose z direction must
    /// be perpendicular to the ROI's plane: the slice the ROI lies on, row by row.
    @objc(ROIMaskForFloatVolumeData:)
    public override func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! {
        let volumeTransform = floatVolume?.volumeTransform ?? N3AffineTransform()
        // make sure floatVolume's z direction is perpendicular to the plane
        assert(OSIROIVolumeGeometry.isParallelToSlices(_plane, volumeTransform: volumeTransform, tolerance: 0.0001))

        guard let runs = OSIROIVolumeGeometry.planarRuns(of: _bezierPath, volumeTransform: volumeTransform,
                                                         pixelsWide: Int(bitPattern: floatVolume?.pixelsWide ?? 0),
                                                         pixelsHigh: Int(bitPattern: floatVolume?.pixelsHigh ?? 0),
                                                         pixelsDeep: Int(bitPattern: floatVolume?.pixelsDeep ?? 0)) else {
            return OSIROIMask(maskRuns: NSArray())
        }
        return OSIROIMask(maskRuns: runs.map { NSValue(osiroiMaskRun: $0) as Any } as NSArray)
    }

    @objc(bezierPath)
    public override func bezierPath() -> N3BezierPath! {
        return _bezierPath
    }

    @objc(osiriXROIs)
    public override func osiriXROIs() -> NSSet! {
        return NSSet(object: _osiriXROI!)
    }

    /// The outline in the stroke colour, and its mask's rows in the fill
    /// colour (the stroke's when there is none), when the slab holds the ROI's plane.
    @objc(drawSlab:dicomToPixTransform:)
    public override func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {
        if OSISlabContainsPlane(slab, _plane) == false {
            return // this ROI does not live on this slice
        }

        var dicomToPixGLTransform = OSIROI.openGLMatrix(dicomToPixTransform)

        ROIGL.pushMatrix()
        ROIGL.multMatrixd(&dicomToPixGLTransform)

        ROIGL.lineWidth(3.0)
        guard let drawColor = self.strokeColor()?.usingColorSpace(.genericRGB) else {
            ROIGL.popMatrix()
            return
        }
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)
        ROIGL.color4f(Float(drawColor.redComponent), Float(drawColor.greenComponent), Float(drawColor.blueComponent), Float(drawColor.alphaComponent))
        OSIROI.drawLineStrip(_bezierPath)

        // let's try drawing some the mask
        let inverseVolumeTransform = inverseHomeVolumeTransform()
        let mask = roiMask(forFloatVolumeData: homeFloatVolumeData())

        let maskColor = self.fillColor()?.usingColorSpace(.genericRGB) ?? drawColor
        ROIGL.color4f(Float(maskColor.redComponent), Float(maskColor.greenComponent), Float(maskColor.blueComponent), Float(maskColor.alphaComponent))
        OSIROI.drawMaskRunLines(mask?.maskRuns(), inverseVolumeTransform: inverseVolumeTransform)
        ROIGL.disable(ROIGL.blend)

        ROIGL.popMatrix()
    }
}
