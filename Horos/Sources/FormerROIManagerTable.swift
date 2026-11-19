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

/// The table the ROI manager showed in Horos and OsiriX, one row for each ROI
/// of the image its viewer shows. The window lists the ROIs in an outline now;
/// a plug-in of the former SDK that reads the manager as the data source of a
/// table still gets these rows.
@MainActor
struct FormerROIManagerTable {
    let viewer: ViewerController?

    private var rois: [ROI] {
        guard let viewer, let lists = viewer.roiList() as? [[Any]] else { return [] }
        let image = Int(viewer.imageView()?.curImage ?? 0)
        return lists.indices.contains(image) ? lists[image].compactMap { $0 as? ROI } : []
    }

    var count: Int { rois.count }

    /// The value of the column «Index», «Name», «area» or «volume» of a row;
    /// nil without a viewer, past the last ROI or for another column.
    func value(column: String?, row: Int) -> Any? {
        let rois = rois
        guard let viewer, rois.indices.contains(row) else { return nil }
        let roi = rois[row]
        switch column {
        case "Index": return String(row + 1)
        case "Name": return roi.name
        case "area": return NSNumber(value: roi.roiArea())
        case "volume":
            let volume = viewer.computeVolume(roi, points: nil, error: nil)
            if volume == 0 { return NSLocalizedString("n/a", comment: "Abreviation for not available") }
            return String(format: volume < 10 ? "%2.5f" : "%2.2f", volume)
        default: return nil
        }
    }
}
