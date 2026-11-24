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
/// any time, for what was installed or updated in those folders since, and
/// each launch after that first answer offers, once, a version those folders
/// have that is higher than the one IsiX has, or a plugin it does not have.
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
            if !problems.isEmpty {
                let lines = problems.map { problem in
                    switch problem {
                    case .alreadyInstalled(let name):
                        return String(format: NSLocalizedString("A plugin named %@ already exists in IsiX.", comment: ""), name)
                    case .copyFailed(let name, let reason):
                        return String(format: NSLocalizedString("%@: %@", comment: ""), name, reason)
                    }
                }
                showPluginImportProblem(lines.joined(separator: "\n"))
            }
        } catch {
            showPluginImportProblem(error.localizedDescription)
        }
        offerNewerPluginsIfNeeded(migration)
        #endif
    }

    // MARK: plugins, asked for again

    /// The rules of plugin bundles the copy follows: the plugin loader's own,
    /// which asks whether this Mac can load a bundle as the loader does before
    /// opening one, by its signature and its files.
    #if !MACAPPSTORE
    static var pluginRules: LegacyPluginImport.Rules {
        rules(canLoad: { PluginManager.refusalBeforeOpening(bundleAt: $0) == nil })
    }

    /// The rules of a launch's own look at those folders. It runs at every
    /// launch, before the plugins load, so it validates no signature and
    /// inspects no bundle: between two bundles of one name the version, the
    /// folder and the format decide, and whether a bundle loads is not asked.
    static var launchPluginRules: LegacyPluginImport.Rules {
        rules(canLoad: { _ in true })
    }

    /// The loader's rules, with `canLoad` answering whether this Mac can load
    /// the bundle at a path. An entry that is a symbolic link or an alias is
    /// asked about as the bundle it leads to, which is the one that loads.
    private static func rules(canLoad: @escaping @Sendable (String) -> Bool) -> LegacyPluginImport.Rules {
        // What the last launch did not load, read once for the rules: a plugin
        // of IsiX in it is replaced by another build of its name, whatever the
        // versions say.
        let notLoaded = PluginsNotLoadedNotice.notice.recorded()
        return LegacyPluginImport.Rules(
            isPlugin: PluginAdmission.isPluginBundle,
            version: PluginBundleVersion.declared(byBundleAt:),
            compare: PluginBundleVersion.compare,
            isPreferred: { first, second in
                SameNamePlugins.isPreferred(.init(path: (first.target ?? first.url).path, version: first.version, folderRank: first.rank),
                                            to: .init(path: (second.target ?? second.url).path, version: second.version, folderRank: second.rank),
                                            canLoad: canLoad)
            },
            canLoad: { canLoad($0.path) },
            failedToLoad: { found in
                guard let bundle = found.target, !notLoaded.isEmpty else { return false }
                return PluginsNotLoadedNotice.notLoadedAtLastLaunch(notLoaded, bundleAt: bundle, version: found.version)
            })
    }

    /// At a launch after the single offer was answered: what the plugins
    /// folders of Horos and OsiriX have gained since, a higher version of a
    /// plugin of IsiX or a plugin it does not have, offered once whatever the
    /// answer. Importing replaces a plugin as an update does, so the copy it
    /// replaces is kept until the new one has loaded; this runs before the
    /// plugins load, so what is imported loads in this launch. Not in
    /// Protected Mode, where no plugin loads.
    @MainActor private static func offerNewerPluginsIfNeeded(_ migration: LegacyPluginImport) {
        guard !DCMPix.isRunOsiriXInProtectedModeActivated() else { return }
        do {
            let failed = try migration.offerNewerIfNeeded(rules: launchPluginRules, shouldImport: { additions in
                let found = lines(of: LegacyPluginImport.Survey(additions: additions)).additions
                var preview = found.prefix(8).joined(separator: "\n")
                if found.count > 8 {
                    preview += "\n" + String(format: NSLocalizedString("… and %ld more", comment: ""), found.count - 8)
                }
                let description = NSLocalizedString("New or newer plugins were found in the Horos or OsiriX plugins folders.", comment: "")
                    + " " + NSLocalizedString("Importing copies the plugins listed as new or newer to your IsiX plugins folders. The Horos and OsiriX folders are not changed.", comment: "")
                // The command's own name, without the ellipsis of a button that asks before acting.
                let title = NSLocalizedString("Import Plugins from Horos or OsiriX…", comment: "").replacingOccurrences(of: "…", with: "")
                let answer = HorosAlertPanel.runInformational(title: title, message: description + "\n\n" + preview,
                                                              defaultButton: NSLocalizedString("Import", comment: ""),
                                                              alternateButton: NSLocalizedString("Not Now", comment: ""),
                                                              otherButton: nil)
                return answer == HorosAlertPanel.defaultResponse
            }, replace: { source, installed in try PluginManager.replaceInstalledPlugin(at: installed, with: source) })
            let failures = lines(of: LegacyPluginImport.Survey(skipped: failed)).leftOut
            if !failures.isEmpty { showPluginImportProblem(failures.joined(separator: "\n")) }
        } catch {
            showPluginImportProblem(error.localizedDescription)
        }
    }

    /// What follows the name of a plugin to bring in that this Mac cannot load,
    /// or nothing: an installer made for Horos or OsiriX puts the Intel-only
    /// build of a plugin in their folders, and the copy would go in to be
    /// refused at launch. Its files are read, as the loader reads them before
    /// opening a bundle, and its signature is not checked: only the few
    /// bundles an offer lists are read, and the loader says the rest.
    static func cannotLoadNote(_ source: LegacyPluginImport.Found) -> String {
        guard let bundle = source.target else { return "" }
        let inspection = PluginInspector().inspect(bundleAt: bundle)
        guard !inspection.isLoadable else { return "" }
        if let found = inspection.foreignArchitectures, !found.isEmpty {
            return " — " + String(format: NSLocalizedString("built for %@ only; it will not load on this Mac", comment: "The architectures of a plugin, as x86_64"),
                                  found.joined(separator: ", "))
        }
        return " — " + NSLocalizedString("it will not load on this Mac", comment: "A plugin an import would copy")
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
            // After the whole line, so that a replacement still reads as one.
            let note = cannotLoadNote(addition.source)
            guard let installed = addition.replaces else { return source + note }
            return String(format: NSLocalizedString("%1$@ replaces %2$@", comment: "A plugin and the installed plugin it takes the place of"),
                          source, named(installed.name, installed.version)) + note
        }
        let leftOut = survey.skipped.map { skipped -> String in
            let source = named(skipped.name, skipped.version)
            switch skipped.reason {
            case .symbolicLink:
                return String(format: NSLocalizedString("%@: it is a symbolic link, not a plugin.", comment: ""), skipped.name)
            case .alias:
                return String(format: NSLocalizedString("%@: it is an alias, not a plugin.", comment: ""), skipped.name)
            case .leadsNowhere:
                return String(format: NSLocalizedString("%@: the link leads to an item that no longer exists.", comment: ""), skipped.name)
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
