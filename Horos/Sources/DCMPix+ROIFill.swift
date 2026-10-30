/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXROI

// The ROI fills and masks of DCMPix: -fillROI: in its six forms (a slice, or a
// plane of the volume in the three orientations, the VR scissors and the
// brush), the restore cache that gives the pixels back, and the polygon and RT
// STRUCT masks. The class stays Objective-C; these are its methods, with the
// same selectors, declared for Objective-C callers in DCMPix+ROI.h. The pixel
// work is IsiXROI's.

/// The images -prepareRestore read again from their files, one per slice of the
/// series it was asked for: the original pixels a restoring fill copies back.
/// One cache for every DCMPix, as before; the viewer and the VR scissors fill
/// one series at a time.
nonisolated(unsafe) private var restoreImageCache: [DCMPix]?

extension DCMPix {

    /// The original pixels of `slice` in the restore cache, if it has them.
    fileprivate static func restoreImage(_ slice: Int) -> UnsafeMutablePointer<Float>? {
        guard let cache = restoreImageCache, slice >= 0, slice < cache.count else { return nil }
        return cache[slice].fImage
    }

    @objc(fillROI:newVal:minValue:maxValue:outside:orientationStack:stackNo:restore:addition:)
    public dynamic func fillROI(_ roi: ROI?, newVal: Float, minValue: Float, maxValue: Float, outside: Bool, orientationStack: Int,
                        stackNo: Int, restore: Bool, addition: Bool) {
        fillROI(roi, newVal: newVal, minValue: minValue, maxValue: maxValue, outside: outside, orientationStack: orientationStack,
                stackNo: stackNo, restore: restore, addition: addition, spline: roiMessages(roi)?.isSpline ?? false)
    }

    @objc(fillROI:newVal:minValue:maxValue:outside:orientationStack:stackNo:restore:addition:spline:)
    public dynamic func fillROI(_ roi: ROI?, newVal: Float, minValue: Float, maxValue: Float, outside: Bool, orientationStack: Int,
                        stackNo: Int, restore: Bool, addition: Bool, spline: Bool) {
        fillROI(roi, newVal: newVal, minValue: minValue, maxValue: maxValue, outside: outside, orientationStack: orientationStack,
                stackNo: stackNo, restore: restore, addition: addition, spline: spline, clipMin: .zero, clipMax: .zero)
    }

    /// Sets (or adds `newVal` to) the pixels inside `roi`, or outside it, whose
    /// value is within `minValue`...`maxValue`, on a plane: the image itself
    /// (orientation 2) or a cut of the volume the series makes (0 at column
    /// `stackNo`, 1 at row `stackNo`). With `restore` the pixels inside come
    /// back from the restore cache. The plane and the clip rectangle are those
    /// the VR scissor bounds accept; a refused request leaves the pixels alone.
    @objc(fillROI:newVal:minValue:maxValue:outside:orientationStack:stackNo:restore:addition:spline:clipMin:clipMax:)
    public dynamic func fillROI(_ roi: ROI?, newVal: Float, minValue: Float, maxValue: Float, outside: Bool, orientationStack: Int,
                        stackNo: Int, restore: Bool, addition: Bool, spline: Bool, clipMin: NSPoint, clipMax: NSPoint) {
        checkLoad()

        let width = horos_width, height = horos_height
        let slices = horos_pixArray?.count ?? 0
        // A copied image used as a 2D ROI mask has pixels but no owning stack.
        // Validate that local plane as one slice; restore and orthogonal cuts
        // still require the original stack and keep their existing bounds checks.
        var sliceCount = slices
        if sliceCount == 0 && orientationStack == 2 && !restore {
            sliceCount = 1
        }
        let plan = VRScissorBounds.plan(width: width, height: height, sliceCount: sliceCount, orientation: orientationStack,
                                        stackNo: stackNo, restore: restore, clipMinX: clipMin.x, clipMinY: clipMin.y,
                                        clipMaxX: clipMax.x, clipMaxY: clipMax.y)
        if !plan.accepted {
            if !plan.reason.isEmpty { NSLog("fillROI: %@", plan.reason) }
            return
        }
        let orientation = plan.orientation
        let stack = plan.stackNo
        var restore = plan.restore
        var clipMin = NSPoint(x: plan.clipMinX, y: plan.clipMinY)
        var clipMax = NSPoint(x: plan.clipMaxX, y: plan.clipMaxY)
        let planeWidth = plan.planeWidth, planeHeight = plan.planeHeight

        if stack < 0 && restore {
            NSLog("error !!!! stackNo < 0 && restore")
            restore = false
        }

        if clipMin.x == 0 && clipMax.x == 0 && clipMin.y == 0 && clipMax.y == 0 {
            clipMin = .zero
            switch orientation {
            case 0: clipMax = NSPoint(x: Double(height), y: Double(slices))
            case 1: clipMax = NSPoint(x: Double(width), y: Double(slices))
            case 2: clipMax = NSPoint(x: Double(width), y: Double(height))
            default: break
            }
        }
        if clipMin.x < 0 { clipMin.x = 0 }
        if clipMin.y < 0 { clipMin.y = 0 }
        switch orientation {
        case 0:
            if clipMax.x > Double(height) { clipMax.x = Double(height) }
            if clipMax.y > Double(slices) { clipMax.y = Double(slices) }
        case 1:
            if clipMax.x > Double(width) { clipMax.x = Double(width) }
            if clipMax.y > Double(slices) { clipMax.y = Double(slices) }
        case 2:
            if clipMax.x > Double(width) { clipMax.x = Double(width) }
            if clipMax.y > Double(height) { clipMax.y = Double(height) }
        default: break
        }

        guard let image = horos_fImage else { return }
        var polygon: [ROIPixelPoint]?

        if let roi = roiMessages(roi) {
            if roi.type == .tPlain {
                fillBrush(roi, image: image, newVal: newVal, minValue: minValue, maxValue: maxValue, outside: outside,
                          addition: addition, orientation: orientation, stack: stack, restore: restore, clipMin: clipMin, clipMax: clipMax, slices: slices)
                return
            }
            let points = (spline ? roi.splinePoints() : roi.points) ?? NSMutableArray()
            var vertices = points.map { ROIPixelPoint(pointMessages($0).point) }
            // Need to clip?
            let clip = vertices.contains {
                Double($0.x) < clipMin.x || Double($0.y) < clipMin.y || Double($0.x) >= clipMax.x || Double($0.y) >= clipMax.y
            }
            if clip {
                vertices = ROIPolygonClip.clip(vertices, min: clipMin, max: clipMax)
            }
            polygon = vertices
        }

        let plane = ROIPlane(pixels: image, width: width, height: height, sliceCount: sliceCount, orientation: orientation,
                             stackNo: stack, isRGB: isRGB)
        let vertices = polygon ?? []

        if outside {
            // The rows above and below the polygon, at once.
            var upLeftY = 0, downRightY = planeHeight
            if let first = vertices.first {
                upLeftY = first.y
                downRightY = first.y
                for vertex in vertices {
                    upLeftY = min(upLeftY, vertex.y)
                    downRightY = max(downRightY, vertex.y)
                }
            }
            upLeftY = min(max(upLeftY, 0), planeHeight - 1)
            downRightY = min(max(downRightY, 0), planeHeight - 1)
            for y in 0..<max(upLeftY, 0) {
                plane.paint(row: y, from: 0, count: planeWidth, minimum: minValue, maximum: maxValue, value: newVal, addition: false)
            }
            for y in stride(from: downRightY, to: planeHeight, by: 1) {
                plane.paint(row: y, from: 0, count: planeWidth, minimum: minValue, maximum: maxValue, value: newVal, addition: false)
            }
        }

        if polygon != nil && vertices.count > 1 {
            ROIPolygonFill.fill(vertices, on: plane, minimum: minValue, maximum: maxValue, outside: outside, value: newVal,
                                addition: addition, restore: restore, restoreImage: DCMPix.restoreImage,
                                outOfRange: DCMPix.logEdgeOutOfRange)
        } else if outside {
            // The image that contains no ROI.
            for y in 0..<max(planeHeight, 0) {
                plane.paint(row: y, from: 0, count: planeWidth, minimum: minValue, maximum: maxValue, value: newVal, addition: false)
            }
        }
    }

    /// A brush ROI on the image: its painted pixels, or the others within the clip.
    private func fillBrush(_ roi: DCMPixROIMessages, image: UnsafeMutablePointer<Float>, newVal: Float, minValue: Float, maxValue: Float,
                           outside: Bool, addition: Bool, orientation: Int, stack: Int, restore: Bool, clipMin: NSPoint, clipMax: NSPoint, slices: Int) {
        if orientation != 2 {
            N2LogStackTraceMessage("Unsupported orientation")
            return
        }
        var texture = DCMPix.texture(roi)
        if texture.bytes == nil || texture.width <= 0 || texture.height <= 0 {
            if !outside { return }  // Empty brush: nothing inside to fill
            texture.width = 0
            texture.height = 0
        }
        var original: UnsafeMutablePointer<Float>?
        if restore {
            if stack >= 0 && stack < slices { original = DCMPix.restoreImage(stack) }
            if original == nil {
                NSLog("fillROI: original pixels unavailable for restore (stack %ld) - image left unchanged", stack)
                return
            }
        }
        let width = horos_width, height = horos_height
        let inside = VRScissorBounds.textureInside(columns: width, rows: height, originX: texture.originX, originY: texture.originY,
                                                   width: texture.width, height: texture.height).map(\.intValue)
        if (inside[2] <= 0 || inside[3] <= 0) && !outside { return }
        ROIBrushRaster.fill(texture, inside: (inside[0], inside[1], inside[2], inside[3]), image: image, imageWidth: width, isRGB: isRGB,
                            clipMin: clipMin, clipMax: clipMax, minimum: minValue, maximum: maxValue, value: newVal,
                            addition: addition, outside: outside, restore: original)
    }

    @objc(fillROI::::::::)
    public dynamic func fillROI(_ roi: ROI?, _ newVal: Float, _ minValue: Float, _ maxValue: Float, _ outside: Bool,
                        _ orientationStack: Int, _ stackNo: Int, _ restore: Bool) {
        fillROI(roi, newVal: newVal, minValue: minValue, maxValue: maxValue, outside: outside, orientationStack: orientationStack,
                stackNo: stackNo, restore: restore, addition: false)
    }

    @objc(fillROI:::::::)
    public dynamic func fillROI(_ roi: ROI?, _ newVal: Float, _ minValue: Float, _ maxValue: Float, _ outside: Bool,
                        _ orientationStack: Int, _ stackNo: Int) {
        fillROI(roi, newVal, minValue, maxValue, outside, orientationStack, stackNo, false)
    }

    /// Fills `roi` on this image: the axial plane at this image's place in
    /// its series, or the first when it has none (an image with no stack).
    @objc(fillROI:::::)
    public dynamic func fillROI(_ roi: ROI?, _ newVal: Float, _ minValue: Float, _ maxValue: Float, _ outside: Bool) {
        let index = horos_pixArray?.indexOfObjectIdentical(to: self) ?? NSNotFound
        fillROI(roi, newVal, minValue, maxValue, outside, 2, index == NSNotFound ? 0 : index)
    }

    /// Reads every slice of the series again from its file into the restore
    /// cache, for a fill that gives the original pixels back. NO without
    /// slices, or when one cannot be read (the cache is emptied then).
    @objc(prepareRestore)
    public dynamic func prepareRestore() -> Bool {
        if restoreImageCache != nil { freeRestore() }
        let slices = pixArray ?? []
        if slices.isEmpty { return false }
        var cache: [DCMPix] = []
        cache.reserveCapacity(slices.count)
        for (i, object) in slices.enumerated() {
            let source = object as! DCMPix
            guard let copy = DCMPix(path: source.srcFile, i, slices.count, nil, source.frameNo, 0, isBonjour: false,
                                    imageObj: source.imageObj()) else {
                NSLog("prepare Restore cache - FAILED: source image %d unavailable (%@)", Int32(truncatingIfNeeded: i), source.srcFile ?? "(null)")
                freeRestore()
                return false
            }
            cache.append(copy)
        }
        restoreImageCache = cache
        NSLog("prepare Restore cache")
        return true
    }

    /// Empties the restore cache.
    @objc(freeRestore)
    public dynamic func freeRestore() {
        if restoreImageCache != nil {
            restoreImageCache = nil
            NSLog("free Restore cache")
        }
    }

    @objc(getMapFromPolygonROI:size:origin:)
    public dynamic func getMapFromPolygonROI(_ roi: ROI?, size: UnsafeMutablePointer<NSSize>?, origin: UnsafeMutablePointer<NSPoint>?) -> UnsafeMutablePointer<UInt8>! {
        DCMPix.mapFromPolygonROI(roi, size: size, origin: origin)
    }

    /// The mask of a closed or open polygon or of a pencil ROI (nil for
    /// another kind), malloc'd, its size and its origin on the image.
    @objc(getMapFromPolygonROI:size:origin:)
    public static dynamic func mapFromPolygonROI(_ roi: ROI?, size: UnsafeMutablePointer<NSSize>?, origin: UnsafeMutablePointer<NSPoint>?) -> UnsafeMutablePointer<UInt8>! {
        guard let roi = roiMessages(roi), roi.type == .tCPolygon || roi.type == .tOPolygon || roi.type == .tPencil else { return nil }
        let points = (roi.points ?? NSMutableArray()).map { pointMessages($0).point }
        if points.isEmpty {
            NSLog("******** ERROR no == 0 getMapFromPolygonROI")
            return nil
        }
        guard let mask = ROIMasks.polygonMask(points) else { return nil }
        size?.pointee = mask.size
        origin?.pointee = mask.origin
        return mask.bytes
    }

    /// RTSTRUCT vertices use ROI coordinates: pixel (x, y) is sampled at
    /// (x + 0.5, y + 0.5). Fractional vertices are kept and the empty texture
    /// border stays outside the image samples.
    @objc(getMapFromRTSTRUCTROI:width:height:size:origin:)
    public static dynamic func getMapFromRTSTRUCTROI(_ roi: ROI?, width: Int32, height: Int32, size: UnsafeMutablePointer<NSSize>?,
                                             origin: UnsafeMutablePointer<NSPoint>?) -> UnsafeMutablePointer<UInt8>! {
        let points = (roiMessages(roi)?.points ?? NSMutableArray()).map { pointMessages($0).point }
        guard let mask = ROIMasks.contourMask(points, width: width, height: height) else { return nil }
        size?.pointee = mask.size
        origin?.pointee = mask.origin
        return mask.bytes
    }
}
