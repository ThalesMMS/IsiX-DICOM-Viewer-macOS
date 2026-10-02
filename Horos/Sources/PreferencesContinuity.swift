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
/// starts with none: it would ask where the database goes and create an empty
/// one beside the database that is already there. The previous domain is copied
/// once, before anything reads a preference, and is left as it was.
@objc(HorosPreferencesContinuity)
public final class PreferencesContinuity: NSObject {

    /// The identifier of the released application.
    @objc public static let releaseIdentifier = "thalesmms.isis.workstation"
    /// The identifier releases carried before the application was renamed.
    @objc public static let previousIdentifier = "org.horosproject.horos"

    /// What to write into the domain of `identifier`, or `nil` to leave it.
    ///
    /// Only the released application imports: a development or test bundle has
    /// an identifier of its own and must not start from the user's settings,
    /// which name the user's database. And only into an empty domain, so a
    /// preference changed after the import is never overwritten.
    static func preferencesToImport(into identifier: String?,
                                    current: [String: Any]?,
                                    previous: [String: Any]?) -> [String: Any]? {
        guard identifier == releaseIdentifier else { return nil }
        guard current?.isEmpty ?? true else { return nil }
        guard let previous, !previous.isEmpty else { return nil }
        return previous
    }

    /// Called from `main`, ahead of `NSApplicationMain`.
    @objc public static func importPreviousPreferences() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        guard let imported = preferencesToImport(into: identifier,
                                                 current: defaults.persistentDomain(forName: identifier),
                                                 previous: defaults.persistentDomain(forName: previousIdentifier))
        else { return }
        defaults.setPersistentDomain(imported, forName: identifier)
        NSLog("Preferences: %ld keys copied from %@; that domain is unchanged", imported.count, previousIdentifier)
    }
}
