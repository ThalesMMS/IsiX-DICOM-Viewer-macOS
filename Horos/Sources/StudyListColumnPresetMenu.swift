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
import IsiXDatabase
import IsiXPreferences

/// The named column presets of the browser's study list, in the menu of its
/// header: an item that saves the columns shown, their order and their widths
/// under a name, an item per preset that puts the list back as it was saved,
/// and the submenus that rename and delete one.
///
/// What a preset is, how it is kept and what applying it does to the columns
/// are IsiXDatabase's StudyListColumnPreset and StudyListColumnPresets; this
/// is the menu, the sheets and the columns of the outline. The items are sent
/// here, not up the responder chain. A preset changes neither the hiding of
/// the patients' names nor the order of the rows.
@MainActor final class StudyListColumnPresetMenu: NSObject, NSTextFieldDelegate {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    /// The button that accepts the name of the sheet that is open: off while
    /// the name is empty.
    private weak var acceptButton: NSButton?

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
        super.init()
    }

    private var outline: MyOutlineView? { browser.horos_databaseOutline }

    private var stored: StudyListColumnPresets {
        StudyListColumnPresets(propertyList: preferences.object(for: DatabasePreferences.databaseColumnPresets))
    }

    /// Keeps the presets and makes the menu again, with their items.
    private func store(_ presets: StudyListColumnPresets) {
        if presets.presets.isEmpty {
            preferences.remove(DatabasePreferences.databaseColumnPresets)
        } else {
            preferences.set(presets.propertyList, forKey: DatabasePreferences.databaseColumnPresets.name)
        }
        browser.buildColumnsMenu()
    }

    /// The columns the list shows, from the first to the last, with their widths.
    private func arrangement(of outline: MyOutlineView) -> [StudyListColumnPreset.Column] {
        outline.tableColumns.filter { !$0.isHidden }
            .map { StudyListColumnPreset.Column(identifier: $0.identifier.rawValue, width: Double($0.width)) }
    }

    // MARK: - The menu

    /// Adds, after the items of the columns: the item that saves a preset,
    /// one item per preset and the submenus that rename and delete one.
    func addItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Save Columns as Preset…", comment: "Database window, menu of the columns header: saves the columns shown, their order and widths under a name"),
                          #selector(savePreset(_:)), preset: nil))

        let names = stored.names
        guard !names.isEmpty else { return }

        menu.addItem(.separator())
        for name in names {
            menu.addItem(item(name, #selector(applyPreset(_:)), preset: name))
        }

        menu.addItem(.separator())
        menu.addItem(submenu(NSLocalizedString("Rename Preset", comment: "Database window, menu of the columns header: submenu of the column presets to rename"),
                             #selector(renamePreset(_:)), names: names))
        menu.addItem(submenu(NSLocalizedString("Delete Preset", comment: ""), #selector(deletePreset(_:)), names: names))
    }

    private func item(_ title: String, _ action: Selector, preset: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = preset
        return item
    }

    private func submenu(_ title: String, _ action: Selector, names: [String]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for name in names {
            menu.addItem(item(name, action, preset: name))
        }
        parent.submenu = menu
        return parent
    }

    /// Checks the item of each preset the list is arranged as.
    func menuWillOpen(_ menu: NSMenu) {
        let items = menu.items.filter { $0.action == #selector(applyPreset(_:)) }
        guard !items.isEmpty, let outline else { return }
        let presets = stored
        let shown = arrangement(of: outline)
        let tableColumns = outline.tableColumns.map(\.identifier.rawValue)
        for item in items {
            let preset = (item.representedObject as? String).flatMap { presets.preset(named: $0) }
            item.state = preset?.matches(shown, of: tableColumns) == true ? .on : .off
        }
    }

    // MARK: - The items

    @objc private func savePreset(_ sender: Any?) {
        askName(NSLocalizedString("Name of the column preset:", comment: "Database window: asks the name of a preset of the list's columns"),
                proposed: "") { name in
            guard let outline = self.outline,
                  let preset = StudyListColumnPreset(name: name, columns: self.arrangement(of: outline)) else { return }
            let presets = self.stored
            self.confirmReplacing(presets.preset(named: preset.name)?.name) {
                self.store(presets.saving(preset))
            }
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let preset = stored.preset(named: name), let outline else { return }
        apply(preset, to: outline)
    }

    @objc private func renamePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        askName(NSLocalizedString("Name of the column preset:", comment: "Database window: asks the name of a preset of the list's columns"),
                proposed: name) { newName in
            let presets = self.stored
            guard let renamed = presets.renaming(name, to: newName) else { return }
            // Another preset that has the new name would be replaced.
            let other = presets.preset(named: newName).flatMap { $0.name == name ? nil : $0.name }
            self.confirmReplacing(other) {
                self.store(renamed)
            }
        }
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        store(stored.removing(named: name))
    }

    // MARK: - Applying

    /// Puts the list as the preset says: its columns shown, each moved to
    /// its place and given its width, the others hidden. The arrangement is
    /// then saved as the one the list has, so that it is still there after
    /// the application is opened again.
    private func apply(_ preset: StudyListColumnPreset, to outline: MyOutlineView) {
        // Which columns there are comes first and the widths last: the list
        // shares width among its columns whenever one is shown or hidden, and
        // a width given before that would not be the one it ends with.
        StudyListColumnArranger.apply(preset.plan(for: outline.tableColumns.map(\.identifier.rawValue)).steps, to: outline)

        browser.studyListColumns.saveShownColumns()
    }

    // MARK: - The sheets

    /// Asks a name on a sheet of the browser's window, and hands it to `then`
    /// when it is accepted. The sheet cannot be accepted while the name is empty.
    private func askName(_ message: String, proposed: String, then: @escaping @MainActor (String) -> Void) {
        guard let window = outline?.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: proposed)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        field.delegate = self
        alert.accessoryView = field
        let accept = alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        accept.isEnabled = StudyListColumnPreset.normalizedName(proposed) != nil
        acceptButton = accept
        alert.window.initialFirstResponder = field

        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            // Out of the way of the sheet that may ask to replace a preset.
            alert.window.orderOut(nil)
            then(field.stringValue)
        }
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        acceptButton?.isEnabled = StudyListColumnPreset.normalizedName(field.stringValue) != nil
    }

    /// Does `then` at once when `name` is nil: no preset is replaced. Else
    /// asks first whether the preset of that name is to be replaced.
    private func confirmReplacing(_ name: String?, then: @escaping @MainActor () -> Void) {
        guard let name else {
            then()
            return
        }
        guard let window = outline?.window else { return }
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("A column preset named %@ already exists. Do you want to replace it?", comment: "Database window: %@ is the name of a preset of the list's columns"), name)
        alert.addButton(withTitle: NSLocalizedString("Replace", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                then()
            }
        }
        alert.beginSheetModal(for: window, completionHandler: answer)
    }
}
