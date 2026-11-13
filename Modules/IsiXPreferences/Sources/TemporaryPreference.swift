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

/// A preference some work changes for as long as it lasts, where every reader
/// of the key finds it: a print turns smart cropping off and enlarges the
/// annotations' font while it captures its pages, and the views that draw them
/// read both from the application's preferences.
///
/// The value goes into the argument domain of the process, which UserDefaults
/// searches before the user's own values and never saves. Nothing is written
/// to the preferences, whatever becomes of the work: a value the user chose
/// stays as chosen, a value that was only the registered one is not stored as
/// the user's when it is put back, and an application that ends in the middle
/// leaves no trace of it. `restore()` leaves the argument domain as it was,
/// with the value the launch gave for the key if it gave one.
///
/// The argument domain is one for the whole process, whatever the instance
/// of UserDefaults. A change made this way posts
/// UserDefaults.didChangeNotification. The key-value observers of the key, a
/// binding of a preference pane among them, are not told by the change itself:
/// UserDefaults tells them when a key, any key, is next read, on the thread
/// that reads it. Left at that, an observer of the main thread would be told
/// on whatever thread read a preference first. `set` and `restore` read the
/// key before they return, so the observers are told by the call, on its
/// thread, when the value read did change. Only a thread that reads a
/// preference in the instant between the exchange and that read would still
/// tell them first.
///
/// Call it on the main thread: that is where the observers expect to be
/// told, and nothing keeps two threads from exchanging the argument domain
/// at once, the later one undoing the earlier.
public struct TemporaryPreference<Value: PreferenceValue> {
    private let key: String
    private let defaults: UserDefaults
    /// What the launch gave for the key; nil when it gave nothing.
    private let launchValue: Any?

    /// `key` in `defaults`, as it stands now: `restore()` comes back to this.
    public init(_ key: PreferenceKey<Value>, in defaults: UserDefaults = .standard) {
        self.key = key.name
        self.defaults = defaults
        launchValue = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key.name]
    }

    /// Makes every reader of the key in this process read `value`.
    public func set(_ value: Value) {
        write(value.preferenceObject)
    }

    /// Takes the value back: the key reads as it did before the first `set`.
    public func restore() {
        write(launchValue)
    }

    private func write(_ value: Any?) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[key] = value
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        // The read that tells the key-value observers, here and now.
        _ = defaults.object(forKey: key)
    }
}
