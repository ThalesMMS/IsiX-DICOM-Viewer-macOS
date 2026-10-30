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
extension ViewerController: @MainActor ROIEnhancementViewerProcessing {

    @objc(roiEnhancementPixAtMovie:slice:)
    func roiEnhancementPix(atMovie movie: Int, slice: Int) -> DCMPix? {
        let list: NSMutableArray = self.maxMovieIndex() > 1 ? self.pixList(movie) : self.pixList()
        if slice < 0 || slice >= list.count {
            return nil
        }
        return (list[slice] as! DCMPix)
    }

    @objc(roiEnhancementProcessCurrentSeries)
    public func roiEnhancementProcessCurrentSeries() -> NSDictionary {
        if self.maxMovieIndex() < 2 {
            return ["code": NSNumber(value: Int32(1)), "reason": "ROI Enhancement needs a dynamic (4D) series with at least two phases, or prepared phantom frames.", "curves": NSArray()]
        }

        let slice = Int(self.imageView().curImage)
        let roiSlices: NSMutableArray = self.roiList()
        if slice < 0 || slice >= roiSlices.count {
            return ["code": NSNumber(value: Int32(3)), "reason": "ROI Enhancement needs an open dynamic 2D viewer series with a ROI, or prepared phantom frames.", "curves": NSArray()]
        }

        var usable: [ROI] = []
        for roi in roiSlices[slice] as! NSArray {
            let roi = roi as! ROI
            if roi.roiArea() > 0 {
                usable.append(roi)
            }
        }
        if usable.count == 0 {
            return ["code": NSNumber(value: Int32(2)), "reason": "ROI Enhancement needs at least one ROI with area.", "curves": NSArray()]
        }

        // The time of each phase: its acquisition time, else the date the
        // database filed its image under, as the plugin API gives it.
        var acquisitionDates: [Date?] = []
        var filedDates: [Date?] = []
        for movie in 0..<Int(self.maxMovieIndex()) {
            let pix = self.roiEnhancementPix(atMovie: movie, slice: slice)
            acquisitionDates.append(pix.flatMap(roiEnhancementAcquisitionDate))
            filedDates.append(pix?.imageObj()?.date)
        }
        let phaseTimes = ROIEnhancement.phaseTimes(acquisition: acquisitionDates, filed: filedDates)
        var curves: [NSDictionary] = []
        curves.reserveCapacity(usable.count)

        for roi in usable {
            var times: [NSNumber] = []
            var mins: [NSNumber] = []
            var means: [NSNumber] = []
            var maxs: [NSNumber] = []
            var counts: [NSNumber] = []

            var movie = 0
            while movie < Int(self.maxMovieIndex()) {
                guard let pix = self.roiEnhancementPix(atMovie: movie, slice: slice) else {
                    return ["code": NSNumber(value: Int32(4)), "reason": "ROI Enhancement frames must share the same width and height.", "curves": NSArray()]
                }

                var min: Float = 0, mean: Float = 0, max: Float = 0
                pix.computeROI(roi, &mean, nil, nil, &min, &max)
                times.append(NSNumber(value: phaseTimes[movie]))
                mins.append(NSNumber(value: min))
                means.append(NSNumber(value: mean))
                maxs.append(NSNumber(value: max))
                counts.append(NSNumber(value: Int32(roi.roiArea() > 0 ? 1 : 0)))
                movie += 1
            }

            curves.append(ROIEnhancementEngine.curve(name: roi.name ?? "ROI",
                                                     times: times,
                                                     mins: mins,
                                                     means: means,
                                                     maxs: maxs,
                                                     counts: counts))
        }

        return ROIEnhancementEngine.result(curves: curves)
    }
}
