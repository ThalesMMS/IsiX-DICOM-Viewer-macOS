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
import IsiXPluginLoading
import IsiXPreferences
import IsiXStorage

/// Imports, at launch, what earlier versions kept in `Application Support/Horos`,
/// and says what could not be imported. Asks before copying plugins, once; the
/// plugin manager's Import Plugins from Horos or OsiriX command looks again at
/// any time, for what was installed or updated in those folders since.
///
/// Horos uses that folder too, and two applications writing the same accounts
/// and pages is what the import ends, so it is not left to a question: the
/// items are copied as soon as they are found. That is safe to do unasked
/// because the import only reads the Horos folder and replaces nothing already
/// in the new one. A Don't Import recorded by an earlier version is kept.
/// The copying, checking and recording are `LegacySupportImport`'s.
/// This runs before the Web Portal opens its accounts, so that it opens the
/// imported ones. The App Store build keeps its own folder in its container and
/// imports nothing.
enum LegacySupportImportPrompt {
    @MainActor static func offerPluginsIfNeeded() {
        #if !MACAPPSTORE
        let migration = LegacyPluginImport(userDomain: StorageLocations.runningUserDomain,
                                           systemDomain: StorageLocations.runningSystemDomain)
        do {
            let problems = try migration.offerIfNeeded(rules: pluginRules) { names in
                let description = NSLocalizedString("Copy the plugins found in the Horos or OsiriX folders to your IsiX plugin folders? IsiX can load active plugins after copying and keeps existing plugins with the same name.", comment: "")
                var preview = names.prefix(8).joined(separator: "\n")
                if names.count > 8 {
                    preview += "\n" + String(format: NSLocalizedString("… and %ld more", comment: ""), names.count - 8)
                }
                let answer = HorosAlertPanel.runInformational(title: NSLocalizedString("Copy plugins to IsiX?", comment: ""),
                                                              message: description + "\n\n" + preview,
                                                              defaultButton: NSLocalizedString("Copy Plugins", comment: ""),
                                                              alternateButton: NSLocalizedString("Don't Copy", comment: ""),
                                                              otherButton: nil)
                return answer == HorosAlertPanel.defaultResponse
            }
            guard !problems.isEmpty else { return }
            let lines = problems.map { problem in
                switch problem {
                case .alreadyInstalled(let name):
                    return String(format: NSLocalizedString("A plugin named %@ already exists in IsiX.", comment: ""), name)
                case .copyFailed(let name, let reason):
                    return String(format: NSLocalizedString("%@: %@", comment: ""), name, reason)
                }
            }
            showPluginImportProblem(lines.joined(separator: "\n"))
        } catch {
            showPluginImportProblem(error.localizedDescription)
        }
        #endif
    }

    // MARK: plugins, asked for again

    /// The rules of plugin bundles the copy follows: the plugin loader's own.
    #if !MACAPPSTORE
    static var pluginRules: LegacyPluginImport.Rules {
        LegacyPluginImport.Rules(
            isPlugin: PluginAdmission.isPluginBundle,
            version: PluginBundleVersion.declared(byBundleAt:),
            compare: PluginBundleVersion.compare,
            isPreferred: { first, second in
                SameNamePlugins.isPreferred(.init(path: first.url.path, version: first.version, folderRank: first.rank),
                                            to: .init(path: second.url.path, version: second.version, folderRank: second.rank))
            })
    }

    /// What a survey found, as the lines the user reads: what would be copied,
    /// and what is left out with its reason. A plugin left out for its name
    /// shows both versions.
    static func lines(of survey: LegacyPluginImport.Survey) -> (additions: [String], leftOut: [String]) {
        func named(_ name: String, _ version: String?) -> String {
            "\(name) (\(version ?? NSLocalizedString("no version", comment: "A plugin that declares no version")))"
        }
        let additions = survey.additions.map { addition -> String in
            let source = named(addition.source.name, addition.source.version)
            guard let installed = addition.replaces else { return source }
            return String(format: NSLocalizedString("%1$@ replaces %2$@", comment: "A plugin and the installed plugin it takes the place of"),
                          source, named(installed.name, installed.version))
        }
        let leftOut = survey.skipped.map { skipped -> String in
            let source = named(skipped.name, skipped.version)
            switch skipped.reason {
            case .symbolicLink:
                return String(format: NSLocalizedString("%@: it is a symbolic link, not a plugin.", comment: ""), skipped.name)
            case .alias:
                return String(format: NSLocalizedString("%@: it is an alias, not a plugin.", comment: ""), skipped.name)
            case .sameName(let preferred):
                return String(format: NSLocalizedString("%1$@: %2$@ has the same name and is used instead.", comment: "Two plugins of one name in the folders searched"),
                              source, named(preferred.name, preferred.version))
            case .installedKept(let installed):
                let comparable = PluginBundleVersion.compare(skipped.version, installed.version) != nil
                return String(format: comparable
                                ? NSLocalizedString("%1$@: IsiX already has %2$@, which is newer.", comment: "")
                                : NSLocalizedString("%1$@: IsiX already has %2$@, and their versions cannot be compared.", comment: ""),
                              source, named(installed.name, installed.version))
            case .copyFailed(let reason):
                return String(format: NSLocalizedString("%@: %@", comment: ""), skipped.name, reason)
            }
        }
        return (additions, leftOut)
    }

    /// The command of the plugin manager: looks again in the plugins folders of
    /// Horos and OsiriX, shows what is new or newer and what is left out, and
    /// copies on confirmation. `replace` puts a newer bundle in the place of
    /// the installed one; `finished` says whether anything was copied.
    ///
    /// The alerts are sheets of the plugin manager's window, begun from its
    /// button's action.
    @MainActor static func importPluginsAgain(attachedTo window: NSWindow, replace: @escaping @Sendable (URL, URL) throws -> Void,
                                              finished: @escaping @MainActor (Bool) -> Void) {
        let migration = LegacyPluginImport(userDomain: StorageLocations.runningUserDomain,
                                           systemDomain: StorageLocations.runningSystemDomain)
        let rules = pluginRules
        let survey = migration.survey(rules: rules)
        let (additions, leftOut) = lines(of: survey)
        let alert = NSAlert()
        // The command's own name, without the ellipsis of a button that asks before acting.
        alert.messageText = NSLocalizedString("Import Plugins from Horos or OsiriX…", comment: "").replacingOccurrences(of: "…", with: "")
        guard !additions.isEmpty || !leftOut.isEmpty else {
            alert.informativeText = NSLocalizedString("No new or newer plugins were found in the Horos or OsiriX plugins folders.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.beginSheetModal(for: window) { _ in finished(false) }
            return
        }
        var sections: [String] = []
        if !additions.isEmpty {
            sections.append(NSLocalizedString("New or newer:", comment: "Heading of the plugins an import would copy") + "\n" + additions.joined(separator: "\n"))
        }
        if !leftOut.isEmpty {
            sections.append(NSLocalizedString("Left out:", comment: "Heading of the plugins an import does not copy") + "\n" + leftOut.joined(separator: "\n"))
        }
        alert.informativeText = additions.isEmpty
            ? NSLocalizedString("No new or newer plugins were found in the Horos or OsiriX plugins folders.", comment: "")
            : NSLocalizedString("Importing copies the plugins listed as new or newer to your IsiX plugins folders. The Horos and OsiriX folders are not changed.", comment: "")
        alert.accessoryView = listView(sections.joined(separator: "\n\n"))
        if additions.isEmpty {
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        } else {
            alert.addButton(withTitle: NSLocalizedString("Import", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        }
        alert.beginSheetModal(for: window) { response in
            guard !additions.isEmpty, response == .alertFirstButtonReturn else {
                finished(false)
                return
            }
            // The sheet stays up until this returns: it leaves first, and what
            // follows (the report of what failed, the request to restart) begins
            // on the next turn of the run loop, over the window and not over it.
            alert.window.orderOut(nil)
            let failures: [String]
            do {
                let failed = try migration.add(survey.additions, rules: rules, replace: replace)
                failures = lines(of: LegacyPluginImport.Survey(skipped: failed)).leftOut
            } catch {
                failures = [error.localizedDescription]
            }
            let copied = failures.count < survey.additions.count
            onMainRunLoop {
                guard !failures.isEmpty else {
                    finished(copied)
                    return
                }
                let report = NSAlert()
                report.messageText = NSLocalizedString("Some plugins were not copied", comment: "")
                report.informativeText = failures.joined(separator: "\n")
                report.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                report.beginSheetModal(for: window) { _ in
                    report.window.orderOut(nil)
                    onMainRunLoop { finished(copied) }
                }
            }
        }
    }

    /// A list that scrolls: the folders of a long-time user hold dozens of plugins.
    @MainActor private static func listView(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 180)
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = false
        if let list = scroll.documentView as? NSTextView {
            list.isEditable = false
            list.isSelectable = true
            list.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            list.textContainerInset = NSSize(width: 4, height: 6)
            list.string = text
        }
        return scroll
    }
    #endif

    private static func showPluginImportProblem(_ message: String) {
        HorosAlertPanel.runInformational(title: NSLocalizedString("Some plugins were not copied", comment: ""),
                                         message: message,
                                         defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    static func importIfNeeded() {
        #if !MACAPPSTORE
        // A configured accounts database is the Web Portal's, wherever it is.
        let configured = !(PreferencesSource.process.preferences[DatabasePreferences.webPortalDatabasePath] ?? "").isEmpty
        let migration = LegacySupportImport(userDomain: StorageLocations.runningUserDomain,
                                            systemDomain: StorageLocations.runningSystemDomain,
                                            items: LegacySupportImport.Item.standard(includingAccounts: !configured))
        guard !migration.isSettled else { return }
        let survey = migration.survey()
        let pending = survey.contains { if case .pending = $0.status { return true } else { return false } }
        guard pending || survey.contains(where: { $0.status == .conflict }) else { return }

        var results = survey
        if pending {
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
