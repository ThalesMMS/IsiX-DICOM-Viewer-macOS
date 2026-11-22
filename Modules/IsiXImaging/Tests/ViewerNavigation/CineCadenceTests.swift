//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import XCTest
@testable import IsiXImaging

final class CineCadenceTests: XCTestCase {
    func testAFrameIntervalIsTheInverseOfTheRate() {
        XCTAssertEqual(CineCadence.frameInterval(rate: 20), 0.05, accuracy: 1e-12)
        XCTAssertEqual(CineCadence.frameInterval(rate: 0), 1.0 / 30, accuracy: 1e-12)
    }

    func testTheToleranceStaysSmallNextToAFrame() {
        XCTAssertEqual(CineCadence.tolerance(interval: 1), 0.002, accuracy: 1e-12)
        XCTAssertEqual(CineCadence.tolerance(interval: 0.01), 0.001, accuracy: 1e-12)
    }

    func testALateTimerDoesNotSlowThePlayer() {
        // At 10/s, firing 3 ms late: the frame counts as due on time.
        XCTAssertEqual(CineCadence.frameTime(now: 100.103, lastFrame: 100, rate: 10), 100.1, accuracy: 1e-9)
    }

    func testATimerThatLostAWholeFrameDoesNotRushThePlayer() {
        XCTAssertEqual(CineCadence.frameTime(now: 100.5, lastFrame: 100, rate: 10), 100.4, accuracy: 1e-9)
    }

    func testAnEarlyTickKeepsItsOwnTime() {
        XCTAssertEqual(CineCadence.frameTime(now: 100.05, lastFrame: 100, rate: 10), 100.05, accuracy: 1e-9)
    }

    func testTheDelayFollowsTheCurrentRateAndIsNeverNegative() {
        XCTAssertEqual(CineCadence.delay(now: 100.01, lastFrame: 100, rate: 10), 0.09, accuracy: 1e-9)
        XCTAssertEqual(CineCadence.delay(now: 100.01, lastFrame: 100, rate: 50), 0.01, accuracy: 1e-9)
        XCTAssertEqual(CineCadence.delay(now: 101, lastFrame: 100, rate: 10), 0)
    }

    func testAPlayerFollowsTheLoadAndIsNeverStoppedByIt() {
        // Nothing loading, or the next image there: the player goes on.
        XCTAssertFalse(CineCadence.waitsForLoad(loading: false, nextImageLoaded: false, now: 10, lastFrame: 9.99))
        XCTAssertFalse(CineCadence.waitsForLoad(loading: true, nextImageLoaded: true, now: 10, lastFrame: 9.99))
        // The load has not reached the next image: a moment for it.
        XCTAssertTrue(CineCadence.waitsForLoad(loading: true, nextImageLoaded: false, now: 10, lastFrame: 9.5))
        // The moment has passed: the image is shown, and loaded as it is shown.
        XCTAssertFalse(CineCadence.waitsForLoad(loading: true, nextImageLoaded: false, now: 10, lastFrame: 10 - CineCadence.loadPatience))
        XCTAssertFalse(CineCadence.waitsForLoad(loading: true, nextImageLoaded: false, now: 100, lastFrame: 10))
    }

    func testAPlayerAheadOfTheLoadWaitsForNoImageUntilItFindsOneLoaded() {
        // The moment has passed for an image the load has not reached: the player shows it and is ahead of the load.
        XCTAssertTrue(CineCadence.isAheadOfLoad(loading: true, nextImageLoaded: false))
        // The images that follow get no moment of their own, however soon after the last frame.
        XCTAssertFalse(CineCadence.waitsForLoad(loading: true, nextImageLoaded: false, aheadOfLoad: true, now: 10, lastFrame: 9.99))
        // An image found loaded, or a load that ended, puts the player behind the load again: the next image it has
        // not reached gets its moment.
        XCTAssertFalse(CineCadence.isAheadOfLoad(loading: true, nextImageLoaded: true))
        XCTAssertFalse(CineCadence.isAheadOfLoad(loading: false, nextImageLoaded: false))
        XCTAssertTrue(CineCadence.waitsForLoad(loading: true, nextImageLoaded: false, aheadOfLoad: false, now: 10, lastFrame: 9.99))
    }

    func testATickThatWaitedLooksAgainSoonAndOneThatShowedAFrameSleepsUntilTheNext() {
        XCTAssertEqual(CineCadence.delayAfterTick(now: 100.01, lastFrame: 100, rate: 10, waited: false), 0.09, accuracy: 1e-9)
        // The frame of a tick that waited is overdue: the timer is not woken at once, over and over, for the whole wait.
        XCTAssertEqual(CineCadence.delay(now: 100.5, lastFrame: 100, rate: 10), 0)
        XCTAssertEqual(CineCadence.delayAfterTick(now: 100.5, lastFrame: 100, rate: 10, waited: true), CineCadence.loadPoll)
        XCTAssertGreaterThan(CineCadence.loadPoll, 0)
        XCTAssertLessThan(CineCadence.loadPoll, CineCadence.loadPatience / 10)
    }

    /// The ticks of a repeating timer with a tolerance that is woken from its own callback, as a player's is.
    private final class Ticks: @unchecked Sendable {
        var count = 0
    }

    @MainActor func testATimerWokenFromItsCallbackGoesOnInEveryModeOfItsRunLoop() {
        // The second mode stands for the one a control tracks the mouse in.
        let modes: [RunLoop.Mode] = [.default, RunLoop.Mode("IsiXImagingTests.CineCadence.tracking")]
        let ticks = Ticks()
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            ticks.count += 1
            CineCadence.wake(timer, afterCallbackIn: modes, delay: 0.02)
        }
        timer.tolerance = CineCadence.tolerance(interval: 0.02)
        for mode in modes { RunLoop.current.add(timer, forMode: mode) }
        defer { timer.invalidate() }

        func ticksWhileRunning(_ mode: RunLoop.Mode, for seconds: TimeInterval) -> Int {
            let before = ticks.count, end = Date(timeIntervalSinceNow: seconds)
            while Date() < end { RunLoop.current.run(mode: mode, before: end) }
            return ticks.count - before
        }

        // 0.4 s at fifty a second is twenty ticks; a loaded machine may lose most of them, a stopped timer gives none.
        XCTAssertGreaterThanOrEqual(ticksWhileRunning(modes[0], for: 0.4), 4, "in the default mode")
        XCTAssertGreaterThanOrEqual(ticksWhileRunning(modes[1], for: 0.4), 4, "in the other mode, where nothing else wakes the run loop")
        // Back from the mode it last fired in: woken inside its callback, the timer never fired here again.
        XCTAssertGreaterThanOrEqual(ticksWhileRunning(modes[0], for: 0.4), 4, "back in the default mode")
        // A stay shorter than a frame in the other mode, and back.
        _ = ticksWhileRunning(modes[1], for: 0.03)
        XCTAssertGreaterThanOrEqual(ticksWhileRunning(modes[0], for: 0.4), 4, "back in the default mode after a short stay in the other")
    }
}
