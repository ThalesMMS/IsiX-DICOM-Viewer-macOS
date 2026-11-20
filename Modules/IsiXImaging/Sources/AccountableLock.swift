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

/// A recursive lock that knows who holds it.
///
/// Every load of an image passes through the lock of the parsed files, on
/// the thread that decodes a series and on the main thread that shows an
/// image. Left held, it stops every load behind it for good, and a plain
/// lock says nothing of who left it. This one records, each time a thread
/// takes it from outside, that thread and where it was; a thread that waits
/// longer than its patience reports the holder and goes on waiting, again at
/// each multiple of the patience; and a thread that reaches a point where it
/// can have no region open hands back what it left held, and says where it
/// took it.
public final class AccountableLock: NSObject, NSLocking, @unchecked Sendable {

    /// Who holds the lock: the thread, how deep, since when (system uptime)
    /// and the return addresses of the frames that took it from outside.
    public struct Holder: Sendable {
        public let thread: String
        public let isMainThread: Bool
        public let depth: Int
        public let since: TimeInterval
        public let frames: [UInt]

        /// The frames by their symbols, one line each.
        public var symbols: [String] {
            frames.map { address in
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname else {
                    return String(format: "0x%lx", address)
                }
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let offset = address - UInt(bitPattern: info.dli_saddr)
                return "\(image) \(String(cString: name)) + \(offset)"
            }
        }
    }

    private struct Record {
        var owner: UInt = 0
        var depth = 0
        var thread = ""
        var isMainThread = false
        var since: TimeInterval = 0
        var frames: [UInt] = []
    }

    /// How long a thread waits before it reports the holder, in seconds.
    public static let defaultPatience: TimeInterval = 5

    private let recursive = NSRecursiveLock()
    private let record = Mutex(Record())
    private let subject: String
    private let patience: TimeInterval
    private let report: @Sendable (String) -> Void

    /// `subject` names what the lock protects in what it reports, a thread
    /// reports after each `patience` seconds of waiting, and `report` takes
    /// each line: the log.
    public init(of subject: String, patience: TimeInterval = AccountableLock.defaultPatience, report: @escaping @Sendable (String) -> Void) {
        self.subject = subject
        self.patience = patience
        self.report = report
        super.init()
    }

    private static var currentThread: UInt { UInt(bitPattern: pthread_self()) }

    /// Who holds the lock now, or nil.
    public var holder: Holder? {
        record.withLock {
            $0.depth > 0 ? Holder(thread: $0.thread, isMainThread: $0.isMainThread, depth: $0.depth, since: $0.since, frames: $0.frames) : nil
        }
    }

    public func lock() {
        if !recursive.try() {
            var waited: TimeInterval = 0
            while !recursive.lock(before: Date(timeIntervalSinceNow: patience)) {
                waited += patience
                report(waitingReport(waited))
            }
        }
        let me = Self.currentThread
        record.withLock {
            // The first of this thread's holds: who it is and where it was.
            if $0.depth == 0 || $0.owner != me {
                $0.owner = me
                $0.depth = 0
                $0.thread = Thread.isMainThread ? "the main thread" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(Thread.current)")
                $0.isMainThread = Thread.isMainThread
                $0.since = ProcessInfo.processInfo.systemUptime
                $0.frames = Self.callerFrames()
            }
            $0.depth += 1
        }
    }

    public func unlock() {
        let me = Self.currentThread
        // A hold the thread already handed back with releaseIfLeftHeld() has nothing to leave.
        let held = record.withLock { record -> Bool in
            guard record.depth > 0, record.owner == me else { return false }
            record.depth -= 1
            if record.depth == 0 { record.frames = [] }
            return true
        }
        if held { recursive.unlock() }
    }

    /// Hands back the lock when the calling thread holds it, and reports
    /// where it was taken. For a point where the thread can have no region of
    /// the lock open, the idle run loop of the main thread above all: what it
    /// still holds there was left by something that went through a region
    /// without leaving it, and every other thread would wait for it for good.
    /// Answers who held it, or nil when the thread held nothing.
    @discardableResult
    public func releaseIfLeftHeld() -> Holder? {
        let me = Self.currentThread
        let left = record.withLock { record -> Holder? in
            guard record.depth > 0, record.owner == me else { return nil }
            let holder = Holder(thread: record.thread, isMainThread: record.isMainThread, depth: record.depth, since: record.since,
                                frames: record.frames)
            record.depth = 0
            record.frames = []
            return holder
        }
        guard let left else { return nil }
        for _ in 0..<left.depth { recursive.unlock() }
        let held = ProcessInfo.processInfo.systemUptime - left.since
        report(String(format: "****** the lock of %@ was left held by %@ (%d deep, for %.1f s) and is handed back; it was taken at:\n%@",
                      subject as NSString, left.thread as NSString, Int32(left.depth), held, left.symbols.joined(separator: "\n") as NSString))
        return left
    }

    private func waitingReport(_ waited: TimeInterval) -> String {
        guard let holder else {
            return String(format: "****** waited %.0f s for the lock of %@, which nobody is recorded as holding", waited, subject as NSString)
        }
        let held = ProcessInfo.processInfo.systemUptime - holder.since
        return String(format: "****** waited %.0f s for the lock of %@, held by %@ (%d deep, for %.1f s) and taken at:\n%@",
                      waited, subject as NSString, holder.thread as NSString, Int32(holder.depth), held,
                      holder.symbols.joined(separator: "\n") as NSString)
    }

    /// The return addresses of the frames above the lock's own.
    private static func callerFrames() -> [UInt] {
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 24) { buffer in
            let count = Int(backtrace(buffer.baseAddress, 24))
            return (min(2, count)..<count).map { UInt(bitPattern: buffer[$0]) }
        }
    }
}
