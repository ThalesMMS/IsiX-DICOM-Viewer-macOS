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

/// The imports of the INCOMING folder, as quitting needs to know them.
///
/// The process's exit destroys DCMTK's data dictionary and loggers, and an
/// import still reading a file then reads freed memory. Quitting used to stop
/// only the threads ThreadsManager lists, and an import is listed late: once it
/// has a file and sees another, and only after the main thread has run the
/// message that adds it, which it no longer does while quitting. An import
/// started just before Quit was never cancelled and was still reading when
/// `exit()` ran. Every import passes through here instead: quitting refuses new
/// ones, cancels those inside, and waits for them to leave.
///
/// An import holds an admission: what admits it names the thread to cancel,
/// and leaving takes the admission back from wherever the import ended, with no
/// need of being on that thread.
@objc(HorosIncomingImportGate)
public final class IncomingImportGate: NSObject, @unchecked Sendable {
    @objc public static let shared = IncomingImportGate()

    /// One import inside the gate. An import can start from inside another,
    /// and each has an admission of its own.
    public struct Admission: Hashable, Sendable {
        fileprivate let number: UInt64
    }

    private let condition = NSCondition()
    /// What is inside, with the thread that checks for cancellation between files.
    private var admitted: [Admission: Thread] = [:]
    private var nextNumber: UInt64 = 0
    private var stopped = false

    /// Admits an import, or refuses it once quitting has begun. Quitting
    /// cancels `thread`, which the import checks between files. An admitted
    /// import gives the admission back with `leave(_:)` when it is over.
    public func admit(cancelling thread: Thread) -> Admission? {
        condition.lock()
        defer { condition.unlock() }
        if stopped { return nil }
        nextNumber += 1
        let admission = Admission(number: nextNumber)
        admitted[admission] = thread
        return admission
    }

    /// Admits a part of an import that is inside and waits for it, on a thread
    /// of its own: never refused, since what the import has already done would
    /// be lost, and quitting waits for it too. Quitting cancels `thread` only if
    /// it comes after the part: one that starts once quitting has begun runs to
    /// its end, within the time quitting gives the imports.
    public func admitPart(cancelling thread: Thread) -> Admission {
        condition.lock()
        defer { condition.unlock() }
        nextNumber += 1
        let admission = Admission(number: nextNumber)
        admitted[admission] = thread
        return admission
    }

    public func leave(_ admission: Admission) {
        condition.lock()
        defer { condition.unlock() }
        admitted[admission] = nil
        condition.broadcast()
    }

    @objc public var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    /// Refuses every import from now on and cancels those under way.
    @objc public func stop() {
        condition.lock()
        defer { condition.unlock() }
        stopped = true
        for thread in admitted.values {
            thread.cancel()
        }
    }

    /// Waits for the imports under way to leave. Returns whether they all had
    /// by the deadline.
    @objc(waitUntilIdleBefore:)
    public func waitUntilIdle(before deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !admitted.isEmpty {
            if !condition.wait(until: deadline) {
                return admitted.isEmpty
            }
        }
        return true
    }
}
