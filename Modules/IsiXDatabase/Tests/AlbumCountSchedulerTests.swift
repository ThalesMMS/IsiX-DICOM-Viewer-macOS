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
import Testing
@testable import IsiXDatabase

/// A counter that counts when the test lets it, and answers what it was told.
private final class HeldCounter: AlbumStudyCounting {
    private struct State {
        var started = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        var answer: [Int?]? = [5]
    }
    private let state = Mutex(State())

    var started: Int { state.withLock { $0.started } }

    func answer(_ counts: [Int?]?) {
        state.withLock { $0.answer = counts }
    }

    func countStudies(progress: @escaping @Sendable ([Int?]) -> Void) async -> [Int?]? {
        state.withLock { $0.started += 1 }
        progress([1])
        await withCheckedContinuation { continuation in
            state.withLock { $0.waiting.append(continuation) }
        }
        return state.withLock { $0.answer }
    }

    /// Lets the counts that wait end.
    func release() {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func waitUntilStarted(_ count: Int) async {
        while started < count { await Task.yield() }
    }
}

/// A sleep that lasts until the test ends it, counting the sleeps asked.
private final class HeldSleep: Sendable {
    private struct State {
        var asked: [Duration] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    var asked: [Duration] { state.withLock { $0.asked } }

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.asked.append(duration)
                $0.waiting.append(continuation)
            }
        }
        try Task.checkCancellation()
    }

    func wake() {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func waitUntilAsked(_ count: Int) async {
        while asked.count < count { await Task.yield() }
    }
}

private final class Received: Sendable {
    private let state = Mutex<(delivered: [[Int?]?], progress: [[Int?]], again: Int)>(([], [], 0))
    var delivered: [[Int?]?] { state.withLock { $0.delivered } }
    var progress: [[Int?]] { state.withLock { $0.progress } }
    var again: Int { state.withLock { $0.again } }
    func deliver(_ counts: [Int?]?) { state.withLock { $0.delivered.append(counts) } }
    func progressed(_ counts: [Int?]) { state.withLock { $0.progress.append(counts) } }
    func askedAgain() { state.withLock { $0.again += 1 } }
}

@Suite struct AlbumCountSchedulerTests {

    private func request(_ scheduler: AlbumCountScheduler<HeldCounter>, _ counter: HeldCounter, _ received: Received) async -> AlbumCountRequest {
        await scheduler.request(counter, progress: { received.progressed($0) },
                                deliver: { received.deliver($0) }, again: { received.askedAgain() })
    }

    @Test func aRequestWithNoCountRunningStartsOne() async {
        let counter = HeldCounter(), sleep = HeldSleep(), received = Received()
        let scheduler = AlbumCountScheduler<HeldCounter>(sleep: { try await sleep.sleep($0) })

        #expect(await request(scheduler, counter, received) == .started)
        await counter.waitUntilStarted(1)
        #expect(await scheduler.isCounting)
        counter.release()
        await scheduler.waitForCount()

        #expect(received.progress == [[1]])
        #expect(received.delivered.count == 1)
        #expect(received.delivered.first == [5])
        #expect(!(await scheduler.isCounting))
        #expect(!(await scheduler.hasPendingRetry))
        #expect(received.again == 0)
    }

    @Test func requestsWhileCountingJoinInOneRetryAfterTheDelay() async {
        let counter = HeldCounter(), sleep = HeldSleep(), received = Received()
        let scheduler = AlbumCountScheduler<HeldCounter>(sleep: { try await sleep.sleep($0) })

        #expect(await request(scheduler, counter, received) == .started)
        await counter.waitUntilStarted(1)
        #expect(await request(scheduler, counter, received) == .deferred)
        #expect(await request(scheduler, counter, received) == .deferred)
        #expect(await request(scheduler, counter, received) == .deferred)
        await sleep.waitUntilAsked(3)
        #expect(sleep.asked.allSatisfy { $0 == .seconds(20) })
        // Only one count ran: the deferred requests did not start their own.
        #expect(counter.started == 1)

        sleep.wake()
        while received.again < 1 { await Task.yield() }
        // Each later request replaced the one before: one retry is asked.
        for _ in 0..<50 { await Task.yield() }
        #expect(received.again == 1)
        #expect(!(await scheduler.hasPendingRetry))

        counter.release()
        await scheduler.waitForCount()
    }

    @Test func aCountInterruptedByAnotherDatabaseAsksAgainLater() async {
        let counter = HeldCounter(), sleep = HeldSleep(), received = Received()
        let scheduler = AlbumCountScheduler<HeldCounter>(sleep: { try await sleep.sleep($0) })
        counter.answer(nil)

        #expect(await request(scheduler, counter, received) == .started)
        await counter.waitUntilStarted(1)
        counter.release()
        await scheduler.waitForCount()
        #expect(received.delivered.count == 1)
        #expect(received.delivered.first == .some(nil))
        await sleep.waitUntilAsked(1)
        #expect(await scheduler.hasPendingRetry)

        sleep.wake()
        while received.again < 1 { await Task.yield() }
        #expect(received.again == 1)
    }

    @Test func cancellingDropsTheRetryThatWaits() async {
        let counter = HeldCounter(), sleep = HeldSleep(), received = Received()
        let scheduler = AlbumCountScheduler<HeldCounter>(sleep: { try await sleep.sleep($0) })

        #expect(await request(scheduler, counter, received) == .started)
        await counter.waitUntilStarted(1)
        #expect(await request(scheduler, counter, received) == .deferred)
        await sleep.waitUntilAsked(1)
        await scheduler.cancel()
        sleep.wake()
        counter.release()
        await scheduler.waitForCount()
        for _ in 0..<50 { await Task.yield() }
        #expect(received.again == 0)
        #expect(!(await scheduler.hasPendingRetry))
    }
}
