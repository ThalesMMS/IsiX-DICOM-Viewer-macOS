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

import AppKit
import IsiXImaging

// The "Registration" block of ViewerController: the series registered with
// this one, the point ROIs of a point-based registration, and the resampling
// of another viewer's series onto this one (same study: by orientation alone;
// otherwise by three or more pairs of named points, Horn's method). The
// orientation transform, the points' coordinates and how the points pair up
// are IsiXImaging's PointRegistration; ITKTransform resamples. The selectors
// are those of the former Objective-C methods.

public extension ViewerController {

    @objc(registeredViewer)
    func registeredViewer() -> ViewerController! {
        return horos_registeredViewer
    }

    /// Kept without retaining it, as before.
    @objc(setRegisteredViewer:)
    func setRegisteredViewer(_ viewer: ViewerController!) {
        horos_assignRegisteredViewer(viewer)
    }

    /// The point ROIs of every slice of the current movie frame, each given its
    /// slice.
    @objc(point2DList)
    func point2DList() -> NSMutableArray! {
        let points = NSMutableArray()
        let allROIs = (roiList() as NSArray?) ?? NSArray()
        let pixList = (self.pixList() as NSArray?) ?? NSArray()
        for s in 0..<allROIs.count {
            guard let rois = allROIs.object(at: s) as? NSArray else { continue }
            for i in 0..<rois.count {
                guard let roi = rois.object(at: i) as? ROI else { continue }
                roi.pix = pixList.object(at: s) as? DCMPix
                if roi.type == .t2DPoint {
                    points.add(roi)
                }
            }
        }
        return points
    }

    @objc(resampleSeriesInNewOrientation)
    func resampleSeriesInNewOrientation() -> ViewerController! {
        return nil
    }

    @objc(resampleSeries:)
    @discardableResult
    func resampleSeries(_ movingViewer: ViewerController!) -> ViewerController! {
        return resampleSeries(movingViewer, rescale: true)
    }

    /// Resamples `movingViewer`'s series onto this one's, in a new viewer:
    /// only between volumes of the same study, whose origins are shared, so
    /// that the orientations alone give the transform.
    @objc(resampleSeries:rescale:)
    @discardableResult
    func resampleSeries(_ movingViewer: ViewerController!, rescale: Bool) -> ViewerController! {
        movingViewer?.displayWarningIfGantryTitled()
        displayWarningIfGantryTitled()

        let volumic = isVolumic(), movingVolumic = movingViewer?.isVolumic() ?? false
        guard volumic && movingVolumic else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Resampling Error", comment: ""),
                                        message: NSLocalizedString("3D Resampling requires volumic data.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        guard let movingViewer, viewerIsEqualToString(studyInstanceUID(), movingViewer.studyInstanceUID()) else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Resampling Error", comment: ""),
                                        message: NSLocalizedString("Resampling is only available for series in the SAME study.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        // No translation: same origin, same study.
        var matrix = PointRegistration.orientationTransform(sensor: movingViewer.firstSliceOrientation(), model: firstSliceOrientation())

        let transform = ITKTransform(viewer: movingViewer)
        let newViewer = matrix.withUnsafeMutableBufferPointer { buffer in
            transform?.computeAffineTransform(withParameters: buffer.baseAddress, resampleOnViewer: self, rescale: rescale)
        }

        horos_imageView?.sendSyncMessage(0)
        adjustSlider()

        return newViewer
    }

    /// Point-based registration of `movingViewer`'s series onto this one: the
    /// point ROIs of the same name on both (at least three, as many on each,
    /// no name more than twice) give the rigid transform, and the moving series
    /// is resampled onto this one in a new viewer.
    @objc(computeRegistrationWithMovingViewer:)
    func computeRegistration(withMovingViewer movingViewer: ViewerController!) {
        let volumic = isVolumic(), movingVolumic = movingViewer?.isVolumic() ?? false
        guard volumic && movingVolumic, let movingViewer else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Registration Error", comment: ""),
                                        message: NSLocalizedString("3D Resampling requires volumic data.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // The point ROIs of this viewer (fixed) and of the dragged one
        // (moving), ordered by name ("Point 1" < "Point 5" < "Point 21").
        let modelPoints = point2DList() ?? NSMutableArray()
        let sensorPoints = movingViewer.point2DList() ?? NSMutableArray()
        let byName: (Any, Any) -> ComparisonResult = { a, b in
            guard let first = (a as? ROI)?.name else { return .orderedSame }
            return (first as NSString).compare((b as? ROI)?.name ?? "", options: .numeric)
        }
        modelPoints.sort(comparator: byName)
        sensorPoints.sort(comparator: byName)

        let models = modelPoints.compactMap { $0 as? ROI }
        let sensors = sensorPoints.compactMap { $0 as? ROI }
        let pairing = PointRegistration.pair(model: models.map { $0.name }, sensor: sensors.map { $0.name })

        if pairing.sameNumberOfPoints && pairing.enoughPoints {
            let horn = HornRegistration()
            let vectorSensor = movingViewer.firstSliceOrientation(), vectorModel = firstSliceOrientation()

            for pair in pairing.pairs {
                let model = PointRegistration.rotated(models[pair.model].dicomLocationOfFirstPoint(), vectorModel)
                let sensor = PointRegistration.rotated(sensors[pair.sensor].dicomLocationOfFirstPoint(), vectorSensor)
                horn.addModelPointX(Double(model[0]), y: Double(model[1]), z: Double(model[2]))
                horn.addSensorPointX(Double(sensor[0]), y: Double(sensor[1]), z: Double(sensor[2]))
            }

            if pairing.namesMatch && !pairing.triplets {
                var matrix = [Double](repeating: 0, count: 16)
                matrix.withUnsafeMutableBufferPointer { horn.computeVTK($0.baseAddress) }

                let transform = ITKTransform(viewer: movingViewer)
                _ = matrix.withUnsafeMutableBufferPointer { buffer in
                    transform?.computeAffineTransform(withParameters: buffer.baseAddress, resampleOnViewer: self)
                }

                horos_imageView?.sendSyncMessage(0)
                adjustSlider()
            }
        }

        var errors: [String] = []
        if !pairing.sameNumberOfPoints {
            // The same number of points on both viewers.
            errors.append(NSLocalizedString("Needs same number of points on both viewers.", comment: ""))
        }
        if !pairing.enoughPoints {
            // At least 3 points on both viewers.
            errors.append(NSLocalizedString("Needs at least 3 points on both viewers.", comment: ""))
        }
        if !pairing.namesMatch {
            errors.append(NSLocalizedString("Points names must match 2 by 2.", comment: ""))
        }
        if pairing.triplets {
            errors.append(NSLocalizedString("Max. 2 points with the same name.", comment: ""))
        }
        if !errors.isEmpty {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Point-Based Registration Error", comment: ""),
                                        message: errors.joined(separator: "\n"),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }
}

extension ViewerController {

    /// Whether the series is a volume a 3D resampling can use: several
    /// regularly spaced slices, or a single one with a known orientation.
    fileprivate func isVolumic() -> Bool {
        let slices = (pixList() as NSArray?) ?? NSArray()
        if slices.count > 1 {
            // Both are asked, as before: -computeInterval keeps the interval it finds.
            let regular = isDataVolumicIn4D(true)
            let interval = computeInterval()
            return regular && interval != 0
        }
        var orientation = [Double](repeating: 0, count: 9)
        (slices.lastObject as? DCMPix)?.orientationDouble(&orientation)
        return !(orientation[6] == 0 && orientation[7] == 0 && orientation[8] == 0)
    }

    /// The orientation (9 direction cosines) of the current movie frame's first slice.
    fileprivate func firstSliceOrientation() -> [Float] {
        var vectors = [Float](repeating: 0, count: 9)
        ((pixList() as NSArray?)?.object(at: 0) as? DCMPix)?.orientation(&vectors)
        return vectors
    }
}

extension ROI {

    /// The patient coordinates of the ROI's first point, at the pixel's centre.
    fileprivate func dicomLocationOfFirstPoint() -> [Float] {
        var location = [Float](repeating: 0, count: 3)
        let point = (points as NSArray?)?.object(at: 0) as? MyPoint
        pix?.convertX(Float(point?.x ?? 0), pixY: Float(point?.y ?? 0), toDICOMCoords: &location, pixelCenter: true)
        return location
    }
}
