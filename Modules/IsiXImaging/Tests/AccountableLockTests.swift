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
@testable import IsiXImaging

/// What a lock reported, from any thread.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func take(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// What a thread of a test was handed back, in order.
private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var holders: [AccountableLock.Holder?] = []

    func note(_ holder: AccountableLock.Holder?) { lock.withLock { holders.append(holder) } }
    var all: [AccountableLock.Holder?] { lock.withLock { holders } }
}

@Suite struct AccountableLockTests {

    private func made(patience: TimeInterval = 0.1) -> (AccountableLock, Reports) {
        let reports = Reports()
        return (AccountableLock(of: "the test", patience: patience) { reports.take($0) }, reports)
    }

    @Test func aThreadTakesItAgainAndLeavesItAsOftenAsItTookIt() {
        let (lock, reports) = made()
        lock.lock()
        lock.lock()
        #expect(lock.holder?.depth == 2)
        lock.unlock()
        #expect(lock.holder?.depth == 1)
        lock.unlock()
        #expect(lock.holder == nil)
        #expect(reports.all.isEmpty)
    }

    @Test func itExcludesAnotherThreadUntilItIsLeft() {
        let (lock, _) = made(patience: 5)
        let entered = DispatchSemaphore(value: 0)
        lock.lock()
        let other = Thread {
            lock.lock()
            entered.signal()
            lock.unlock()
        }
        other.start()
        #expect(entered.wait(timeout: .now() + 0.2) == .timedOut)
        lock.unlock()
        #expect(entered.wait(timeout: .now() + 5) == .success)
    }

    @Test func aThreadThatWaitsReportsTheHolderAndWhereItTookTheLock() {
        let (lock, reports) = made(patience: 0.1)
        let held = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let holder = Thread {
            lock.lock()
            held.signal()
            leave.wait()
            lock.unlock()
        }
        holder.name = "the holder of the test"
        holder.start()
        held.wait()
        let waiter = Thread {
            lock.lock()
            lock.unlock()
            done.signal()
        }
        waiter.start()
        // Two patiences at least: it reports at each and goes on waiting.
        Thread.sleep(forTimeInterval: 0.35)
        leave.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
        let lines = reports.all
        #expect(lines.count >= 2)
        #expect(lines.allSatisfy { $0.contains("the lock of the test") && $0.contains("held by the holder of the test") && $0.contains("taken at:") })
        #expect(lines.first?.split(separator: "\n").count ?? 0 > 1)
    }

    @Test func whatAThreadLeftHeldIsHandedBackAndTheOthersGoOn() {
        let (lock, reports) = made(patience: 5)
        let left = DispatchSemaphore(value: 0), healed = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let found = Found()
        let leaker = Thread {
            // Two regions entered and never left, as when something unwinds through them.
            lock.lock()
            lock.lock()
            left.signal()
            Thread.sleep(forTimeInterval: 0.2)
            found.note(lock.releaseIfLeftHeld())
            found.note(lock.releaseIfLeftHeld())
            // A region that was open when the lock was handed back leaves it: there is nothing to leave.
            lock.unlock()
            healed.signal()
        }
        leaker.name = "the leaker of the test"
        leaker.start()
        left.wait()
        let other = Thread {
            lock.lock()
            entered.signal()
            lock.unlock()
        }
        other.start()
        #expect(entered.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(healed.wait(timeout: .now() + 5) == .success)
        #expect(entered.wait(timeout: .now() + 5) == .success)
        #expect(found.all.count == 2)
        #expect(found.all.first??.depth == 2)
        #expect(found.all.first??.thread == "the leaker of the test")
        #expect(found.all.last! == nil)
        #expect(reports.all.count == 1)
        #expect(reports.all.first?.contains("was left held by the leaker of the test (2 deep") == true)
        // The lock works as before for whoever takes it next.
        lock.lock()
        #expect(lock.holder?.depth == 1)
        lock.unlock()
        #expect(lock.holder == nil)
    }

    @Test func aThreadThatHoldsNothingHandsNothingBack() {
        let (lock, reports) = made()
        #expect(lock.releaseIfLeftHeld() == nil)
        let held = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        Thread {
            lock.lock()
            held.signal()
            leave.wait()
            lock.unlock()
        }.start()
        held.wait()
        // Another thread's hold is its own: nothing is taken from it.
        #expect(lock.releaseIfLeftHeld() == nil)
        #expect(lock.holder?.depth == 1)
        leave.signal()
        #expect(reports.all.isEmpty)
    }
}
