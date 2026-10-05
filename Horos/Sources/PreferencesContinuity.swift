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

import Foundation

/// Carries the preferences of an installation made under the application's
/// previous identifier over to the current one.
///
/// macOS keeps preferences per bundle identifier, so the renamed application
/// starts with none. The previous domain is copied once, before anything reads a
/// preference, and is left as it was.
///
/// That domain is the one Horos uses, and Horos is another application with a
/// database of its own. Its nodes, listener, presets and the rest come over;
/// where its database is does not. The database model differs, so opening the
/// Horos database here would upgrade it to a format Horos may then refuse, and
/// the two applications working on one database can damage it.
@objc(HorosPreferencesContinuity)
public final class PreferencesContinuity: NSObject {

    /// The identifier of the released application.
    @objc public static let releaseIdentifier = "thalesmms.isis.workstation"
    /// The identifier releases carried before the application was renamed.
    @objc public static let previousIdentifier = "org.horosproject.horos"

    /// The keys that say where the database is, or that its place was chosen.
    static let databaseLocationKeys: Set<String> = [
        "DATABASELOCATION", "DATABASELOCATIONURL", "DEFAULT_DATABASELOCATION", "DEFAULT_DATABASELOCATIONURL",
        "DatabaseLocationChoiceCompleted", "DatabaseLocationChoicePending",
        DatabaseLocation.adoptedHorosDirectoriesKey,
    ]

    /// What to write into the domain of `identifier`, or `nil` to leave it.
    ///
    /// Only the released application imports: a development or test bundle has
    /// an identifier of its own and must not start from the user's settings.
    /// And only into an empty domain, so a preference changed after the import
    /// is never overwritten.
    static func preferencesToImport(into identifier: String?,
                                    current: [String: Any]?,
                                    previous: [String: Any]?,
                                    namesOwnDatabase: (String) -> Bool = DatabaseLocation.namesOwnDatabase) -> [String: Any]? {
        guard identifier == releaseIdentifier else { return nil }
        guard current?.isEmpty ?? true else { return nil }
        guard let previous, !previous.isEmpty else { return nil }
        return withoutDatabaseLocation(previous, namesOwnDatabase: namesOwnDatabase)
    }

    /// `preferences` without anything that leads to a Horos database: the
    /// location keys, the local sources that are not this application's
    /// databases, and any text that names a path inside `Horos Data`.
    static func withoutDatabaseLocation(_ preferences: [String: Any],
                                        namesOwnDatabase: (String) -> Bool) -> [String: Any] {
        var kept: [String: Any] = [:]
        for (key, value) in preferences {
            if databaseLocationKeys.contains(key) { continue }
            if key == "localDatabasePaths", let sources = value as? [Any] {
                kept[key] = sources.filter { source in
                    guard let path = (source as? [String: Any])?["Path"] as? String else { return true }
                    return namesOwnDatabase(path)
                }
                continue
            }
            if let text = value as? String, namesHorosDataDirectory(text) { continue }
            kept[key] = value
        }
        return kept
    }

    static func namesHorosDataDirectory(_ text: String) -> Bool {
        let path = text.hasPrefix("file://") ? (URL(string: text)?.path ?? text) : text
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }
        return (path as NSString).pathComponents.contains(DatabaseLocation.horosDataDirectoryName)
    }

    /// Called from `main`, ahead of `NSApplicationMain`.
    @objc public static func importPreviousPreferences() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: identifier)
        if let imported = preferencesToImport(into: identifier,
                                              current: current,
                                              previous: defaults.persistentDomain(forName: previousIdentifier)) {
            defaults.setPersistentDomain(imported, forName: identifier)
            NSLog("Preferences: %ld keys copied from %@, without its database location; that domain is unchanged",
                  imported.count, previousIdentifier)
        }
        // An installation with preferences of its own existed before this
        // version, and may be using a Horos Data directory: it keeps it.
        DatabaseLocation.recordHorosDirectoriesInUse(existingInstallation: !(current?.isEmpty ?? true))
    }
}
