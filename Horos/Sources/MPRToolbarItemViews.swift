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

/// The layout of the 3D MPR's Shadings item: the Shading check box above the
/// Edit button, the three lines of the shading values to their right.
///
/// The nib gives the three controls the frames one language needs, and a
/// longer translation of «Shading» was cut at the check box's 65 pt. The
/// frames are replaced by constraints: the check box and the button are as
/// wide as their titles ask, the values keep the room of their widest text,
/// and the view's fitting width is what the running language needs
/// (ToolbarPolicy.localizedSize).
@MainActor
enum MPRShadingItemLayout {

    private static let identifier = "HorosMPRShadingItemLayout"

    /// `item` made the Shadings item on `view`, as wide as the running
    /// language asks. The check box takes its title from the catalog when the
    /// nib left it in English: Spanish and Italian open the English nib, and
    /// the Japanese one did not translate it.
    static func fill(_ item: NSToolbarItem?, view: NSView?, check: NSButton?, values: NSTextField?, widestText: String) {
        if check?.title == "Shading" { check?.title = NSLocalizedString("Shading", comment: "") }
        install(check: check, values: values, widestValues: widestText)
        item?.label = NSLocalizedString("Shadings", comment: "")
        item?.paletteLabel = NSLocalizedString("Shadings", comment: "")
        item?.view = view
        let size = ToolbarPolicy.localizedSize(of: view)
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
    }

    /// Replaces the frames of `check`, the other button of its view and
    /// `values` by constraints, once. `widestValues` is the widest text the
    /// values are given; the nib's width for them is the least they take.
    static func install(check: NSButton?, values: NSTextField?, widestValues: String) {
        guard let check, let values, let content = check.superview, values.superview === content,
              !content.constraints.contains(where: { $0.identifier == identifier }) else { return }
        let edit = content.subviews.compactMap { $0 as? NSButton }.first { $0 !== check }

        // The cell scrolls and clips in the nib, which leaves the title cut
        // without an ellipsis; its whole title is what sizes it now.
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        check.setContentHuggingPriority(.required, for: .horizontal)

        // Measured beside the field, whose text is the controller's to write.
        let font = values.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        let widest = (widestValues as NSString).size(withAttributes: [.font: font]).width
        let valuesWidth = max(values.frame.width, widest.rounded(.up) + 6)

        // Constraints place alignment rectangles, which these controls hold
        // inside their frames: each constant carries the insets, so that the
        // frames stay where the nib has them.
        let checkInsets = check.alignmentRectInsets, valuesInsets = values.alignmentRectInsets
        let trailing = content.bounds.maxX - values.frame.maxX
        let gap = max(1, values.frame.minX - check.frame.maxX)

        var constraints = [
            check.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: check.frame.minX + checkInsets.left),
            check.topAnchor.constraint(equalTo: content.topAnchor, constant: checkInsets.top),
            values.leadingAnchor.constraint(greaterThanOrEqualTo: check.trailingAnchor,
                                            constant: gap + checkInsets.right + valuesInsets.left),
            values.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(trailing + valuesInsets.right)),
            values.topAnchor.constraint(equalTo: content.topAnchor, constant: valuesInsets.top),
            values.heightAnchor.constraint(equalToConstant: values.frame.height - valuesInsets.top - valuesInsets.bottom),
            values.widthAnchor.constraint(equalToConstant: valuesWidth - valuesInsets.left - valuesInsets.right),
        ]
        if let edit {
            let editInsets = edit.alignmentRectInsets
            let editGap = min(8, max(4, values.frame.minX - edit.frame.maxX))
            constraints += [
                edit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edit.frame.minX + editInsets.left),
                edit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -(edit.frame.minY + editInsets.bottom)),
                edit.widthAnchor.constraint(greaterThanOrEqualToConstant: edit.frame.width - editInsets.left - editInsets.right),
                values.leadingAnchor.constraint(greaterThanOrEqualTo: edit.trailingAnchor,
                                                constant: editGap + editInsets.right + valuesInsets.left),
            ]
            edit.translatesAutoresizingMaskIntoConstraints = false
        }
        check.translatesAutoresizingMaskIntoConstraints = false
        values.translatesAutoresizingMaskIntoConstraints = false
        for constraint in constraints { constraint.identifier = identifier }
        NSLayoutConstraint.activate(constraints)

        // The box places its content by frames, which no constraint of the
        // content reaches: the width the controls ask for is given to the
        // item's view itself, so its fitting width is that one.
        if let box = content.superview {
            let needed = content.fittingSize.width.rounded(.up) + (box.frame.width - content.frame.width)
            let least = box.widthAnchor.constraint(greaterThanOrEqualToConstant: needed)
            least.identifier = identifier
            least.isActive = true
        }
    }
}
