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

/// The toolbar of the window, the toolbar panel that replaces it and the items kept for both, and the timer that checks the 12-bit display.
final class ViewerToolbarState: @unchecked Sendable {
    var toolbar: NSToolbar?
    var toolbarPanel: ToolbarPanelController?
    var retainedToolbarItems: NSMutableArray?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var t12BitTimer: Timer?
}

extension ViewerController {
    var horos_toolbar: NSToolbar? {
        get { toolbarState.toolbar }
        set { toolbarState.toolbar = newValue }
    }
    var horos_toolbarPanel: ToolbarPanelController? {
        get { toolbarState.toolbarPanel }
        set { toolbarState.toolbarPanel = newValue }
    }
    var horos_retainedToolbarItems: NSMutableArray? {
        get { toolbarState.retainedToolbarItems }
        set { toolbarState.retainedToolbarItems = newValue }
    }
    var horos_t12BitTimer: Timer? {
        get { toolbarState.t12BitTimer }
        set { toolbarState.t12BitTimer = newValue }
    }
}
