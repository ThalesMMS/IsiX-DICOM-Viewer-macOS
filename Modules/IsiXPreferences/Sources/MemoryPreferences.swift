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

/// Preferences held in memory, with no domain on disk: what a test reads and
/// writes, and what a tool that has not registered the application's defaults
/// reads from a dictionary. Each value is kept as a preferences domain keeps
/// it, an immutable property list (a single-precision number stays one), the
/// user's own over the registered ones.
public final class MemoryPreferences: PreferenceStore {
    /// An immutable property list, read back from its serialized form: no one
    /// can change it, so it is shared between threads as it is.
    private struct Stored: @unchecked Sendable {
        let object: Any

        init?(_ value: Any) {
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
            self.object = object
        }

        static func dictionary(_ entry: [String: Any]) -> [String: Stored] {
            entry.compactMapValues { Stored($0) }
        }
    }

    private struct State: Sendable {
        var values: [String: Stored]
        var registered: [String: Stored]
        var writes: [String] = []
    }

    private let state: Mutex<State>
    private let arguments: Set<String>

    /// `values` are the user's own, `registered` what lies beneath them, and
    /// `arguments` the keys that count as given at the launch. An object a
    /// property list cannot hold is left out.
    public init(_ values: [String: Any] = [:], registered: [String: Any] = [:], arguments: Set<String> = []) {
        state = Mutex(State(values: Stored.dictionary(values), registered: Stored.dictionary(registered)))
        self.arguments = arguments
    }

    public func object(forKey key: String) -> Any? {
        let stored = state.withLock { state in state.values[key] ?? state.registered[key] }
        return stored?.object
    }

    public func set(_ value: Any?, forKey key: String) {
        let stored = value.flatMap { Stored($0) }
        state.withLock { state in
            state.values[key] = stored
            state.writes.append(key)
        }
    }

    public func isGivenAsLaunchArgument(_ key: String) -> Bool {
        arguments.contains(key)
    }

    /// Adds `defaults` beneath the user's own values, as `register(defaults:)` does.
    public func register(defaults: [String: Any]) {
        let values = Stored.dictionary(defaults)
        state.withLock { state in state.registered.merge(values) { $1 } }
    }

    /// The keys written, in order, one entry per write.
    public var writes: [String] {
        state.withLock { $0.writes }
    }
}
