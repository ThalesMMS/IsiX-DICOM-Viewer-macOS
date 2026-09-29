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
    /// with up and down arrows; the item shows "MIP ⌄" instead (#985).
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
    public static func install(in view: NSView?) {
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
