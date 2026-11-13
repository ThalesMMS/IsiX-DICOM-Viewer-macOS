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

/// Where the preferences are kept: one property-list value per key, read and
/// written as it is stored. The application's store is UserDefaults; a test
/// gives `MemoryPreferences`.
///
/// Nothing is cached on the way: every typed read asks the store and every
/// write goes to it under the key's own name, so key-value observing,
/// NSUserDefaultsController bindings and UserDefaults.didChangeNotification
/// see the same keys the typed reads and writes use.
public protocol PreferenceStore: Sendable {
    /// The property list stored under `key` in any domain the store searches
    /// (for UserDefaults: the launch arguments, the user's own, the registered
    /// defaults); nil when none.
    func object(forKey key: String) -> Any?
    /// Stores a property list under `key`; nil removes the user's own value.
    func set(_ value: Any?, forKey key: String)
    /// Whether `key` was given as an argument of the launch (`-SERVERS ...`),
    /// which hides the stored value for that launch only.
    func isGivenAsLaunchArgument(_ key: String) -> Bool
}

extension UserDefaults: PreferenceStore {
    /// The argument domain holds what the launch was given, for that launch only.
    public func isGivenAsLaunchArgument(_ key: String) -> Bool {
        volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil
    }
}

extension PreferenceStore where Self == UserDefaults {
    /// The application's preferences, where a store is asked for: a caller that
    /// passed `.standard` to a reader of UserDefaults still does.
    public static var standard: UserDefaults { UserDefaults.standard }
}

extension PreferenceStore {
    /// The value of `key`, converted as the UserDefaults accessor of its type
    /// converts what is stored: absent is false, 0 or nil. While some work
    /// gives the key a value of its own (TemporaryPreference), that value.
    public subscript<Value>(key: PreferenceKey<Value>) -> Value {
        Value.reading(object(for: key))
    }

    /// The property list the readers of `key` are given: the value of work in
    /// course (TemporaryPreference) when the store is a UserDefaults, else
    /// what the store holds under the key's name; nil when neither.
    ///
    /// `object(forKey:)` of UserDefaults itself answers what is stored,
    /// whatever work is in course: that is what a binding of a nib and a
    /// key-value observer read.
    public func object<Value>(for key: PreferenceKey<Value>) -> Any? {
        // The table first: it answers nil at once while no work gives a key a value.
        if let given = TemporaryPreferenceValues.process.value(given: key.name), self is UserDefaults { return given }
        return object(forKey: key.name)
    }

    /// Stores `value` under `key`, in the form the preference panes and their
    /// bindings write; a nil optional removes the user's own value.
    public func set<Value>(_ value: Value, for key: PreferenceKey<Value>) {
        set(value.preferenceObject, forKey: key.name)
    }

    /// Removes the user's own value of `key`: the registered one shows again.
    public func remove<Value>(_ key: PreferenceKey<Value>) {
        set(nil, forKey: key.name)
    }

    /// Whether `key` was given as an argument of the launch.
    public func isGivenAsLaunchArgument<Value>(_ key: PreferenceKey<Value>) -> Bool {
        isGivenAsLaunchArgument(key.name)
    }
}
