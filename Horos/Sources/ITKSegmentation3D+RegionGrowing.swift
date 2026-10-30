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

// The region growing: from a seed in the viewer's series, with one of the four
// algorithms of the region growing window (RegionGrowingFilter), ITK grows the
// region in the whole volume or in one slice (IsiXITKRegionGrowing), and the
// region becomes a new series' voxels, brush ROIs or polygons
// (ITKSegmentation3D+Results.swift).
extension ITKSegmentation3D {

    /// Grows the region of `srcViewer`'s series from `startingPoint` (pixels of
    /// the image shown) in the whole volume (`slice` -1) or in `slice`, with
    /// algorithm `algorithmNumber` and its `parameters` (numbers), and:
    /// - with `destViewer`, sets the region's voxels of its series to `inValue`
    ///   (`setIn`) or to the source's;
    /// - with `roiType` 0, adds brush ROIs named `newname` to the source viewer,
    ///   merged with those there when `mergeWithExistingROIs`;
    /// - else adds the region's outline as closed polygons named `newname`, of
    ///   at most 200 points and one in `roiResolution`.
    /// `setOut` and `outValue` are not read: the caller fills a new series with
    /// the outside value.
    @MainActor
    @objc(regionGrowing3D::::::::::::::)
    public func regionGrowing3D(_ srcViewer: ViewerController!, _ destViewer: ViewerController?, _ slice: Int,
                                _ startingPoint: NSPoint, _ algorithmNumber: Int32, _ parameters: [Any]?, _ setIn: Bool,
                                _ inValue: Float, _ setOut: Bool, _ outValue: Float, _ roiType: ToolMode,
                                _ roiResolution: Int, _ newname: String?, _ mergeWithExistingROIs: Bool) {
        guard let srcViewer else { return }

        let seed = RegionGrowingFilter.seed(x: Double(startingPoint.x), y: Double(startingPoint.y), slice: slice,
                                            currentImage: srcViewer.imageView()?.curImage ?? 0)
        let filter = RegionGrowingFilter.of(algorithm: Int(algorithmNumber),
                                            float: { Self.parameter(parameters, $0)?.floatValue ?? 0 },
                                            integer: { Self.parameter(parameters, $0)?.int32Value ?? 0 },
                                            seedValue: { srcViewer.imageView()?.curDCM?.getPixelValueX(seed.x, y: seed.y) ?? 0 })

        var wait: WaitRendering? = nil
        if slice == -1 {
            wait = WaitRendering(NSLocalizedString("Propagating Region...", comment: ""))
        }
        wait?.showWindow(self)

        NSLog("RegionGrowing starts...")

        var mask: IsiXITKMask? = nil
        if let filter {
            do {
                mask = try IsiXITKRegionGrowing.grow(volume, seedX: seed.x, y: seed.y, z: seed.z,
                                                     parameters: Self.adapterParameters(filter))
            } catch {
                NSLog("RegionGrowing failed... %@", error.localizedDescription)
            }
        } else {
            NSLog("RegionGrowing failed... no algorithm %d", algorithmNumber)
        }

        NSLog("Done...")

        if let mask {
            wait?.setString(NSLocalizedString("Preparing Results...", comment: "Preparing Results..."))
            let name = newname ?? ""
            if let destViewer {
                fillSeries(of: destViewer, from: srcViewer, mask: mask, slice: slice, setIn: setIn, inValue: inValue)
            } else if roiType.rawValue == 0 {
                addBrushROIs(to: srcViewer, mask: mask, slice: slice, name: name, merge: mergeWithExistingROIs)
                srcViewer.needsDisplayUpdate()
            } else {
                addPolygons(to: srcViewer, mask: mask, slice: slice, name: name, roiResolution: roiResolution)
            }
        }

        wait?.close()
    }

    /// Parameter `index` of the region growing, a number (or a numeric string).
    private static func parameter(_ parameters: [Any]?, _ index: Int) -> NSNumber? {
        guard let parameters, index >= 0, index < parameters.count else { return nil }
        switch parameters[index] {
        case let number as NSNumber: return number
        case let text as NSString: return NSNumber(value: text.floatValue)
        default: return nil
        }
    }

    /// The adapter's description of `filter`.
    private static func adapterParameters(_ filter: RegionGrowingFilter) -> IsiXITKRegionGrowingParameters {
        var parameters = IsiXITKRegionGrowingParameters()
        switch filter {
        case let .connectedThreshold(lower, upper):
            parameters.filter = .connectedThreshold
            parameters.lower = lower
            parameters.upper = upper
        case let .neighborhoodConnected(lower, upper, radius):
            parameters.filter = .neighborhoodConnected
            parameters.lower = lower
            parameters.upper = upper
            parameters.radius = radius
        case let .confidenceConnected(multiplier, iterations, radius):
            parameters.filter = .confidenceConnected
            parameters.multiplier = multiplier
            parameters.iterations = iterations
            parameters.radius = radius
        }
        return parameters
    }
}
