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
private final class CleaningDouble: DatabaseCleaning {
    private struct State {
        var idle = true
        var passes = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    let cleaningIdentifier: String

    init(_ identifier: String = "db") { cleaningIdentifier = identifier }

    var passes: Int { state.withLock { $0.passes } }
    var waiting: Int { state.withLock { $0.waiting.count } }
    func setIdle(_ idle: Bool) { state.withLock { $0.idle = idle } }
    func endPasses() {
        for pass in state.withLock({ state -> [CheckedContinuation<Void, Never>] in
            defer { state.waiting = [] }
            return state.waiting
        }) { pass.resume() }
    }

    func isIdleForCleaning() -> Bool { state.withLock { $0.idle } }
    func runCleanupPass() async {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.passes += 1
                $0.waiting.append(continuation)
            }
        }
    }
    func previewCleanup() async -> CleanupPreview { CleanupPreview(summary: "", rows: [], failed: false) }
    func cleanForFreeSpace() {}
}

/// The timer's clock: `sleep` returns when the test lets a tick through, and
/// throws, ending the timer, when `stop` is called.
private final class TickDouble: Sendable {
    private struct State {
        var durations: [Duration] = []
        var ticks = 0
        var stopped = false
        var waiting: CheckedContinuation<Void, any Error>?
    }
    private struct Stopped: Error {}
    private let state = Mutex(State())

    var durations: [Duration] { state.withLock { $0.durations } }
    var isWaiting: Bool { state.withLock { $0.waiting != nil } }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let (ready, stopped) = state.withLock { state -> (Bool, Bool) in
                state.durations.append(duration)
                if state.stopped { return (false, true) }
                if state.ticks > 0 {
                    state.ticks -= 1
                    return (true, false)
                }
                state.waiting = continuation
                return (false, false)
            }
            if stopped { continuation.resume(throwing: Stopped()) } else if ready { continuation.resume() }
        }
    }

    func tick() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            defer { state.waiting = nil }
            if state.waiting == nil { state.ticks += 1 }
            return state.waiting
        }
        waiting?.resume()
    }

    func stop() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            defer { state.waiting = nil }
            state.stopped = true
            return state.waiting
        }
        waiting?.resume(throwing: Stopped())
    }
}

/// Waits, at most ten seconds, until `condition` holds.
private func arrives(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

@Suite struct CleanupSchedulerTests {

    @Test func thePassesAreFifteenMinutesAndTwoAndAHalfSecondsApart() {
        #expect(CleanupScheduler.passInterval == .seconds(902.5))
    }

    @Test func aPassRunsWithoutTheCallerWaitingForIt() async {
        let scheduler = CleanupScheduler()
        let database = CleaningDouble()
        await scheduler.initiate(database)
        #expect(await arrives { database.passes == 1 })
        database.endPasses()
    }

    @Test func oneDatabaseHasOnePassAtATime() async {
        let scheduler = CleanupScheduler()
        let database = CleaningDouble()
        await scheduler.initiate(database)
        #expect(await arrives { database.waiting == 1 })
        await scheduler.initiate(database)
        await scheduler.initiate(CleaningDouble("db")) // an independent database of the same one
        #expect(database.passes == 1)

        database.endPasses()
        #expect(await arrives {
            await scheduler.initiate(database)
            return database.passes == 2
        })
        database.endPasses()
    }

    @Test func twoDatabasesCleanAtTheSameTime() async {
        let scheduler = CleanupScheduler()
        let first = CleaningDouble("first"), second = CleaningDouble("second")
        await scheduler.initiate(first)
        await scheduler.initiate(second)
        #expect(await arrives { first.waiting == 1 && second.waiting == 1 })
        first.endPasses()
        second.endPasses()
    }

    @Test func aDatabaseSomethingElseIsCleaningGetsNoPass() async {
        let scheduler = CleanupScheduler()
        let database = CleaningDouble()
        database.setIdle(false)
        await scheduler.initiate(database)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(database.passes == 0)

        database.setIdle(true)
        await scheduler.initiate(database)
        #expect(await arrives { database.passes == 1 })
        database.endPasses()
    }

    @Test func aPassLeavesTheActorFree() async {
        let scheduler = CleanupScheduler()
        let database = CleaningDouble()
        await scheduler.initiate(database)
        #expect(await arrives { database.waiting == 1 })
        // Answers while the pass is still under way.
        _ = await scheduler.claimLimitWarning()
        #expect(database.waiting == 1)
        database.endPasses()
    }

    @Test func theLimitWarningIsClaimedOnce() async {
        let scheduler = CleanupScheduler()
        #expect(await scheduler.claimLimitWarning())
        #expect(await !scheduler.claimLimitWarning())
        #expect(await !scheduler.claimLimitWarning())
    }

    @Test func theTimerRunsAPassEachInterval() async {
        let clock = TickDouble()
        let passes = Mutex(0)
        let scheduler = CleanupScheduler(interval: .seconds(7), sleep: { try await clock.sleep($0) })
        await scheduler.startTimer { passes.withLock { $0 += 1 } }
        #expect(await arrives { clock.isWaiting })
        #expect(passes.withLock { $0 } == 0)

        clock.tick()
        #expect(await arrives { passes.withLock { $0 } == 1 })
        clock.tick()
        #expect(await arrives { passes.withLock { $0 } == 2 })
        #expect(await arrives { clock.isWaiting })
        clock.stop()
        #expect(clock.durations.allSatisfy { $0 == .seconds(7) })
    }

    @Test func onlyTheFirstDatabaseMakesTheTimer() async {
        let clock = TickDouble()
        let first = Mutex(0), second = Mutex(0)
        let scheduler = CleanupScheduler(sleep: { try await clock.sleep($0) })
        await scheduler.startTimer { first.withLock { $0 += 1 } }
        await scheduler.startTimer { second.withLock { $0 += 1 } }
        #expect(await arrives { clock.isWaiting })
        clock.tick()
        #expect(await arrives { first.withLock { $0 } == 1 })
        #expect(await arrives { clock.isWaiting })
        clock.stop()
        #expect(second.withLock { $0 } == 0)
        #expect(clock.durations.count <= 2)
    }

    @Test func theTimerEndsWhenItsClockThrows() async {
        let clock = TickDouble()
        let passes = Mutex(0)
        let scheduler = CleanupScheduler(sleep: { try await clock.sleep($0) })
        clock.stop()
        await scheduler.startTimer { passes.withLock { $0 += 1 } }
        #expect(await arrives { clock.durations.count == 1 })
        #expect(passes.withLock { $0 } == 0)
    }
}
