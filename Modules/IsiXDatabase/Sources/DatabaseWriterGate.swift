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

/// The one import that may write to a database at a time, shared by a main
/// database and its independent databases.
///
/// Each of those has a context of its own, and a context sees only what is
/// saved. Two imports that overlap between reading which studies exist and
/// saving each make the same new study, so the gate covers that whole stretch.
///
/// Replacing the index file is a write too: the rebuild of the SQL file holds
/// the gate from the moment it reads the index until the main database has a
/// context over the new file, and names the coordinator of the former one
/// retired. A writer that waited comes in with the context it had, over the
/// file that went to the backups; seeing it retired, it takes a context over
/// the new index instead of writing where nobody will read.
///
/// `@unchecked Sendable`: the table of retired coordinators is read and changed
/// only under `retiredLock`.
public final class DatabaseWriterGate: @unchecked Sendable {
    // Recursive: indexing a file can archive a study's annotations, which
    // imports the archive on the same thread.
    private let lock = NSRecursiveLock()
    private let retiredLock = NSLock()
    /// Weak: a retired coordinator goes once its last context does.
    private let retired = NSHashTable<AnyObject>.weakObjects()

    public init() {}

    /// Says that `coordinator` is over an index a rebuild took out of its
    /// place: what a context over it writes is no longer read.
    public func retire(_ coordinator: AnyObject) {
        retiredLock.withLock { retired.add(coordinator) }
    }

    /// Whether `coordinator` is over an index that is no longer in its place.
    public func isRetired(_ coordinator: AnyObject?) -> Bool {
        guard let coordinator else { return false }
        return retiredLock.withLock { retired.contains(coordinator) }
    }

    /// Runs `write` once no other thread is inside the gate; the thread already
    /// inside may enter again. `write` must not wait for a thread that can be
    /// waiting here, the main thread above all.
    ///
    /// An Objective-C exception passes over `defer` and would leave the gate
    /// held for the rest of the session: a `write` that can raise catches the
    /// exception and raises it again after this returns.
    public func withExclusiveWrite<Result>(_ write: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try write()
    }
}
