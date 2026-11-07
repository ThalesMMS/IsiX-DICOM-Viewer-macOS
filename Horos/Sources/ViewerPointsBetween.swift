//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXROI

// ROI ▸ Create Points Between Two Points: with exactly two point ROIs on the
// images of the time point shown, a point ROI every millimetre of the straight
// line between them, each on the image whose plane is nearest to it. Which
// image and where on it are IsiXROI's (ROIPointsBetween), from the planes of
// the images; here the viewer's images become planes and the placements
// become ROIs, added to the images' ROI lists and announced as a ROI drawn
// there, so that they are saved with the others and drawn when their image is
// shown. The menu item is ViewerStudyCommands', offered with exactly two
// point ROIs.

/// The points of the line between the two point ROIs of a viewer's series.
@MainActor enum ViewerPointsBetween {

    /// A point ROI and the index of the image it is on.
    struct Endpoint {
        let roi: ROI
        let slice: Int
    }

    /// The point ROIs of the images of the time point shown, in image order;
    /// a ROI shown on several images counts once, on the first.
    static func points(of viewer: ViewerController) -> [Endpoint] {
        let movie = Int(viewer.horos_curMovieIndex)
        guard let slices = ViewerROISlices(viewer, movie: movie) else { return [] }
        let count = min(slices.count, viewer.horos_pixList(at: movie)?.count ?? 0)
        var seen = Set<ObjectIdentifier>()
        var points: [Endpoint] = []
        for slice in 0..<count {
            for roi in slices.rois(at: slice) where roi.type == .t2DPoint && seen.insert(ObjectIdentifier(roi)).inserted {
                points.append(Endpoint(roi: roi, slice: slice))
            }
        }
        return points
    }

    /// The plane of `pix` in the patient, from its origin, orientation and
    /// pixel spacing; an image without an orientation is axial.
    static func plane(of pix: DCMPix) -> ROISlicePlane {
        var cosines = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&cosines)
        return ROISlicePlane(origin: SIMD3(pix.originX, pix.originY, pix.originZ),
                             rowDirection: SIMD3(cosines[0], cosines[1], cosines[2]),
                             columnDirection: SIMD3(cosines[3], cosines[4], cosines[5]),
                             columnSpacing: pix.pixelSpacingX, rowSpacing: pix.pixelSpacingY)
    }

    /// The point of a point ROI in the patient: the ROI keeps the centre of a
    /// pixel at half coordinates, the plane at whole ones.
    static func patientPoint(of roi: ROI, on plane: ROISlicePlane) -> SIMD3<Double> {
        let origin = roi.rect.origin
        return plane.patientPoint(column: Double(origin.x) - 0.5, row: Double(origin.y) - 0.5)
    }

    /// Adds a point ROI every millimetre of the line between the two point
    /// ROIs of the series, each on the image nearest to it, as one undo step,
    /// from the one on the later image towards the one on the earlier image;
    /// nothing when the series has not exactly two.
    static func add(in viewer: ViewerController) {
        let movie = Int(viewer.horos_curMovieIndex)
        let endpoints = points(of: viewer)
        guard endpoints.count == 2, let slices = ViewerROISlices(viewer, movie: movie),
              let pixList = viewer.horos_pixList(at: movie) else { return }
        let pixs = (0..<min(slices.count, pixList.count)).compactMap { pixList.object(at: $0) as? DCMPix }
        guard pixs.count == min(slices.count, pixList.count) else { return }
        let planes = pixs.map(plane(of:))
        let start = patientPoint(of: endpoints[1].roi, on: planes[endpoints[1].slice])
        let end = patientPoint(of: endpoints[0].roi, on: planes[endpoints[0].slice])
        let placements = ROIPointsBetween.placements(from: start, to: end, planes: planes)
        guard !placements.isEmpty else {
            NSSound.beep()
            return
        }

        viewer.add(toUndoQueue: "roi")
        let view = viewer.horos_imageView
        for placement in placements {
            let pix = pixs[placement.slice]
            guard let list = slices.list(at: placement.slice),
                  let roi = ROI(type: .t2DPoint, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY),
                                DCMPix.originCorrected(accordingToOrientation: pix)) else { continue }
            roi.rect = NSRect(x: placement.column + 0.5, y: placement.row + 0.5, width: 0, height: 0)
            roi.pix = pix
            view?.roiSet(roi)
            viewerArrayAdd(roi, to: list)
            if let view { ROIEventEmitter.added(roi, to: view, slice: Int32(placement.slice)) }
            ROIEventEmitter.changed(roi)
        }
        view?.needsDisplay = true
    }
}
