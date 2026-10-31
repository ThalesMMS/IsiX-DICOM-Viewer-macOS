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
import IsiXDatabase

@Suite struct IngestBatchLaneTests {

    private final class Log: Sendable {
        let finished = Mutex<[Int]>([])
        let running = Mutex(0)
        let mostAtOnce = Mutex(0)
    }

    @Test func worksOnTheBatchesInOrderOneAtATime() async {
        let log = Log()
        let lane = IngestBatchLane<Int> { batch in
            let now = log.running.withLock { running in
                running += 1
                return running
            }
            log.mostAtOnce.withLock { $0 = max($0, now) }
            try? await Task.sleep(for: .milliseconds(batch % 3))
            log.running.withLock { $0 -= 1 }
            log.finished.withLock { $0.append(batch) }
        }
        for batch in 0..<30 { lane.deliver(batch) }
        await lane.finish()
        #expect(log.finished.withLock { $0 } == Array(0..<30))
        #expect(log.mostAtOnce.withLock { $0 } == 1)
    }

    /// Whoever prepares the batches may stop early; what it delivered is worked on.
    @Test func finishEndsAfterWhatWasDelivered() {
        let log = Log()
        let lane = IngestBatchLane<Int> { batch in
            try? await Task.sleep(for: .milliseconds(20))
            log.finished.withLock { $0.append(batch) }
        }
        lane.deliver(1)
        lane.deliver(2)
        lane.finishAndWait()
        #expect(log.finished.withLock { $0 } == [1, 2])
    }

    @Test func aLaneThatReceivedNothingEndsAtOnce() {
        let lane = IngestBatchLane<Int> { _ in }
        lane.finishAndWait()
    }

    @Test func whatIsDeliveredAfterTheEndIsNotWorkedOn() async {
        let log = Log()
        let lane = IngestBatchLane<Int> { batch in log.finished.withLock { $0.append(batch) } }
        lane.deliver(1)
        await lane.finish()
        lane.deliver(2)
        await lane.finish()
        #expect(log.finished.withLock { $0 } == [1])
    }
}
