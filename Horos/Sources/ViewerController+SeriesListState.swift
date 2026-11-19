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

/// The series list and the series menu: whether they are to be built again, whether the list was built while shown, the split view made when the nib had none, the contextual menu of the series, and the highlight of the viewer with its timer.
final class ViewerSeriesListState: @unchecked Sendable {
    /// The pending scroll of the other viewers' lists after this one's scrolled.
    var scrollSyncTimer: Timer?
}

extension ViewerController {
    var horos_matrixPreviewBuilt: Bool {
        get { _matrixPreviewBuilt }
        set { _matrixPreviewBuilt = newValue }
    }
    var horos_needsToBuildSeriesPopupMenu: Bool {
        get { _needsToBuildSeriesPopupMenu }
        set { _needsToBuildSeriesPopupMenu = newValue }
    }
    var horos_needsToBuildSeriesMatrix: Bool {
        get { _needsToBuildSeriesMatrix }
        set { _needsToBuildSeriesMatrix = newValue }
    }
    var horos_splitViewAllocated: Bool {
        get { _splitViewAllocated }
        set { _splitViewAllocated = newValue }
    }
    var horos_flagListPODComparatives: NSNumber? {
        get { _flagListPODComparatives }
        set { _flagListPODComparatives = newValue }
    }
    var horos_seriesPopupContextualMenu: NSMenuItem? {
        get { _seriesPopupContextualMenu }
        set { _seriesPopupContextualMenu = newValue }
    }
    var horos_highLighted: Float {
        get { _highLighted }
        set { _highLighted = newValue }
    }
    var horos_highLightedTimer: Timer? {
        get { _highLightedTimer.wrappedValue }
        set { _highLightedTimer.wrappedValue = newValue }
    }
    var horos_scrollSyncTimer: Timer? {
        get { seriesListState.scrollSyncTimer }
        set { seriesListState.scrollSyncTimer = newValue }
    }
}
