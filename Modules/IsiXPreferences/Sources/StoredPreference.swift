//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// What is stored under a key as the person's own, kept across work during
/// which other code may store a value of its own there: a study opened by a
/// hanging protocol has its windows tiled, and the Viewers pane, when it is
/// open, stores the full-screen size of a viewer's window as soon as it sees
/// tiling on.
///
/// The work once read the key before it started and wrote the value read
/// afterwards, always. Reading searches the launch's values and the
/// registered ones as well: a value given at the launch was written over the
/// person's, and a value that was only the registered one became a stored
/// one. This remembers what is stored, which may be nothing, and `putBack()`
/// writes only when that changed: the value that was stored, or the removal
/// of one that was not there.
///
/// It keeps nothing from being stored meanwhile: the readers of the key find
/// what the other code stored for as long as the work lasts, as they did, and
/// an application that ends before `putBack()` leaves it stored.
public struct StoredPreference {
    private let key: String
    private let defaults: UserDefaults
    /// The stored preferences `defaults` writes: nil for the application's.
    private let storedDomain: String?
    /// What was stored under the key when this was made; nil for nothing.
    private let found: NSObject?

    /// `key` as `defaults` has it stored now, in `storedDomain`: a suite's
    /// name, nil for the preferences of the application.
    public init<Value>(_ key: PreferenceKey<Value>, in defaults: UserDefaults = .standard, storedDomain: String? = nil) {
        self.key = key.name
        self.defaults = defaults
        self.storedDomain = storedDomain
        found = Self.stored(key.name, in: storedDomain)
    }

    /// Stores again what was stored when this was made, if something else is
    /// stored now; writes nothing otherwise.
    public func putBack() {
        let now = Self.stored(key, in: storedDomain)
        if let now, let found, now.isEqual(found) { return }
        if now == nil && found == nil { return }
        defaults.set(found, forKey: key)
    }

    /// What is stored for `key` as the person's, whatever the launch gave or
    /// the application registered: the value the process already knows, asked
    /// of no file.
    private static func stored(_ key: String, in domain: String?) -> NSObject? {
        let domain = domain.map { $0 as CFString } ?? kCFPreferencesCurrentApplication
        return CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSObject
    }
}
