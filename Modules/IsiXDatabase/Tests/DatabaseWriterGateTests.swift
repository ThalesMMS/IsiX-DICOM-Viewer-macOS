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

@Suite struct DatabaseWriterGateTests {

    private struct WriteFailed: Error {}

    /// Runs `body` on a thread of its own and says whether it ended in time.
    private func finishes(within seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            finished.signal()
        }
        return finished.wait(timeout: .now() + seconds) == .success
    }

    @Test func theThreadInsideEntersAgain() {
        let gate = DatabaseWriterGate()
        #expect(finishes(within: 5) {
            gate.withExclusiveWrite { gate.withExclusiveWrite { gate.withExclusiveWrite {} } }
        })
    }

    @Test func anotherThreadWaitsUntilTheWriterIsDone() {
        let gate = DatabaseWriterGate()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            gate.withExclusiveWrite {
                entered.signal()
                release.wait()
            }
        }
        entered.wait()

        let second = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            gate.withExclusiveWrite {}
            second.signal()
        }
        #expect(second.wait(timeout: .now() + 0.3) == .timedOut)

        release.signal()
        #expect(second.wait(timeout: .now() + 5) == .success)
    }

    @Test func writersDoNotOverlap() {
        let gate = DatabaseWriterGate()
        let inside = Atomic<Int>(0), overlaps = Atomic<Int>(0)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            Thread.detachNewThread {
                for _ in 0..<200 {
                    gate.withExclusiveWrite {
                        if inside.add(1, ordering: .sequentiallyConsistent).newValue != 1 {
                            overlaps.add(1, ordering: .sequentiallyConsistent)
                        }
                        inside.subtract(1, ordering: .sequentiallyConsistent)
                    }
                }
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(overlaps.load(ordering: .sequentiallyConsistent) == 0)
    }

    @Test func aWriteThatThrowsLetsTheGateGo() throws {
        let gate = DatabaseWriterGate()
        #expect(throws: WriteFailed.self) {
            try gate.withExclusiveWrite { throw WriteFailed() }
        }
        #expect(finishes(within: 5) { gate.withExclusiveWrite {} })
    }

    @Test func aGateHandsBackWhatTheWriteAnswers() {
        let gate = DatabaseWriterGate()
        #expect(gate.withExclusiveWrite { 7 } == 7)
    }

    @Test func onlyTheCoordinatorsNamedAreRetired() {
        let gate = DatabaseWriterGate()
        let former = NSObject(), current = NSObject()
        #expect(!gate.isRetired(former))
        #expect(!gate.isRetired(nil))
        gate.retire(former)
        #expect(gate.isRetired(former))
        #expect(!gate.isRetired(current))
    }

    @Test func aRetiredCoordinatorIsNotKeptAlive() {
        let gate = DatabaseWriterGate()
        weak var gone: NSObject?
        autoreleasepool {
            let former = NSObject()
            gone = former
            gate.retire(former)
        }
        #expect(gone == nil)
    }
}
