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

/// What some work of the application asks of a preference while it lasts,
/// whatever the user chose: an MPR that lays its planes out anew keeps their
/// zooms together, a retrieval that needs its images at once has them imported
/// as they arrive.
///
/// The work once stored its own value under the key and put back afterwards
/// the value it had read. A value that was only the registered one was then
/// stored as the user's, a value given at the launch was written over the
/// user's, and an application that ended in the middle left the work's value
/// as the user's choice. Here the preference is left alone: the work holds
/// this while it lasts, and the code that decides by the key asks
/// `value(in:)`, which answers the work's value while anything holds it and
/// the preference otherwise. Nothing is written anywhere, so no observer of
/// the key and no binding of a preference pane is told of anything, and a
/// reader that does not ask here reads the user's own value throughout.
///
/// It is the state of the process: any thread may hold it, and the pieces of
/// work that hold it at once are counted, so that the first to end does not
/// end it for the others.
public final class ForcedPreference<Value: PreferenceValue>: Sendable {
    /// The preference the work overrides.
    public let key: PreferenceKey<Value>
    /// What its readers are answered while the work lasts.
    public let forced: Value
    /// How many pieces of work hold it.
    private let holders = Mutex(0)

    public init(_ key: PreferenceKey<Value>, to forced: Value) {
        self.key = key
        self.forced = forced
    }

    /// Whether any work holds it now.
    public var isHeld: Bool {
        holders.withLock { $0 > 0 }
    }

    /// A piece of work starts: `end()` ends it.
    public func begin() {
        holders.withLock { $0 += 1 }
    }

    /// A piece of work that began ends. One that never began ends nothing.
    public func end() {
        holders.withLock { $0 = max(0, $0 - 1) }
    }

    /// The work's value while any holds it, the value of `store` otherwise.
    public func value(in store: any PreferenceStore) -> Value {
        isHeld ? forced : store[key]
    }

    /// Runs `body` as a piece of work, ended when it returns or throws.
    public func during<Result>(_ body: () throws -> Result) rethrows -> Result {
        begin()
        defer { end() }
        return try body()
    }
}
