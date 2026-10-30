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

/// The presets chosen in the menus (CLUT, convolution, window level, opacity, the CLUT to restore) and whether each popup was set.
final class ViewerPresetState: @unchecked Sendable {
    var curCLUTMenu: String?
    var curConvMenu: String?
    var curWLWWMenu: String?
    var curOpacityMenu: String?
    var backCurCLUTMenu: String?
    var clutPopupSet: Bool = false
    var convPopupSet: Bool = false
    var wlwwPopupSet: Bool = false
    var OpacityPopupSet: Bool = false
}

extension ViewerController {
    var horos_curCLUTMenu: String? {
        get { presetState.curCLUTMenu }
        set { presetState.curCLUTMenu = newValue }
    }
    var horos_curConvMenu: String? {
        get { presetState.curConvMenu }
        set { presetState.curConvMenu = newValue }
    }
    var horos_curWLWWMenu: String? {
        get { presetState.curWLWWMenu }
        set { presetState.curWLWWMenu = newValue }
    }
    var horos_curOpacityMenu: String? {
        get { presetState.curOpacityMenu }
        set { presetState.curOpacityMenu = newValue }
    }
    var horos_backCurCLUTMenu: String? {
        get { presetState.backCurCLUTMenu }
        set { presetState.backCurCLUTMenu = newValue }
    }
    var horos_clutPopupSet: Bool {
        get { presetState.clutPopupSet }
        set { presetState.clutPopupSet = newValue }
    }
    var horos_convPopupSet: Bool {
        get { presetState.convPopupSet }
        set { presetState.convPopupSet = newValue }
    }
    var horos_wlwwPopupSet: Bool {
        get { presetState.wlwwPopupSet }
        set { presetState.wlwwPopupSet = newValue }
    }
    var horos_OpacityPopupSet: Bool {
        get { presetState.OpacityPopupSet }
        set { presetState.OpacityPopupSet = newValue }
    }
}
