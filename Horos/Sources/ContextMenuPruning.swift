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

/// A context menu shows only what applies to the clicked selection: the
/// commands that do not apply are hidden rather than dimmed, and so are the
/// submenus they leave empty and the separators left with nothing to separate.
@objc(HorosContextMenuPruning)
final class ContextMenuPruning: NSObject {
    /// Hides the items of `menu` that `isAvailable` refuses. Only the submenus
    /// in `groups` are entered; any other submenu (one copied from the main
    /// menu, filled when it opens) is shown as it is. A group with nothing
    /// visible is hidden with its item.
    @objc(hideUnavailableItemsIn:groups:isAvailable:)
    static func hideUnavailableItems(in menu: NSMenu, groups: [NSMenu], isAvailable: (NSMenuItem) -> Bool) {
        _ = prune(menu, groups: groups.map(ObjectIdentifier.init), isAvailable: isAvailable)
    }

    /// Hides the items of `menu` that their target's validation refuses. An
    /// item without a target goes to `defaultTarget` when it answers the
    /// action, and otherwise to the responder chain.
    @MainActor @objc(hideUnavailableItemsIn:groups:defaultTarget:)
    static func hideUnavailableItems(in menu: NSMenu, groups: [NSMenu], defaultTarget: NSObject) {
        hideUnavailableItems(in: menu, groups: groups) { item in
            guard let action = item.action else { return false }
            var target = item.target
            if target == nil, defaultTarget.responds(to: action) {
                target = defaultTarget
            }
            if target == nil {
                target = NSApp.target(forAction: action, to: nil, from: item) as AnyObject?
            }
            // AppKit asks any target that answers validateMenuItem:, declared
            // conformance or not; Swift controllers often do not declare it.
            if let valid = (target as AnyObject?)?.validateMenuItem?(item) {
                return valid
            }
            return target != nil
        }
    }

    /// Whether `menu` is `root` or one of the submenus under it.
    @objc(menu:contains:)
    static func menu(_ root: NSMenu, contains menu: NSMenu) -> Bool {
        root === menu || root.items.contains { $0.submenu.map { self.menu($0, contains: menu) } ?? false }
    }

    /// Returns whether `menu` keeps a visible command.
    private static func prune(_ menu: NSMenu, groups: [ObjectIdentifier], isAvailable: (NSMenuItem) -> Bool) -> Bool {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                if groups.contains(ObjectIdentifier(submenu)) {
                    item.isHidden = !prune(submenu, groups: groups, isAvailable: isAvailable)
                }
            } else if item.action != nil {
                item.isHidden = !isAvailable(item)
            }
        }
        hideStraySeparators(in: menu)
        return menu.items.contains { !$0.isSeparatorItem && !$0.isHidden }
    }

    /// Keeps a separator only between two visible commands, and one of a run.
    private static func hideStraySeparators(in menu: NSMenu) {
        var pending: NSMenuItem?
        var seenCommand = false
        for item in menu.items {
            if item.isSeparatorItem {
                item.isHidden = true
                if seenCommand, pending == nil { pending = item }
            } else if !item.isHidden {
                pending?.isHidden = false
                pending = nil
                seenCommand = true
            }
        }
    }
}

/// Hides the unavailable items of a context menu that is built once and
/// shown again and again, each time it is about to open. Every submenu of
/// the menu is one of its groups.
@MainActor @objc(HorosContextMenuPruningDelegate)
final class ContextMenuPruningDelegate: NSObject, NSMenuDelegate {
    private weak var defaultTarget: NSObject?

    @objc init(defaultTarget: NSObject) {
        self.defaultTarget = defaultTarget
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let defaultTarget else { return }
        ContextMenuPruning.hideUnavailableItems(in: menu, groups: menu.items.compactMap(\.submenu), defaultTarget: defaultTarget)
    }

    // The menu has no key equivalents: answering spares it a validation of
    // every command on each key press.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }
}
