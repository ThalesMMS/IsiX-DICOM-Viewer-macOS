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
import IsiXDICOMFile
import UniformTypeIdentifiers

// The target of main menu items on the study selected in the database
// window, an object of MainMenu.xib made with -init and kept, like the nib's
// other top-level objects, for the life of the process; the list's contextual
// menu targets `shared`, since a menu item does not keep its target.
// File > Import > Import Images and PDFs into Selected Study… converts the
// JPEG, PNG, TIFF and PDF files chosen in an open panel into new series of
// the selected study (StudyFileImporter). It is enabled only when one row of
// the list is selected and its study can take files: a local database that
// is not read-only, a study neither distant nor locked.

/// The main menu's commands on the study selected in the database window.
@MainActor @objc(IsiXDatabaseStudyCommands)
final class DatabaseStudyCommands: NSObject, NSMenuItemValidation {

    /// The target of the list's contextual menu item. The object holds no
    /// state, so it serves as well as the nib's.
    static let shared = DatabaseStudyCommands()

    private var browser: BrowserController? { BrowserDatabaseSource.process.processGraph.currentBrowser }

    /// File > Import > Import Images and PDFs into Selected Study…: an open
    /// panel of JPEG, PNG, TIFF and PDF files, which go into the selected study.
    @IBAction @objc(importImagesAndPDFsIntoSelectedStudy:)
    func importImagesAndPDFsIntoSelectedStudy(_ sender: Any?) {
        guard let browser, let study = StudyFileImporter.selectedStudy(in: browser) else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = StudyFileImport.acceptedTypes
        panel.prompt = NSLocalizedString("Import", comment: "")
        panel.message = NSLocalizedString("Import Images and PDFs", comment: "")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        StudyFileImporter.convert(panel.urls.map(\.path), into: study, browser: browser)
    }

    /// What the command does without its panel and its alert, for scripts
    /// and checks: converts `paths` into the study selected in the database
    /// window and answers how many objects were indexed, -1 when no study
    /// can take them.
    @objc(importFilesAtPathsIntoSelectedStudy:)
    func importFilesIntoSelectedStudy(_ paths: [String]) -> Int {
        guard let browser, let study = StudyFileImporter.selectedStudy(in: browser), let database = browser.database else {
            return -1
        }
        return StudyFileImporter(study: study, database: database).convert(paths).indexedCount
    }

    /// The items of the list's contextual menu that the browser does not
    /// answer, aimed at `shared`, which validates them; the menu hides them
    /// when they do not apply.
    static func addContextualItems(to menu: NSMenu) {
        let item = NSMenuItem(title: NSLocalizedString("Import Images and PDFs into Selected Study…", comment: ""),
                              action: #selector(importImagesAndPDFsIntoSelectedStudy(_:)), keyEquivalent: "")
        item.target = shared
        menu.addItem(item)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(importImagesAndPDFsIntoSelectedStudy(_:)):
            return browser.flatMap { StudyFileImporter.selectedStudy(in: $0) } != nil
        default:
            return true
        }
    }
}
