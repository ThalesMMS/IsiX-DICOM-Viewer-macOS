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

private struct StandInError: Error {}

/// A stand-in of the DICOMweb client: each path answers with the next of its
/// scripted outcomes, a number of objects handed over or a failure, and every
/// call is recorded.
private final class StandInClient: DICOMwebRetrieving, @unchecked Sendable {
    enum Outcome { case objects([String]), failure(DICOMwebRequestFailure) }

    private let lock = NSLock()
    private var script: [String: [Outcome]]
    private(set) var calls: [(path: String, fallbackOnly: Bool)] = []
    var retrieveFallbackTransferSyntax: String? = "1.2.840.10008.1.2.1"

    init(script: [String: [Outcome]]) { self.script = script }

    func accepts(retrievedTransferSyntax syntax: String) -> Bool { syntax == "1.2.840.10008.1.2.4.90" }

    func retrieveObjects(path: String, stagingDirectory: String, fallbackOnly: Bool,
                         handler: @escaping (String) -> String?) throws(DICOMwebRequestFailure) -> Int {
        let outcome: Outcome? = lock.withLock {
            calls.append((path, fallbackOnly))
            return script[path]?.isEmpty == false ? script[path]!.removeFirst() : nil
        }
        switch outcome {
        case .failure(let failure): throw failure
        case .objects(let files):
            var handed = 0
            for file in files {
                if handler(file) != nil { break }
                handed += 1
            }
            return handed
        case nil: return 0
        }
    }

    func previewPicture(study: String, series: String, instance: String?) throws(DICOMwebRequestFailure) -> Data {
        throw failure(.notFound, 404)
    }
}

private func failure(_ kind: DICOMwebFailureKind, _ code: Int, handedOver: Int = 0, retryAfter: String? = nil) -> DICOMwebRequestFailure {
    DICOMwebRequestFailure(kind: kind, code: code, retryAfter: retryAfter, objectsHandedOver: handedOver, underlying: StandInError())
}

/// Runs the queue the way the application's workers do, one request at a
/// time, with no wait before a retry.
private func run(_ queue: DICOMwebRetrieveQueue, client: StandInClient, taken: @escaping (String) -> String? = { _ in nil }) {
    while let request = queue.next(cancelled: false) {
        if let failure = queue.perform(request, with: client, stagingDirectory: "/nonexistent", handler: taken) {
            if let action = queue.recovery(of: request, failure: failure) { queue.apply(action, to: request, failure: failure) }
        } else {
            queue.complete(request)
        }
    }
}

@Suite struct DICOMwebRetrieveQueueTests {
    @Test func pathsNameTheResource() {
        #expect(DICOMwebRetrieveRequest.path(study: "1.2") == "studies/1.2")
        #expect(DICOMwebRetrieveRequest.path(study: "1.2", series: "") == "studies/1.2")
        #expect(DICOMwebRetrieveRequest.path(study: "1.2", series: "3") == "studies/1.2/series/3")
        #expect(DICOMwebRetrieveRequest.path(study: "1.2", series: "3", instance: "4") == "studies/1.2/series/3/instances/4")
    }

    @Test func limitStartsWorkersAndNextFollowsTheSeriesOrder() {
        let queue = DICOMwebRetrieveQueue(limit: 2, orderedSeries: { ["b", "a"] })
        #expect(queue.enqueue(path: "studies/s/series/a", series: "a"))
        #expect(queue.enqueue(path: "studies/s/series/c", series: "c"))
        #expect(!queue.enqueue(path: "studies/s/series/b", series: "b"))
        #expect(!queue.enqueue(path: "studies/s"))
        #expect(queue.running == 2)
        #expect(queue.next(cancelled: false)?.path == "studies/s")
        #expect(queue.next(cancelled: false)?.series == "b")
        #expect(queue.next(cancelled: false)?.series == "a")
        #expect(queue.next(cancelled: false)?.series == "c")
        #expect(queue.next(cancelled: false) == nil)
        #expect(queue.running == 1)
    }

    @Test func withoutAnOrderTheFirstQueuedStarts() {
        let pending = ["x", "y"].map { DICOMwebRetrieveRequest(path: $0, series: $0) }
        #expect(DICOMwebRetrieveQueue.nextIndex(of: pending, orderedSeries: nil) == 0)
        #expect(DICOMwebRetrieveQueue.nextIndex(of: pending, orderedSeries: ["z"]) == 0)
        #expect(DICOMwebRetrieveQueue.nextIndex(of: pending, orderedSeries: ["y"]) == 1)
    }

    @Test func cancellingDropsWhatIsPending() {
        let queue = DICOMwebRetrieveQueue(limit: 1)
        queue.enqueue(path: "studies/s")
        queue.requeue(DICOMwebRetrieveRequest(path: "studies/t"))
        #expect(queue.next(cancelled: true) == nil)
        #expect(queue.running == 0)
        #expect(queue.next(cancelled: false) == nil)
    }

    @Test func aTransientFailureIsAskedAgainAndThenLeftMissing() {
        let path = "studies/s/series/a/instances/i"
        let client = StandInClient(script: [path: [.failure(failure(.http, 503)), .failure(failure(.network, -1005)),
                                                   .failure(failure(.timeout, -1001))]])
        let queue = DICOMwebRetrieveQueue(limit: 1)
        queue.enqueue(path: path, uid: "i", series: "a")
        run(queue, client: client)
        #expect(client.calls.count == 3)
        #expect(!queue.failed)
        #expect(queue.hasUnresolvedFailure)
        #expect(queue.failure?.code == -1001)
    }

    @Test func aStudyLeftMissingStopsTheRetrieve() {
        let client = StandInClient(script: ["studies/s": [.failure(failure(.notFound, 404))]])
        let queue = DICOMwebRetrieveQueue(limit: 1)
        queue.enqueue(path: "studies/s")
        queue.requeue(DICOMwebRetrieveRequest(path: "studies/s/series/a", series: "a"))
        run(queue, client: client)
        #expect(queue.failed)
        #expect(client.calls.map(\.path) == ["studies/s"])
    }

    @Test func authenticationStopsAtOnce() {
        let client = StandInClient(script: ["studies/s/series/a/instances/i": [.failure(failure(.authentication, 401))]])
        let queue = DICOMwebRetrieveQueue(limit: 1)
        queue.enqueue(path: "studies/s/series/a/instances/i", uid: "i", series: "a")
        run(queue, client: client)
        #expect(queue.failed)
        #expect(client.calls.count == 1)
    }

    @Test func aCutStudyIsKeptToResumeInTheFallbackSyntax() {
        let client = StandInClient(script: ["studies/s": [.failure(failure(.invalidResponse, 4, handedOver: 2))]])
        let queue = DICOMwebRetrieveQueue(limit: 1)
        queue.enqueue(path: "studies/s")
        run(queue, client: client)
        #expect(queue.firstCut?.isCutAfterObjects == true)
        queue.useFallbackOnly()
        let resumed = queue.takeInterrupted()
        #expect(resumed.map(\.path) == ["studies/s"])
        #expect(resumed.first?.failure == nil && resumed.first?.attempts == 1)
        #expect(queue.takeInterrupted().isEmpty)
        queue.enqueue(path: "studies/s/series/a/instances/i", uid: "i", series: "a")
        run(queue, client: client)
        #expect(client.calls.last?.fallbackOnly == true)
    }

    @Test func anInstanceThatArrivedNeedsNothingMore() {
        let queue = DICOMwebRetrieveQueue(limit: 1)
        let request = DICOMwebRetrieveRequest(path: "studies/s/series/a/instances/i", uid: "i", series: "a")
        let cut = failure(.network, -1005, handedOver: 1)
        #expect(queue.recovery(of: request, failure: cut) == .retry)
        queue.take("i")
        #expect(queue.recovery(of: request, failure: cut) == nil)
    }

    @Test func recoveryFollowsTheKindAndTheAttempts() {
        typealias R = DICOMwebRecovery
        #expect(R.action(for: failure(.http, 429), attempts: 1) == .retry)
        #expect(R.action(for: failure(.http, 429), attempts: 3) == .skip)
        #expect(R.action(for: failure(.http, 418), attempts: 1) == .skip)
        #expect(R.action(for: failure(.http, 206, handedOver: 2), attempts: 1) == .resume)
        #expect(R.action(for: failure(.tls, -1202), attempts: 1) == .stop)
        #expect(R.action(for: failure(.cancelled, 0), attempts: 1) == .stop)
        #expect(R.delay(beforeAttempt: 2, retryAfter: " 7 ") == 7)
        #expect(R.delay(beforeAttempt: 2, retryAfter: "600") == 60)
        #expect(R.delay(beforeAttempt: 4, retryAfter: "soon") == 4)
        #expect(R.delay(beforeAttempt: 20, retryAfter: nil) == 32)
    }

    @Test func adaptiveRepeatsOnlyWhatBroughtNothing() {
        let request = DICOMwebRetrieveRequest(path: "studies/s")
        #expect(DICOMwebRetrieveQueue.repeatsAdaptively(request, failure: failure(.http, 503), busyOrTransient: true))
        #expect(!DICOMwebRetrieveQueue.repeatsAdaptively(request, failure: failure(.http, 503, handedOver: 1), busyOrTransient: true))
        #expect(!DICOMwebRetrieveQueue.repeatsAdaptively(request, failure: failure(.http, 404), busyOrTransient: false))
        var tired = request
        tired.attempts = 3
        #expect(!DICOMwebRetrieveQueue.repeatsAdaptively(tired, failure: failure(.http, 503), busyOrTransient: true))
    }

    @Test func objectsTakenAreRecordedAndARefusedOneEndsTheRequest() {
        let client = StandInClient(script: ["studies/s": [.objects(["one", "two", "bad", "three"])]])
        let queue = DICOMwebRetrieveQueue(limit: 1)
        queue.enqueue(path: "studies/s")
        run(queue, client: client) { file in
            if file == "bad" { return "refused" }
            queue.take(file)
            return nil
        }
        #expect(queue.isTaken("one") && queue.isTaken("two") && !queue.isTaken("three"))
        #expect(queue.completedPaths == ["studies/s"])
    }

    @Test func anObjectBelongsWhenItsIdentifiersAreTheOnesAskedFor() {
        let instance = DICOMwebRetrieveRequest(path: "p", uid: "i", series: "a")
        func belongs(_ request: DICOMwebRetrieveRequest, series: String = "", study: String? = "s", seriesUID: String? = "a",
                     object: String? = "i", sources: [String] = [], seen: Set<String> = []) -> Bool {
            DICOMwebRetrieveQueue.belongs(study: "s", series: series, request: request, actualStudy: study, actualSeries: seriesUID,
                                          objectUID: object, sources: sources, seen: seen)
        }
        #expect(belongs(instance))
        #expect(!belongs(instance, study: "t"))
        #expect(!belongs(instance, seriesUID: "b"))
        #expect(!belongs(instance, series: "b"))
        #expect(!belongs(instance, object: "j"))
        #expect(belongs(instance, object: "j", sources: ["i"]))
        #expect(!belongs(instance, seen: ["i"]))
        #expect(!belongs(instance, object: ""))
        #expect(!belongs(instance, study: nil))
        #expect(belongs(DICOMwebRetrieveRequest(path: "studies/s"), object: "anything"))
    }
}
