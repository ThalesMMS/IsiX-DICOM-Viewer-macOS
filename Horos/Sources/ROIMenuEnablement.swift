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

/// Whether a ROI menu command applies to the current selection.
///
/// Selecting a viewer, a series and a ROI must produce *predictable*
/// enablement, and a mode which does not apply is refused explicitly rather
/// than by enabling everything. The brush merge is the case where that went
/// wrong: its validation walked the selection assigning the answer on every
/// element, so only the **last** one decided. A selection of a brush followed by
/// a polygon disabled the command, and the same two ROIs selected the other way
/// round enabled it — and the merge would then run over a ROI that is not a
/// brush.
///
/// The rule is the one the command can actually honour: at least one ROI, and
/// every one of them a brush.
@objc(HorosROIMenuEnablement)
public final class ROIMenuEnablement: NSObject {
    /// `tPlain` in `ToolMode` (DCMView.h) — the brush ROI.
    @objc public static let brushToolMode = 20

    /// `types` carries one `ToolMode` per selected ROI, in selection order.
    /// The answer must not depend on that order.
    @objc(mayMergeBrushROIsWithTypes:)
    public static func mayMergeBrushROIs(types: [NSNumber]) -> Bool {
        guard !types.isEmpty else { return false }
        return types.allSatisfy { $0.intValue == brushToolMode }
    }

    /// Whether one ROI can become the same ROI on every image of its series.
    ///
    /// These are the ROIs the old Shift-click on a 2D ROI tool made that way: a
    /// ROI of a type the tools draw. A ROI already shown on every image has
    /// nothing left to do, and a length measured between slices already belongs
    /// to the whole volume, with its own storage; a layer and the 3D types are
    /// not drawn on an image.
    @objc(mayShowROIOnAllImagesWithType:aliased:betweenSlices:)
    public static func mayShowROIOnAllImages(type: Int, aliased: Bool, betweenSlices: Bool) -> Bool {
        !aliased && !betweenSlices && ToolModeCapability.drawsROIs(toolMode: type)
    }

    /// The menu command applies to the whole selection or not at all: at least
    /// one ROI, and every one of them able to go on every image. The answer does
    /// not depend on the order of the selection.
    public static func mayShowROIsOnAllImages(_ rois: [(type: Int, aliased: Bool, betweenSlices: Bool)]) -> Bool {
        guard !rois.isEmpty else { return false }
        return rois.allSatisfy { mayShowROIOnAllImages(type: $0.type, aliased: $0.aliased, betweenSlices: $0.betweenSlices) }
    }
}
