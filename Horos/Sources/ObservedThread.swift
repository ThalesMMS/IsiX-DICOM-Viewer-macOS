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

/// A thread that other threads look at to know whether it was cancelled, or
/// cancel: the thread of a retrieve its helper threads follow, or the load
/// thread of a viewer the analysis of its frames stops with.
///
/// `@unchecked Sendable`: Thread is not Sendable, but `isCancelled`,
/// `isFinished` and `cancel()` are answered and done from any thread, and
/// nothing else of the thread is reachable through this.
struct ObservedThread: @unchecked Sendable {
    private let thread: Thread

    init(_ thread: Thread) {
        self.thread = thread
    }

    /// The thread that calls this.
    static var current: ObservedThread { ObservedThread(Thread.current) }

    var isCancelled: Bool { thread.isCancelled }

    var isFinished: Bool { thread.isFinished }

    func cancel() { thread.cancel() }
}
