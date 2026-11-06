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

// The states a study can be given (empty, unread, reviewed…), as every part
// of the application shows them: the State column of the database list and of
// the Query window, the viewer's status pop-up and series list, the smart
// albums' rule editor and the Web Portal all ask here. The list itself, with
// the rule that a state keeps its number, is IsiXDatabase's StudyStateList,
// kept in the preferences; the user edits it in StudyStatesEditor.

/// The list of study states the application shows, and what applying one does.
@objc(IsiXStudyStates)
public final class StudyStates: NSObject {
    // MARK: - The list

    public static var list: StudyStateList {
        StudyStateList(stored: PreferencesSource.process.preferences[StudyStateList.preference])
    }

    /// Keeps the list and has the State columns show it; the pop-ups of the
    /// viewers take it the next time they show a state. The list of a new
    /// installation is kept as no preference at all.
    public static func save(_ list: StudyStateList) {
        let preferences = PreferencesSource.process.preferences
        if list == .standard {
            preferences.remove(StudyStateList.preference)
        } else {
            preferences.set(list.stored, for: StudyStateList.preference)
        }
        DispatchQueue.main.async {
            columns.removeAll { !$0.refresh() }
        }
    }

    /// The name of one of the first states, in the user's language.
    static func builtInName(_ key: String) -> String {
        switch key {
        case "empty": return NSLocalizedString("empty", comment: "")
        case "unread": return NSLocalizedString("unread", comment: "")
        case "reviewed": return NSLocalizedString("reviewed", comment: "")
        case "dictated": return NSLocalizedString("dictated", comment: "")
        case "validated": return NSLocalizedString("validated", comment: "")
        case "printed": return NSLocalizedString("printed", comment: "")
        case "distributed": return NSLocalizedString("distributed", comment: "")
        case "archived": return NSLocalizedString("archived", comment: "")
        default: return key
        }
    }

    /// The name of a state the user added and did not name.
    static func numberedName(_ number: Int) -> String {
        String(format: NSLocalizedString("State %d", comment: ""), number)
    }

    /// The names of the states, by number.
    @objc public static var names: [String] {
        list.names(localized: builtInName, numbered: numberedName)
    }

    /// The name of the state a study stores as `value`; nil for a number the
    /// list does not have.
    @objc(nameOfState:)
    public static func name(ofStored value: Int) -> String? {
        let list = list
        return list.index(ofStored: value).map { list.name(at: $0, localized: builtInName, numbered: numberedName) }
    }

    // MARK: - Menus

    /// A dot of the state's colour, for its menu item; nil without a colour.
    @MainActor static func image(for color: StudyStateColor?) -> NSImage? {
        guard let color else { return nil }
        let fill = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    /// An item per state, in the order of their numbers, the number as tag.
    @MainActor static func menuItems(shortcuts: Bool = false) -> [NSMenuItem] {
        let list = list
        return list.states.indices.map { index in
            let item = NSMenuItem(title: list.name(at: index, localized: builtInName, numbered: numberedName), action: nil, keyEquivalent: "")
            item.tag = index
            item.image = image(for: list.states[index].color)
            if shortcuts, let digit = StudyStateList.shortcutDigit(at: index) {
                item.keyEquivalent = String(digit)
                item.keyEquivalentModifierMask = [.option]
            }
            return item
        }
    }

    /// Fills a pop-up with the states, keeping the state it showed. With
    /// `editItem`, an item that opens the editor follows them.
    @MainActor static func fill(_ menu: NSMenu, editItem: Bool = false) {
        menu.removeAllItems()
        menuItems().forEach(menu.addItem)
        if editItem {
            menu.addItem(.separator())
            menu.addItem(withTitle: NSLocalizedString("Edit States…", comment: ""), action: nil, keyEquivalent: "")
        }
    }

    /// Shows the state `value` in the viewer's status pop-up, whose items are
    /// the list's.
    @MainActor static func select(_ value: Int, in popup: NSPopUpButton?) {
        guard let popup, let menu = popup.menu else { return }
        if menu.items.map(\.title) != names { fill(menu) }
        popup.selectItem(withTag: list.index(ofStored: value) ?? 0)
    }

    /// The State columns of the lists that are open.
    @MainActor private static var columns: [StudyStateColumn] = []

    /// Gives the State columns of a list their pop-up cell, and keeps it the
    /// list's as the list changes.
    @MainActor static func install(on outline: NSOutlineView?, columns identifiers: [String], editable: Bool) {
        guard let outline else { return }
        let column = StudyStateColumn(outline: outline, columns: identifiers, editable: editable)
        column.apply()
        columns.append(column)
    }

    /// Whether the value a State cell was given is its "Edit States…" item,
    /// which opens the editor and is not a state.
    @MainActor static func openEditorIfChosen(_ value: Any?, column: NSTableColumn?) -> Bool {
        guard column?.identifier.rawValue == "stateText", let index = (value as? NSNumber)?.intValue, index >= list.states.count else { return false }
        StudyStatesEditor.shared.show()
        return true
    }

    // MARK: - The database list

    @MainActor private static let commands = StudyStateCommands()

    /// The "Study State" submenu of the list's contextual menu.
    @MainActor static func addContextualItems(to menu: NSMenu) {
        let submenu = NSMenu(title: NSLocalizedString("Study State", comment: ""))
        for item in menuItems(shortcuts: true) {
            item.target = commands
            item.action = #selector(StudyStateCommands.applyState(_:))
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let edit = NSMenuItem(title: NSLocalizedString("Edit States…", comment: ""), action: #selector(StudyStateCommands.editStates(_:)), keyEquivalent: "")
        edit.target = commands
        submenu.addItem(edit)
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    /// Option and a digit in the database list give the selected studies the
    /// state of that number. False for any other key.
    @MainActor static func applyShortcut(_ event: NSEvent, in controller: NSWindowController?) -> Bool {
        let flags = event.modifierFlags.intersection([.option, .command, .control, .shift])
        guard flags == .option, let browser = controller as? BrowserController,
              let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
              StudyStateList.shortcutDigit(at: digit) != nil, list.index(ofStored: digit) != nil else { return false }
        apply(digit, toSelectionOf: browser)
        return true
    }

    /// Gives the rows selected in the database list the state `state`.
    @MainActor static func apply(_ state: Int, toSelectionOf browser: BrowserController) {
        guard browser.database?.isReadOnly != true, let item = browser.databaseSelection()?.first else {
            NSSound.beep()
            return
        }
        browser.setDatabaseValue(NSNumber(value: state), item: item, forKey: "stateText")
        browser.horos_databaseOutline?.reloadData()
    }

    // MARK: - Actions

    /// A study's state went from `previous` to `state`: what the new state
    /// does by itself is done, on the main thread, for a study of the
    /// database shown. The DICOM PDF the "validated" preference already made
    /// is not made twice.
    static func stateChanged(of study: DicomStudy, from previous: Int32, to state: Int32) {
        let action = list.action(from: Int(previous), to: Int(state))
        guard action != .none else { return }
        if action == .reportToDICOMPDF, ValidatedReportPDF.isDue(from: previous, to: state),
           PreferencesSource.process.preferences[DatabasePreferences.generatesDICOMPDFWhenValidated] { return }
        let identifier = study.objectID
        DispatchQueue.main.async {
            guard let browser = BrowserDatabaseSource.process.processGraph.currentBrowser,
                  let found = try? browser.database?.managedObjectContext?.existingObject(with: identifier) as? DicomStudy else { return }
            perform(action, on: found, in: browser)
        }
    }

    @MainActor private static func perform(_ action: StudyStateAction, on study: DicomStudy, in browser: BrowserController) {
        switch action {
        case .none:
            break
        case .openImages:
            browser.databaseOpenStudy(study)
        case .reportToDICOMPDF:
            if study.reportURL != nil { study.archiveValidatedReportAsDICOMPDF() }
        case .reportToPDF:
            // Beside the report, which stays the study's report.
            guard let report = study.reportURL, (report as NSString).pathExtension.lowercased() != "pdf", report.hasPrefix("/") else { return }
            writeReportPDF(of: study, to: ((report as NSString).deletingPathExtension as NSString).appendingPathExtension("pdf"))
        case .saveReportAsPDF:
            guard study.reportURL != nil, let base = browser.database?.dataBaseDirPath else { return }
            let folder = (base as NSString).appendingPathComponent(reportsExportFolderName)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            writeReportPDF(of: study, to: (folder as NSString).appendingPathComponent(reportFileName(of: study)))
        }
    }

    /// The folder of the data folder the reports saved by a state go to.
    static let reportsExportFolderName = "EXPORT-REPORTS"

    /// "<patient> <study date> <end of the study's identifier>.pdf", with
    /// nothing a file name cannot hold.
    static func reportFileName(of study: DicomStudy) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let parts = [study.name ?? "", study.date.map(formatter.string(from:)) ?? "", (study.studyInstanceUID ?? "").split(separator: ".").last.map(String.init) ?? ""]
        let name = parts.filter { !$0.isEmpty }.joined(separator: " ")
        return name.map { "/:\\\n\r".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) } + ".pdf"
    }

    @MainActor private static func writeReportPDF(of study: DicomStudy, to path: String?) {
        guard let path else { return }
        do {
            try study.writeReportPDF(atPath: path)
        } catch {
            let reason = StudyDocumentError.exception(of: error).reason ?? "\(error)"
            PreferencesSource.process.processGraph.userNotifications.post(title: NSLocalizedString("Report Error", comment: ""),
                                                                           description: "\(study.name ?? ""): \(reason)", name: "reportConversion")
        }
    }
}

/// The State columns of one list: their pop-up cell, made again when the
/// list of states changes.
@MainActor private final class StudyStateColumn {
    private weak var outline: NSOutlineView?
    private let columns: [String]
    private let editable: Bool

    init(outline: NSOutlineView, columns: [String], editable: Bool) {
        self.outline = outline
        self.columns = columns
        self.editable = editable
    }

    func apply() {
        for identifier in columns {
            let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
            cell.isEditable = editable
            cell.isBordered = false
            if let menu = cell.menu { StudyStates.fill(menu, editItem: editable) }
            outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.dataCell = cell
        }
    }

    /// Shows the list as it is now; false once the list of studies is gone.
    func refresh() -> Bool {
        guard let outline else { return false }
        apply()
        outline.reloadData()
        return true
    }
}

/// The target of the contextual menu's state items.
@MainActor private final class StudyStateCommands: NSObject, NSMenuItemValidation {
    private var browser: BrowserController? { BrowserDatabaseSource.process.processGraph.currentBrowser }

    @objc func applyState(_ sender: NSMenuItem) {
        if let browser { StudyStates.apply(sender.tag, toSelectionOf: browser) }
    }

    @objc func editStates(_ sender: Any?) {
        StudyStatesEditor.shared.show()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(applyState(_:)) else { return true }
        return browser?.database?.isReadOnly == false && !(browser?.databaseSelection()?.isEmpty ?? true)
    }
}
