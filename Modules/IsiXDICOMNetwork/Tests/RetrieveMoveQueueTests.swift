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

/// A transfer that blocks a thread of its own, as the DCMTK operations do,
/// until it is let go or cancelled.
private final class StandInTransfer: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var cancelled = false
    private(set) var started = 0

    /// Blocks a new thread until released or cancelled; returns whether it was cancelled.
    func run() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread {
                    self.condition.lock()
                    self.started += 1
                    self.condition.broadcast()
                    while !self.released && !self.cancelled { self.condition.wait() }
                    let cancelled = self.cancelled
                    self.condition.unlock()
                    continuation.resume(returning: cancelled)
                }.start()
            }
        } onCancel: {
            condition.withLock { cancelled = true; condition.broadcast() }
        }
    }

    func waitUntilStarted(_ count: Int) {
        condition.withLock { while started < count { condition.wait() } }
    }

    func release() {
        condition.withLock { released = true; condition.broadcast() }
    }
}

/// The retrieves a window has under way, and the operations of each node.
struct RetrieveMoveQueueTests {

    @Test func theRetrievesThatRunAreCountedUntilTheyReturn() async {
        let queue = RetrieveMoveQueue(), transfer = StandInTransfer()
        #expect(await queue.runningCount == 0)
        let first = Task { await queue.run { await transfer.run() } }
        let second = Task { await queue.run { await transfer.run() } }
        transfer.waitUntilStarted(2)
        // The blocked transfers do not hold the queue: it answers meanwhile.
        #expect(await queue.runningCount == 2)
        transfer.release()
        let firstCancelled = await first.value, secondCancelled = await second.value
        #expect(!firstCancelled && !secondCancelled)
        #expect(await queue.runningCount == 0)
    }

    @Test func cancellingTheTaskCancelsTheTransferAndItStopsCounting() async {
        let queue = RetrieveMoveQueue(), transfer = StandInTransfer()
        let running = Task { await queue.run { await transfer.run() } }
        transfer.waitUntilStarted(1)
        running.cancel()
        let cancelled = await running.value
        #expect(cancelled)
        #expect(await queue.runningCount == 0)
    }

    @Test func aNodeAlreadyMovingIsNotMovedAgain() {
        let operations = RetrieveOperationsUnderWay()
        let node = NSObject(), other = NSObject()
        var ran: [String] = []
        let outer = operations.run(for: node) { () -> Int in
            #expect(operations.contains(node) && !operations.contains(other))
            let inner = operations.run(for: node) { () -> Int in ran.append("inner"); return 2 }
            #expect(inner == nil)
            #expect(operations.run(for: other) { () -> Int in ran.append("other"); return 3 } == 3)
            ran.append("outer")
            return 1
        }
        #expect(outer == 1 && ran == ["other", "outer"] && !operations.contains(node))
    }

    @Test func anOperationThatThrowsLetsItsNodeGo() {
        let operations = RetrieveOperationsUnderWay(), node = NSObject()
        #expect(throws: CocoaError.self) { try operations.run(for: node) { throw CocoaError(.userCancelled) } }
        #expect(!operations.contains(node))
        #expect(operations.run(for: node) { 4 } == 4)
    }

    @Test func anotherThreadIsRefusedTheNodeWhileItsOperationRuns() {
        final class Node: Sendable {}
        let operations = RetrieveOperationsUnderWay(), node = Node()
        let claimed = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        Thread {
            _ = operations.run(for: node) { () -> Bool in
                claimed.signal()
                done.wait()
                return true
            }
            finished.signal()
        }.start()
        claimed.wait()
        #expect(operations.run(for: node) { true } == nil)
        done.signal()
        finished.wait()
        #expect(operations.run(for: node) { true } == true)
    }
}
