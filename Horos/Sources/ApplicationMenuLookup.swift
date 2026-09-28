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

import AppKit

/// Resolves application menus independently of translated titles and item order.
@objc(HorosApplicationMenuLookup)
public final class ApplicationMenuLookup: NSObject {
    @objc(submenuInMenu:identifier:)
    public static func submenu(in menu: NSMenu?, identifier: String) -> NSMenu? {
        menu?.items.first { $0.identifier?.rawValue == identifier }?.submenu
    }
}
