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
@testable import IsiXDICOMNetwork

/// The one wait for a study whose files are still coming in, which the order
/// to open a study and the `then` of a Retrieve share.
struct StudyArrivalWaitTests {

    /// A clock the pauses of a wait move, so a wait of 30 s takes no time.
    private final class Clock {
        var time: TimeInterval = 100
        var pauses: [TimeInterval] = []
        func pause(_ seconds: TimeInterval) {
            pauses.append(seconds)
            time += seconds
        }
    }

    private struct LookFailed: Error {}

    @Test func theLooksAreHalfASecondApart() {
        #expect(StudyArrivalWait.interval == 0.5)
    }

    @Test func aStudyThatArrivesBeforeTheLimitIsAnswered() throws {
        let clock = Clock()
        var looks = 0
        let found = try StudyArrivalWait.first(within: 30, now: { clock.time }, pause: clock.pause) { () -> String? in
            looks += 1
            return clock.time >= 101.4 ? "1.2.3" : nil
        }
        #expect(found == "1.2.3")
        // Looked at 0, 0.5, 1 and 1.5 s: three pauses of the interval, none after the study came.
        #expect(looks == 4)
        #expect(clock.pauses == [0.5, 0.5, 0.5])
    }

    @Test func aStudyAlreadyHereIsAnsweredWithoutAPause() throws {
        let clock = Clock()
        let found = try StudyArrivalWait.first(within: 30, now: { clock.time }, pause: clock.pause) { "here" }
        #expect(found == "here")
        #expect(clock.pauses.isEmpty)
    }

    @Test func aStudyThatDoesNotArriveEndsTheWaitAtTheLimit() throws {
        let clock = Clock()
        var looks = 0
        let found = try StudyArrivalWait.first(within: 30, now: { clock.time }, pause: clock.pause) { () -> String? in
            looks += 1
            return nil
        }
        #expect(found == nil)
        // 60 pauses fill the 30 s, and a look follows the last of them.
        #expect(clock.pauses.count == 60)
        #expect(looks == 61)
        #expect(clock.time - 100 == 30)
    }

    @Test func aCancelledWaitEndsAtItsNextLook() throws {
        let clock = Clock()
        var looks = 0
        let found = try StudyArrivalWait.first(within: 30, isCancelled: { looks == 3 }, now: { clock.time },
                                               pause: clock.pause) { () -> String? in
            looks += 1
            return nil
        }
        #expect(found == nil)
        #expect(looks == 3 && clock.pauses.count == 2)
    }

    @Test func onlyTheFailureOfTheLastLookIsThrown() throws {
        // A look that fails and a later one that finds: the failure is forgotten.
        let clock = Clock()
        var looks = 0
        let found = try StudyArrivalWait.first(within: 30, now: { clock.time }, pause: clock.pause) { () -> String? in
            looks += 1
            if looks == 1 { throw LookFailed() }
            return looks == 3 ? "1.2.3" : nil
        }
        #expect(found == "1.2.3")

        // A look that fails and a later one that finds nothing: nothing came, and that is the answer.
        let quiet = Clock()
        var quietLooks = 0
        let nothing = try StudyArrivalWait.first(within: 1, now: { quiet.time }, pause: quiet.pause) { () -> String? in
            quietLooks += 1
            if quietLooks == 1 { throw LookFailed() }
            return nil
        }
        #expect(nothing == nil)

        // Every look fails: the wait ends at the limit with the last failure.
        let failing = Clock()
        #expect(throws: LookFailed.self) {
            _ = try StudyArrivalWait.first(within: 1, now: { failing.time }, pause: failing.pause) { () -> String? in
                throw LookFailed()
            }
        }
        #expect(failing.pauses.count == 2)
    }

    /// A second request made while the first still waits is answered at once:
    /// each wait runs on its caller's thread and shares nothing with another.
    @Test func aWaitInProgressDoesNotHoldASecondOne() throws {
        let firstLooked = DispatchSemaphore(value: 0)
        let firstEnded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = Thread {
            // The first request's study never comes; its wait pauses until the test lets it go.
            _ = try? StudyArrivalWait.first(within: 30, isCancelled: { Thread.current.isCancelled }, pause: { _ in
                firstLooked.signal()
                _ = release.wait(timeout: .now() + 20)
                Thread.current.cancel()
            }) { () -> String? in nil }
            firstEnded.signal()
        }
        first.start()
        #expect(firstLooked.wait(timeout: .now() + 10) == .success)

        let started = Date.timeIntervalSinceReferenceDate
        let second = try StudyArrivalWait.first(within: 30) { "second" }
        #expect(second == "second")
        #expect(Date.timeIntervalSinceReferenceDate - started < 5)
        // The first is still waiting once the second has been answered.
        #expect(firstEnded.wait(timeout: .now()) == .timedOut)

        release.signal()
        #expect(firstEnded.wait(timeout: .now() + 10) == .success)
    }
}
