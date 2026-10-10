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

import Foundation

/// The ROI a deletion leaves selected, so that pressing Delete again removes
/// the slice's ROIs from the newest to the oldest without a click between.
@objc(HorosROIDeletionSuccessor)
public final class ROIDeletionSuccessor: NSObject {
    @objc public static let preferenceKey = "ROISelectPreviousAfterDelete"

    @objc public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// The first ROI of `rois` that a click could select and Delete remove.
    /// A slice's list runs from the front to the back: a new ROI is brought
    /// to the front, at its start, so the list goes from the newest to the
    /// oldest, and it is saved and read back in that order. Bring to Front
    /// and Send to Back move a ROI in it, and the one on top comes first. A
    /// hidden or unselectable ROI cannot be selected by a click, and a locked
    /// one cannot be deleted: choosing it would stop the sequence of
    /// deletions.
    @objc(successorAmongROIs:)
    public static func successor(among rois: [NSObject]) -> NSObject? {
        rois.first { roi in
            roi.value(forKey: "hidden") as? Bool == false
                && roi.value(forKey: "locked") as? Bool == false
                && roi.value(forKey: "selectable") as? Bool == true
        }
    }
}
