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
@testable import IsiXPreferences

/// A change of the preferences reaches the main actor without the thread that
/// wrote them waiting for the main thread.
///
/// Each test posts on a centre of its own, on a serial queue that stands for
/// the queue of a managed object context, while the main thread waits for
/// that queue: the wait a save of the database index was in when its write of
/// a preference told an observer of the main queue.
@MainActor @Suite struct PreferenceChangeNoticeTests {
    private final class Count: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    /// Posts the change on a queue and waits for the post to return, as the
    /// main thread waits for a context's queue. False when the post did not
    /// return in `seconds`: the writer is waiting for this thread.
    private func writerReturns(postingOn center: NotificationCenter, within seconds: Double) -> Bool {
        let writer = DispatchQueue(label: "PreferenceChangeNoticeTests.writer")
        let returned = DispatchSemaphore(value: 0)
        writer.async {
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            returned.signal()
        }
        return returned.wait(timeout: .now() + seconds) == .success
    }

    /// Leaves the main actor to what waits for it until `done`, or for two
    /// seconds. A test is itself a block of the main queue, which runs no
    /// other while the test does not suspend.
    private func leaveMainActor(until done: () -> Bool) async {
        let limit = Date(timeIntervalSinceNow: 2)
        while !done(), Date() < limit {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aWriterTheMainThreadWaitsForGoesOn() async {
        let center = NotificationCenter()
        let told = Count()
        let token = PreferenceChangeNotice.observe(in: center) { told.add() }
        defer { center.removeObserver(token) }

        #expect(writerReturns(postingOn: center, within: 5))
        // The main thread was waiting: nothing ran on it meanwhile.
        #expect(told.value == 0)
        await leaveMainActor { told.value == 1 }
        #expect(told.value == 1)
    }

    /// What the type is for: the same wait with an observer of the main queue
    /// keeps the writer until the main thread stops waiting for it.
    @Test func anObserverOfTheMainQueueKeepsTheWriterWaiting() async {
        let center = NotificationCenter()
        let told = Count()
        let token = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in told.add() }
        defer { center.removeObserver(token) }

        #expect(!writerReturns(postingOn: center, within: 0.5))
        // Once the main thread is free, the block runs and the writer goes on.
        await leaveMainActor { told.value == 1 }
        #expect(told.value == 1)
    }

    @Test func aChangeOnTheMainThreadIsAnsweredAtOnce() {
        let center = NotificationCenter()
        let told = Count()
        let token = PreferenceChangeNotice.observe(in: center) { told.add() }
        defer { center.removeObserver(token) }

        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(told.value == 1)
    }

    @Test func everyChangeIsToldOnceAndNoneAfterTheTokenIsRemoved() async {
        let center = NotificationCenter()
        let told = Count()
        let token = PreferenceChangeNotice.observe(in: center) { told.add() }

        #expect(writerReturns(postingOn: center, within: 5))
        #expect(writerReturns(postingOn: center, within: 5))
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await leaveMainActor { told.value == 3 }
        #expect(told.value == 3)

        center.removeObserver(token)
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(writerReturns(postingOn: center, within: 5))
        await leaveMainActor { false }
        #expect(told.value == 3)
    }
}
