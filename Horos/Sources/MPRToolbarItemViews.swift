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

/// The mode popup of the 3D MPR's Thick Slab item.
///
/// The menu keeps the full names ("MIP - Max Intensity Projection"), and the
/// overflow menu copies them; the closed popup shows the name before " - "
/// ("MIP"), which fits the item at the window's default width instead of being
/// cut with an ellipsis. The full name is the popup's tooltip. The selection is
/// the menu's own, so the selectedTag binding, `selectedItem` and
/// `selectItemWithTag:` behave as before.
@objc(HorosMPRThickSlabModePopUpButtonCell)
public final class MPRThickSlabModePopUpButtonCell: NSPopUpButtonCell {

    /// "MIP - Max Intensity Projection" → "MIP"; a title without " - " stays whole.
    @objc(shortTitleForItem:)
    public static func shortTitle(for item: NSMenuItem?) -> String {
        guard let title = item?.title else { return "" }
        let short = title.components(separatedBy: " - ").first ?? title
        return short.trimmingCharacters(in: .whitespaces)
    }

    private var updatingTitle = false

    public override init(textCell stringValue: String, pullsDown pullDown: Bool) {
        super.init(textCell: stringValue, pullsDown: pullDown)
        showShortTitle()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        showShortTitle()
    }

    public override func synchronizeTitleAndSelectedItem() {
        super.synchronizeTitleAndSelectedItem()
        showShortTitle()
    }

    public override func select(_ item: NSMenuItem?) {
        super.select(item)
        showShortTitle()
    }

    public override func selectItem(at index: Int) {
        super.selectItem(at: index)
        showShortTitle()
    }

    /// Draws a detached item holding the short name.
    private func showShortTitle() {
        guard !updatingTitle else { return }
        updatingTitle = true
        defer { updatingTitle = false }
        usesItemFromMenu = false
        let selected = selectedItem
        menuItem = NSMenuItem(title: Self.shortTitle(for: selected), action: nil, keyEquivalent: "")
        controlView?.toolTip = selected?.title
    }
}
