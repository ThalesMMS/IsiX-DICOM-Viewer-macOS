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
import IsiXSegmentation

// What a grown region becomes: the voxels of a new series, brush ROIs (one per
// slice that holds part of the region) or closed polygons traced around it by
// VTK (IsiXVTKContour). The mask is ITK's, one byte per voxel of the volume.
extension ITKSegmentation3D {

    /// The name of the region growing window's preview ROI.
    private static var previewName: String { NSLocalizedString("Segmentation Preview", comment: "") }

    /// Sets the region's voxels of `destViewer`'s series to `inValue`
    /// (`setIn`) or to those of `srcViewer`'s, in every slice when the whole
    /// volume grew (`slice` -1), else in `slice`.
    @MainActor
    func fillSeries(of destViewer: ViewerController, from srcViewer: ViewerController, mask: IsiXITKMask, slice: Int,
                    setIn: Bool, inValue: Float) {
        let destination: NSArray = destViewer.pixList() ?? NSMutableArray()
        let source: NSArray = srcViewer.pixList() ?? NSMutableArray()
        let plane = mask.width * mask.height, maskWidth = mask.width, inside = RegionGrowingResult.inside
        for i in RegionGrowingResult.slices(slice: slice, sliceCount: destination.count) {
            guard let curPix = destination[i] as? DCMPix, let dst = curPix.fImage,
                  let src = (source[i] as? DCMPix)?.fImage else { continue }
            let region = mask.bytes + RegionGrowingResult.maskPlane(slice: slice, resultSlice: i) * plane
            let width = curPix.pwidth, height = curPix.pheight
            var y = 0
            while y < height {
                let row = region + y * maskWidth, target = dst + y * width, copied = src + y * width
                var x = 0
                if setIn {
                    while x < width {
                        if row[x] == inside { target[x] = inValue }
                        x += 1
                    }
                } else {
                    while x < width {
                        if row[x] == inside { target[x] = copied[x] }
                        x += 1
                    }
                }
                y += 1
            }
        }
    }

    /// Adds the region to `srcViewer` as brush ROIs named `name`: one in each
    /// slice that holds part of it when the whole volume grew (`slice` -1),
    /// else one in `slice`; the preview ROI is coloured and commented, the
    /// others merged with the brush ROIs there when `merge`.
    @MainActor
    func addBrushROIs(to srcViewer: ViewerController, mask: IsiXITKMask, slice: Int, name: String, merge: Bool) {
        let previewName = Self.previewName
        let isPreview = RegionGrowingResult.isPreview(name: name, previewName: previewName)
        let pixList: NSArray = srcViewer.pixList() ?? NSMutableArray()
        let roiList: NSArray = srcViewer.roiList() ?? NSMutableArray()
        let curDCM = srcViewer.imageView()?.curDCM
        let spacingX = Float(curDCM?.pixelSpacingX ?? 0), spacingY = Float(curDCM?.pixelSpacingY ?? 0)
        var buffer = mask.bytes

        if slice == -1 {
            for i in 0 ..< pixList.count {
                guard let pix = pixList[i] as? DCMPix else { continue }
                let width = Int32(truncatingIfNeeded: pix.pwidth), height = Int32(truncatingIfNeeded: pix.pheight)

                if memchr(buffer, 255, Int(width &* height)) != nil {
                    let theNewROI: ROI = ROI(texture: buffer, textWidth: width, textHeight: height, textName: name,
                                             positionX: 0, positionY: 0, spacingX: spacingX, spacingY: spacingY,
                                             imageOrigin: DCMPix.originCorrected(accordingToOrientation: curDCM))

                    (roiList[i] as? NSMutableArray)?.add(theNewROI)

                    NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                                    userInfo: ["ROI": theNewROI, "sliceNumber": NSNumber(value: Int32(truncatingIfNeeded: i))])
                    NotificationCenter.default.post(name: .OsirixROIChange, object: theNewROI, userInfo: nil)

                    if isPreview {
                        Self.markAsPreview(theNewROI, comment: NSLocalizedString("3D region growing preview (whole volume)", comment: ""))
                    }

                    theNewROI.roImode = Int(ROI_selected)
                    NotificationCenter.default.post(name: .OsirixROISelected, object: theNewROI, userInfo: nil)

                    theNewROI.sliceThickness = curDCM?.sliceThickness ?? 0
                }

                buffer += Int(height &* width)
            }

            // A preview must never absorb the user's existing brush ROIs:
            // merging folds them into the "Segmentation Preview" ROI, which is
            // deleted by the next click or Compute, so every previous seed
            // result would be lost when working with several seeds.
            if RegionGrowingResult.mergesVolume(name: name, previewName: previewName, merge: merge) {
                let currentImageIndex = srcViewer.imageView()?.curImage ?? 0

                for case let rois as NSMutableArray in roiList {
                    srcViewer.mergeBrushROI(self, rois: rois as? [Any], roiList: rois)
                }

                srcViewer.imageView()?.setIndex(currentImageIndex)
                srcViewer.imageView()?.sendSyncMessage(0)
                srcViewer.adjustSlider()
            }
        } else {
            // The result of the segmentation only holds one slice.
            guard let first = pixList.firstObject as? DCMPix else { return }
            let width = Int32(truncatingIfNeeded: first.pwidth), height = Int32(truncatingIfNeeded: first.pheight)

            let theNewROI: ROI = ROI(texture: buffer, textWidth: width, textHeight: height, textName: name,
                                     positionX: 0, positionY: 0, spacingX: spacingX, spacingY: spacingY,
                                     imageOrigin: DCMPix.originCorrected(accordingToOrientation: curDCM))
            _ = theNewROI.reduceTextureIfPossible()
            theNewROI.sliceThickness = curDCM?.sliceThickness ?? 0
            (roiList[slice] as? NSMutableArray)?.add(theNewROI)
            srcViewer.imageView()?.roiSet()

            NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                            userInfo: ["ROI": theNewROI, "sliceNumber": NSNumber(value: Int32(truncatingIfNeeded: slice))])
            NotificationCenter.default.post(name: .OsirixROIChange, object: theNewROI, userInfo: nil)

            if isPreview {
                Self.markAsPreview(theNewROI, comment: NSLocalizedString("2D region growing preview (this image only)", comment: ""))
            } else if RegionGrowingResult.mergesSlice(name: name, previewName: previewName, merge: merge) {
                srcViewer.imageView()?.selectAll(self)
                srcViewer.mergeBrushROI(self)
            }

            theNewROI.roImode = Int(ROI_selected)
            NotificationCenter.default.post(name: .OsirixROISelected, object: theNewROI, userInfo: nil)
        }
    }

    /// Adds the region's outline to `srcViewer` as closed polygons named
    /// `name`, one per slice whose outline has more than three lines: at most
    /// 200 points, and one in `roiResolution` (raised for the following
    /// slices when a slice needs more to stay under 200).
    @MainActor
    func addPolygons(to srcViewer: ViewerController, mask: IsiXITKMask, slice: Int, name: String, roiResolution: Int) {
        let pixList: NSArray = srcViewer.pixList() ?? NSMutableArray()
        let plane = mask.width * mask.height
        var resolution = roiResolution
        var buffer = mask.bytes
        var image = [UInt8](repeating: 0, count: plane)

        for i in RegionGrowingResult.slices(slice: slice, sliceCount: pixList.count) {
            guard let curPix = pixList[i] as? DCMPix else { continue }
            let width = Int32(truncatingIfNeeded: curPix.pwidth), height = Int32(truncatingIfNeeded: curPix.pheight)

            var contour: IsiXVTKContour? = nil
            image.withUnsafeMutableBufferPointer { slice in
                guard let base = slice.baseAddress else { return }
                base.update(from: buffer, count: plane)
                if curPix.pwidth * curPix.pheight <= plane {
                    ContourTracing.clearBorder(base, width: curPix.pwidth, height: curPix.pheight)
                }
                do {
                    contour = try IsiXVTKContour.trace(base, width: mask.width, height: mask.height, tracer: .contourFilter,
                                                       largestRegion: true)
                } catch {
                    NSLog("Region outline failed: %@", error.localizedDescription)
                }
            }

            if let contour, ContourTracing.makesPolygon(lineCount: contour.lineCount), let newROI = srcViewer.horosMakeROI(.tCPolygon),
               let points = newROI.points {
                // VTK's pixel centres become the ROI's pixel corners; the
                // points go through floats, as -newPoint:: took them.
                for index in ContourTracing.pointOrder(lineCount: contour.lineCount) where index < contour.pointCount {
                    points.add(MyPoint(point: NSPoint(x: CGFloat(Float(contour.x(at: index) + 0.5)),
                                                      y: CGFloat(Float(contour.y(at: index) + 0.5)))))
                }

                resolution = ContourTracing.resolution(pointCount: points.count, numPoints: RegionGrowingResult.polygonMaximumPoints,
                                                       resolution: resolution)
                let kept = ContourTracing.keptIndices(count: points.count, resolution: resolution)
                if kept.count != points.count {
                    points.setArray(kept.map { points[$0] })
                }

                let roiSeriesList: NSArray = srcViewer.roiList() ?? NSMutableArray()
                let roiImageList = roiSeriesList[slice == -1 ? i : (srcViewer.imageView()?.curImage ?? 0)] as? NSMutableArray

                newROI.name = name
                roiImageList?.add(newROI)
                srcViewer.imageView()?.roiSet()
                srcViewer.needsDisplayUpdate()
            }

            buffer += Int(height &* width)
        }
    }

    /// Colours `roi` as the preview and says so in its comments.
    private static func markAsPreview(_ roi: ROI, comment: String) {
        let colour = RegionGrowingResult.previewColour
        roi.rgbcolor = RGBColor(red: colour.red, green: colour.green, blue: colour.blue)
        roi.comments = comment
    }
}
