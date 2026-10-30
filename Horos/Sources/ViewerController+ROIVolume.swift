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

import Foundation
import IsiXROI

// The volume of the ROIs named like a given one through the slices of the
// frame shown: optionally the missing ROIs morphed in between first, then the
// volume by HorosROIVolumeGeometry, the contour points in patient
// coordinates for the surface renderer and the statistics of the pixel values
// under the ROIs. The statistics and the thinning of the points are IsiXROI's
// ROIValueStatistics and ROIVolumePoints. The selectors are those of the
// former Objective-C methods.

public extension ViewerController {

    @objc(computeVolume:points:error:)
    func computeVolume(_ selectedRoi: ROI!, points pts: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Float {
        computeVolume(selectedRoi, points: pts, generateMissingROIs: false, generatedROIs: nil, computeData: nil, error: error)
    }

    @objc(computeVolume:points:generateMissingROIs:error:)
    func computeVolume(_ selectedRoi: ROI!, points pts: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!,
                       generateMissingROIs: Bool, error: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Float {
        computeVolume(selectedRoi, points: pts, generateMissingROIs: generateMissingROIs, generatedROIs: nil, computeData: nil, error: error)
    }

    /// The volume in cm³ of the ROIs named like `selectedRoi` (0 with
    /// `error` set when it cannot be computed).
    ///
    /// With `generateMissingROIs`, ROIs are morphed into the slices between
    /// two ROIs of that name first (and, without `generatedROIs`, the ones
    /// generated before are deleted); `generatedROIs` collects the new ones.
    /// `pts` receives the contour points in patient coordinates, closed by
    /// three points above and below; `data` the statistics of the values
    /// under the ROIs, with the volume and the ROIs.
    @objc(computeVolume:points:generateMissingROIs:generatedROIs:computeData:error:)
    func computeVolume(_ selectedRoi: ROI!, points pts: AutoreleasingUnsafeMutablePointer<NSMutableArray?>!,
                       generateMissingROIs: Bool, generatedROIs: NSMutableArray!, computeData data: NSMutableDictionary!,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Float {
        let movie = Int(horos_curMovieIndex)
        let slices = horos_pixList(at: movie) ?? NSMutableArray()
        let roiList = horos_roiList(at: movie) ?? NSMutableArray()
        let name = selectedRoi?.name

        var missingSlice = false
        var theSlices: [(roi: ROI, pix: DCMPix)] = []
        var volumeSlices: [ROIVolumeSlice] = []
        var seriesOrigins: [ROIPatientPoint] = []

        if let pts { pts.pointee = NSMutableArray() }
        if let error { error.pointee = nil }

        NSLog("computeVolume started")

        // Explicit interpolation only. Occupied-only volume is HorosROIVolumeGeometry.
        if generateMissingROIs {
            // Surface preparation tracks temporary additions in generatedROIs.
            // Keep existing interpolated contours: deleting them here and then
            // removing their replacements changes the source ROI and its volume.
            // The explicit Generate Missing ROIs command still regenerates them.
            if generatedROIs == nil {
                roiDeleteGeneratedROIs(forName: name)
            }

            var lastROI: ROI?
            var lastImageIndex = -1
            for x in 0..<slices.count {
                let sliceROIs = roiList.object(at: x) as! NSMutableArray
                var i = 0
                while i < sliceROIs.count {
                    let curROI = sliceROIs.object(at: i) as! ROI
                    i += 1
                    guard viewerIsEqualToString(curROI.name, name), curROI.isValidForVolume() else { continue }

                    if let lastROI, lastImageIndex + 1 < x {
                        for y in (lastImageIndex + 1)..<x {
                            let ratio = Float(y - lastImageIndex) / Float(x - lastImageIndex)
                            if let c = roiMorphingBetween(lastROI, and: curROI, ratio: ratio) {
                                c.comments = "morphing generated"
                                c.name = name
                                horos_imageView?.roiSet(c)
                                (roiList.object(at: y) as! NSMutableArray).add(c)

                                generatedROIs?.add(c)
                                NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                                                userInfo: ["ROI": c, "sliceNumber": NSNumber(value: x)])
                            }
                        }
                    }

                    lastImageIndex = x
                    lastROI = curROI
                }
            }

            NSLog("generated ROI done")
        }

        var globalCount = 0
        var lastImageIndex = -1
        for case let seriesPix as DCMPix in slices {
            seriesOrigins.append(ROIPatientPoint(x: Double(seriesPix.originX), y: Double(seriesPix.originY), z: Double(seriesPix.originZ)))
        }

        var fROI: ROI?, lROI: ROI?
        var fROIIndex = 0, lROIIndex = 0
        let queue = OperationQueue()
        let lock: AnyObject = self
        nonisolated(unsafe) let sink = pts?.pointee

        for x in 0..<slices.count {
            let pic = slices.object(at: x) as! DCMPix
            var imageCount = 0
            var sliceArea = 0.0

            let sliceROIs = roiList.object(at: x) as! NSMutableArray
            for i in 0..<sliceROIs.count {
                let curROI = sliceROIs.object(at: i) as! ROI
                guard viewerIsEqualToString(curROI.name, name), curROI.isValidForVolume() else { continue }

                if fROI == nil {
                    fROI = curROI
                    fROIIndex = x
                }
                lROI = curROI
                lROIIndex = x

                globalCount += 1
                imageCount += 1

                let curPix = slices.object(at: x) as! DCMPix
                let curArea = curROI.roiArea()

                curROI.pix = curPix

                if curArea == 0 {
                    error?.pointee = NSLocalizedString("One ROI has an area equal to ZERO!", comment: "") as NSString
                    return 0
                }

                sliceArea += Double(curArea)

                if let sink {
                    nonisolated(unsafe) let roi = curROI, slice = pic, owner = lock, target = sink
                    queue.addOperation {
                        ViewerController.appendContourPoints(of: roi, on: slice, to: target, lockedBy: owner)
                    }
                }

                theSlices.append((curROI, curPix))
            }

            if imageCount > 0 {
                if lastImageIndex >= 0 && lastImageIndex + 1 < x {
                    missingSlice = true
                }

                var orientation = [Float](repeating: 0, count: 9)
                pic.orientation(&orientation)
                volumeSlices.append(ROIVolumeSlice(areaCm2: sliceArea,
                                                   originX: Double(pic.originX), originY: Double(pic.originY), originZ: Double(pic.originZ),
                                                   normalX: Double(orientation[6]), normalY: Double(orientation[7]), normalZ: Double(orientation[8]),
                                                   componentCount: imageCount, maskPixelCount: 0, pixelAreaMm2: 0,
                                                   spacingBetweenSlicesMm: Double(pic.spacingBetweenSlices)))
                lastImageIndex = x
            }
        }

        while queue.operationCount > 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let measured = ROIVolumeGeometry.volume(from: volumeSlices, seriesOrigins: seriesOrigins, interpolateMissing: false, meshPointCount: 0)
        guard let measured, measured.occupiedPlaneCount >= 2 else {
            error?.pointee = NSLocalizedString("I found only ONE ROI : not possible to compute a volume!", comment: "") as NSString
            return 0
        }
        var volume = measured.volumeCm3
        if volume == 0 {
            error?.pointee = NSLocalizedString("Not possible to compute a volume!", comment: "") as NSString
            return 0
        }

        NSLog("********")

        if let sink {
            if let fROI, let lROI {
                // Close the floor and the ceil of the volume: three points
                // around the centroid of the first and of the last ROI, one
                // slice further out.
                if fROIIndex > 0 { fROIIndex -= 1 }
                if lROIIndex < slices.count - 1 { lROIIndex += 1 }

                for (roi, index) in [(fROI, fROIIndex), (lROI, lROIIndex)] {
                    let pic = slices.object(at: index) as! DCMPix
                    let centroid = roi.centroid()
                    var location = [Float](repeating: 0, count: 3)
                    pic.convertX(Float(centroid.x), pixY: Float(centroid.y), toDICOMCoords: &location, pixelCenter: true)
                    sink.add(Self.point3D(location[0] - 1, location[1] - 1, location[2]))
                    sink.add(Self.point3D(location[0] - 1, location[1] + 1, location[2]))
                    sink.add(Self.point3D(location[0], location[1], location[2]))
                }
            }

            if sink.count == 0 {
                error?.pointee = NSLocalizedString("Not possible to compute a volume!", comment: "") as NSString
                return 0
            }
        }

        NSLog("volume computation done")

        if let sink, sink.count > 0 {
            NSLog("number of points: %d", Int32(truncatingIfNeeded: sink.count))

            // Display-only decimation. The source volume is HorosROIVolumeGeometry, already stored.
            if let kept = ROIVolumePoints.keptIndices(count: sink.count) {
                let thinned = NSMutableArray(capacity: ROIVolumePoints.displayLimit * 2)
                for i in kept { thinned.add(sink.object(at: i)) }

                NSLog("too much points, reducing from: %d, to: %d", Int32(truncatingIfNeeded: sink.count), Int32(truncatingIfNeeded: thinned.count))

                sink.removeAllObjects()
                sink.addObjects(from: thinned as! [Any])
            }
        }

        if let data {
            if missingSlice {
                NSLog("**** Warning cannot compute data on a ROI with missing slices. Turn generateMissingROIs to TRUE to solve this.")
            } else {
                var values: [Float] = []
                let rois = NSMutableArray()
                for (roi, pix) in theSlices {
                    rois.add(roi)
                    var count = 0
                    if let buffer = pix.getROIValue(&count, roi, nil) {
                        values.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))
                        free(buffer)
                    }
                }

                let skewnessAndKurtosis = UserDefaults.standard.bool(forKey: "ROIComputeSkewnessAndKurtosis")
                var statistics = ROIValueStatistics(min: 0, max: 0, mean: 0, total: 0, deviation: 0)
                var skewness = 0.0, kurtosis = 0.0
                values.withUnsafeBufferPointer { buffer in
                    guard let computed = ROIValueStatistics.of(buffer), let base = buffer.baseAddress else { return }
                    statistics = computed
                    if skewnessAndKurtosis {
                        let pointer = UnsafeMutablePointer(mutating: base)
                        skewness = Double(DCMPix.skewness(pointer, length: buffer.count, mean: computed.mean))
                        kurtosis = Double(DCMPix.kurtosis(pointer, length: buffer.count, mean: computed.mean))
                    }
                }

                data["min"] = NSNumber(value: statistics.min)
                data["max"] = NSNumber(value: statistics.max)
                data["mean"] = NSNumber(value: statistics.mean)
                data["total"] = NSNumber(value: statistics.total)
                data["dev"] = NSNumber(value: statistics.deviation)
                if skewnessAndKurtosis {
                    data["skewness"] = NSNumber(value: skewness)
                    data["kurtosis"] = NSNumber(value: kurtosis)
                }
                data["volume"] = NSNumber(value: abs(volume))
                data["rois"] = rois
            }
        }

        NSLog("data computation done")

        if globalCount == 1 {
            error?.pointee = NSLocalizedString("I found only ONE ROI : not possible to compute a volume!", comment: "") as NSString
            return 0
        }

        if volume < 0 { volume = -volume }

        return Float(volume)
    }
}

extension ViewerController {

    /// One point of the surface: patient coordinates as three NSNumber floats.
    nonisolated fileprivate static func point3D(_ x: Float, _ y: Float, _ z: Float) -> NSArray {
        [NSNumber(value: x), NSNumber(value: y), NSNumber(value: z)]
    }

    /// Adds the contour of `roi` on `pix` to `sink` in patient coordinates:
    /// the outline of a brush ROI's mask (100 points), the spline of the
    /// others. Runs on the operation queue of -computeVolume:...; `sink` is
    /// written under the viewer's lock.
    nonisolated fileprivate static func appendContourPoints(of roi: ROI, on pix: DCMPix, to sink: NSMutableArray, lockedBy owner: AnyObject) {
        let points: NSMutableArray?
        if roi.type == .tPlain {
            points = ITKSegmentation3D.extractContour(roi.textureBuffer, width: Int(roi.textureWidth), height: Int(roi.textureHeight),
                                                      numPoints: 100, largestRegion: false)
            let mx = Float(roi.textureUpLeftCornerX), my = Float(roi.textureUpLeftCornerY)
            for case let point as MyPoint in points ?? NSMutableArray() {
                point.move(mx, my)
            }
        } else {
            points = roi.splinePoints()
        }

        for case let point as MyPoint in points ?? NSMutableArray() {
            var location = [Float](repeating: 0, count: 3)
            pix.convertX(point.x, pixY: point.y, toDICOMCoords: &location, pixelCenter: true)
            let pt3D = point3D(location[0], location[1], location[2])
            objc_sync_enter(owner)
            sink.add(pt3D)
            objc_sync_exit(owner)
        }
    }
}
