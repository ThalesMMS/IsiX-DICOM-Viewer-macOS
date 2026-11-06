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

/// Runs blocking work on a thread of its own that the Activity window lists,
/// with its name and its Cancel button, and waits for it without blocking
/// the caller. Cancelling the task cancels the thread, which the DICOM
/// queries and retrieves check as they go. `configure` gives the thread what
/// else Activity shows of it (its status, its progress, the ticket of its
/// place in the retrieve queue) before it starts.
enum ActivityThread {
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var thread: Thread?
        private var cancelled = false

        func set(_ thread: Thread) {
            lock.withLock {
                self.thread = thread
                if cancelled { thread.cancel() }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                thread?.cancel()
            }
        }
    }

    static func run<T: Sendable>(name: String, configure: @Sendable (Thread) -> Void = { _ in },
                                 _ body: @escaping @Sendable () -> T) async -> T {
        await waited(name: name, configure: { thread in
            configure(thread)
            thread.supportsCancel = true
        }, start: start, body)
    }

    /// Runs `body` as `run` does, without a Cancel button, for work the user
    /// must not stop once it has begun. Cancelling the task still cancels the thread.
    static func runWithoutCancel<T: Sendable>(name: String, _ body: @escaping @Sendable () -> T) async -> T {
        await waited(name: name, configure: { _ in }, start: start, body)
    }

    /// Runs `body` as `run` does, on a thread Activity does not list, for work
    /// that often finds nothing to do and shows itself only when it has some.
    /// Cancelling the task cancels the thread.
    static func runUnlisted<T: Sendable>(name: String, _ body: @escaping @Sendable () -> T) async -> T {
        await waited(name: name, configure: { _ in }, start: { $0.start() }, body)
    }

    private static func waited<T: Sendable>(name: String, configure: (Thread) -> Void, start: (Thread) -> Void,
                                            _ body: @escaping @Sendable () -> T) async -> T {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    continuation.resume(returning: body())
                }
                thread.name = name
                configure(thread)
                handle.set(thread)
                start(thread)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Starts `thread` through the thread manager, which lists it.
    static func start(_ thread: Thread) {
        if let manager = ThreadsManager.default() {
            manager.addThreadAndStart(thread)
        } else {
            thread.start()
        }
    }

    /// Starts `body` on a thread of its own that nobody waits for, listed in
    /// Activity with a Cancel button, before this returns. `configure` gives
    /// the thread what else Activity shows of it before it starts.
    static func startListed(name: String, configure: (Thread) -> Void = { _ in }, _ body: @escaping @Sendable () -> Void) {
        let thread = made(name: name, body)
        thread.supportsCancel = true
        configure(thread)
        start(thread)
    }

    /// Starts `body` on a thread of its own that nobody waits for and Activity
    /// does not list. Work that often finds nothing to do would only flash a
    /// row there, so `body` calls `listInActivity` once it knows there is work.
    /// `configure` receives the thread before it starts, to show it elsewhere.
    @discardableResult
    static func startUnlisted(name: String, configure: (Thread) -> Void = { _ in },
                              _ body: @escaping @Sendable (_ listInActivity: @Sendable () -> Void) -> Void) -> Thread {
        let thread = made(name: name) {
            body { ThreadsManager.default()?.addThreadAndStart(Thread.current) }
        }
        configure(thread)
        thread.start()
        return thread
    }

    private static func made(name: String, _ body: @escaping @Sendable () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.name = name
        return thread
    }
}
