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

import AppKit

/// ROI > Show on All Images of the Series: the selected ROIs become the same
/// ROI objects on every image of the series (an alias), so moving a point on
/// one image moves it on all of them.
///
/// This is what Shift-click with a ROI tool used to do when it drew a new ROI.
/// Shift is now only the lens of the ROI tools, and the menu command does the
/// same to ROIs already drawn. The mechanism is the one the ROI archive already
/// reads and writes: the ROI is flagged `isAliased`, remembers the image it was
/// made on in `originalIndexForAlias`, and the one object is put in every
/// image's ROI list. `-saveROI:` stores it with that image only, and
/// `-loadROI:` puts it back on the other images of the same series.
public extension ViewerController {

    /// The ROIs the command would act on, or nil when it does not apply.
    private func horosROIsForAllImagesOfSeries() -> [ROI]? {
        let rois = (self.selectedROIs() as NSArray? ?? NSArray()).compactMap { $0 as? ROI }
        let described = rois.map { roi in
            (type: Int(roi.type.rawValue), aliased: roi.isAliased, betweenSlices: roi is HorosVolumeLengthROI)
        }
        return ROIMenuEnablement.mayShowROIsOnAllImages(described) ? rois : nil
    }

    /// Menu validation: enabled when at least one ROI is selected on the current
    /// image and every selected ROI can be shown on all images.
    @objc(canShowSelectedROIsOnAllImagesOfSeries)
    func canShowSelectedROIsOnAllImagesOfSeries() -> Bool {
        return horosROIsForAllImagesOfSeries() != nil
    }

    @objc(showSelectedROIsOnAllImagesOfSeries:)
    @IBAction func showSelectedROIsOnAllImagesOfSeries(_ sender: Any?) {
        guard let imageView = self.horos_imageView else { return }
        // A ROI still being drawn is finished first, as the other ROI commands do.
        imageView.stopROIEditingForce(true)

        guard let rois = horosROIsForAllImagesOfSeries() else {
            NSSound.beep()
            return
        }

        let movie = Int(self.horos_curMovieIndex)
        let current = Int(imageView.curImage)
        guard let slices = self.horos_roiList(at: movie), current >= 0, current < slices.count else { return }
        let files = self.horos_fileList(at: movie)

        // One undo step brings back the ROIs as they were, on this image alone.
        self.add(toUndoQueue: "roi")

        // The images of another series, which a viewer can hold, are left out:
        // -loadROI: puts an alias back on the images of its own series only.
        let series = (files?.object(at: current) as? NSObject)?.value(forKey: "series") as AnyObject?

        for roi in rois {
            roi.originalIndexForAlias = Int32(current)
            roi.isAliased = true

            for index in 0..<slices.count where index != current {
                if index < (files?.count ?? 0),
                   ((files?.object(at: index) as? NSObject)?.value(forKey: "series") as AnyObject?) !== series {
                    continue
                }
                guard let slice = slices.object(at: index) as? NSMutableArray else { continue }
                if slice.indexOfObjectIdentical(to: roi) == NSNotFound {
                    slice.add(roi)
                }
            }
            NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)
        }

        imageView.setIndex(imageView.curImage)
    }
}
