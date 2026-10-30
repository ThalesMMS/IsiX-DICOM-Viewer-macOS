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

/// ITK's region growing on a viewer's series, and the outline of a mask.
///
/// The volume is handed to ITK when the object is made (ITKVolumeImport); the
/// growing and what becomes of the region are in
/// ITKSegmentation3D+RegionGrowing.swift and ITKSegmentation3D+Results.swift.
/// ITK and VTK are reached through the adapters (IsiXITKRegionGrowing,
/// IsiXVTKContour); the decisions are IsiXSegmentation's. The Objective-C
/// selectors are those of the former Objective-C++ class.
@objc(ITKSegmentation3D)
public final class ITKSegmentation3D: NSObject {

    /// The series' volume, as ITK reads it.
    let volume: IsiXITKVolume

    @objc(initWith:::)
    public convenience init?(_ pix: NSMutableArray?, _ volumeData: UnsafeMutablePointer<Float>?, _ slice: Int) {
        self.init(pix: pix, volume: volumeData, slice: slice, resampleData: false)
    }

    /// The region growing of the slices `pix` over `volumeData`, the series'
    /// volume, in the whole volume (`slice` -1) or in `slice` alone; the
    /// volume halved along every axis when `resampleData`. nil without slices
    /// or voxels.
    @objc(initWithPix:volume:slice:resampleData:)
    public init?(pix: NSMutableArray?, volume volumeData: UnsafeMutablePointer<Float>?, slice: Int, resampleData: Bool) {
        NSLog("slice ID: %d", Int32(truncatingIfNeeded: slice))
        guard let volume = ITKVolumeImport.volume(pix: pix, voxels: volumeData, slice: slice, resampleData: resampleData) else {
            return nil
        }
        self.volume = volume
        super.init()
    }

    // MARK: - Outline of a mask

    /// The outline of the `width` x `height` mask at `map` (0 or 255 a byte),
    /// in at most about 100 points, of its largest region. Sent as a message,
    /// as the Objective-C class method was, so a stand-in class can answer it.
    @objc(extractContour:width:height:)
    public dynamic class func extractContour(_ map: UnsafeMutablePointer<UInt8>?, width: Int, height: Int) -> NSMutableArray! {
        return extractContour(map, width: width, height: height, numPoints: 100)
    }

    /// The outline of the mask's largest region, in at most about `numPoints` points.
    @objc(extractContour:width:height:numPoints:)
    public class func extractContour(_ map: UnsafeMutablePointer<UInt8>?, width: Int, height: Int, numPoints: Int) -> NSMutableArray! {
        return extractContour(map, width: width, height: height, numPoints: numPoints, largestRegion: true)
    }

    /// The outline of the mask's largest region, or of all its regions, in at
    /// most about `numPoints` points (MyPoint, in the ROI's pixel-corner
    /// coordinates): VTK's marching squares on the mask, the points in
    /// ContourTracing's order, one in ContourTracing's resolution kept. Empty
    /// when the outline has three lines or fewer.
    @objc(extractContour:width:height:numPoints:largestRegion:)
    public class func extractContour(_ map: UnsafeMutablePointer<UInt8>?, width: Int, height: Int, numPoints: Int,
                                     largestRegion: Bool) -> NSMutableArray! {
        let points = NSMutableArray()
        guard let map, width > 0, height > 0 else { return points }

        let contour: IsiXVTKContour
        do {
            contour = try IsiXVTKContour.trace(map, width: width, height: height, tracer: .marchingSquares, largestRegion: largestRegion)
        } catch {
            NSLog("Contour extraction failed: %@", error.localizedDescription)
            return points
        }
        guard ContourTracing.makesPolygon(lineCount: contour.lineCount) else { return points }

        // VTK places pixel i's value at i, its centre; a ROI's pixel i spans i to i + 1.
        for index in ContourTracing.pointOrder(lineCount: contour.lineCount) where index < contour.pointCount {
            points.add(MyPoint(point: NSPoint(x: contour.x(at: index) + 0.5, y: contour.y(at: index) + 0.5)))
        }

        let resolution = ContourTracing.resolution(pointCount: points.count, numPoints: numPoints)
        let kept = ContourTracing.keptIndices(count: points.count, resolution: resolution)
        guard kept.count != points.count else { return points }
        return NSMutableArray(array: kept.map { points[$0] })
    }
}
