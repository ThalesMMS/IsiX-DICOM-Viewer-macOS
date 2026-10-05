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

/// What happens when the user explicitly chooses a folder holding a Horos
/// database: as the database location, as a database to open, or at first use.
///
/// Opening it here upgrades it to this application's model, and Horos may then
/// refuse it or rebuild it, losing its albums, comments and status. The user is
/// told so and chooses: import its studies, which leaves it as it is, open it
/// anyway, which makes it this installation's database from then on, or cancel.
@objc(HorosForeignDatabaseChoice)
public final class ForeignDatabaseChoice: NSObject {

    @objc(HorosForeignDatabaseDecision)
    public enum Decision: Int {
        case importStudies, open, cancel
    }

    /// Whether to go on opening `path`. Asks first when it holds a Horos
    /// database this installation has not adopted; importing or cancelling
    /// answers no.
    @objc(confirmOpeningPath:)
    @MainActor public static func confirmOpening(path: String?) -> Bool {
        return confirmedPath(forChosenPath: path) != nil
    }

    /// The path to open for the one the user chose: that path itself when it
    /// leads to no Horos database; the Horos database's own directory when this
    /// installation adopted it or the user opens it anyway, because a folder
    /// holding it may also hold a database of this application, which would be
    /// opened first; and `nil` when the user imported its studies or cancelled.
    @objc(confirmedPathForChosenPath:)
    @MainActor public static func confirmedPath(forChosenPath path: String?) -> String? {
        guard let horos = DatabaseLocation.horosDataDirectory(forChosenPath: path, adopted: []) else { return path }
        if DatabaseLocation.isAdopted(horos, in: DatabaseLocation.adoptedHorosDirectories()) { return horos }
        let open = apply(ask(horosDirectory: horos), horosDirectory: horos, defaults: .standard,
                         startImport: { importIntoCurrentDatabase($0) })
        return open ? horos : nil
    }

    /// Does what the chosen option says, and answers whether to open the database.
    @MainActor static func apply(_ decision: Decision, horosDirectory: String, defaults: UserDefaults,
                      startImport: (String) -> Void) -> Bool {
        switch decision {
        case .open:
            DatabaseLocation.adoptHorosDirectory(horosDirectory, defaults: defaults)
            return true
        case .importStudies:
            startImport(DatabaseLocation.importFolder(forDataDirectory: horosDirectory))
            return false
        case .cancel:
            return false
        }
    }

    @MainActor static func ask(horosDirectory: String) -> Decision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("This folder holds a Horos database", comment: "Choosing a Horos database")
        alert.informativeText = String(format: NSLocalizedString("%@ is a database made by Horos. Opening it here upgrades it to the format of IsiX DICOM Viewer, and Horos may then no longer open it. The two applications working on one database can also damage it.\n\nImport Studies leaves the Horos database as it is and brings its studies into a database of IsiX DICOM Viewer.", comment: "Choosing a Horos database"), horosDirectory)
        alert.addButton(withTitle: NSLocalizedString("Import Studies", comment: "Choosing a Horos database"))
        alert.addButton(withTitle: NSLocalizedString("Open Anyway", comment: "Choosing a Horos database"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Choosing a Horos database"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .importStudies
        case .alertSecondButtonReturn: return .open
        default: return .cancel
        }
    }

    /// File > Import on `folder`, into the database the browser shows. That
    /// flow asks whether to copy the files or only link to them.
    @MainActor static func importIntoCurrentDatabase(_ folder: String) {
        NSLog("Database: importing the studies of %@", folder)
        BrowserController.currentBrowser()?.subSelectFilesAndFolders(toAdd: [folder])
    }

    /// At first use there is no database to import into yet: the import starts
    /// once the chosen location is open.
    @MainActor private static var pendingImport: String?

    @MainActor static func importAfterSetup(_ folder: String) {
        pendingImport = folder
    }

    @objc @MainActor public static func startPendingImport() {
        guard let folder = pendingImport else { return }
        pendingImport = nil
        DispatchQueue.main.async { importIntoCurrentDatabase(folder) }
    }
}
