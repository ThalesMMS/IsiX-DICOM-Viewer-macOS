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

/// The geometry of the volume ROIs (OSIROI and its subclasses) in patient
/// space and in a volume's indexes: Nitrogen's paths and transforms around the
/// rules of IsiXROI (VolumeROIScan, VolumeROIBox, VolumeROIHull,
/// VolumeROIOutline). It needs nothing of the app but Nitrogen, OSIGeometry and
/// the mask run of OSIROIMask.h.
enum OSIROIVolumeGeometry {

    // MARK: - Outlines

    /// The outline of a planar path ROI in patient space: its 2D ROI's `kind`
    /// and `points` (pix space), carried by `pixToDICOM`. Nil when the ROI has
    /// none (a measure with fewer than two points, an empty traced ROI, another tool).
    static func planarOutline(kind: VolumeROIOutline.Kind, points: [NSPoint], firstTwoCoincide: Bool,
                              pixToDICOM: N3AffineTransform) -> N3MutableBezierPath? {
        guard let outline = VolumeROIOutline.make(kind: kind, points: points, firstTwoCoincide: firstTwoCoincide) else {
            return nil
        }
        let path: N3MutableBezierPath
        switch outline {
        case let .segment(a, b):
            // The ends are carried one by one: the path is not transformed afterwards.
            path = N3MutableBezierPath()
            path.move(to: N3VectorApplyTransform(N3VectorMakeFromNSPoint(a), pixToDICOM))
            path.line(to: N3VectorApplyTransform(N3VectorMakeFromNSPoint(b), pixToDICOM))
            return path
        case let .nodes(nodes):
            path = N3MutableBezierPath(nodeArray: nodes.map { NSValue(n3Vector: N3VectorMakeFromNSPoint($0)) as Any },
                                       style: N3BezierNodeEndsMeetStyle)
        case let .polyline(points):
            path = N3MutableBezierPath()
            path.move(to: N3VectorMakeFromNSPoint(points[0]))
            for point in points.dropFirst() {
                path.line(to: N3VectorMakeFromNSPoint(point))
            }
        }
        if path.elementCount() != 0 {
            path.close()
        }
        path.applyAffineTransform(pixToDICOM)
        return path
    }

    /// The outline of a path ROI (the first, non-planar kind) through
    /// `points`, each carried by `pixToDICOM` first: a measure's segment
    /// between its two points, or an open or closed polygon whose ends point
    /// out. Nil for the other tools.
    static func pathOutline(kind: VolumeROIOutline.Kind, points: [NSPoint], pixToDICOM: N3AffineTransform) -> N3MutableBezierPath? {
        let patient = points.map { N3VectorApplyTransform(N3VectorMakeFromNSPoint($0), pixToDICOM) }
        switch kind {
        case .measure:
            let path: N3MutableBezierPath = N3MutableBezierPath()
            path.move(to: patient[0])
            path.line(to: patient[1])
            return path
        case .openPolygon, .closedPolygon:
            let path: N3MutableBezierPath = N3MutableBezierPath(nodeArray: patient.map { NSValue(n3Vector: $0) as Any },
                                                                style: N3BezierNodeOpenEndsStyle)
            if kind == .closedPolygon {
                path.close()
            }
            return path
        default:
            return nil
        }
    }

    // MARK: - Hulls

    /// The elements of `path`: kind, both controls and the end.
    static func elements(of path: N3BezierPath?) -> [(kind: VolumeROIPathElement, control1: N3Vector, control2: N3Vector, end: N3Vector)] {
        guard let path else { return [] }
        return (0..<path.elementCount()).map { i in
            var control1 = N3VectorZero, control2 = N3VectorZero, end = N3VectorZero
            let type = path.element(at: i, control1: &control1, control2: &control2, endpoint: &end)
            let kind: VolumeROIPathElement
            switch type {
            case Int(N3MoveToBezierPathElement.rawValue): kind = .moveTo
            case Int(N3LineToBezierPathElement.rawValue): kind = .lineTo
            case Int(N3CurveToBezierPathElement.rawValue): kind = .curveTo
            default: kind = .closePath
            }
            return (kind, control1, control2, end)
        }
    }

    /// The points a path ROI lies within: each end, and the controls of curves.
    static func hull(of path: N3BezierPath?) -> [N3Vector] {
        VolumeROIHull.points(of: elements(of: path))
    }

    /// The hull of an extrusion of `path` along `normal`: the path's points
    /// moved half the normal one way, then the other.
    static func extrusionHull(of path: N3BezierPath?, normal: N3Vector) -> [N3Vector] {
        let points = hull(of: path)
        let halfNormal = N3VectorScalarMultiply(normal, 0.5)
        let otherHalf = N3VectorInvert(halfNormal)
        return points.map { N3VectorAdd($0, halfNormal) } + points.map { N3VectorAdd($0, otherHalf) }
    }

    // MARK: - Masks of an outline

    /// The runs a planar outline covers in a volume (`volumeTransform` from
    /// patient space to its indexes): the path is flattened in the volume, its
    /// z rounded to the slice, each row cut where the outline crosses it, half
    /// a voxel up. Nil when the slice is outside the volume.
    static func planarRuns(of path: N3BezierPath?, volumeTransform: N3AffineTransform,
                           pixelsWide: Int, pixelsHigh: Int, pixelsDeep: Int) -> [OSIROIMaskRun]? {
        guard let cut = planarSpans(of: path, volumeTransform: volumeTransform, pixelsWide: pixelsWide,
                                    pixelsHigh: pixelsHigh, pixelsDeep: pixelsDeep) else {
            return nil
        }
        return cut.spans.map { run(row: $0.row, start: $0.start, length: $0.length, slice: cut.slice) }
    }

    /// The runs of an outline extruded through `slab`: the outline's runs on
    /// each slice the slab covers in the volume, row by row. Nil when the
    /// outline's own slice is outside the volume.
    static func extrudedRuns(of path: N3BezierPath?, slab: OSISlab, volumeTransform: N3AffineTransform,
                             pixelsWide: Int, pixelsHigh: Int, pixelsDeep: Int) -> [OSIROIMaskRun]? {
        let transformedSlab = OSISlabApplyTransform(slab, volumeTransform)
        guard let cut = planarSpans(of: path, volumeTransform: volumeTransform, pixelsWide: pixelsWide,
                                    pixelsHigh: pixelsHigh, pixelsDeep: pixelsDeep) else {
            return nil
        }
        let slices = VolumeROIScan.extrusionSlices(center: Double(transformedSlab.plane.point.z),
                                                   thickness: Double(transformedSlab.thickness), depth: pixelsDeep)
        return cut.spans.flatMap { span in
            slices.map { run(row: span.row, start: span.start, length: span.length, slice: $0) }
        }
    }

    /// The axis of the slab in the volume, which must be the volume's z.
    static func extrusionAxis(of slab: OSISlab, volumeTransform: N3AffineTransform) -> N3Vector {
        OSISlabApplyTransform(slab, volumeTransform).plane.normal
    }

    private static func planarSpans(of path: N3BezierPath?, volumeTransform: N3AffineTransform,
                                    pixelsWide: Int, pixelsHigh: Int, pixelsDeep: Int)
        -> (slice: Int, spans: [(row: Int, start: Int, length: Int)])? {
        let volumePath = path?.mutableCopy() as? N3MutableBezierPath
        volumePath?.applyAffineTransform(N3AffineTransformConcat(volumeTransform, N3AffineTransformMakeTranslation(0, -0.5, 0)))
        volumePath?.flatten(N3BezierDefaultFlatness)
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var z = 0.0
        var zSet = false
        for i in 0..<(volumePath?.elementCount() ?? 0) {
            var endpoint = N3VectorZero
            volumePath?.element(at: i, control1: nil, control2: nil, endpoint: &endpoint)
            endpoint.z = endpoint.z.rounded()
            volumePath?.setVectorsForElementAt(i, control1: N3VectorZero, control2: N3VectorZero, endpoint: endpoint)
            minY = volumeROIMin(minY, Double(endpoint.y))
            maxY = volumeROIMax(maxY, Double(endpoint.y))
            if !zSet {
                z = Double(endpoint.z)
                zSet = true
            }
            assert(Double(endpoint.z) == z)
        }
        guard let slice = VolumeROIScan.slice(z: z, depth: pixelsDeep) else {
            return nil
        }
        var spans: [(row: Int, start: Int, length: Int)] = []
        for row in VolumeROIScan.rows(minY: minY, maxY: maxY, height: pixelsHigh) {
            let plane = N3PlaneMake(N3VectorMake(0, CGFloat(row), 0), N3VectorMake(0, 1, 0))
            let crossings = (volumePath?.intersections(with: plane) ?? []).map { Double(($0 as! NSValue).n3VectorValue().x) }
            for span in VolumeROIScan.spans(crossings: crossings, width: pixelsWide) {
                spans.append((row, span.start, span.length))
            }
        }
        return (slice, spans)
    }

    private static func run(row: Int, start: Int, length: Int, slice: Int) -> OSIROIMaskRun {
        var run = OSIROIMaskRunZero
        run.depthIndex = UInt(slice)
        run.heightIndex = UInt(row)
        run.widthRange = NSMakeRange(start, length)
        return run
    }

    // MARK: - A group of ROIs in one volume

    /// The volume a group of ROIs is merged in: the voxels of the home
    /// volume (`volumeTransform`) around the points of their hulls, with one
    /// to spare on each side. Its transform and size.
    static func coalescedVolume(hull: [N3Vector], volumeTransform: N3AffineTransform)
        -> (volumeTransform: N3AffineTransform, width: Int, height: Int, depth: Int) {
        let points = hull.map { point -> (x: Double, y: Double, z: Double) in
            let index = N3VectorApplyTransform(point, volumeTransform)
            return (Double(index.x), Double(index.y), Double(index.z))
        }
        let box = VolumeROIBox.padded(points)
        let transform = N3AffineTransformConcat(volumeTransform,
                                                N3AffineTransformMakeTranslation(CGFloat(-box.minX), CGFloat(-box.minY), CGFloat(-box.minZ)))
        return (transform, box.width, box.height, box.depth)
    }

    // MARK: - A mask of the home volume

    /// The runs of a mask of the home volume (`homeTransform`) in another volume
    /// (`volumeTransform`, `width` by `height` by `depth`) on the same grid,
    /// whole voxels away from it, as the box of a group is: moved by the offset
    /// and cut to that volume. Nil when the volumes are on different grids.
    static func maskRuns(_ runs: [OSIROIMaskRun], from homeTransform: N3AffineTransform, to volumeTransform: N3AffineTransform,
                         width: Int, height: Int, depth: Int) -> [OSIROIMaskRun]? {
        let map = N3AffineTransformConcat(N3AffineTransformInvert(homeTransform), volumeTransform)
        let linear = [map.m11, map.m12, map.m13, map.m21, map.m22, map.m23, map.m31, map.m32, map.m33].map { Double($0) }
        guard let offset = VolumeROIMaskGrid.wholeVoxelOffset(linear: linear,
                                                              translation: (Double(map.m41), Double(map.m42), Double(map.m43))) else {
            return nil
        }
        let moved = VolumeROIMaskGrid.moved(runs.map { ($0.widthRange.location, $0.widthRange.length,
                                                        Int(bitPattern: $0.heightIndex), Int(bitPattern: $0.depthIndex), $0.intensity) },
                                            by: offset, width: width, height: height, depth: depth)
        return moved.map { moved in
            var maskRun = run(row: moved.row, start: moved.location, length: moved.length, slice: moved.slice)
            maskRun.intensity = moved.intensity
            return maskRun
        }
    }

    /// The hull of a mask of a volume in patient space. OSIROIMask's hull gives
    /// the corners of the mask's box as (column, slice, row); they are put back
    /// in index order (column, row, slice) and carried to patient space by
    /// `inverseVolumeTransform`.
    static func maskHull(_ corners: [N3Vector], inverseVolumeTransform: N3AffineTransform) -> [N3Vector] {
        corners.map { N3VectorApplyTransform(N3VectorMake($0.x, $0.z, $0.y), inverseVolumeTransform) }
    }

    /// The picture a slab of a volume (`volumeTransform`, `width` by `height`
    /// by `depth`) is resampled to, in a view's pix space: its corner in pix
    /// space, its size, and the transform from the picture to patient space.
    static func slabPicture(volumeTransform: N3AffineTransform, width: Int, height: Int, depth: Int,
                            dicomToPixTransform: N3AffineTransform)
        -> (minCorner: N3Vector, width: Int, height: Int, sliceToDicomTransform: N3AffineTransform) {
        let volumeToPix = N3AffineTransformConcat(N3AffineTransformInvert(volumeTransform), dicomToPixTransform)
        let corners = VolumeROIBox.sliceCorners(width: width, height: height, depth: depth).map { corner -> (x: Double, y: Double) in
            let pix = N3VectorApplyTransform(N3VectorMake(CGFloat(corner.x), CGFloat(corner.y), CGFloat(corner.z)), volumeToPix)
            return (Double(pix.x), Double(pix.y))
        }
        let box = VolumeROIBox.padded(corners)
        let minCorner = N3VectorMake(CGFloat(box.minX), CGFloat(box.minY), 0)
        let sliceToDicom = N3AffineTransformConcat(N3AffineTransformMakeTranslation(minCorner.x, minCorner.y, 0),
                                                   N3AffineTransformInvert(dicomToPixTransform))
        return (minCorner, box.width, box.height, sliceToDicom)
    }

    /// The transform that resamples a whole volume (`volumeTransform`,
    /// `pixelsDeep` deep) from its middle slice: the slab is the volume.
    static func wholeVolumeSliceToDicom(volumeTransform: N3AffineTransform, pixelsDeep: Int) -> N3AffineTransform {
        // The depth was halved as a float.
        let halfDepth = CGFloat(Float(pixelsDeep)) / 2.0
        return N3AffineTransformInvert(N3AffineTransformConcat(volumeTransform, N3AffineTransformMakeTranslation(0, 0, halfDepth)))
    }

    // MARK: - A brush ROI

    /// The corners of a brush ROI's texture, from its upper left (`left`,
    /// `top`) to its lower right (`right`, `bottom`) in pix space, in patient
    /// space: the points it lies within.
    static func brushHull(left: Int32, top: Int32, right: Int32, bottom: Int32, pixToDICOM: N3AffineTransform) -> [N3Vector] {
        [N3VectorMake(CGFloat(left), CGFloat(top), 0), N3VectorMake(CGFloat(left), CGFloat(bottom), 0),
         N3VectorMake(CGFloat(right), CGFloat(top), 0), N3VectorMake(CGFloat(right), CGFloat(bottom), 0)]
            .map { N3VectorApplyTransform($0, pixToDICOM) }
    }

    /// The transform from patient space to the indexes of a brush ROI's
    /// texture, whose upper left corner is at (`left`, `top`) in pix space.
    static func brushVolumeTransform(left: Int32, top: Int32, pixToDICOM: N3AffineTransform) -> N3AffineTransform {
        N3AffineTransformConcat(N3AffineTransformInvert(pixToDICOM), N3AffineTransformMakeTranslation(CGFloat(-left), CGFloat(-top), 0))
    }

    /// Where a planar ROI on `plane` is in a volume (`volumeTransform`): the
    /// index of its point, and the transform from the slice there to patient space.
    static func planeSlice(_ plane: N3Plane, volumeTransform: N3AffineTransform)
        -> (planePixelPoint: N3Vector, sliceToDicomTransform: N3AffineTransform) {
        let planePixelPoint = N3VectorApplyTransform(plane.point, volumeTransform)
        let sliceToDicom = N3AffineTransformInvert(N3AffineTransformConcat(volumeTransform,
                                                                           N3AffineTransformMakeTranslation(0, 0, -planePixelPoint.z)))
        return (planePixelPoint, sliceToDicom)
    }

    /// The plane of the slice a 2D ROI was drawn on, in patient space.
    static func roiPlane(pixToDICOM: N3AffineTransform) -> N3Plane {
        N3PlaneApplyTransform(N3PlaneZZero, pixToDICOM)
    }

    /// Whether a planar ROI on `plane` is parallel to the slices of a volume
    /// (`volumeTransform`), as its mask requires.
    static func isParallelToSlices(_ plane: N3Plane, volumeTransform: N3AffineTransform, tolerance: CGFloat) -> Bool {
        N3VectorLength(N3VectorCrossProduct(N3VectorApplyTransformToDirectionalVector(plane.normal, volumeTransform),
                                            N3VectorMake(0, 0, 1))) < tolerance
    }
}
