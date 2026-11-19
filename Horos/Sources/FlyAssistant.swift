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

/*=========================================================================
 Author: Chunliang Wang (chunliang.wang@liu.se)
 
 
 Program:  FLy Through Assistant And Centerline tracking for CT endoscopy
 
 This file is part of FLy Through Assistant And Centerline tracking for CT endoscopy.
 
 Copyright (c) 2010,
 Center for Medical Image Science and Visualization (CMIV),
 Linköping University, Sweden, http://www.cmiv.liu.se/
 
 FLy Through Assistant And Centerline tracking for CT endoscopy is free software;
 you can redistribute it and/or modify it under the terms of the
 GNU General Public License as published by the Free Software 
 Foundation, either version 3 of the License, or (at your option)
 any later version.
 
 FLy Through Assistant And Centerline tracking for CT endoscopy  is distributed in
 the hope that it will be useful, but WITHOUT ANY WARRANTY; 
 without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 
 =========================================================================*/


import Foundation
import IsiXVolumeRendering

/// The fly-through assistant of the endoscopy (and of plugins that kept the
/// class), in the points and arrays its callers keep: Point3D and OSIVoxel, in
/// input voxels. The curved MPR traces with VesselPathAssistant instead.
/// The work is IsiXVolumeRendering's FlyPathAssistant; the smoothing of a
/// centerline takes VTK's cardinal spline through Spline3D. The Objective-C
/// name and selectors are those of the former class; the error codes are
/// FlyAssistant.h's ERROR_NOENOUGHMEM, ERROR_CANNOTFINDPATH and
/// ERROR_DISTTRANSNOTFINISH.
@objc(FlyAssistant)
public final class FlyAssistant: NSObject, @unchecked Sendable {
    let core: FlyPathAssistant

    // The instance variables of the former Horos and OsiriX plugin SDK, each
    // with the type its header declared: a plugin reads them at the exported
    // offset. The assistant's state is the core's; the fields below are
    // written from it by copyCoreState(), after each message that changes it,
    // and never read. Nothing stands behind the distance map, the cross
    // section, the histogram, the two transforms and the plane of the cross
    // section, which the core keeps to itself.
    final var _input: UnsafeMutablePointer<Float>?, _distmap: UnsafeMutablePointer<Float>?
    final var _im2wordTransformMatrix = IsiXFlyAssistantTransform(), _word2imTransformMatirx = IsiXFlyAssistantTransform()
    final var _inputWidth: Int32 = 0, _inputHeight: Int32 = 0, _inputDepth: Int32 = 0
    final var _inputSpacing_x: Float = 0, _inputSpacing_y: Float = 0, _inputSpacing_z: Float = 0
    final var _distmapWidth: Int32 = 0, _distmapHeight: Int32 = 0, _distmapDepth: Int32 = 0
    final var _resampleVoxelSize: Float = 0
    final var _resampleScale_x: Float = 0, _resampleScale_y: Float = 0, _resampleScale_z: Float = 0
    final var _distmapVolumeSize: Int32 = 0, _distmapImageSize: Int32 = 0
    final var _sampleMetric = IsiXFlyAssistantSampleMetric()
    final var _csmap: UnsafeMutablePointer<Float>?
    final var _centerlineResampleStepLength: Float = 0
    final var _threshold: Float = 0
    final var _isDistanceTransformFinished = false
    final var _inputImageSize: UInt = 0, _inputVolumeSize: UInt = 0
    final var _thresholdA: Float = 0, _thresholdB: Float = 0
    final var _inputMinValue: Float = 0, _inputMaxValue: Float = 0
    final var _inputHisto: UnsafeMutablePointer<UInt>?
    final var _histoSize: UInt32 = 0

    /// Writes the fields above that follow the core from it.
    final func copyCoreState() {
        _distmapWidth = Int32(truncatingIfNeeded: core.distmapWidth)
        _distmapHeight = Int32(truncatingIfNeeded: core.distmapHeight)
        _distmapDepth = Int32(truncatingIfNeeded: core.distmapDepth)
        _distmapImageSize = Int32(truncatingIfNeeded: core.distmapWidth &* core.distmapHeight)
        _distmapVolumeSize = Int32(truncatingIfNeeded: core.distmapWidth &* core.distmapHeight &* core.distmapDepth)
        _resampleVoxelSize = core.resampleVoxelSize
        _resampleScale_x = core.resampleScale.x
        _resampleScale_y = core.resampleScale.y
        _resampleScale_z = core.resampleScale.z
        _centerlineResampleStepLength = core.centerlineResampleStepLength
        _threshold = core.threshold
        _isDistanceTransformFinished = core.isDistanceTransformFinished
        _thresholdA = core.thresholdA
        _thresholdB = core.thresholdB
        _inputMinValue = core.inputMinValue
        _inputMaxValue = core.inputMaxValue
        _histoSize = core.histogramSize
    }

    /// Where the caller's coordinates put the centre of the volume's first
    /// voxel: 0, the default, for coordinates that count from a voxel's
    /// centre; the endoscopy's MPR views count a pixel from its corner.
    /// FlyPathAssistant's `firstVoxelCentre`.
    public var firstVoxelCentre: SIMD3<Float> {
        get { core.firstVoxelCentre }
        set { core.firstVoxelCentre = newValue }
    }

    /// The assistant of `data`, `dim[0]` × `dim[1]` × `dim[2]` floats spaced by
    /// `spacing` millimetres, resampled at `vsize`; nil when the distance map
    /// cannot be allocated.
    @objc(initWithVolume:WidthDimension:Spacing:ResampleVoxelSize:)
    public init?(volume data: UnsafeMutablePointer<Float>!, widthDimension dim: UnsafeMutablePointer<Int32>!,
                 spacing: UnsafeMutablePointer<Float>!, resampleVoxelSize vsize: Float) {
        guard let data, let dim, let spacing,
              let core = FlyPathAssistant(volume: UnsafePointer(data), width: Int(dim[0]), height: Int(dim[1]),
                                          depth: Int(dim[2]), spacing: SIMD3(spacing[0], spacing[1], spacing[2]),
                                          resampleVoxelSize: vsize) else { return nil }
        self.core = core
        _input = data
        _inputWidth = dim[0]
        _inputHeight = dim[1]
        _inputDepth = dim[2]
        _inputSpacing_x = spacing[0]
        _inputSpacing_y = spacing[1]
        _inputSpacing_z = spacing[2]
        _inputImageSize = UInt(bitPattern: Int(Int32(truncatingIfNeeded: core.inputWidth &* core.inputHeight)))
        _inputVolumeSize = UInt(bitPattern: Int(Int32(truncatingIfNeeded: core.inputWidth &* core.inputHeight &* core.inputDepth)))
        super.init()
        copyCoreState()
    }

    @objc public var centerlineResampleStepLength: Float {
        get { core.centerlineResampleStepLength }
        set {
            core.centerlineResampleStepLength = newValue
            _centerlineResampleStepLength = newValue
        }
    }

    @objc(setResampleVoxelSize:)
    public func setResampleVoxelSize(_ vsize: Float) -> Int32 {
        let error = core.setResampleVoxelSize(vsize)
        copyCoreState()
        return error
    }

    /// The distance transform for the lumen at `thres`; `async` runs it on a
    /// thread of its own, as -distanceTransformWithThreshold: did.
    @objc(setThreshold:Asynchronous:)
    public func setThreshold(_ thres: Float, asynchronous async: Bool) {
        core.threshold = thres
        if async {
            let core = self.core
            _threshold = thres
            Thread.detachNewThread { [weak self] in
                core.distanceTransform()
                self?.copyCoreState()
            }
        } else {
            core.distanceTransform()
            copyCoreState()
        }
    }

    @objc(distanceTransformWithThreshold:)
    public func distanceTransform(withThreshold sender: Any?) {
        core.distanceTransform()
        copyCoreState()
    }

    @objc(converPoint2ResampleCoordinate:)
    public func converPoint2ResampleCoordinate(_ pt: Point3D!) {
        guard let pt else { return }
        set(pt, core.resampleCoordinates(ofInputPoint: vector(pt)))
    }

    @objc(converPoint2InputCoordinate:)
    public func converPoint2InputCoordinate(_ pt: Point3D!) {
        guard let pt else { return }
        set(pt, core.inputCoordinates(ofResamplePoint: vector(pt)))
    }

    /// One step of the path navigator: `pt` and `dir`, in input voxels, are
    /// moved and turned in place.
    @objc(caculateNextPositionFrom:Towards:)
    public func caculateNextPosition(from pt: Point3D!, towards dir: Point3D!) -> Int32 {
        guard let pt, let dir else { return FlyPathAssistant.cannotFindPath }
        var position = vector(pt), direction = vector(dir)
        let error = core.nextPosition(from: &position, towards: &direction)
        set(pt, position)
        set(dir, direction)
        return error
    }

    /// The center of the lumen `steplen` ahead, in resample coordinates, or nil.
    @objc(caculateNextCenterPointFrom:Towards:WithStepLength:)
    public func caculateNextCenterPoint(from pt: Point3D!, towards dir: Point3D!, withStepLength steplen: Float) -> Point3D? {
        guard let pt, let dir,
              let point = core.nextCenterPoint(from: vector(pt), towards: vector(dir), stepLength: steplen) else { return nil }
        return Point3D(x: point.x, y: point.y, z: point.z)
    }

    /// The centerline from `pta` to `ptb` appended to `centerline` as
    /// OSIVoxels in input voxels, then the whole array thinned by the lumen's
    /// radius and, with `smoothFlag`, smoothed every
    /// `centerlineResampleStepLength`. The centerline starts at `pta` and
    /// ends at `ptb` (held to the volume); the points given stay as they are.
    @objc(createCenterline:FromPointA:ToPointB:withSmoothing:)
    public func createCenterline(_ centerline: NSMutableArray!, fromPointA pta: Point3D!, toPointB ptb: Point3D!,
                                 withSmoothing smoothFlag: Bool) -> Int32 {
        let (error, points) = core.centerline(from: pta.map(vector) ?? .zero, to: ptb.map(vector) ?? .zero)
        guard error == 0 else { return error }
        for point in points {
            centerline?.add(OSIVoxel(x: point.x, y: point.y, z: point.z, value: nil))
        }
        downSampleCenterline(withLocalRadius: centerline)
        if smoothFlag {
            createSmoothedCenterlin(centerline, withStepLength: core.centerlineResampleStepLength)
        }
        return 0
    }

    /// The array without the points closer to the last kept one than the
    /// mean of their radii; the points kept are the same objects.
    @objc(downSampleCenterlineWithLocalRadius:)
    public func downSampleCenterline(withLocalRadius centerline: NSMutableArray!) {
        guard let centerline, centerline.count > 2 else { return }
        let items = centerline.map { $0 }
        let kept = core.thinnedCenterlineIndices(items.map(coordinates))
        guard kept.count != items.count else { return }
        centerline.setArray(kept.map { items[$0] })
    }

    /// The array replaced by the points of a cardinal spline through it, one
    /// every `len` along it.
    @objc(createSmoothedCenterlin:withStepLength:)
    public func createSmoothedCenterlin(_ centerline: NSMutableArray!, withStepLength len: Float) {
        guard let centerline, centerline.count > 2 else { return }
        let points = centerline.map(coordinates)
        guard let smoothed = FlyPathAssistant.smoothedCenterline(points, stepLength: len, spline: Spline3D()) else { return }
        centerline.removeAllObjects()
        for point in smoothed {
            centerline.add(OSIVoxel(x: point.x, y: point.y, z: point.z, value: nil))
        }
    }

    /// The lumen's radius in millimetres at a point in input voxels.
    @objc(radiusAtPoint:)
    public func radius(atPoint pt: OSIVoxel!) -> Float {
        core.radius(at: coordinates(pt as Any?))
    }

    @objc(averageRadiusAt:On:InRange:)
    public func averageRadius(at index: Int32, on centerline: NSMutableArray!, inRange nrange: Int32) -> Float {
        let points = (centerline ?? []).map(coordinates)
        return core.averageRadius(at: Int(index), on: points, range: Int(nrange))
    }

    /// Where to look from `center` toward `direction`, centerline points in
    /// input voxels: a new OSIVoxel as far from center as direction is.
    @objc(computeMaximizingViewDirectionFrom:LookingAt:)
    public func computeMaximizingViewDirection(from center: OSIVoxel!, lookingAt direction: OSIVoxel!) -> OSIVoxel! {
        // A missing point reads as the origin, as a message to nil answered 0.
        let view = core.maximizingViewDirection(from: coordinates(center as Any?), lookingAt: coordinates(direction as Any?))
        return OSIVoxel(x: view.x, y: view.y, z: view.z, value: nil)
    }

    /// The steps of one resampled voxel from `center` along `direction`
    /// (resample coordinates) up to the first out of the lumen.
    @objc(traceLineFrom:accordingTo:)
    public func traceLine(from center: Point3D!, accordingTo direction: Point3D!) -> UInt32 {
        guard let center, let direction else { return 0 }
        return core.traceLine(from: vector(center), along: vector(direction))
    }

    /// A centerline point's coordinates: the arrays hold OSIVoxels, and a
    /// Point3D or any object answering x, y and z reads the same; anything
    /// else reads as the origin, as the former messages to it did not reach.
    private func coordinates(_ item: Any?) -> SIMD3<Float> {
        switch item {
        case let voxel as OSIVoxel: return SIMD3(voxel.x, voxel.y, voxel.z)
        case let point as Point3D: return SIMD3(point.x, point.y, point.z)
        case let object as NSObject where object.responds(to: NSSelectorFromString("x")):
            func read(_ key: String) -> Float { (object.value(forKey: key) as? NSNumber)?.floatValue ?? 0 }
            return SIMD3(read("x"), read("y"), read("z"))
        default: return .zero
        }
    }

    private func vector(_ p: Point3D) -> SIMD3<Float> {
        SIMD3(p.x, p.y, p.z)
    }

    private func set(_ p: Point3D, _ value: SIMD3<Float>) {
        p.x = value.x
        p.y = value.y
        p.z = value.z
    }
}
