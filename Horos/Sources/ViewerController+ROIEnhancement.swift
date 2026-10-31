//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/*
 ViewerController+ROIEnhancement.m
 Horos
*/

import AppKit

/// pix.acquisitionTime, or nil without an acquisition time. The property is an
/// NSCalendarDate, which Swift does not import, so it is read through its
/// getter by key.
fileprivate func roiEnhancementAcquisitionDate(_ pix: DCMPix) -> Date? {
    pix.value(forKey: "acquisitionTime") as? Date
}

/// The ViewerController (ROIEnhancement) category, in Swift: the
/// selectors and <Horos/ViewerController+ROIEnhancement.h> are those of the
/// former category, which also adopted ROIEnhancementViewerProcessing.
/// ROIEnhancementFilter sends -roiEnhancementProcessCurrentSeries by selector.
/// The curves are ViewerROIEnhancement's.
extension ViewerController: @MainActor ROIEnhancementViewerProcessing {

    @objc(roiEnhancementPixAtMovie:slice:)
    func roiEnhancementPix(atMovie movie: Int, slice: Int) -> DCMPix? {
        ViewerROIEnhancement.pix(atMovie: movie, slice: slice, in: self)
    }

    @objc(roiEnhancementProcessCurrentSeries)
    public func roiEnhancementProcessCurrentSeries() -> NSDictionary {
        ViewerROIEnhancement.curves(of: self)
    }
}

/// The time-attenuation curves of the ROIs of the image shown, across the
/// time points of a dynamic series: for each phase, the minimum, mean and
/// maximum of each ROI with an area, as ROIEnhancementEngine records them.
@MainActor enum ViewerROIEnhancement {

    /// The outcome of a series the curves cannot be drawn for.
    static func refusal(_ code: ROIEnhancement.ErrorCode, _ reason: String) -> NSDictionary {
        ["code": NSNumber(value: Int32(code.rawValue)), "reason": reason, "curves": [Any]()]
    }

    /// Image `slice` of time point `movie` (of the series shown with one time
    /// point), nil past the series.
    static func pix(atMovie movie: Int, slice: Int, in viewer: ViewerController) -> DCMPix? {
        let list = viewer.maxMovieIndex() > 1 ? viewer.pixList(movie) : viewer.pixList()
        guard let list, slice >= 0, slice < list.count else { return nil }
        return list[slice] as? DCMPix
    }

    /// The curves of the ROIs with an area of the image shown, or why there
    /// are none.
    static func curves(of viewer: ViewerController) -> NSDictionary {
        let movieCount = Int(viewer.maxMovieIndex())
        if movieCount < 2 {
            return refusal(.tooFewPhases, "ROI Enhancement needs a dynamic (4D) series with at least two phases, or prepared phantom frames.")
        }

        let slice = Int(viewer.imageView().curImage)
        guard let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)), slice >= 0, slice < slices.count else {
            return refusal(.emptySeries, "ROI Enhancement needs an open dynamic 2D viewer series with a ROI, or prepared phantom frames.")
        }

        let usable = slices.rois(at: slice).filter { $0.roiArea() > 0 }
        if usable.isEmpty {
            return refusal(.missingROI, "ROI Enhancement needs at least one ROI with area.")
        }

        // The time of each phase: its acquisition time, else the date the
        // database filed its image under, as the plugin API gives it.
        let phases = (0..<movieCount).map { pix(atMovie: $0, slice: slice, in: viewer) }
        let phaseTimes = ROIEnhancement.phaseTimes(acquisition: phases.map { $0.flatMap(roiEnhancementAcquisitionDate) },
                                                   filed: phases.map { $0?.imageObj()?.date })
        let frames = phases.compactMap { $0 }
        if frames.count != phases.count {
            return refusal(.sizeMismatch, "ROI Enhancement frames must share the same width and height.")
        }

        let curves = usable.map { roi in
            var mins: [NSNumber] = [], means: [NSNumber] = [], maxs: [NSNumber] = []
            for pix in frames {
                var min: Float = 0, mean: Float = 0, max: Float = 0
                pix.computeROI(roi, &mean, nil, nil, &min, &max)
                mins.append(NSNumber(value: min))
                means.append(NSNumber(value: mean))
                maxs.append(NSNumber(value: max))
            }
            return ROIEnhancementEngine.curve(name: roi.name ?? "ROI", times: phaseTimes.map { NSNumber(value: $0) },
                                              mins: mins, means: means, maxs: maxs,
                                              counts: frames.map { _ in NSNumber(value: Int32(1)) })
        }
        return ROIEnhancementEngine.result(curves: curves)
    }
}
