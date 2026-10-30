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
    var matrixPreviewBuilt: Bool = false
    var needsToBuildSeriesPopupMenu: Bool = false
    var needsToBuildSeriesMatrix: Bool = false
    var splitViewAllocated: Bool = false
    var flagListPODComparatives: NSNumber?
    var seriesPopupContextualMenu: NSMenuItem?
    var highLighted: Float = 0
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var highLightedTimer: Timer?
}

extension ViewerController {
    var horos_matrixPreviewBuilt: Bool {
        get { seriesListState.matrixPreviewBuilt }
        set { seriesListState.matrixPreviewBuilt = newValue }
    }
    var horos_needsToBuildSeriesPopupMenu: Bool {
        get { seriesListState.needsToBuildSeriesPopupMenu }
        set { seriesListState.needsToBuildSeriesPopupMenu = newValue }
    }
    var horos_needsToBuildSeriesMatrix: Bool {
        get { seriesListState.needsToBuildSeriesMatrix }
        set { seriesListState.needsToBuildSeriesMatrix = newValue }
    }
    var horos_splitViewAllocated: Bool {
        get { seriesListState.splitViewAllocated }
        set { seriesListState.splitViewAllocated = newValue }
    }
    var horos_flagListPODComparatives: NSNumber? {
        get { seriesListState.flagListPODComparatives }
        set { seriesListState.flagListPODComparatives = newValue }
    }
    var horos_seriesPopupContextualMenu: NSMenuItem? {
        get { seriesListState.seriesPopupContextualMenu }
        set { seriesListState.seriesPopupContextualMenu = newValue }
    }
    var horos_highLighted: Float {
        get { seriesListState.highLighted }
        set { seriesListState.highLighted = newValue }
    }
    var horos_highLightedTimer: Timer? {
        get { seriesListState.highLightedTimer }
        set { seriesListState.highLightedTimer = newValue }
    }
}
