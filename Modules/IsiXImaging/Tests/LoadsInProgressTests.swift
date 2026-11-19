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

/// The application's exception guard, played here: a body "raises" by leaving
/// its exception with the guard and returning at once, and the guard answers
/// it, as the application's answers what it caught.
private final class StandInGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: NSException?

    func raise(_ reason: String) {
        lock.withLock { pending = NSException(name: .internalInconsistencyException, reason: reason) }
    }

    var caught: LoadsInProgress.ExceptionGuard {
        { body in
            body()
            return self.lock.withLock {
                defer { self.pending = nil }
                return self.pending
            }
        }
    }
}

/// What several threads write of a test.
private final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func note(_ value: Int) { lock.withLock { values.append(value) } }
    var all: [Int] { lock.withLock { values } }
}

@Suite struct LoadsInProgressTests {
    private let standIn = StandInGuard()

    private func counter(waitingAtMost limit: TimeInterval = 5) -> LoadsInProgress {
        LoadsInProgress(waitingAtMost: limit, guardedBy: standIn.caught)
    }

    /// A load as the application writes one: a value out of the counted body,
    /// and what the body raised.
    private func run<T>(in loads: LoadsInProgress, _ body: () -> T) -> (value: T?, raised: NSException?) {
        var value: T?
        let raised = loads.counted { value = body() }
        return (value, raised)
    }

    private func seconds(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return -start.timeIntervalSinceNow
    }

    @Test func aLoadIsCountedWhileItRunsAndCountedOutOnItsReturn() {
        let loads = counter()
        #expect(loads.inProgress == 0)
        var during = -1
        let load = run(in: loads) { () -> Bool in
            during = loads.inProgress
            return true
        }
        #expect(during == 1)
        #expect(load.value == true)
        #expect(load.raised == nil)
        #expect(loads.inProgress == 0)
    }

    @Test func aLoadThatReturnsEarlyIsCountedOut() {
        let loads = counter()
        for parsed in [false, true] {
            var reached = false
            let load = run(in: loads) { () -> Bool in
                guard parsed else { return false }
                reached = true
                return true
            }
            #expect(load.value == parsed)
            #expect(reached == parsed)
            #expect(load.raised == nil)
            #expect(loads.inProgress == 0)
        }
    }

    @Test func aLoadThatRaisesIsCountedOutOnceAndItsExceptionIsAnswered() {
        let loads = counter()
        for round in 1...2 {
            var during = -1
            let load = run(in: loads) { () -> Bool in
                during = loads.inProgress
                standIn.raise("the entry of the cache raised")
                return true
            }
            #expect(during == 1, "round \(round)")
            #expect(load.raised?.reason == "the entry of the cache raised")
            #expect(load.raised?.name == .internalInconsistencyException)
            #expect(loads.inProgress == 0, "round \(round)")
        }
        // The count still works after them.
        #expect(run(in: loads) { loads.inProgress }.value == 1)
        #expect(loads.inProgress == 0)
    }

    @Test func aLoadInsideALoadIsCountedToo() {
        let loads = counter()
        var counts: [Int] = []
        var inner: NSException?
        _ = loads.counted {
            counts.append(loads.inProgress)
            _ = loads.counted { counts.append(loads.inProgress) }
            counts.append(loads.inProgress)
            // The inner one raises: the outer one stays counted.
            inner = loads.counted { standIn.raise("inner") }
            counts.append(loads.inProgress)
        }
        #expect(inner?.reason == "inner")
        #expect(counts == [1, 2, 1, 1])
        #expect(loads.inProgress == 0)
    }

    @Test func loadsOfSeveralThreadsAreEachCountedOutOnce() {
        let loads = counter()
        let queue = DispatchQueue(label: "loads", attributes: .concurrent)
        let group = DispatchGroup()
        let seen = Record()
        for index in 0..<64 {
            queue.async(group: group) {
                for _ in 0..<50 {
                    _ = loads.counted {
                        if index.isMultiple(of: 2) { return }
                        seen.note(loads.inProgress)
                    }
                }
            }
        }
        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(loads.inProgress == 0)
        #expect(seen.all.count == 32 * 50)
        #expect(seen.all.allSatisfy { (1...64).contains($0) })
    }

    @Test func thePurgeDoesNotWaitWithNoLoadInProgress() {
        let loads = counter(waitingAtMost: 5)
        var ran = 0
        var wait: LoadsInProgress.Wait?
        let waited = seconds { wait = loads.whenNoneInProgress { ran += 1 } }
        #expect(wait == .ran(raised: nil))
        #expect(ran == 1)
        #expect(waited < 1)
        #expect(loads.inProgress == 0)
    }

    @Test func thePurgeGivesUpAtItsLimitWhileALoadIsInProgress() {
        let loads = counter(waitingAtMost: 0.3)
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "load").async {
            _ = loads.counted {
                started.signal()
                finish.wait()
            }
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 10) == .success)

        var ran = 0
        var wait: LoadsInProgress.Wait?
        let waited = seconds { wait = loads.whenNoneInProgress { ran += 1 } }
        #expect(wait == .gaveUp(inProgress: 1))
        #expect(ran == 0)
        #expect(waited >= 0.3)
        #expect(waited < 3)
        // Giving up takes nothing: the load is still the only one counted,
        // and ends as any other.
        #expect(loads.inProgress == 1)
        finish.signal()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(loads.inProgress == 0)

        // With the load over, the next purge runs at once.
        let again = seconds { wait = loads.whenNoneInProgress { ran += 1 } }
        #expect(wait == .ran(raised: nil))
        #expect(ran == 1)
        #expect(again < 0.3)
    }

    @Test func thePurgeRunsOnceALoadEndsWithinItsLimit() {
        let loads = counter(waitingAtMost: 10)
        let started = DispatchSemaphore(value: 0)
        DispatchQueue(label: "load").async {
            _ = loads.counted {
                started.signal()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        #expect(started.wait(timeout: .now() + 10) == .success)
        var countDuring = -1
        var wait: LoadsInProgress.Wait?
        let waited = seconds { wait = loads.whenNoneInProgress { countDuring = loads.inProgress } }
        #expect(wait == .ran(raised: nil))
        #expect(countDuring == 0)
        #expect(waited < 5)
    }

    @Test func noLoadStartsWhileThePurgeRuns() {
        let loads = counter()
        let entered = DispatchSemaphore(value: 0)
        var startedDuring: DispatchTimeoutResult?
        let wait = loads.whenNoneInProgress {
            DispatchQueue(label: "load").async {
                _ = loads.counted { entered.signal() }
            }
            startedDuring = entered.wait(timeout: .now() + 0.2)
        }
        #expect(wait == .ran(raised: nil))
        #expect(startedDuring == .timedOut)
        // The load that waited runs once the purge is over.
        #expect(entered.wait(timeout: .now() + 10) == .success)
    }

    @Test func aPurgeThatRaisesLeavesTheCountAndAnswersItsException() {
        let loads = counter(waitingAtMost: 0.3)
        let wait = loads.whenNoneInProgress { standIn.raise("the purge raised") }
        guard case .ran(let raised) = wait else {
            Issue.record("the purge did not run")
            return
        }
        #expect(raised?.reason == "the purge raised")
        // Left taken, the count would stop the next load and the next purge.
        #expect(run(in: loads) { loads.inProgress }.value == 1)
        #expect(loads.whenNoneInProgress {} == .ran(raised: nil))
        #expect(loads.inProgress == 0)
    }

    @Test func thePurgeWaitsTenSecondsUnlessToldOtherwise() {
        #expect(LoadsInProgress.purgeLimit == 10)
    }

    /// A probe written in Objective-C reads the count from the class as a
    /// build compiled it.
    @Test func theCountIsReadFromObjectiveC() {
        let loads = counter()
        #expect(NSStringFromClass(LoadsInProgress.self) == "IsiXLoadsInProgress")
        #expect(loads.responds(to: NSSelectorFromString("inProgress")))
    }
}
