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
import IsiXContracts
import Synchronization
import Testing
@testable import IsiXDatabase

/// A database whose passes wait until the test lets them end.
private final class PassDouble: IngestPassRunning {
    private struct State {
        var ready = true
        var passes = 0
        var cancelled = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    let ingestIdentifier: String

    init(_ identifier: String = "db") { ingestIdentifier = identifier }

    var passes: Int { state.withLock { $0.passes } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    var waiting: Int { state.withLock { $0.waiting.count } }
    func setReady(_ ready: Bool) { state.withLock { $0.ready = ready } }
    func endPasses() {
        for pass in state.withLock({ state -> [CheckedContinuation<Void, Never>] in
            defer { state.waiting = [] }
            return state.waiting
        }) { pass.resume() }
    }

    func isReadyForPass() -> Bool { state.withLock { $0.ready } }
    func runPass() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock {
                    $0.passes += 1
                    $0.waiting.append(continuation)
                }
            }
        } onCancel: {
            state.withLock { $0.cancelled += 1 }
        }
    }
}

/// Waits until `condition` holds, or two seconds pass.
private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A clock the test advances one tick at a time.
private final class TickDouble: Sendable {
    private struct State {
        var waiting: [CheckedContinuation<Void, any Error>] = []
        var sleeps: [Duration] = []
    }
    private let state = Mutex(State())

    var sleeps: [Duration] { state.withLock { $0.sleeps } }
    var waiting: Int { state.withLock { $0.waiting.count } }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock {
                $0.sleeps.append(duration)
                $0.waiting.append(continuation)
            }
        }
    }

    func tick() {
        for sleeper in state.withLock({ state -> [CheckedContinuation<Void, any Error>] in
            defer { state.waiting = [] }
            return state.waiting
        }) { sleeper.resume() }
    }

    func end() {
        for sleeper in state.withLock({ state -> [CheckedContinuation<Void, any Error>] in
            defer { state.waiting = [] }
            return state.waiting
        }) { sleeper.resume(throwing: CancellationError()) }
    }
}

private final class Counter: Sendable {
    private let value = Atomic<Int>(0)
    var count: Int { value.load(ordering: .acquiring) }
    func add() { value.add(1, ordering: .releasing) }
}

@Suite struct IngestSchedulerTests {
    @Test func passesRunOneAtATimeAndRequestsCoalesceIntoOne() async {
        let scheduler = IngestScheduler()
        let database = PassDouble()
        await scheduler.request(database)
        #expect(await eventually { database.waiting == 1 })

        for _ in 0..<20 { await scheduler.request(database) }
        #expect(database.passes == 1)

        database.endPasses()
        #expect(await eventually { database.passes == 2 })
        database.endPasses()
        #expect(await eventually { !scheduler.isPassRunning("db") })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(database.passes == 2)
    }

    @Test func eachDatabaseHasItsOwnPass() async {
        let scheduler = IngestScheduler()
        let first = PassDouble("first"), second = PassDouble("second")
        await scheduler.request(first)
        await scheduler.request(second)
        #expect(await eventually { first.waiting == 1 && second.waiting == 1 })
        #expect(scheduler.isPassRunning("first"))
        first.endPasses()
        #expect(await eventually { !scheduler.isPassRunning("first") })
        #expect(scheduler.isPassRunning("second"))
        second.endPasses()
    }

    @Test func aDatabaseThatIsNotReadyStartsNothingAndIsNotRemembered() async {
        let scheduler = IngestScheduler()
        let database = PassDouble()
        database.setReady(false)
        await scheduler.request(database)
        database.setReady(true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(database.passes == 0)
        #expect(!scheduler.isPassRunning("db"))
        await scheduler.request(database)
        #expect(await eventually { database.passes == 1 })
        database.endPasses()
    }

    @Test func aRequestLeftForAfterThePassAsksAgainWhetherItIsReady() async {
        let scheduler = IngestScheduler()
        let database = PassDouble()
        await scheduler.request(database)
        #expect(await eventually { database.waiting == 1 })
        await scheduler.request(database)
        database.setReady(false)
        database.endPasses()
        #expect(await eventually { !scheduler.isPassRunning("db") })
        #expect(database.passes == 1)
    }

    // A retrieve asks for a pass each time it looks at the index, and takes the
    // import for idle only when this is false: counted at the request, it
    // would be true at every look, and the retrieve would wait for ever.
    @Test func thePassIsReportedWhileItRunsAndNotWhileItIsOnlyAskedFor() async {
        let scheduler = IngestScheduler()
        let database = PassDouble()
        #expect(!scheduler.isPassRunning("db"))
        database.setReady(false)
        await scheduler.request(database)
        #expect(!scheduler.isPassRunning("db"))

        database.setReady(true)
        await scheduler.request(database)
        #expect(scheduler.isPassRunning("db"))
        #expect(await eventually { database.waiting == 1 })
        #expect(scheduler.isPassRunning("db"))
        database.endPasses()
        #expect(await eventually { !scheduler.isPassRunning("db") })
    }

    @Test func stoppingCancelsThePassesAndNoneStartsAfter() async {
        let scheduler = IngestScheduler()
        let database = PassDouble()
        await scheduler.request(database)
        #expect(await eventually { database.waiting == 1 })
        await scheduler.request(database)

        await scheduler.stop()
        #expect(await eventually { database.cancelled == 1 })
        database.endPasses()
        #expect(await eventually { !scheduler.isPassRunning("db") })
        await scheduler.request(database)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(database.passes == 1)
    }

    @Test func theTimerFollowsTheInterval() async {
        let clock = TickDouble()
        let scheduler = IngestScheduler(sleep: { try await clock.sleep($0) })
        let ticks = Counter()

        await scheduler.syncTimer(seconds: 15) { ticks.add() }
        #expect(await eventually { clock.waiting == 1 })
        #expect(clock.sleeps == [.seconds(15)])

        // The same interval keeps the timer that runs, and the time it has left.
        await scheduler.syncTimer(seconds: 15) { ticks.add() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(clock.sleeps == [.seconds(15)])

        clock.tick()
        #expect(await eventually { ticks.count == 1 && clock.waiting == 1 })

        // A new interval replaces it: the old loop's sleep ends without a tick.
        await scheduler.syncTimer(seconds: 2) { ticks.add() }
        #expect(await eventually { clock.waiting == 2 })
        #expect(clock.sleeps.last == .seconds(2))
        clock.end()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(ticks.count == 1)
    }

    @Test func aZeroIntervalStopsTheTimer() async {
        let clock = TickDouble()
        let scheduler = IngestScheduler(sleep: { try await clock.sleep($0) })
        let ticks = Counter()
        await scheduler.syncTimer(seconds: 0) { ticks.add() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(clock.waiting == 0)

        await scheduler.syncTimer(seconds: 1) { ticks.add() }
        #expect(await eventually { clock.waiting == 1 })
        await scheduler.syncTimer(seconds: 0) { ticks.add() }
        clock.tick()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(ticks.count == 0)
    }

    @Test func stoppingEndsTheTimer() async {
        let clock = TickDouble()
        let scheduler = IngestScheduler(sleep: { try await clock.sleep($0) })
        let ticks = Counter()
        await scheduler.syncTimer(seconds: 1) { ticks.add() }
        #expect(await eventually { clock.waiting == 1 })
        await scheduler.stop()
        clock.tick()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(ticks.count == 0)

        await scheduler.syncTimer(seconds: 3) { ticks.add() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(clock.waiting == 0)
    }
}
