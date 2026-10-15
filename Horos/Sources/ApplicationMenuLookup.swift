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

/// Resolves application menus independently of translated titles, item order
/// and grouping: a submenu is found at any depth, so it can move into a group
/// without its callers changing.
@objc(HorosApplicationMenuLookup)
public final class ApplicationMenuLookup: NSObject {
    @objc(submenuInMenu:identifier:)
    public static func submenu(in menu: NSMenu?, identifier: String) -> NSMenu? {
        guard let menu else { return nil }
        if let found = menu.items.first(where: { $0.identifier?.rawValue == identifier })?.submenu {
            return found
        }
        for case let submenu? in menu.items.map(\.submenu) {
            if let found = self.submenu(in: submenu, identifier: identifier) { return found }
        }
        return nil
    }
}
