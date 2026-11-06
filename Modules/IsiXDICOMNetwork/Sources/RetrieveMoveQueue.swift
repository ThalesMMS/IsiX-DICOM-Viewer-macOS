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

/// The retrieves a Query window has under way: each one runs through `run`,
/// and the window, and its automatic retrieve, ask how many run before
/// starting another.
///
/// The transfer itself blocks: the app runs it on a thread of its own that
/// Activity lists and cancels, and `run` awaits it without blocking. Cancelling
/// the task that awaits `run` cancels that transfer.
public actor RetrieveMoveQueue {
    private var running = 0

    public init() {}

    /// How many retrieves run now.
    public var runningCount: Int { running }

    /// Runs `retrieve`, counted among the retrieves under way until it returns.
    @discardableResult
    public func run<Result: Sendable>(_ retrieve: @Sendable () async -> Result) async -> Result {
        running += 1
        defer { running -= 1 }
        return await retrieve()
    }
}

/// The C-MOVE and C-GET operations under way in the process, by the node that
/// runs each: a node already moving is not moved again until its operation
/// ends, whichever thread asks.
///
/// The threads that run the operations block in them, so they ask
/// synchronously: the nodes are behind a mutex, by identity, and an operation
/// claims its node for as long as it runs.
public final class RetrieveOperationsUnderWay: Sendable {
    private let nodes = Mutex<Set<ObjectIdentifier>>([])

    public init() {}

    /// Whether `node` is running an operation now.
    public func contains(_ node: AnyObject) -> Bool {
        nodes.withLock { $0.contains(ObjectIdentifier(node)) }
    }

    /// Runs `operation` with `node` counted as moving, unless it already is;
    /// nil then, without running it.
    public func run<Result>(for node: AnyObject, _ operation: () throws -> Result) rethrows -> Result? {
        let id = ObjectIdentifier(node)
        guard nodes.withLock({ $0.insert(id).inserted }) else { return nil }
        defer { _ = nodes.withLock { $0.remove(id) } }
        return try operation()
    }
}
