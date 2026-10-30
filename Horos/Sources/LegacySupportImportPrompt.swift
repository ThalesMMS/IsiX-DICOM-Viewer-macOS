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
import IsiXStorage

/// Asks the user, at launch, whether to import what earlier versions kept in
/// `Application Support/Horos`, and says what could not be imported.
///
/// Horos uses that folder too, so its contents are never assumed to be this
/// app's: nothing is copied before the user chooses Import, and Don't Import
/// is remembered. The copying, checking and recording are `LegacySupportImport`'s.
/// This runs before the Web Portal opens its accounts, so that it opens the
/// imported ones. The App Store build keeps its own folder in its container and
/// imports nothing.
enum LegacySupportImportPrompt {
    static func offerIfNeeded() {
        #if !MACAPPSTORE
        // A configured accounts database is the Web Portal's, wherever it is.
        let configured = !(UserDefaults.standard.string(forKey: "WebPortalDatabasePath") ?? "").isEmpty
        let migration = LegacySupportImport(userDomain: StorageLocations.runningUserDomain,
                                            items: LegacySupportImport.Item.standard(includingAccounts: !configured))
        guard !migration.isSettled else { return }
        let survey = migration.survey()
        let pending = survey.filter { if case .pending = $0.status { return true } else { return false } }
        let conflicts = survey.filter { $0.status == .conflict }
        guard !pending.isEmpty || !conflicts.isEmpty else { return }

        var results = survey
        if !pending.isEmpty {
            let list = survey.filter { $0.status == .pending || $0.status == .conflict }.map { entry in
                "• " + (entry.status == .conflict
                        ? String(format: NSLocalizedString("%@ (already in the new folder, which is kept)", comment: ""), title(of: entry.item))
                        : title(of: entry.item))
            }.joined(separator: "\n")
            let message = String(format: NSLocalizedString("Earlier versions of IsiX DICOM Viewer kept these items in %@, a folder that Horos also uses:\n\n%@\n\nImporting copies them to %@. Nothing in the Horos folder is changed, nothing already in the new folder is replaced, and plugins are not imported.", comment: ""),
                                 abbreviated(migration.source), list, abbreviated(migration.destination))
            let answer = HorosAlertPanel.runInformational(title: NSLocalizedString("Import from the Horos folder?", comment: ""),
                                                          message: message,
                                                          defaultButton: NSLocalizedString("Import", comment: ""),
                                                          alternateButton: NSLocalizedString("Not Now", comment: ""),
                                                          otherButton: NSLocalizedString("Don't Import", comment: ""))
            if answer == HorosAlertPanel.otherResponse {
                do { try migration.decline() } catch { NSLog("---- Import from the Horos folder: could not record the choice: %@", error.localizedDescription as NSString) }
                return
            }
            guard answer == HorosAlertPanel.defaultResponse else { return }
            results = migration.run()
            for entry in results {
                NSLog("---- Import from the Horos folder: %@ %@", entry.item.name as NSString, String(describing: entry.status) as NSString)
            }
        }
        report(results, of: migration)
        #endif
    }

    /// Says which items stay where they were, and records that the user has
    /// seen the conflicts.
    private static func report(_ results: [LegacySupportImport.Entry], of migration: LegacySupportImport) {
        let conflicts = results.filter { $0.status == .conflict }
        let lines = results.compactMap { entry -> String? in
            switch entry.status {
            case .conflict:
                return String(format: NSLocalizedString("%@: already in %@. That copy was kept, and the one in the Horos folder was not merged into it.", comment: ""),
                              title(of: entry.item), abbreviated(migration.destination))
            case .failed(let reason):
                return String(format: NSLocalizedString("%@: could not be copied (%@).", comment: ""), title(of: entry.item), reason)
            default:
                return nil
            }
        }
        guard !lines.isEmpty else { return }
        let message = lines.joined(separator: "\n\n") + "\n\n"
            + NSLocalizedString("Nothing in the Horos folder was changed. What could not be copied will be offered again the next time IsiX DICOM Viewer opens.", comment: "")
        HorosAlertPanel.runInformational(title: NSLocalizedString("Some items were not imported", comment: ""), message: message,
                                         defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        do { try migration.keepExisting(conflicts) } catch { NSLog("---- Import from the Horos folder: could not record the choice: %@", error.localizedDescription as NSString) }
    }

    private static func title(of item: LegacySupportImport.Item) -> String {
        switch item {
        case .webPortalAccounts: return NSLocalizedString("Web Portal accounts and their settings", comment: "")
        case .customWebPages: return NSLocalizedString("Custom Web Portal pages", comment: "")
        case .weasis: return NSLocalizedString("Weasis customization", comment: "")
        default: return item.name
        }
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
