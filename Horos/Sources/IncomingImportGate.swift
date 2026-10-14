//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The threads importing the INCOMING folder, as quitting needs to know them.
///
/// The process's exit destroys DCMTK's data dictionary and loggers, and an
/// import still reading a file then reads freed memory. Quitting used to stop
/// only the threads ThreadsManager lists, and an import is listed late: once it
/// has a file and sees another, and only after the main thread has run the
/// message that adds it, which it no longer does while quitting. An import
/// started just before Quit was never cancelled and was still reading when
/// `exit()` ran. Every import passes through here instead: quitting refuses new
/// ones, cancels those inside, and waits for them to leave.
@objc(HorosIncomingImportGate)
public final class IncomingImportGate: NSObject, @unchecked Sendable {
    @objc public static let shared = IncomingImportGate()

    private let condition = NSCondition()
    /// One entry per admission: a thread can import again from inside an import.
    private var importing: [Thread] = []
    private var stopped = false

    /// Admits the calling thread to an import, or refuses it once quitting has
    /// begun. An admitted thread calls `leave()` when its import is over.
    @objc public func enter() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if stopped { return false }
        importing.append(Thread.current)
        return true
    }

    @objc public func leave() {
        condition.lock()
        defer { condition.unlock() }
        if let index = importing.lastIndex(where: { $0 === Thread.current }) {
            importing.remove(at: index)
        }
        condition.broadcast()
    }

    @objc public var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    /// Refuses every import from now on and cancels those under way; the import
    /// checks its thread's cancellation between files.
    @objc public func stop() {
        condition.lock()
        defer { condition.unlock() }
        stopped = true
        for thread in importing {
            thread.cancel()
        }
    }

    /// Waits for the imports under way to leave. Returns whether they all had
    /// by the deadline.
    @objc(waitUntilIdleBefore:)
    public func waitUntilIdle(before deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !importing.isEmpty {
            if !condition.wait(until: deadline) {
                return importing.isEmpty
            }
        }
        return true
    }
}
