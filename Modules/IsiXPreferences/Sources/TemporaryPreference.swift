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

/// A preference some work changes for as long as it lasts, where the readers
/// of the catalog find it: a print turns smart cropping off and enlarges the
/// annotations' font while it captures its pages, and the views that draw them
/// read both through the catalog's keys.
///
/// The value is kept by the process (TemporaryPreferenceValues), in no domain
/// of UserDefaults. Nothing is written to the preferences, whatever becomes of
/// the work: a value the user chose stays as chosen, a value that was only the
/// registered one is not stored as the user's when it is taken back, and an
/// application that ends in the middle leaves no trace of it. `restore()`
/// leaves the key reading what it read before: what the launch gave, what is
/// stored, or what is registered.
///
/// Who reads it: every typed read of a UserDefaults (`store[key]`,
/// `store.object(for:)`), whatever the instance and the thread. Who does not:
/// a reader that asks UserDefaults by the key's name. A binding of a
/// preference pane or of a menu item, and a key-value observer, keep showing
/// what is stored and are told nothing, on any thread; that is the point, see
/// TemporaryPreferenceValues. Code of the application that reads one of
/// these keys reads it through the catalog.
///
/// A change of what the key reads posts UserDefaults.didChangeNotification,
/// as a stored change does, on the thread that made it and before the call
/// returns: what follows the preferences by that notification reads the
/// value again. A value given that is the value already read posts nothing.
///
/// Call it on the main thread: that is where the notification is expected,
/// and nothing keeps two threads from giving one key a value at once, the
/// later one undoing the earlier.
public struct TemporaryPreference<Value: PreferenceValue> {
    private let key: PreferenceKey<Value>
    private let defaults: UserDefaults

    /// `key` in `defaults`, as it stands now: `restore()` comes back to this.
    public init(_ key: PreferenceKey<Value>, in defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    /// Makes every typed reader of the key in this process read `value`.
    public func set(_ value: Value) {
        write(value.preferenceObject)
    }

    /// Takes the value back: the key reads as it did before the first `set`.
    public func restore() {
        write(nil)
    }

    private func write(_ value: Any?) {
        let before = key.read(from: defaults)
        TemporaryPreferenceValues.process.give(value, to: key.name)
        if key.read(from: defaults) != before {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
    }
}
