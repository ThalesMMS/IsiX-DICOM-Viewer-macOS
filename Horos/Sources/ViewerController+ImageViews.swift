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

/// The image views: the series view of the study view and its current image view, whether the tiling views are to be updated, and the fit to the window asked at opening.
final class ViewerImageViews: @unchecked Sendable {
    var imageView: DCMView?
    var seriesView: SeriesView?
    var updateTilingViews: Bool = false
    var openingScaleToFitRequested: Bool = false
    var openingContentBoundsByPixels: [AnyHashable: Any]?
}

extension ViewerController {
    nonisolated var horos_imageView: DCMView? {
        get { imageViewsState.imageView }
        set { imageViewsState.imageView = newValue }
    }
    nonisolated var horos_seriesView: SeriesView? {
        get { imageViewsState.seriesView }
        set { imageViewsState.seriesView = newValue }
    }
    var horos_updateTilingViews: Bool {
        get { imageViewsState.updateTilingViews }
        set { imageViewsState.updateTilingViews = newValue }
    }
    var horos_openingScaleToFitRequested: Bool {
        get { imageViewsState.openingScaleToFitRequested }
        set { imageViewsState.openingScaleToFitRequested = newValue }
    }
    var horos_openingContentBoundsByPixels: [AnyHashable: Any]? {
        get { imageViewsState.openingContentBoundsByPixels }
        set { imageViewsState.openingContentBoundsByPixels = newValue }
    }
}
