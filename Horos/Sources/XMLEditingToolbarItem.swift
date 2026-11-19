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

/// The DICOM editing items of the Meta-Data window's toolbar: Edit, Add and
/// Apply, and the level the modifications are applied to.
///
/// They are four ordinary toolbar items, so the toolbar draws each label
/// under its item, on the line of the labels of the items beside them,
/// whatever height the toolbar of a version of macOS gives its items. They
/// were one item, "Editing", whose view stacked the three buttons over labels
/// of its own beside two rows of radio buttons, 42 points high: a toolbar that
/// gives a labelled item less than that draws the item's label over the lower
/// part of the view. Only the level has a view, a pop-up button of the height
/// of a control.
///
/// A toolbar customized while they were one item still names that item. It
/// is answered with the four as a group, which a toolbar labels as one item,
/// and `replaceLegacyItem(in:)` then puts the four where it was.
@MainActor
final class XMLEditingToolbarItem: NSObject {
    static let legacyIdentifier = "Editing"
    static let editIdentifier = "EditingEdit"
    static let addIdentifier = "EditingAdd"
    static let applyIdentifier = "EditingApply"
    static let levelIdentifier = "EditingLevel"
    /// The four, in the order a new toolbar shows them.
    static let identifiers = [editIdentifier, addIdentifier, applyIdentifier, levelIdentifier]

    /// The levels, in the order of their tags: 0 the image, 1 its series, 2
    /// its study, 3 the patient.
    static var levelTitles: [String] {
        [NSLocalizedString("Image", comment: "Meta-Data window, DICOM editing: apply the modifications to this image"),
         NSLocalizedString("Series", comment: "Meta-Data window, DICOM editing: apply the modifications to the series of the image"),
         NSLocalizedString("Study", comment: "Meta-Data window, DICOM editing: apply the modifications to the study of the image"),
         NSLocalizedString("Patient", comment: "Meta-Data window, DICOM editing: apply the modifications to the patient of the image")]
    }

    private var edit: NSToolbarItem?
    private var add: NSToolbarItem?
    private var apply: NSToolbarItem?
    private var level: NSPopUpButton?
    private var levelItem: NSToolbarItem?
    private var editImages: (off: NSImage?, on: NSImage?) = (nil, nil)
    private weak var controller: XMLController?
    private var observing = false
    private nonisolated static let observedKeys = ["editingActivated", "modificationsToApply"]
    private static var ownerKey: UInt8 = 0

    /// The item of an identifier, for a toolbar or for its customization
    /// palette; nil for an identifier that is none of these. The item keeps
    /// what updates it alive for as long as it lives.
    static func item(_ identifier: String, for controller: XMLController) -> NSToolbarItem? {
        guard identifier == legacyIdentifier || identifiers.contains(identifier) else { return nil }
        let owner = XMLEditingToolbarItem(controller: controller)
        let item: NSToolbarItem
        if identifier == legacyIdentifier {
            let group = NSToolbarItemGroup(itemIdentifier: NSToolbarItem.Identifier(identifier))
            group.label = NSLocalizedString("DICOM Editing", comment: "")
            group.paletteLabel = group.label
            group.toolTip = group.label
            group.subitems = identifiers.compactMap { owner.part($0) }
            item = group
        } else if let part = owner.part(identifier) {
            item = part
        } else {
            return nil
        }
        item.visibilityPriority = .high
        objc_setAssociatedObject(item, &ownerKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        for key in observedKeys { controller.addObserver(owner, forKeyPath: key, options: [], context: nil) }
        owner.observing = true
        owner.update()
        return item
    }

    /// Puts the four where a toolbar saved before them has the single item,
    /// and takes that item away. An item of the four that the toolbar already
    /// has stays where it is.
    static func replaceLegacyItem(in toolbar: NSToolbar?) {
        guard let toolbar, var index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == legacyIdentifier }) else { return }
        toolbar.removeItem(at: index)
        for identifier in identifiers where !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == identifier }) {
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(identifier), at: index)
            index += 1
        }
    }

    private init(controller: XMLController) {
        self.controller = controller
        super.init()
    }

    deinit {
        // Removing an observer that was never added raises.
        guard observing, let controller else { return }
        for key in Self.observedKeys { controller.removeObserver(self, forKeyPath: key) }
    }

    private func part(_ identifier: String) -> NSToolbarItem? {
        func item(_ label: String, _ toolTip: String, _ image: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(identifier))
            item.label = label
            item.paletteLabel = label
            item.toolTip = toolTip
            item.image = NSImage(named: image)
            item.target = controller
            item.action = action
            // Enabled by `update()`, from what the window is editing.
            item.autovalidates = false
            ToolbarPolicy.prepare(item)
            return item
        }
        switch identifier {
        case Self.editIdentifier:
            let item = item(NSLocalizedString("Edit", comment: "Meta-Data window toolbar: turns the editing of the DICOM fields on and off"),
                            NSLocalizedString("Activate the edition", comment: "Meta-Data window toolbar: tooltip of Edit"),
                            "Autofill", #selector(XMLController.switchEditing(_:)))
            editImages = (item.image, Self.pressed(item.image))
            edit = item
            return item
        case Self.addIdentifier:
            let item = item(NSLocalizedString("Add", comment: "Meta-Data window toolbar: adds a DICOM element"),
                            NSLocalizedString("Add a new group/element", comment: "Meta-Data window toolbar: tooltip of Add"),
                            "add-large", #selector(XMLController.addDICOMField(_:)))
            add = item
            return item
        case Self.applyIdentifier:
            let item = item(NSLocalizedString("Apply", comment: "Meta-Data window toolbar: writes the modifications to the files"),
                            NSLocalizedString("Save the modifications to the file", comment: "Meta-Data window toolbar: tooltip of Apply"),
                            "Save", #selector(XMLController.applyModifications(_:)))
            apply = item
            return item
        case Self.levelIdentifier:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            popUp.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            for (tag, title) in Self.levelTitles.enumerated() {
                popUp.addItem(withTitle: title)
                popUp.lastItem?.tag = tag
            }
            popUp.sizeToFit()
            popUp.target = self
            popUp.action = #selector(levelChosen(_:))
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(identifier))
            item.label = NSLocalizedString("Level", comment: "Meta-Data window toolbar: the pop-up that chooses what the modifications are applied to, the image, its series, its study or the patient")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Apply the modifications to this image, to its series, to its study or to the patient", comment: "Meta-Data window toolbar: tooltip of the Level pop-up")
            popUp.toolTip = item.toolTip
            item.view = popUp
            ToolbarPolicy.constrainView(of: item, minimum: popUp.frame.size, maximum: popUp.frame.size)
            ToolbarPolicy.prepare(item)
            level = popUp
            levelItem = item
            return item
        default:
            return nil
        }
    }

    // The window says so on the main thread, where it edits.
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated { update() }
    }

    @objc private func levelChosen(_ sender: Any?) {
        guard let level else { return }
        controller?.editingLevel = Int32(level.selectedTag())
    }

    /// The image of Edit while the fields are being edited: the same drawing
    /// on the selection's colour, as a pressed button.
    private static func pressed(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        return NSImage(size: image.size, flipped: false) { rect in
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width / 6, yRadius: rect.height / 6).fill()
            image.draw(in: rect.insetBy(dx: rect.width / 10, dy: rect.height / 10))
            return true
        }
    }

    /// Shows what the window is doing: Edit pressed while it edits, Add and
    /// the level usable then, Apply when there is a modification to write.
    private func update() {
        guard let controller else { return }
        let editing = controller.editingActivated
        edit?.image = editing ? editImages.on : editImages.off
        add?.isEnabled = editing
        apply?.isEnabled = editing && controller.modificationsToApply()
        // Through the item, which dims its label with its pop-up.
        levelItem?.isEnabled = editing
        level?.selectItem(withTag: Int(controller.editingLevel))
    }
}
