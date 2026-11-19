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

extension ViewerController {
    var horos_toolbar: NSToolbar? {
        get { _toolbar }
        set { _toolbar = newValue }
    }
    var horos_toolbarPanel: ToolbarPanelController? {
        get { _toolbarPanel }
        set { _toolbarPanel = newValue }
    }
    var horos_retainedToolbarItems: NSMutableArray? {
        get { _retainedToolbarItems }
        set { _retainedToolbarItems = newValue }
    }
    var horos_t12BitTimer: Timer? {
        get { _t12BitTimer.wrappedValue }
        set { _t12BitTimer.wrappedValue = newValue }
    }
}
