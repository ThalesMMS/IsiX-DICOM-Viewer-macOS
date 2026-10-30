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


/// One volume ROI for the planar ROIs of one name on the slices of a volume
/// (OSIROIManager coalesces them): their masks merged in a volume around
/// their hulls, which a slab is resampled from to draw it.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSICoalescedPlanarROI.h> are those of the former class. The boxes
/// are made by OSIROIVolumeGeometry, from IsiXROI's rules.
@objc(OSICoalescedPlanarROI)
public final class OSICoalescedPlanarROI: OSIROI {
    private let _sourceROIs: [Any]
    private var _coalescedROIMaskVolumeData: OSIFloatVolumeData?
    private var _cachedSlab = OSISlab()
    private var _cachedDicomToPixTransform = N3AffineTransform()
    private var _cachedMinCorner = N3VectorZero
    private var _cachedMaskRunsData: NSData?

    @objc(initWithSourceROIs:homeFloatVolumeData:)
    public init(sourceROIs rois: [Any]!, homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!) {
        _sourceROIs = rois ?? []
        super.init()
        setHomeFloatVolumeData(floatVolumeData)
    }

    /// The planar ROIs this ROI stands for.
    @objc(sourceROIs)
    public var sourceROIs: [Any]! {
        return _sourceROIs
    }

    private var sources: [OSIROI] {
        return _sourceROIs.compactMap { $0 as? OSIROI }
    }

    @objc(name)
    public override func name() -> String! {
        if _sourceROIs.count > 0 {
            return (_sourceROIs[0] as? OSIROI)?.name()
        }
        return nil
    }

    @objc(convexHull)
    public override func convexHull() -> [Any]! {
        return sources.flatMap { $0.convexHull() ?? [] }
    }

    /// The runs of every source ROI in the home volume. The volume asked for
    /// is not used while there is a home volume, as before; without one, the
    /// merged volume is resampled to an empty request.
    @objc(ROIMaskForFloatVolumeData:)
    public override func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! {
        if let home = homeFloatVolumeData() {
            let maskRuns = NSMutableArray()
            for roi in sources {
                maskRuns.addObjects(from: (roi.roiMask(forFloatVolumeData: home)?.maskRuns() as? [Any]) ?? [])
            }
            return OSIROIMask(maskRuns: maskRuns)
        }
        // we need to create a
        let coalescedROIMaskVolume = coalescedROIMaskVolumeData()

        let sliceRequest = CPRObliqueSliceGeneratorRequest()
        sliceRequest.pixelsWide = 0
        sliceRequest.pixelsHigh = 0
        sliceRequest.slabSampleDistance = 0
        sliceRequest.slabWidth = 0
        sliceRequest.sliceToDicomTransform = OSIROIVolumeGeometry.wholeVolumeSliceToDicom(volumeTransform: N3AffineTransform(), pixelsDeep: 0)

        let resampledVolume = CPRGenerator.synchronousRequestVolume(sliceRequest, volumeData: coalescedROIMaskVolume)

        assert((resampledVolume?.pixelsWide ?? 0) == 0)
        assert((resampledVolume?.pixelsHigh ?? 0) == 0)
        assert((resampledVolume?.pixelsDeep ?? 0) == 0)

        return OSIROI.roiMask(fromResampled: resampledVolume)
    }

    @objc(osiriXROIs)
    public override func osiriXROIs() -> NSSet! {
        let osirixROIs = NSMutableSet(capacity: _sourceROIs.count)
        for roi in sources {
            osirixROIs.addObjects(from: roi.osiriXROIs()?.allObjects ?? [])
        }
        return osirixROIs
    }

    /// The home volume of the receiver and of every source ROI.
    @objc(setHomeFloatVolumeData:)
    public override func setHomeFloatVolumeData(_ homeFloatVolumeData: OSIFloatVolumeData!) {
        for roi in sources {
            roi.setHomeFloatVolumeData(homeFloatVolumeData)
        }
        super.setHomeFloatVolumeData(homeFloatVolumeData)
    }

    /// The merged volume resampled through the slab (its maximum), drawn as
    /// one quad per run in the fill colour, the stroke's when there is none.
    @objc(drawSlab:dicomToPixTransform:)
    public override func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {
        let maskRunsData: NSData?
        let minCorner: N3Vector

        if let cached = _cachedMaskRunsData, OSISlabEqualTo(slab, _cachedSlab),
           N3AffineTransformEqualToTransform(dicomToPixTransform, _cachedDicomToPixTransform) {
            maskRunsData = cached
            minCorner = _cachedMinCorner
        } else {
            let picture = slabPictureRuns(for: slab, dicomToPixTransform: dicomToPixTransform)
            _cachedMaskRunsData = picture.maskRunsData
            _cachedMinCorner = picture.minCorner
            _cachedSlab = slab
            _cachedDicomToPixTransform = dicomToPixTransform
            maskRunsData = _cachedMaskRunsData
            minCorner = _cachedMinCorner
        }

        ROIGL.lineWidth(3.0)
        guard let drawColor = self.fillColor()?.usingColorSpace(.genericRGB) ?? self.strokeColor()?.usingColorSpace(.genericRGB) else {
            return
        }
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)
        ROIGL.color4f(Float(drawColor.redComponent), Float(drawColor.greenComponent), Float(drawColor.blueComponent), Float(drawColor.alphaComponent))
        ROIGL.begin(ROIGL.quads)
        let runsCount = (maskRunsData?.length ?? 0) / MemoryLayout<OSIROIMaskRun>.size
        let maskRunsBytes = maskRunsData?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
        for i in 0..<runsCount {
            let maskRun = maskRunsBytes![i]
            let widthIndex = Double(maskRun.widthRange.location) + Double(minCorner.x)
            let maxWidthIndex = widthIndex + Double(maskRun.widthRange.length)
            let heightIndex = Double(maskRun.heightIndex) + Double(minCorner.y)
            let depthIndex = Double(maskRun.depthIndex)

            ROIGL.vertex3d(widthIndex, heightIndex, depthIndex)
            ROIGL.vertex3d(maxWidthIndex, heightIndex, depthIndex)
            ROIGL.vertex3d(maxWidthIndex, heightIndex + 1.0, depthIndex)
            ROIGL.vertex3d(widthIndex, heightIndex + 1.0, depthIndex)
        }
        ROIGL.end()
        ROIGL.disable(ROIGL.blend)
    }

    /// The source ROIs' masks merged (each voxel its largest intensity) in a
    /// volume around their hulls, aligned with the home volume; made once.
    private func coalescedROIMaskVolumeData() -> OSIFloatVolumeData? {
        if _coalescedROIMaskVolumeData == nil {
            let hull = sources.flatMap { ($0.convexHull() ?? []).map { ($0 as! NSValue).n3VectorValue() } }
            let box = OSIROIVolumeGeometry.coalescedVolume(hull: hull,
                                                           volumeTransform: homeFloatVolumeData()?.volumeTransform ?? N3AffineTransform())
            // A group with no hull has no box (the former code allocated a negative size).
            let sized = box.width > 0 && box.height > 0 && box.depth > 0
            let width = sized ? box.width : 0, height = sized ? box.height : 0, depth = sized ? box.depth : 0
            let count = width * height * depth
            let bytes = malloc(count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
            if let bytes {
                memset(bytes, 0, count * MemoryLayout<Float>.size)
            }
            let volume = OSIFloatVolumeData(floatBytesNoCopy: UnsafePointer(bytes), pixelsWide: UInt(width), pixelsHigh: UInt(height), pixelsDeep: UInt(depth),
                                            volumeTransform: box.volumeTransform, outOfBoundsValue: 0, freeWhenDone: true)
            _coalescedROIMaskVolumeData = volume

            for roi in sources {
                let coalescedMask = roi.roiMask(forFloatVolumeData: volume)
                assert(volume.checkDebugROIMask(coalescedMask))
                let runs = (coalescedMask?.maskRuns() ?? NSArray()).map { value -> (location: Int, length: Int, row: Int, slice: Int, intensity: Float) in
                    let run = (value as! NSValue).osiroiMaskRun()
                    return (run.widthRange.location, run.widthRange.length,
                            Int(bitPattern: run.heightIndex), Int(bitPattern: run.depthIndex), run.intensity)
                }
                if let bytes {
                    VolumeROIMaskVolume.mergeMaximum(runs, into: bytes, width: width, height: height, count: count)
                }
            }
        }

        return _coalescedROIMaskVolumeData
    }

    /// The merged volume resampled through `slab` (maximum intensity) in a
    /// picture of the view's pix space: its runs, and the picture's corner.
    private func slabPictureRuns(for slab: OSISlab, dicomToPixTransform: N3AffineTransform) -> (maskRunsData: NSData?, minCorner: N3Vector) {
        let volume = coalescedROIMaskVolumeData()
        let picture = OSIROIVolumeGeometry.slabPicture(volumeTransform: volume?.volumeTransform ?? N3AffineTransform(),
                                                       width: Int(bitPattern: volume?.pixelsWide ?? 0),
                                                       height: Int(bitPattern: volume?.pixelsHigh ?? 0),
                                                       depth: Int(bitPattern: volume?.pixelsDeep ?? 0),
                                                       dicomToPixTransform: dicomToPixTransform)

        let sliceRequest = CPRObliqueSliceGeneratorRequest()
        sliceRequest.pixelsWide = UInt(bitPattern: picture.width)
        sliceRequest.pixelsHigh = UInt(bitPattern: picture.height)
        sliceRequest.slabWidth = slab.thickness
        sliceRequest.projectionMode = CPRProjectionMode(CPRProjectionModeMIP.rawValue)
        sliceRequest.sliceToDicomTransform = picture.sliceToDicomTransform

        let floatVolumeData = CPRGenerator.synchronousRequestVolume(sliceRequest, volumeData: volume)
        let sliceMask = OSIROI.roiMask(fromResampled: floatVolumeData)

        return (sliceMask?.maskRunsData(), picture.minCorner)
    }
}
