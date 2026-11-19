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
    var horos_curCLUTMenu: String? {
        get { _curCLUTMenu as String? }
        set { _curCLUTMenu = newValue as NSString? }
    }
    var horos_curConvMenu: String? {
        get { _curConvMenu as String? }
        set { _curConvMenu = newValue as NSString? }
    }
    var horos_curWLWWMenu: String? {
        get { _curWLWWMenu as String? }
        set { _curWLWWMenu = newValue as NSString? }
    }
    var horos_curOpacityMenu: String? {
        get { _curOpacityMenu as String? }
        set { _curOpacityMenu = newValue as NSString? }
    }
    var horos_backCurCLUTMenu: String? {
        get { _backCurCLUTMenu as String? }
        set { _backCurCLUTMenu = newValue as NSString? }
    }
    var horos_clutPopupSet: Bool {
        get { _clutPopupSet }
        set { _clutPopupSet = newValue }
    }
    var horos_convPopupSet: Bool {
        get { _convPopupSet }
        set { _convPopupSet = newValue }
    }
    var horos_wlwwPopupSet: Bool {
        get { _wlwwPopupSet }
        set { _wlwwPopupSet = newValue }
    }
    var horos_OpacityPopupSet: Bool {
        get { _OpacityPopupSet }
        set { _OpacityPopupSet = newValue }
    }
}
