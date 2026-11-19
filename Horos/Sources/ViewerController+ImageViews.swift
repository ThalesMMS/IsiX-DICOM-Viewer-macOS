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

/// The image views: whether the tiling views are to be updated, and the fit to the window asked at opening. The current image view and its series view are fields of the viewer, where plugins of the former SDK read them.
final class ViewerImageViews: @unchecked Sendable {
    /// The fit asked at opening, waiting for the layout to settle.
    let openingScaleToFit = DeferredCalls()
}

extension ViewerController {
    var horos_updateTilingViews: Bool {
        get { _updateTilingViews }
        set { _updateTilingViews = newValue }
    }
    var horos_openingScaleToFitRequested: Bool {
        get { _openingScaleToFitRequested }
        set { _openingScaleToFitRequested = newValue }
    }
    var horos_openingContentBoundsByPixels: [AnyHashable: Any]? {
        get { _openingContentBoundsByPixels as? [AnyHashable: Any] }
        set { _openingContentBoundsByPixels = newValue as NSDictionary? }
    }
}
