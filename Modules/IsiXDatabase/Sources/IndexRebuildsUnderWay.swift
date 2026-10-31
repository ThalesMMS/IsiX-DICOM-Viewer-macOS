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

/// The rebuilds of a database index under way, as quitting needs to know them.
///
/// A rebuild runs on a thread that neither the thread manager nor the gate of
/// the incoming imports lists, and it cannot be cancelled: the exit of the
/// process stopped it where it was, with DCMTK destroyed under the files it
/// read, and a complete rebuild left a new index half filled, with the former
/// one only in the backups. Quitting waits while one is under way.
public final class IndexRebuildsUnderWay: Sendable {
    public static let shared = IndexRebuildsUnderWay()

    private let count = Mutex(0)

    public init() {}

    /// A rebuild begins; it calls `end()` once it has ended, however it ended.
    public func begin() {
        count.withLock { $0 += 1 }
    }

    public func end() {
        count.withLock { $0 = max(0, $0 - 1) }
    }

    public var isEmpty: Bool {
        count.withLock { $0 == 0 }
    }
}
