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
}
