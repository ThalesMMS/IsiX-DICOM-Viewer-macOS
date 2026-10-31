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

/// A database whose batches wait until the test lets them end.
private final class WorkerDouble: ConversionRunning {
    private struct State {
        var started: [FileConversionBatch] = []
        var ended = 0
        var running = 0
        var mostAtOnce = 0
        var queued: [Int] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    let conversionIdentifier: String
    private let holds: Bool

    init(_ identifier: String = "db", holds: Bool = true) {
        conversionIdentifier = identifier
        self.holds = holds
    }

    var started: [FileConversionBatch] { state.withLock { $0.started } }
    var ended: Int { state.withLock { $0.ended } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }
    var queued: [Int] { state.withLock { $0.queued } }

    func endBatch() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.waiting.isEmpty ? nil : state.waiting.removeFirst()
        }
        waiting?.resume()
    }

    func filesQueued(_ count: Int) {
        state.withLock { $0.queued.append(count) }
    }

    func run(_ batch: FileConversionBatch) async {
        state.withLock {
            $0.started.append(batch)
            $0.running += 1
            $0.mostAtOnce = max($0.mostAtOnce, $0.running)
        }
        if holds {
            await withCheckedContinuation { continuation in
                state.withLock { $0.waiting.append(continuation) }
            }
        } else {
            await Task.yield()
        }
        state.withLock {
            $0.running -= 1
            $0.ended += 1
        }
    }
}

private func request(_ files: [String], mode: FileConversionMode = .decompress) -> FileConversionBatch {
    FileConversionBatch(files: files, mode: mode, destination: nil, isFromScan: false)
}

private func scanned(_ files: [String], mode: FileConversionMode = .decompress) -> FileConversionBatch {
    FileConversionBatch(files: files, mode: mode, destination: "INCOMING", isFromScan: true)
}

/// What another thread answered.
private final class Answer: Sendable {
    private let value = Mutex<Bool?>(nil)
    var given: Bool? { value.withLock { $0 } }
    func give(_ answer: Bool) { value.withLock { $0 = answer } }
}

/// Waits for a condition the actor makes true, at most five seconds.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 5000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@Suite struct ConversionQueueTests {
    @Test func isPublishedBeforeEnqueueReturnsAndUntilTheLastBatchHasEnded() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        #expect(!queue.isConverting("db"))

        queue.enqueue(request(["a"]), runner: worker)
        #expect(queue.isConverting("db"), "published on the thread that queued it, before the actor")
        queue.enqueue(request(["b"]), runner: worker)

        #expect(await eventually { worker.started.count == 1 })
        worker.endBatch()
        #expect(await eventually { worker.started.count == 2 })
        #expect(worker.ended == 1)
        #expect(queue.isConverting("db"), "between two batches the queue is still at work")
        worker.endBatch()
        #expect(await eventually { !queue.isConverting("db") })
        #expect(worker.ended == 2)
    }

    @Test func runsOneBatchOfADatabaseAtATimeInOrder() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        for name in ["a", "b", "c"] { queue.enqueue(request([name], mode: name == "b" ? .compress : .decompress), runner: worker) }

        for count in 1 ... 3 {
            #expect(await eventually { worker.started.count == count })
            worker.endBatch()
        }
        #expect(await eventually { !queue.isConverting("db") })
        #expect(worker.started.map(\.files) == [["a"], ["b"], ["c"]])
        #expect(worker.started.map(\.mode) == [.decompress, .compress, .decompress])
        #expect(worker.mostAtOnce == 1)
    }

    @Test func twoDatabasesDoNotWaitForEachOther() async {
        let queue = ConversionQueue()
        let first = WorkerDouble("first"), second = WorkerDouble("second")
        queue.enqueue(request(["a"]), runner: first)
        queue.enqueue(request(["b"]), runner: second)
        #expect(await eventually { first.started.count == 1 && second.started.count == 1 })
        first.endBatch()
        #expect(await eventually { !queue.isConverting("first") })
        #expect(queue.isConverting("second"))
        second.endBatch()
        #expect(await eventually { !queue.isConverting("second") })
    }

    @Test func whatTheScanMovedJoinsWhatIsWaitingAndARequestStaysApart() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        queue.enqueue(request(["running"]), runner: worker)
        #expect(await eventually { worker.started.count == 1 })

        queue.enqueue(scanned(["1"]), runner: worker)
        queue.enqueue(request(["asked"]), runner: worker)
        queue.enqueue(scanned(["2", "3"]), runner: worker)
        queue.enqueue(scanned(["4"], mode: .compress), runner: worker)
        queue.enqueue(request(["asked too"]), runner: worker)

        for count in 2 ... 5 {
            worker.endBatch()
            #expect(await eventually { worker.started.count == count })
        }
        worker.endBatch()
        #expect(await eventually { !queue.isConverting("db") })
        #expect(worker.started.map(\.files) == [["running"], ["1", "2", "3"], ["asked"], ["4"], ["asked too"]])
        #expect(worker.queued == [1, 2, 4, 5, 6], "each addition counts every file waiting")
    }

    @Test func aRunningBatchIsNotJoined() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        queue.enqueue(scanned(["1"]), runner: worker)
        #expect(await eventually { worker.started.count == 1 })
        queue.enqueue(scanned(["2"]), runner: worker)
        worker.endBatch()
        #expect(await eventually { worker.started.count == 2 })
        worker.endBatch()
        #expect(await eventually { !queue.isConverting("db") })
        #expect(worker.started.map(\.files) == [["1"], ["2"]])
    }

    @Test func nothingIsLostNorRepeatedWhenManyThreadsQueueAtOnce() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble(holds: false)
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            queue.enqueue(index % 3 == 0 ? request(["\(index)"]) : scanned(["\(index)"], mode: index % 2 == 0 ? .compress : .decompress), runner: worker)
        }
        #expect(await eventually { !queue.isConverting("db") })
        let files = worker.started.flatMap(\.files)
        #expect(files.count == 2000)
        #expect(Set(files) == Set((0 ..< 2000).map(String.init)))
        #expect(worker.mostAtOnce == 1)
        #expect(worker.ended == worker.started.count)
    }

    @Test func waitingForTheQueueReturnsWhenItEmpties() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        #expect(!queue.waitUntilIdle("db"), "nothing to wait for")

        queue.enqueue(request(["a"]), runner: worker)
        #expect(await eventually { worker.started.count == 1 })
        let answer = Answer()
        Task.detached { answer.give(queue.waitUntilIdle("db")) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answer.given == nil, "it returned with a batch running")
        worker.endBatch()
        #expect(await eventually { answer.given != nil })
        #expect(answer.given == true)
    }

    @Test func waitingForWhatTheScanMovedDoesNotWaitForARequest() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        #expect(!queue.waitForScannedFiles("db"), "nothing to wait for")

        queue.enqueue(request(["asked"]), runner: worker)
        #expect(await eventually { worker.started.count == 1 })
        #expect(!queue.waitForScannedFiles("db"), "it waited for a request alone")

        queue.enqueue(scanned(["1"]), runner: worker)
        queue.enqueue(request(["asked too"]), runner: worker)
        let answer = Answer()
        Task.detached { answer.give(queue.waitForScannedFiles("db")) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answer.given == nil, "it returned with what the scan moved still waiting")

        worker.endBatch()
        #expect(await eventually { worker.started.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answer.given == nil, "it returned with what the scan moved being converted")

        worker.endBatch()
        #expect(await eventually { answer.given != nil })
        #expect(answer.given == true)
        #expect(worker.started.map(\.files) == [["asked"], ["1"], ["asked too"]], "the order is the one asked for")
        #expect(worker.ended == 2 && queue.isConverting("db"), "the request after it was still running")

        worker.endBatch()
        #expect(await eventually { !queue.isConverting("db") })
    }

    @Test func waitingForWhatTheScanMovedEndsWithTheLane() async {
        let queue = ConversionQueue()
        let worker = WorkerDouble()
        queue.enqueue(scanned(["1"]), runner: worker)
        #expect(await eventually { worker.started.count == 1 })
        let answer = Answer()
        Task.detached { answer.give(queue.waitForScannedFiles("db")) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answer.given == nil)
        worker.endBatch()
        #expect(await eventually { answer.given == true })
        #expect(!queue.isConverting("db"))
    }

    @Test func aLaneKeepsTheDatabaseItBeganWithUntilItEnds() async {
        let queue = ConversionQueue()
        let opened = WorkerDouble(), reopened = WorkerDouble()
        queue.enqueue(scanned(["1"]), runner: opened)
        #expect(await eventually { opened.started.count == 1 })
        queue.enqueue(request(["2"]), runner: reopened)
        opened.endBatch()
        #expect(await eventually { opened.started.count == 2 })
        opened.endBatch()
        #expect(await eventually { !queue.isConverting("db") })
        #expect(reopened.started.isEmpty, "a batch ran on another worker while the lane lasted")

        queue.enqueue(request(["3"]), runner: reopened)
        #expect(await eventually { reopened.started.count == 1 })
        reopened.endBatch()
        #expect(await eventually { !queue.isConverting("db") })
    }

    @Test func anEmptyBatchIsNoWork() {
        let queue = ConversionQueue()
        queue.enqueue(request([]), runner: WorkerDouble())
        #expect(!queue.isConverting("db"))
    }

    @Test func aLaneThatEndedKeepsNoDatabase() async {
        let queue = ConversionQueue()
        weak var released: WorkerDouble?
        do {
            let worker = WorkerDouble(holds: false)
            released = worker
            queue.enqueue(request(["a"]), runner: worker)
            #expect(await eventually { !queue.isConverting("db") })
        }
        #expect(await eventually { released == nil })
    }
}
