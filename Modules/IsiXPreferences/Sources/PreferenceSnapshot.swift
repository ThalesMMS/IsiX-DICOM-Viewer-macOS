//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Synchronization

/// What a reader keeps of the preferences, read from any thread: the image loading, the drawing and the ROIs
/// ask for it at every image or frame, where reading the store each time would cost too much. The owner
/// replaces it when the preferences change; until then every thread reads the same value, whole.
public final class PreferenceSnapshot<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    public init(_ value: Value) {
        state = Mutex(value)
    }

    /// The value kept now.
    public var value: Value {
        state.withLock { $0 }
    }

    /// What `body` takes from the value kept now, without copying the whole value: a reader at every
    /// frame asks for one setting.
    public func read<Result: Sendable>(_ body: (borrowing Value) -> Result) -> Result {
        state.withLock { value in body(value) }
    }

    /// Keeps `value` instead, as when the preferences were read again.
    public func replace(_ value: Value) {
        state.withLock { $0 = value }
    }

    /// Changes the value kept in place, under the lock: a viewer that changes a setting itself.
    @discardableResult
    public func update<Result: Sendable>(_ change: (inout Value) -> Result) -> Result {
        state.withLock { value in change(&value) }
    }
}
