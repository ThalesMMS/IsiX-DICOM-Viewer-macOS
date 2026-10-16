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

/// The Thick Slab mode popup of the 2D viewer's toolbar.
///
/// The menu keeps the full names ("MIP - Max Intensity Projection"), and the
/// overflow menu copies them; the closed popup shows the short one ("MIP") so
/// the item stays as narrow as the other items with controls. The selection is
/// the menu's own, so `selectedItem`, `selectedTag` and `selectItemWithTag:`
/// behave as before.
@objc(HorosThickSlabModePopUpButtonCell)
public final class ThickSlabModePopUpButtonCell: NSPopUpButtonCell {

    /// Short names by menu item tag (the fusion mode `-setFusionMode:` takes).
    @objc(shortTitleForItem:)
    public static func shortTitle(for item: NSMenuItem?) -> String {
        guard let item else { return "" }
        switch item.tag {
        case 1: return "Mean"
        case 2: return "MIP"
        case 3: return "MinIP"
        case 4: return "VR Up"
        case 5: return "VR Down"
        default: return item.title
        }
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

    /// The chevron after the short name. Without a bezel AppKit draws a pop-up
    /// with up and down arrows; the item shows "MIP ⌄" instead.
    @objc public static let chevron: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        return NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }()

    /// Draw a detached item holding the short name and the chevron; the full
    /// name stays the popup's tooltip.
    private func showShortTitle() {
        guard !updatingTitle else { return }
        updatingTitle = true
        defer { updatingTitle = false }
        usesItemFromMenu = false
        let selected = selectedItem
        let item = NSMenuItem(title: Self.shortTitle(for: selected), action: nil, keyEquivalent: "")
        if !isBordered {
            item.image = Self.chevron
            arrowPosition = .noArrow
            imagePosition = .imageTrailing
        }
        menuItem = item
        controlView?.toolTip = selected?.title
    }
}

/// The images of the 2D viewer's Windows Tiling popup, one per arrangement.
///
/// Each menu item's tag is rows * 10 + columns (what `-SetWindowsTiling:`
/// reads). The image is a template drawn here, a grid of rows x columns
/// windows, so AppKit tints it for the light and the dark appearance; the
/// popup shows the selected arrangement.
@objc(HorosWindowsTilingImage)
public final class WindowsTilingImage: NSObject {

    @objc public static let imageSize = NSSize(width: 30, height: 22)

    @objc(imageWithRows:columns:)
    public static func image(rows: Int, columns: Int) -> NSImage {
        let rows = max(rows, 1), columns = max(columns, 1)
        let image = NSImage(size: imageSize, flipped: true) { bounds in
            let gap: CGFloat = 2
            let area = bounds.insetBy(dx: 1, dy: 1)
            let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    let cell = NSRect(x: area.minX + CGFloat(column) * (width + gap),
                                      y: area.minY + CGFloat(row) * (height + gap),
                                      width: width, height: height)
                    let path = NSBezierPath(roundedRect: cell.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
                    NSColor.black.withAlphaComponent(0.3).setFill()
                    path.fill()
                    NSColor.black.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(rows) × \(columns)"
        return image
    }

    /// Give every item of the tiling popups in `view` the image of its tag.
    @objc(installInView:)
    @MainActor public static func install(in view: NSView?) {
        guard let view else { return }
        if let popup = view as? NSPopUpButton {
            for item in popup.itemArray where item.tag > 0 {
                item.image = image(rows: item.tag / 10, columns: item.tag % 10)
            }
            popup.synchronizeTitleAndSelectedItem()
        }
        for subview in view.subviews {
            install(in: subview)
        }
    }
}

/// The chevron beside the 2D viewer's Propagate button: a pull-down with the
/// same choices as 2D Viewer > Sync & Propagate > Propagate Between Series.
///
/// The button still switches propagation on and off; the pull-down picks what
/// travels between series. Each choice is a user default, so it holds for
/// every viewer and every exam until it is changed, from here or from the menu
/// bar.
@MainActor
@objc(HorosPropagateSettingsOptions)
public final class PropagateSettingsOptions: NSObject, NSMenuItemValidation {

    private static let shared = PropagateSettingsOptions()
    private static let popUpIdentifier = NSUserInterfaceItemIdentifier("org.horos.toolbar.propagate-options")
    private static let propagateKey = "COPYSETTINGS"

    /// A choice and the user default behind it. Most defaults say what is
    /// *not* propagated, so a checkmark is the negated value.
    private struct Choice {
        let title: String
        let key: String
        let negated: Bool
        /// Only meaningful while settings are propagated between series.
        let needsPropagation: Bool
    }

    /// Adds the chevron to the right of the button, once per view. The view is
    /// widened before the toolbar reads its designed size.
    @objc(installInView:)
    public static func install(in view: NSView?) {
        guard let view, let holder = view.subviews.first,
              !view.subviews.contains(where: { $0.identifier == popUpIdentifier }) else { return }

        let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
        popUp.identifier = popUpIdentifier
        popUp.isBordered = false
        (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popUp.menu = menu()
        popUp.toolTip = NSLocalizedString("Propagate Between Series", comment: "")
        popUp.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(popUp)

        // The holder keeps the button's width and the chevron takes the new
        // room on its right.
        let buttonWidth = view.frame.width
        let chevronWidth: CGFloat = 16
        for constraint in view.constraints {
            let holderTrailing = constraint.firstItem === holder && constraint.firstAttribute == .trailing
            let viewWidth = constraint.firstItem === view && constraint.firstAttribute == .width && constraint.secondItem == nil
            if holderTrailing || viewWidth { constraint.isActive = false }
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: buttonWidth + chevronWidth),
            holder.widthAnchor.constraint(equalToConstant: buttonWidth),
            popUp.leadingAnchor.constraint(equalTo: holder.trailingAnchor),
            popUp.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            popUp.widthAnchor.constraint(equalToConstant: chevronWidth),
            popUp.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        view.setFrameSize(NSSize(width: buttonWidth + chevronWidth, height: view.frame.height))
    }

    private static func menu() -> NSMenu {
        let menu = NSMenu()
        // A pull-down shows its first item, hidden from the open menu.
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = ThickSlabModePopUpButtonCell.chevron
        title.isHidden = true
        menu.addItem(title)

        menu.addItem(item(Choice(title: NSLocalizedString("Propagate Settings Between Series", comment: ""),
                                 key: propagateKey, negated: false, needsPropagation: false)))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: NSLocalizedString("Propagate", comment: "")))
        let choices = [
            Choice(title: NSLocalizedString("WL&WW", comment: ""), key: "DONTCOPYWLWWSETTINGS", negated: true, needsPropagation: true),
            Choice(title: NSLocalizedString("Zoom", comment: ""), key: "DONTCOPYZOOMSETTINGS", negated: true, needsPropagation: true),
            Choice(title: NSLocalizedString("Position", comment: ""), key: "DONTCOPYPANSETTINGS", negated: true, needsPropagation: true),
            Choice(title: NSLocalizedString("Rotation", comment: ""), key: "DONTCOPYROTATIONSETTINGS", negated: true, needsPropagation: true),
        ]
        for choice in choices {
            menu.addItem(item(choice))
        }
        menu.addItem(.separator())
        menu.addItem(item(Choice(title: NSLocalizedString("Zoom Only if Planes are Parallel", comment: ""),
                                 key: "AlwaysPropagateScaleLevel", negated: true, needsPropagation: false)))
        return menu
    }

    private static func item(_ choice: Choice) -> NSMenuItem {
        let item = NSMenuItem(title: choice.title, action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = [choice.key, choice.negated, choice.needsPropagation]
        return item
    }

    private static func choice(of item: NSMenuItem) -> (key: String, negated: Bool, needsPropagation: Bool)? {
        guard let values = item.representedObject as? [Any], values.count == 3,
              let key = values[0] as? String, let negated = values[1] as? Bool,
              let needsPropagation = values[2] as? Bool else { return nil }
        return (key, negated, needsPropagation)
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let choice = Self.choice(of: sender) else { return }
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: choice.key), forKey: choice.key)
        // Switching propagation on brings the other viewers in line now, as
        // the menu bar command does.
        if choice.key == Self.propagateKey, defaults.bool(forKey: choice.key) {
            NSApp.sendAction(NSSelectorFromString("copySettingsToOthers:"), to: nil, from: sender)
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let choice = Self.choice(of: menuItem) else { return true }
        let defaults = UserDefaults.standard
        menuItem.state = defaults.bool(forKey: choice.key) != choice.negated ? .on : .off
        return !choice.needsPropagation || defaults.bool(forKey: Self.propagateKey)
    }
}
