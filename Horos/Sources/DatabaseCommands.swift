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

// The target of the main menu's commands on the database, an object of
// MainMenu.xib, made with -init and kept, like the nib's other top-level
// objects, for the life of the process:
// File > Files & Maintenance > Find Unindexed Files… (UnindexedFileImport),
// which acts on the active local database, enabled when that database can be
// written and rebuilt and no search of it is under way.

/// The main menu's commands on the database.
@MainActor @objc(IsiXDatabaseCommands)
final class DatabaseCommands: NSObject, NSMenuItemValidation {

    /// File > Files & Maintenance > Find Unindexed Files…
    @IBAction @objc(findUnindexedFiles:)
    func findUnindexedFiles(_ sender: Any?) {
        UnindexedFileImport.run()
    }

    /// The DICOM files of the data folder of the active local database that
    /// the command would offer now, without asking anything. For scripts and
    /// checks; the search runs on the calling thread.
    @objc(unindexedFilesOfActiveDatabase)
    func unindexedFilesOfActiveDatabase() -> [String] {
        UnindexedFileImport.unindexedFiles()
    }

    /// What the command does once the user agrees, without asking: finds the
    /// files and indexes them where they are, on the calling thread. Returns
    /// how many are now in the index. For scripts and checks.
    @objc(importUnindexedFilesOfActiveDatabase)
    func importUnindexedFilesOfActiveDatabase() -> Int {
        UnindexedFileImport.importUnindexedFiles()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findUnindexedFiles(_:)):
            return UnindexedFileImport.isPossible
        default:
            return true
        }
    }
}
