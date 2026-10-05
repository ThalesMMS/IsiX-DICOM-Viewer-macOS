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
import Synchronization

/// Chooses a storage location before the first database is opened. Existing
/// installations and explicit launch locations keep their configured behavior.
@objc(HorosDatabaseFirstUse)
public final class DatabaseFirstUse: NSObject {
    static let completedKey = "DatabaseLocationChoiceCompleted"
    static let pendingKey = "DatabaseLocationChoicePending"
    /// The data directory of an installation, as it is called now and as it
    /// was called in earlier versions, newest first. `Horos Data` is not one:
    /// it belongs to Horos, unless this installation already used it.
    static let dataDirectoryNames = [DatabaseLocation.dataDirectoryName] + DatabaseLocation.previousDataDirectoryNames

    static func needsChoice(defaults: UserDefaults, documents: URL) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments["DATABASELOCATION"] != nil || arguments["DEFAULT_DATABASELOCATION"] != nil ||
            arguments["DATABASELOCATIONURL"] != nil || arguments["DEFAULT_DATABASELOCATIONURL"] != nil {
            return false
        }
        if defaults.bool(forKey: completedKey) || defaults.integer(forKey: "DEFAULT_DATABASELOCATION") != 0 {
            return false
        }
        if defaults.bool(forKey: pendingKey) { return true }
        // Even a damaged or partially created database belongs to an existing
        // installation. Location setup must not redirect it to a new empty one.
        if dataDirectoryNames.contains(where: { FileManager.default.fileExists(atPath: documents.appendingPathComponent($0).path) }) {
            return false
        }
        let horos = documents.appendingPathComponent(DatabaseLocation.horosDataDirectoryName).path
        return !DatabaseLocation.isAdopted(horos, in: DatabaseLocation.adoptedHorosDirectories(defaults))
    }

    /// The Horos database on this Mac, if there is one: where the Horos
    /// preferences place it, or else `Horos Data` in Documents. First use says
    /// it was left alone and how to import its studies.
    @objc(horosDatabaseWithHorosPreferences:documents:)
    static func horosDatabase(horosPreferences: [String: Any]?, documents: URL) -> String? {
        var candidates: [String] = []
        let name = DatabaseLocation.horosDataDirectoryName
        if let preferences = horosPreferences,
           (preferences["DEFAULT_DATABASELOCATION"] as? NSNumber)?.intValue == 1,
           let folder = preferences["DEFAULT_DATABASELOCATIONURL"] as? String, !folder.isEmpty {
            // Horos keeps its database in `Horos Data`, inside the chosen folder
            // or as the folder itself.
            let components = (folder as NSString).pathComponents
            if let index = components.lastIndex(of: name) {
                candidates.append(NSString.path(withComponents: Array(components[0...index])))
            } else {
                candidates.append((folder as NSString).appendingPathComponent(name))
            }
        }
        candidates.append(documents.appendingPathComponent(name).path)
        return candidates.first { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    }

    /// The first-use explanation, with what became of a Horos database.
    @objc(explanationForDocuments:horosDatabase:)
    static func explanation(documents: URL, horosDatabase: String?) -> String {
        var text = String(format: NSLocalizedString("IsiX DICOM Viewer stores its index and imported images in an IsiX Data folder. This folder grows as you import studies.\n\nDocuments: %@\n\nYou can choose another folder or drive. Choosing a location does not move or duplicate existing data. Change it later in Settings > Database.", comment: "First use storage explanation"), documents.path)
        if let horosDatabase {
            text += "\n\n" + String(format: NSLocalizedString("A Horos database was found at %@. It was not opened or changed: IsiX DICOM Viewer keeps a database of its own.\n\nTo bring its studies over, choose File > Import > Import Files... once this step is done, and select the DATABASE.noindex folder inside it. Depending on Settings > Database, the import asks whether to copy the files or only link to them.", comment: "First use, Horos database left alone"), horosDatabase)
        }
        return text
    }

    /// Set and cleared at launch on the main thread. +[DicomDatabase
    /// defaultDatabase] asks `hasPendingChoice` on every call, from whichever
    /// thread, so that answer is an atomic flag kept beside the URL.
    private static let pendingDocuments = Mutex<URL?>(nil)
    private static let pendingChoice = Atomic<Bool>(false)

    @objc(prepareWithAlternateDefault:)
    public static func prepare(alternateDefault: String?) {
        #if MACAPPSTORE
        return
        #else
        guard alternateDefault.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              needsChoice(defaults: .standard, documents: documents) else { return }
        UserDefaults.standard.set(true, forKey: pendingKey)
        pendingDocuments.withLock { $0 = documents }
        pendingChoice.store(true, ordering: .releasing)
        #endif
    }

    @objc public static var hasPendingChoice: Bool { pendingChoice.load(ordering: .acquiring) }

    // Present after class initialization, when AppKit can service accessibility
    // and window events, but before the browser opens its database.
    @objc(choosePreparedLocation)
    @MainActor public static func choosePreparedLocation() -> Bool {
        guard let documents = pendingDocuments.withLock({ $0 }) else { return true }
        let chosen = chooseLocation(defaults: .standard, documents: documents)
        pendingDocuments.withLock { $0 = nil }
        pendingChoice.store(false, ordering: .releasing)
        return chosen
    }

    @MainActor static func chooseLocation(defaults: UserDefaults, documents: URL) -> Bool {
        while true {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Choose where to store your database", comment: "First use")
            alert.informativeText = explanation(
                documents: documents,
                horosDatabase: horosDatabase(horosPreferences: defaults.persistentDomain(forName: PreferencesContinuity.previousIdentifier),
                                             documents: documents))
            alert.addButton(withTitle: NSLocalizedString("Use Documents", comment: "First use"))
            alert.addButton(withTitle: NSLocalizedString("Choose Folder…", comment: "First use"))
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: "First use"))
            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                defaults.synchronize()
                return false
            }
            var location = documents
            if response == .alertSecondButtonReturn {
                let panel = NSOpenPanel()
                panel.title = NSLocalizedString("Choose database folder", comment: "First use")
                panel.message = NSLocalizedString("Select a folder for IsiX Data, or select an existing database to reopen it. No data will be moved or copied.", comment: "First use")
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = documents
                guard panel.runModal() == .OK, let selected = panel.url else { continue }
                location = selected
                // A Horos database is opened only once the user has read what
                // that does to it. Importing keeps it as it is and puts this
                // application's database beside it.
                if let horos = DatabaseLocation.horosDataDirectory(
                    forChosenPath: selected.path, adopted: DatabaseLocation.adoptedHorosDirectories(defaults)) {
                    let decision = ForeignDatabaseChoice.ask(horosDirectory: horos)
                    let open = ForeignDatabaseChoice.apply(decision, horosDirectory: horos, defaults: defaults,
                                                           startImport: { ForeignDatabaseChoice.importAfterSetup($0) })
                    if decision == .cancel { continue }
                    // Opened, it is the Horos directory itself, which a folder
                    // also holding a database of this application would hide;
                    // imported, this application's database goes beside it.
                    location = URL(fileURLWithPath: open ? horos : (horos as NSString).deletingLastPathComponent)
                }
            }
            if CloudFileAccess.providerName(forPath: location.path) != nil {
                let warn = NSAlert()
                warn.messageText = NSLocalizedString(
                    "Cloud storage is not validated for an active database",
                    comment: "First use cloud warning")
                warn.informativeText = CloudFileAccess.activeDatabaseWarning(forPath: location.path)
                warn.addButton(withTitle: NSLocalizedString("Choose a different folder", comment: "First use"))
                warn.addButton(withTitle: NSLocalizedString("Continue anyway", comment: "First use"))
                if warn.runModal() == .alertFirstButtonReturn {
                    continue
                }
            }
            // Store Documents explicitly too: subsequent launches reopen the
            // same selected folder through the existing location contract.
            defaults.set(location.path, forKey: "DEFAULT_DATABASELOCATIONURL")
            defaults.set(1, forKey: "DEFAULT_DATABASELOCATION")
            defaults.set(true, forKey: completedKey)
            defaults.removeObject(forKey: pendingKey)
            defaults.synchronize()
            return true
        }
    }
}
