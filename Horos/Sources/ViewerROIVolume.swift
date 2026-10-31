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
import IsiXPreferences
import IsiXROI

/// The volume of the ROIs named like a given one through the images of the
/// time point shown: optionally the missing ROIs morphed in between first,
/// then the volume of the planes by the physical trapezoid
/// (HorosROIVolumeGeometry), the contour points of the surface in patient
/// coordinates and the statistics of the pixel values under the ROIs. The
/// ROIs and images are read here, on the main thread; IsiXROI's ROIVolumeJob
/// takes their values and decides the rest. The viewer passes itself to each
/// call: nothing here keeps it.
@MainActor enum ViewerROIVolume {

    /// What a measure answers: the volume in cm³, the surface's points, the
    /// statistics when they were asked for, and why there is no volume.
    struct Measurement {
        var volume: Float = 0
        var points: [ROIVolumeJob.Point] = []
        var statistics: [String: Any]?
        var failure: ROIVolumeJob.Failure?

        /// The points as the surface renderer reads them: three NSNumber floats each.
        var surface: [[NSNumber]] {
            points.map { [NSNumber(value: $0.x), NSNumber(value: $0.y), NSNumber(value: $0.z)] }
        }
    }

    /// Measures the volume of the ROIs named like `selected`. With
    /// `generateMissingROIs`, ROIs are morphed into the images between two
    /// ROIs of that name first (and, without `keepsGenerated`, the ones
    /// generated before are deleted); `generated` receives each new one.
    /// `surface` asks for the contour points, `values` for the statistics.
    static func measure(_ selected: ROI?, in viewer: ViewerController, surface: Bool, values: Bool,
                        generateMissingROIs: Bool, keepsGenerated: Bool, generated: (ROI) -> Void) -> Measurement {
        let movie = Int(viewer.horos_curMovieIndex)
        let images = viewer.horos_pixList(at: movie) as? [Any] ?? []
        let lists = ViewerROISlices(viewer, movie: movie)
        let name = selected?.name
        var measurement = Measurement()

        NSLog("computeVolume started")

        // Explicit interpolation only. Occupied-only volume is HorosROIVolumeGeometry.
        if generateMissingROIs {
            // Surface preparation keeps its temporary additions. Keep existing
            // interpolated contours: deleting them here and then removing their
            // replacements changes the source ROI and its volume. The explicit
            // Generate Missing ROIs command still regenerates them.
            if !keepsGenerated {
                viewer.roiDeleteGeneratedROIs(forName: name)
            }
            morphMissingROIs(named: name, in: viewer, imageCount: images.count, generated: generated)
            NSLog("generated ROI done")
        }

        var job = ROIVolumeJob()
        var measured: [(roi: ROI, pix: DCMPix)] = []
        var volumeSlices: [ROIVolumeSlice] = []
        let seriesOrigins = images.compactMap { ($0 as? DCMPix).map { ROIPatientPoint(x: Double($0.originX), y: Double($0.originY), z: Double($0.originZ)) } }
        var first: (roi: ROI, image: Int)?, last: (roi: ROI, image: Int)?

        for x in 0..<images.count {
            guard let pic = images[x] as? DCMPix else { continue }
            var imageCount = 0
            var sliceArea = 0.0

            for curROI in lists?.rois(at: x) ?? [] {
                guard viewerIsEqualToString(curROI.name, name), curROI.isValidForVolume() else { continue }

                if first == nil { first = (curROI, x) }
                last = (curROI, x)
                imageCount += 1

                let curArea = curROI.roiArea()
                curROI.pix = pic
                do {
                    try job.addROI(onImage: x, area: curArea)
                } catch {
                    measurement.failure = error
                    measurement.points = job.points
                    return measurement
                }

                sliceArea += Double(curArea)
                if surface { job.addContour(contour(of: curROI, on: pic)) }
                measured.append((curROI, pic))
            }

            if imageCount > 0 {
                var orientation = [Float](repeating: 0, count: 9)
                pic.orientation(&orientation)
                volumeSlices.append(ROIVolumeSlice(areaCm2: sliceArea,
                                                   originX: Double(pic.originX), originY: Double(pic.originY), originZ: Double(pic.originZ),
                                                   normalX: Double(orientation[6]), normalY: Double(orientation[7]), normalZ: Double(orientation[8]),
                                                   componentCount: imageCount, maskPixelCount: 0, pixelAreaMm2: 0,
                                                   spacingBetweenSlicesMm: Double(pic.spacingBetweenSlices)))
            }
        }

        let result = ROIVolumeGeometry.volume(from: volumeSlices, seriesOrigins: seriesOrigins, interpolateMissing: false, meshPointCount: 0)
        if let failure = ROIVolumeJob.failure(volumeCm3: result?.volumeCm3, occupiedPlaneCount: result?.occupiedPlaneCount ?? 0) {
            measurement.failure = failure
            measurement.points = job.points
            return measurement
        }
        let volume = result?.volumeCm3 ?? 0

        NSLog("********")

        if surface {
            // Close the floor and the ceiling of the volume: three points
            // around the centroid of the first and of the last ROI, one
            // image further out.
            if let first, let last {
                let caps = ROIVolumeJob.capImages(first: first.image, last: last.image, imageCount: images.count)
                for (roi, index) in [(first.roi, caps.floor), (last.roi, caps.ceiling)] {
                    guard let pic = images[index] as? DCMPix else { continue }
                    let centroid = roi.centroid()
                    var location = [Float](repeating: 0, count: 3)
                    pic.convertX(Float(centroid.x), pixY: Float(centroid.y), toDICOMCoords: &location, pixelCenter: true)
                    job.addCap(around: ROIVolumeJob.Point(location[0], location[1], location[2]))
                }
            }

            if let failure = job.surfaceFailure {
                measurement.failure = failure
                return measurement
            }
        }

        NSLog("volume computation done")

        if surface {
            NSLog("number of points: %d", Int32(truncatingIfNeeded: job.points.count))
            // Display-only decimation. The source volume is HorosROIVolumeGeometry, already stored.
            measurement.points = job.displayedPoints
            if measurement.points.count != job.points.count {
                NSLog("too much points, reducing from: %d, to: %d", Int32(truncatingIfNeeded: job.points.count),
                      Int32(truncatingIfNeeded: measurement.points.count))
            }
        }

        if values {
            if job.hasMissingImage {
                NSLog("**** Warning cannot compute data on a ROI with missing slices. Turn generateMissingROIs to TRUE to solve this.")
            } else {
                measurement.statistics = statistics(of: measured, volume: volume, preferences: viewer.sessionGraph.preferences)
            }
        }

        NSLog("data computation done")

        if let failure = job.countFailure {
            measurement.failure = failure
            return measurement
        }

        measurement.volume = Float(abs(volume))
        return measurement
    }

    /// Morphs a ROI named `name` into each image between two images with
    /// ROIs of that name, through the images of the current time point.
    static func morphMissingROIs(named name: String?, in viewer: ViewerController, imageCount: Int, generated: (ROI) -> Void) {
        guard let lists = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)) else { return }
        var lastROI: ROI?
        var lastImageIndex = -1
        for x in 0..<imageCount {
            guard let list = lists.list(at: x) else { continue }
            var i = 0
            while i < list.count {
                let candidate = list.object(at: i) as? ROI
                i += 1
                guard let curROI = candidate, viewerIsEqualToString(curROI.name, name), curROI.isValidForVolume() else { continue }

                if let lastROI, lastImageIndex + 1 < x {
                    for y in (lastImageIndex + 1)..<x {
                        let ratio = Float(y - lastImageIndex) / Float(x - lastImageIndex)
                        if let c = viewer.roiMorphingBetween(lastROI, and: curROI, ratio: ratio) {
                            c.comments = "morphing generated"
                            c.name = name
                            viewer.horos_imageView?.roiSet(c)
                            lists.list(at: y)?.add(c)

                            generated(c)
                            postViewerNotification(.OsirixAddROI, viewer, ["ROI": c, "sliceNumber": NSNumber(value: x)])
                        }
                    }
                }

                lastImageIndex = x
                lastROI = curROI
            }
        }
    }

    /// The contour of `roi` on `pix` in patient coordinates: the outline of
    /// a brush ROI's mask (100 points), the spline of the others.
    static func contour(of roi: ROI, on pix: DCMPix) -> [ROIVolumeJob.Point] {
        let points: [Any]
        var offset: (x: Float, y: Float) = (0, 0)
        if roi.type == .tPlain {
            points = ITKSegmentation3D.extractContour(roi.textureBuffer, width: Int(roi.textureWidth), height: Int(roi.textureHeight),
                                                      numPoints: 100, largestRegion: false) as? [Any] ?? []
            offset = (Float(roi.textureUpLeftCornerX), Float(roi.textureUpLeftCornerY))
        } else {
            points = roi.splinePoints() as? [Any] ?? []
        }

        return points.compactMap { $0 as? MyPoint }.map { point in
            if roi.type == .tPlain { point.move(offset.x, offset.y) }
            var location = [Float](repeating: 0, count: 3)
            pix.convertX(point.x, pixY: point.y, toDICOMCoords: &location, pixelCenter: true)
            return ROIVolumeJob.Point(location[0], location[1], location[2])
        }
    }

    /// The statistics of the values under the measured ROIs, with the volume
    /// and the ROIs, under the keys -computeVolume:... has always used.
    static func statistics(of measured: [(roi: ROI, pix: DCMPix)], volume: Double, preferences: any PreferenceStore) -> [String: Any] {
        var values: [Float] = []
        for (roi, pix) in measured {
            var count = 0
            if let buffer = pix.getROIValue(&count, roi, nil) {
                values.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))
                free(buffer)
            }
        }

        let skewnessAndKurtosis = preferences[ViewerPreferences.roiComputesSkewnessAndKurtosis]
        let statistics = ROIVolumeJob.statistics(of: values)
        var skewness = 0.0, kurtosis = 0.0
        if skewnessAndKurtosis, !values.isEmpty {
            values.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                skewness = Double(DCMPix.skewness(base, length: buffer.count, mean: statistics.mean))
                kurtosis = Double(DCMPix.kurtosis(base, length: buffer.count, mean: statistics.mean))
            }
        }

        var data: [String: Any] = ["min": NSNumber(value: statistics.min), "max": NSNumber(value: statistics.max),
                                   "mean": NSNumber(value: statistics.mean), "total": NSNumber(value: statistics.total),
                                   "dev": NSNumber(value: statistics.deviation),
                                   "volume": NSNumber(value: abs(volume)),
                                   // The mutable list the dictionary has always held.
                                   "rois": NSMutableArray(array: measured.map(\.roi))]
        if skewnessAndKurtosis {
            data["skewness"] = NSNumber(value: skewness)
            data["kurtosis"] = NSNumber(value: kurtosis)
        }
        return data
    }
}
