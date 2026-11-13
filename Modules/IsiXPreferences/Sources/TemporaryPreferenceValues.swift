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
import Synchronization

/// The values work gives preferences for as long as it lasts
/// (TemporaryPreference), kept by the process itself and not by UserDefaults.
///
/// They were once put in the argument domain of UserDefaults, so that every
/// reader of UserDefaults found them. UserDefaults does not tell the key-value
/// observers of a key when a domain is exchanged: it tells them when a key,
/// any key, is next read, on the thread that reads it, and it posts
/// UserDefaults.didChangeNotification before the thread that made the exchange
/// can read anything. A thread retrieving a study that read a preference in
/// that interval told a control bound to the key, and AppKit set its state
/// away from the main thread. No reading order closes that interval, since
/// any thread of the process, the system's among them, may read first.
///
/// Kept here, a value is in no domain of UserDefaults: there is nothing for
/// UserDefaults to tell anyone, on any thread. The typed readers of a
/// UserDefaults (`store[key]`) ask here first.
///
/// One for the process, as the argument domain was: whatever instance of
/// UserDefaults reads the key. Any thread.
final class TemporaryPreferenceValues: @unchecked Sendable {
    static let process = TemporaryPreferenceValues()

    /// Which lengths the keys that have a value are of: bit n is set while
    /// some key of n UTF-8 bytes (modulo 64) has one. A read of a key of
    /// another length, and every read while no key has a value, which is
    /// nearly always, answers from this alone: no lock, no table. The typed
    /// read of a preference runs wherever the application draws and loads, so
    /// what it adds to a read that finds nothing is one load and one test.
    private let lengths = Atomic<UInt64>(0)
    private let lock = NSLock()
    /// Property lists, never changed once given. Guarded by `lock`.
    private var values: [String: Any] = [:]

    private static func bit(of key: String) -> UInt64 {
        1 << UInt64(key.utf8.count & 63)
    }

    /// The value work gave `key`, nil when no work gives it one.
    func value(given key: String) -> Any? {
        let held = lengths.load(ordering: .acquiring)
        guard held != 0, held & Self.bit(of: key) != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    /// Gives `key` a value for the process; nil takes it back.
    func give(_ value: Any?, to key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        lengths.store(values.keys.reduce(0) { $0 | Self.bit(of: $1) }, ordering: .releasing)
    }
}
