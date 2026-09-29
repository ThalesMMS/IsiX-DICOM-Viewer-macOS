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

/// One policy for every window that builds an `NSToolbar`.
///
/// Artwork, overflow menus and plugin overrides already have helpers. This type
/// is the single call each delegate makes after plugins have had their turn, and
/// the place that records what a missing translation is (not a geometry bug),
/// which items must stay out of overflow, and how the detached 2D panel behaves
/// in the host's custom fullscreen.
@objc(HorosToolbarPolicy)
public final class ToolbarPolicy: NSObject {

    @objc public enum LabelKind: Int {
        case translated = 0
        case englishFallback = 1
        case missingTranslation = 2
        case geometricStress = 3
    }

    @objc public enum Presentation: Int {
        case windowed = 0
        case fullscreen = 1
        case overflow = 2
    }

    /// Languages the shipped bundle actually has. Portuguese is not among them;
    /// that absence is a translation gap, not a clipped-label failure.
    @objc(availableLocalizationsInBundle:)
    public static func availableLocalizations(in bundle: Bundle) -> [String] {
        bundle.localizations
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .filter { $0 != "Base" }
            .sorted()
    }

    @objc(isLanguageAvailable:inLocalizations:)
    public static func isLanguageAvailable(_ language: String, in localizations: [String]) -> Bool {
        let wanted = language.lowercased()
        return localizations.contains { loc in
            let have = loc.lowercased()
            return have == wanted || have.hasPrefix(wanted + "-") || wanted.hasPrefix(have + "-")
        }
    }

    /// Controlled labels for layout stress. They are not catalog copy and must
    /// not be confused with a missing `Localizable.strings` entry.
    @objc(stressLabelForLanguage:)
    public static func stressLabel(for language: String) -> String {
        let code = language.lowercased()
        if code.hasPrefix("pt") {
            return "Projeção de Intensidade Máxima — Espessura do Corte Combinada"
        }
        if code.hasPrefix("de") {
            return "Maximale Intensitätsprojektion — kombinierte Schichtdicke"
        }
        if code.hasPrefix("it") {
            return "Proiezione di Intensità Massima — Spessore di Strato Combinato"
        }
        return "Maximum Intensity Projection — Combined Thick Slab Thickness"
    }

    @objc(classifyLabel:english:localized:requestedLanguage:)
    public static func classify(label: String,
                                english: String,
                                localized: String?,
                                requestedLanguage: String) -> LabelKind {
        if label == stressLabel(for: requestedLanguage) {
            return .geometricStress
        }
        let language = requestedLanguage.lowercased()
        if language.hasPrefix("en") {
            return label == english ? .translated : .englishFallback
        }
        if let localized, localized != english, label == localized {
            return .translated
        }
        if label == english {
            return .missingTranslation
        }
        return .englishFallback
    }

    /// High-priority interactive views stay on the bar (Search, Thick Slab,
    /// mouse-tool palette). Overflow still receives a menu so a narrow window
    /// or a customized order cannot swallow the commands.
    @objc(prepareItem:)
    public static func prepare(_ item: NSToolbarItem?) {
        guard let item else { return }
        _ = flatInstaller
        ToolbarImage.normalize(for: item)
        flatten(item)
        ToolPaletteCell.adoptToolPalettes(in: item.view)
        ToolbarMenuBridge.install(for: item)
        if containsInteractiveControl(item.view),
           item.visibilityPriority.rawValue < NSToolbarItem.VisibilityPriority.high.rawValue {
            item.visibilityPriority = .high
        }
    }

    /// Every Horos toolbar is flat: the legacy artwork was drawn without a
    /// button frame, and the reference layout groups controls by label, not by
    /// capsule. macOS 26 turns `bordered` back on for view-backed items when
    /// the toolbar inserts them, so the policy is applied twice: at creation and
    /// again after insertion, from the toolbar's own notification.
    ///
    /// The customization palette never sees that notification: it snapshots
    /// the items the delegate returns with `willBeInsertedIntoToolbar: NO`, and
    /// AppKit draws the glass capsule from the item's `isBordered` getter, which
    /// an `NSPopUpButton` or `NSSegmentedControl` view answers YES for whatever
    /// was set. A plain `NSToolbarItem` therefore becomes a `FlatToolbarItem`,
    /// whose getter always answers NO, in the bar, in the palette and in the
    /// copies AppKit makes. Subclasses (plugins, search, groups) keep their
    /// class and only have the property cleared.
    @objc(flattenItem:)
    public static func flatten(_ item: NSToolbarItem) {
        guard !(item is NSToolbarItemGroup) else { return }
        if object_getClass(item) == NSToolbarItem.self {
            object_setClass(item, FlatToolbarItem.self)
        }
        if item.isBordered {
            item.isBordered = false
        }
    }

    private static let flatInstaller: Void = {
        NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification,
                                               object: nil,
                                               queue: .main) { note in
            guard let item = note.userInfo?["item"] as? NSToolbarItem else { return }
            flatten(item)
            DispatchQueue.main.async { flatten(item) }
        }
    }()

    /// The Space the palettes offer: AppKit's own. A title-bar toolbar keeps
    /// its items packed after the window title, as Horos toolbars always were;
    /// a 32 pt Horos Space and a row of the toolbar's own briefly replaced this
    /// and spread the items apart.
    ///
    /// In the customization palette the Space is AppKit's drawing too: the
    /// delegate is never asked for it, and on macOS 27 its palette entry is a
    /// 36 pt hollow square traced at about a fifth of the label colour's
    /// opacity, in light and dark alike, hard to see against the palette.
    /// Horos does not replace it with a Space of its own (see above).
    @objc public static let spaceItemIdentifier = NSToolbarItem.Identifier.space.rawValue
    /// The Horos Space that configuration saved. It still loads, and
    /// adopt(toolbar:in:) turns it back into AppKit's Space.
    static let savedHorosSpaceItemIdentifier = "HorosToolbarSpaceItem"

    @objc(spaceItemForIdentifier:)
    public static func spaceItem(for identifier: String) -> NSToolbarItem? {
        guard identifier == savedHorosSpaceItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(identifier))
        item.label = ""
        item.paletteLabel = NSLocalizedString("Space", comment: "Toolbar customization item")
        item.isBordered = false
        return item
    }

    /// Call once the toolbar is in its window. The window keeps its toolbar
    /// style, so the toolbar shares the title bar; Horos Spaces saved by an
    /// earlier configuration become AppKit's Space again.
    @objc(adoptToolbar:inWindow:)
    public static func adopt(toolbar: NSToolbar?, in window: NSWindow?) {
        guard let toolbar else { return }
        for (index, item) in toolbar.items.enumerated().reversed()
        where item.itemIdentifier.rawValue == savedHorosSpaceItemIdentifier {
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: .space, at: index)
        }
    }

    @objc(adoptPluginItem:replacing:)
    public static func adopt(plugin: NSToolbarItem?, replacing host: NSToolbarItem?) -> NSToolbarItem? {
        let item = plugin ?? host
        prepare(item)
        return item
    }

    @objc(containsInteractiveControl:)
    public static func containsInteractiveControl(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if view is NSPopUpButton || view is NSSlider || view is NSMatrix || view is NSSearchField {
            return true
        }
        if let button = view as? NSButton, button.action != nil {
            return true
        }
        return view.subviews.contains { containsInteractiveControl($0) }
    }

    /// Prefer high-priority identifiers when the window can no longer show every
    /// item. Widths are in points; the result is identifiers, not views.
    @objc(splitIdentifiers:widths:highPriority:windowWidth:)
    public static func split(identifiers: [String],
                             widths: [NSNumber],
                             highPriority: [String],
                             windowWidth: CGFloat) -> NSDictionary {
        guard identifiers.count == widths.count else {
            return ["visible": identifiers, "overflow": []]
        }
        let preferred = Set(highPriority)
        var remaining = windowWidth
        var visible: [String] = []
        var overflow: [String] = []

        func place(_ identifier: String, at index: Int) {
            let width = CGFloat(truncating: widths[index])
            if remaining >= width {
                visible.append(identifier)
                remaining -= width
            } else {
                overflow.append(identifier)
            }
        }

        for (index, identifier) in identifiers.enumerated() where preferred.contains(identifier) {
            place(identifier, at: index)
        }
        for (index, identifier) in identifiers.enumerated() where !preferred.contains(identifier) {
            place(identifier, at: index)
        }
        return ["visible": visible, "overflow": overflow]
    }

    @objc(actionCatalogForItem:)
    public static func actionCatalog(for item: NSToolbarItem) -> [[String: Any]] {
        var catalog: [[String: Any]] = []
        if item.action != nil {
            catalog.append([
                "title": item.label,
                "tag": item.tag,
                "hasAction": true
            ])
        }
        if let menu = item.menuFormRepresentation?.submenu {
            catalog.append(contentsOf: commands(in: menu))
        }
        return catalog
    }

    @objc(actionsReachable:inPresentation:)
    public static func actionsReachable(_ actions: [[String: Any]],
                                        in presentation: Presentation) -> Bool {
        guard !actions.isEmpty else { return false }
        switch presentation {
        case .windowed:
            return true
        case .fullscreen, .overflow:
            return actions.contains { ($0["hasAction"] as? Bool) == true }
        }
    }

    /// Custom fullscreen covers the screen. Leave the same strip the tiling
    /// already reserves for the detached panel so the toolbar stays clickable
    /// without changing the host's fullscreen policy.
    @objc(fullscreenContentRectOnScreen:reservingPanelHeight:)
    public static func fullscreenContentRect(on screenFrame: NSRect,
                                             reservingPanelHeight height: CGFloat) -> NSRect {
        var rect = screenFrame
        let reserved = max(0, height)
        if rect.size.height > reserved {
            rect.size.height -= reserved
        }
        return rect
    }

    @objc(shouldKeepDetachedToolbarVisibleWhenFullScreen:)
    public static func shouldKeepDetachedToolbarVisible(whenFullScreen fullScreen: Bool) -> Bool {
        fullScreen
    }

    @objc(toolbarPanelLevelWhenFullScreen:)
    public static func toolbarPanelLevel(whenFullScreen fullScreen: Bool) -> Int {
        fullScreen ? Int(CGWindowLevelForKey(.screenSaverWindow)) : Int(CGWindowLevelForKey(.normalWindow))
    }

    private static func commands(in menu: NSMenu) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                result.append(contentsOf: commands(in: submenu))
            } else if item.action != nil {
                result.append([
                    "title": item.title,
                    "tag": item.tag,
                    "hasAction": true
                ])
            }
        }
        return result
    }
}

/// A toolbar item that is never bordered, so AppKit never gives it a glass
/// capsule. `ToolbarPolicy.flatten` swaps a plain `NSToolbarItem` to this class;
/// it adds no storage, only the answer to `isBordered`.
@objc(HorosFlatToolbarItem)
final class FlatToolbarItem: NSToolbarItem {
    override var isBordered: Bool {
        get { false }
        set {}
    }
}

/// One tool of a Mouse button function palette: an `NSMatrix` of bordered
/// square bevel buttons, one row, cells overlapping by their border
/// (`intercellSpacing.width` of -2), as every viewer's xib builds it.
///
/// On macOS 26 a bordered square bevel button inside a toolbar is drawn as a
/// glass button: the selected tool becomes an accent circle wider than its
/// segment, which shrinks and shifts its icon, and the others lose their
/// frame. This cell draws the palette the way the xibs were laid out: every
/// tool framed as a segment, the selected one filled with the accent colour
/// over the whole segment, the icon inside at the same size in every state.
///
/// Settings → Viewers offers both looks (#983): with
/// `ToolPaletteSelectionStyle` at 1 the cell leaves the drawing to AppKit, and
/// the selected tool is the accent circle again.
@objc(HorosToolPaletteCell)
public final class ToolPaletteCell: NSButtonCell {

    /// The preference that picks the look: 0, the default, frames the
    /// segments; 1 is AppKit's accent circle.
    @objc public static let selectionStyleKey = "ToolPaletteSelectionStyle"

    @objc public static var drawsFramedSegments: Bool {
        UserDefaults.standard.integer(forKey: selectionStyleKey) == 0
    }

    /// The palettes adopted so far, redrawn when the preference changes so an
    /// open viewer follows it without being reopened.
    private static let palettes = NSHashTable<NSMatrix>.weakObjects()
    private static var lastDrawsFramedSegments = true
    private static let styleObserver: Void = {
        lastDrawsFramedSegments = drawsFramedSegments
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil,
                                               queue: .main) { _ in
            let framed = drawsFramedSegments
            guard framed != lastDrawsFramedSegments else { return }
            lastDrawsFramedSegments = framed
            for matrix in palettes.allObjects {
                matrix.needsDisplay = true
            }
        }
    }()

    /// Makes every tool palette under `view` draw as segments. Called for
    /// each toolbar item's view; a palette already adopted is left alone.
    @objc(adoptToolPalettesInView:)
    public static func adoptToolPalettes(in view: NSView?) {
        guard let view else { return }
        if let matrix = view as? NSMatrix, isToolPalette(matrix) {
            _ = styleObserver
            for case let cell as NSButtonCell in matrix.cells
            where object_getClass(cell) == NSButtonCell.self {
                object_setClass(cell, ToolPaletteCell.self)
            }
            palettes.add(matrix)
            matrix.needsDisplay = true
        }
        for subview in view.subviews {
            adoptToolPalettes(in: subview)
        }
    }

    /// A radio matrix whose cells are all bordered square bevel buttons with
    /// an image: the tool palettes, and not the Left/Right Button radios next
    /// to them.
    @objc(isToolPalette:)
    public static func isToolPalette(_ matrix: NSMatrix) -> Bool {
        guard matrix.mode == .radioModeMatrix, !matrix.cells.isEmpty else { return false }
        return matrix.cells.allSatisfy { cell in
            guard let button = cell as? NSButtonCell else { return false }
            return button.isBordered && button.bezelStyle == .regularSquare && button.image != nil
        }
    }

    /// The part of `cellFrame` this tool owns. Neighbouring cells overlap by
    /// the matrix's negative spacing; half of it goes to each side, so the
    /// segments tile without overlapping and share one separator.
    @objc(segmentRectForCellFrame:inView:)
    public static func segmentRect(forCellFrame cellFrame: NSRect, in controlView: NSView?) -> NSRect {
        let overlap = max(0, -((controlView as? NSMatrix)?.intercellSpacing.width ?? 0))
        return cellFrame.insetBy(dx: overlap / 2, dy: 0)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard Self.drawsFramedSegments else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        let segment = Self.segmentRect(forCellFrame: cellFrame, in: controlView)
        let accent = NSColor.controlAccentColor
        if state == .on {
            accent.withAlphaComponent(isEnabled ? 0.45 : 0.2).setFill()
            segment.fill()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            segment.fill()
        }

        // Top, bottom and leading edges; the trailing edge is the next tool's
        // leading one, except after the last tool.
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: segment.minX, y: segment.minY, width: segment.width, height: 1).fill()
        NSRect(x: segment.minX, y: segment.maxY - 1, width: segment.width, height: 1).fill()
        NSRect(x: segment.minX, y: segment.minY, width: 1, height: segment.height).fill()
        if isLastColumn(in: controlView) {
            NSRect(x: segment.maxX - 1, y: segment.minY, width: 1, height: segment.height).fill()
        }
        if state == .on {
            accent.setFill()
            segment.frame(withWidth: 1.5, using: .sourceOver)
        }

        drawInterior(withFrame: segment, in: controlView)
    }

    /// The icon, in the segment's inset box, the same size selected or not.
    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard Self.drawsFramedSegments, let image else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let box = cellFrame.insetBy(dx: 3, dy: 3)
        drawImage(image, withFrame: Self.imageRect(for: image.size, in: box), in: controlView)
    }

    /// `image` fitted into `box` without distortion and centred, pixel-aligned.
    @objc(imageRectForSize:inBox:)
    public static func imageRect(for size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return NSRect(x: (box.midX - width / 2).rounded(),
                      y: (box.midY - height / 2).rounded(),
                      width: width,
                      height: height)
    }

    private func isLastColumn(in controlView: NSView) -> Bool {
        guard let matrix = controlView as? NSMatrix else { return true }
        var row = 0
        var column = 0
        guard matrix.getRow(&row, column: &column, of: self) else { return true }
        return column == matrix.numberOfColumns - 1
    }
}
