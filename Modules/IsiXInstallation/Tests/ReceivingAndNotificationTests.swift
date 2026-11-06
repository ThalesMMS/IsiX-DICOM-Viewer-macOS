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
import Testing
@testable import IsiXInstallation

/// The receiving counter of the Dock arrow, the grouping of a burst of
/// notifications and the timing of the automatic update checks, without a
/// Dock, a Notification Center or a network.
struct ReceivingAndNotificationTests {

    /// A thread that runs one body: the receptions run on threads of their
    /// own, since the main thread does not count its retains.
    private final class BodyThread: Thread, @unchecked Sendable {
        private let body: @Sendable () -> Void
        private let done = DispatchSemaphore(value: 0)
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
        override func main() { body(); done.signal() }
        func wait() { done.wait() }
    }

    /// Runs `body` on a thread of its own and waits for it.
    private func onThread(_ body: @escaping @Sendable () -> Void) {
        let thread = BodyThread(body)
        thread.start()
        thread.wait()
    }

    @Test func aThreadCountsItsReceptionsAndOtherThreadsTheirOwn() {
        let counter = ReceivingThreadCounter()
        let first = Thread(), second = Thread()
        #expect(counter.receivingThreads == 0)
        #expect(counter.begin(on: first) == 1)
        #expect(counter.begin(on: first) == 1)
        #expect(counter.begin(on: second) == 2)
        #expect(counter.receptions(on: first) == 2)
        #expect(counter.end(on: first) == 2)
        #expect(counter.end(on: second) == 1)
        #expect(counter.end(on: first) == 0)
        // An end without a start changes nothing.
        #expect(counter.end(on: first) == 0)
        #expect(counter.receptions(on: first) == 0)
        #expect(counter.receivingThreads == 0)
    }

    @Test func aThreadIsKeptOnceWhileItReceivesAndLetGoAfter() {
        let counter = ReceivingThreadCounter()
        weak var kept: Thread?
        autoreleasepool {
            let thread = Thread()
            kept = thread
            counter.begin(on: thread)
            counter.begin(on: thread)
        }
        // Nothing else holds the thread: the counter does, so its identity
        // cannot go to another thread.
        #expect(kept != nil)
        if let thread = kept {
            counter.end(on: thread)
        }
        #expect(kept != nil, "released before its last reception ended")
        if let thread = kept {
            counter.end(on: thread)
        }
        #expect(kept == nil, "the thread is still held after its last reception")
        #expect(counter.receivingThreads == 0)
    }

    @Test func theRetainCountOfAReceivingThreadRisesOnceAndComesBack() {
        let counter = ReceivingThreadCounter()
        onThread {
            let thread = Thread.current
            var count: CFIndex = 0
            func read() { count = CFGetRetainCount(thread) }
            counter.begin(); counter.end()
            read()
            let base = count
            for _ in 0..<50 { counter.begin(); counter.end() }
            read()
            precondition(count == base, "\(count - base) retains left after 50 receptions")
            counter.begin(); counter.begin(); counter.begin()
            read()
            precondition(count == base + 1, "\(count - base) retains for three receptions")
            counter.end(); counter.end(); counter.end()
            read()
            precondition(count == base, "\(count - base) retains after the last reception")
        }
    }

    @Test func receptionsFromManyThreadsAddUp() {
        let counter = ReceivingThreadCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            onThread {
                counter.begin()
                counter.begin()
                counter.end()
                counter.end()
            }
        }
        #expect(counter.receivingThreads == 0)
    }

    @Test func aBurstOfOneKindIsDeliveredOnceAndThenWithTheLatestText() {
        var policy = NotificationBurstPolicy(interval: 10, quietSound: 60)
        let kind = NotificationBurstPolicy.kind(of: "newfiles")
        #expect(policy.post(.init(title: "Incoming Files", body: "1"), kind: kind, at: 100) == .deliverNow(sound: true))
        #expect(policy.post(.init(title: "Incoming Files", body: "2"), kind: kind, at: 101) == .deliverLater(after: 9))
        for i in 3...50 {
            #expect(policy.post(.init(title: "Incoming Files", body: "\(i)"), kind: kind, at: 102) == .replacedPending)
        }
        // Another kind is not held by this one's burst.
        #expect(policy.post(.init(title: "Import Paused", body: "full"), kind: "importpaused", at: 102) == .deliverNow(sound: true))
        #expect(policy.flush(kind: kind, at: 110) == .init(title: "Incoming Files", body: "50"))
        #expect(policy.flush(kind: kind, at: 111) == nil, "the burst is delivered twice")
        // The interval counts from the delayed delivery.
        #expect(policy.post(.init(title: "Incoming Files", body: "51"), kind: kind, at: 115) == .deliverLater(after: 5))
        #expect(policy.flush(kind: kind, at: 120) == .init(title: "Incoming Files", body: "51"))
        // After the interval, delivered at once, silent within the quiet time.
        #expect(policy.post(.init(title: "Incoming Files", body: "52"), kind: kind, at: 131) == .deliverNow(sound: false))
        // A sound again after a minute without a delivery.
        #expect(policy.post(.init(title: "Incoming Files", body: "53"), kind: kind, at: 191) == .deliverNow(sound: true))
    }

    @Test func aNotificationWithoutANameHasTheApplicationsKind() {
        #expect(NotificationBurstPolicy.kind(of: nil) == "horos")
        #expect(NotificationBurstPolicy.kind(of: "") == "horos")
        #expect(NotificationBurstPolicy.kind(of: "reportConversion") == "reportConversion")
        let policy = NotificationBurstPolicy()
        #expect(policy.interval == 10 && policy.quietSound == 60)
    }

    @Test func theAutomaticChecksRunHourlyAndWaitAMinuteWhileOff() {
        typealias S = UpdateCheckSchedule
        #expect(S.atLaunch(crashed: false, automaticChecks: true, listenerErrorsHidden: false) == .automatic)
        #expect(S.atLaunch(crashed: false, automaticChecks: false, listenerErrorsHidden: true) == .automatic)
        #expect(S.atLaunch(crashed: true, automaticChecks: false, listenerErrorsHidden: false) == .afterCrash)
        #expect(S.atLaunch(crashed: true, automaticChecks: false, listenerErrorsHidden: true) == .none)
        #expect(S.atLaunch(crashed: true, automaticChecks: true, listenerErrorsHidden: false) == .none)
        #expect(S.afterCheck(automaticChecks: true) == .check(after: 3600))
        #expect(S.afterCheck(automaticChecks: false) == .wait(after: 60))
        #expect(S.afterWait(automaticChecks: true) == .check(after: 0))
        #expect(S.afterWait(automaticChecks: false) == .wait(after: 60))
    }
}
