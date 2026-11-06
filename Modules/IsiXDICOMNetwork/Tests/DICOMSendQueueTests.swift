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

// MARK: Stand-in of the SCU

/// The transport: records every part, DICOMweb and direct send it is given,
/// counts the parts running at once, and answers with the outcome set for a
/// file. A part whose first file is in `waitsForCancellation` runs until its
/// task is cancelled.
actor StandInTransport: DICOMSendTransport {
    var stored: [DICOMStorePart] = []
    var dicomweb: [DICOMSendRequest] = []
    var direct: [DICOMSendRequest] = []
    var running = 0
    var mostRunning = 0
    var outcomes: [String: DICOMSendOutcome] = [:]
    var waitsForCancellation: Set<String> = []
    var directOutcome = DICOMSendOutcome.sent
    var delay: Duration = .zero

    func set(outcomes: [String: DICOMSendOutcome] = [:], waits: Set<String> = [], direct: DICOMSendOutcome = .sent,
             delay: Duration = .zero) {
        self.outcomes = outcomes
        waitsForCancellation = waits
        directOutcome = direct
        self.delay = delay
    }

    func store(_ part: DICOMStorePart) async -> DICOMSendOutcome {
        stored.append(part)
        running += 1
        mostRunning = max(mostRunning, running)
        defer { running -= 1 }
        let first = part.files.first ?? ""
        if waitsForCancellation.contains(first) {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return .cancelled
            }
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return outcomes[first] ?? .sent
    }

    func sendByDICOMweb(_ request: DICOMSendRequest) async -> DICOMSendOutcome {
        dicomweb.append(request)
        return .sent
    }

    func sendByDirectTransfer(_ request: DICOMSendRequest) async -> DICOMSendOutcome {
        direct.append(request)
        return directOutcome
    }
}

private let node = DICOMNode(entry: ["AETitle": .string("PACS"), "Address": .string("127.0.0.1"), "Port": .string("104"),
                                     "TLSEnabled": .boolean(false)])

private func request(_ batches: [DICOMSendRequest.Batch], associations: UInt32 = 1, most: Int = 4,
                     route: DICOMSendRoute = .cStore) -> DICOMSendRequest {
    DICOMSendRequest(destination: node, batches: batches, transferSyntax: 5, compression: 1, route: route,
                     options: DICOMSendOptions(callingAETitle: "ISIX", associationsPerBatch: associations,
                                               mostConcurrentSends: most))
}

private func files(_ prefix: String, _ count: Int) -> [String] {
    (1...max(count, 1)).prefix(count).map { "/\(prefix)\($0)" }
}

// MARK: The request

@Suite struct DICOMSendRequestTests {
    @Test func partsSplitABatchOverItsAssociations() {
        let batch = DICOMSendRequest.Batch(patientName: "Alpha", files: files("a", 10))
        #expect(request([batch], associations: 1).parts(of: batch).map(\.files.count) == [10])
        #expect(request([batch], associations: 3).parts(of: batch).map(\.files.count) == [4, 4, 2])
        #expect(request([batch], associations: 4).parts(of: batch).map(\.files.count) == [3, 3, 3, 1])
        #expect(request([batch], associations: 20).parts(of: batch).map(\.files.count) == Array(repeating: 1, count: 10))
        let parts = request([batch], associations: 3).parts(of: batch)
        #expect(parts.flatMap(\.files) == batch.files)
        #expect(parts.allSatisfy { $0.patientName == "Alpha" && $0.callingAETitle == "ISIX" && $0.transferSyntax == 5
                                   && $0.destination == node })
        let empty = DICOMSendRequest.Batch(patientName: nil, files: [])
        #expect(request([empty]).parts(of: empty).isEmpty)
    }

    @Test func associationsFollowTheSettings() {
        #expect(DICOMSendOptions.associationsPerBatch(requested: 1, maximum: 4) == 1)
        #expect(DICOMSendOptions.associationsPerBatch(requested: 3, maximum: 4) == 3)
        #expect(DICOMSendOptions.associationsPerBatch(requested: 9, maximum: 4) == 4)
        #expect(DICOMSendOptions.associationsPerBatch(requested: 0, maximum: 4) == 1)
        // A negative count is a large unsigned one, held to the maximum.
        #expect(DICOMSendOptions.associationsPerBatch(requested: -2, maximum: 4) == 4)
        #expect(DICOMSendOptions.associationsPerBatch(requested: 2, maximum: 0) == 1)
    }

    @Test func thePortIsReadAsTheAssociationReadsIt() {
        func port(_ value: PropertyListValue?) -> Int32 {
            var destination = node
            destination[DICOMNode.Key.port] = value
            return DICOMStorePart(destination: destination, files: [], transferSyntax: 0, compression: 1,
                                  callingAETitle: nil, patientName: nil).port
        }
        #expect(port(.string("104")) == 104)
        #expect(port(.string(" 11112abc")) == 11112)
        #expect(port(.integer(4242)) == 4242)
        #expect(port(.boolean(true)) == 1)
        #expect(port(nil) == 0)
        #expect(port(.string("none")) == 0)
    }

    @Test func allFilesAreEachSentOnce() {
        let request = request([.init(patientName: "A", files: ["/1", "/2"]), .init(patientName: "B", files: ["/2", "/3"])])
        #expect(request.allFiles == ["/1", "/2", "/3"])
        #expect(request.fileCount == 4)
    }
}

// MARK: The selection

@Suite struct DICOMSendSelectionTests {
    typealias Item = DICOMSendSelection.Item

    @Test func onePatientPerBatchInPatientUIDOrder() {
        let items = [Item(patientUID: "P2", patientName: "Beta", path: "/b1"),
                     Item(patientUID: "P1", patientName: "Alpha", path: "/a1"),
                     Item(patientUID: "P3", patientName: "Gamma", path: "/g1"),
                     Item(patientUID: "p1", patientName: "Alpha", path: "/a2"),
                     Item(patientUID: "P2", patientName: "Beta", path: "/b2"),
                     Item(patientUID: nil, patientName: nil, path: "/n1")]
        let batches = DICOMSendSelection.batches(of: items, sendsAppSeries: false)
        #expect(batches == [.init(patientName: nil, files: ["/n1"]),
                            .init(patientName: "Alpha", files: ["/a1"]),
                            .init(patientName: "Beta", files: ["/b1", "/b2"]),
                            .init(patientName: "Gamma", files: ["/g1"]),
                            .init(patientName: "Alpha", files: ["/a2"])])
    }

    @Test func aFileIsSentOnceAndTheAppSeriesOnlyWithROIs() {
        let items = [Item(patientUID: "P1", patientName: "Alpha", path: "/roi", isAppSeries: true),
                     Item(patientUID: "P1", patientName: "Alpha", path: "/a1"),
                     Item(patientUID: "P1", patientName: "Alpha", path: "/a1"),
                     Item(patientUID: "P2", patientName: "Beta", path: "/b-roi", isAppSeries: true),
                     Item(patientUID: "P3", patientName: "Gamma", path: nil)]
        #expect(DICOMSendSelection.batches(of: items, sendsAppSeries: false)
                == [.init(patientName: "Alpha", files: ["/a1"]), .init(patientName: "Gamma", files: [])])
        #expect(DICOMSendSelection.batches(of: items, sendsAppSeries: true)
                == [.init(patientName: "Alpha", files: ["/roi", "/a1"]), .init(patientName: "Beta", files: ["/b-roi"]),
                    .init(patientName: "Gamma", files: [])])
    }

    @Test func pathsAreComparedByTheirCodeUnits() {
        let composed = "/caf\u{E9}", decomposed = "/cafe\u{301}"
        #expect(DICOMSendSelection.unique([composed, decomposed, composed]) == [composed, decomposed])
    }
}

// MARK: The queue

@Suite struct DICOMSendQueueTests {
    @Test func everyBatchGoesInItsPartsToTheDestination() async {
        let transport = StandInTransport()
        let queue = DICOMSendQueue()
        let sent = request([.init(patientName: "Alpha", files: files("a", 5)), .init(patientName: "Beta", files: files("b", 2))],
                           associations: 2)
        #expect(await queue.send(sent, through: transport) == .sent)
        let stored = await transport.stored
        #expect(stored.map(\.files).sorted { $0[0] < $1[0] } == [["/a1", "/a2", "/a3"], ["/a4", "/a5"], ["/b1"], ["/b2"]])
        #expect(stored.allSatisfy { $0.destination == node && $0.transferSyntax == 5 && $0.port == 104 })
        #expect(queue.pendingSends == 0)
    }

    @Test func atMostTheProcessSlotsRunAtOnce() async {
        let transport = StandInTransport()
        await transport.set(delay: .milliseconds(50))
        let queue = DICOMSendQueue()
        let tasks = (1...8).map { index in
            queue.enqueue(request([.init(patientName: "P\(index)", files: ["/c\(index)"])], most: 4), through: transport)
        }
        #expect(queue.pendingSends == 8)
        for task in tasks {
            #expect(await task.value == .sent)
        }
        #expect(await transport.stored.count == 8)
        // A send starts when none runs or when it makes fewer than four.
        #expect(await transport.mostRunning == 3)
        #expect(queue.pendingSends == 0)
    }

    @Test func oneSlotSendsOneAtATime() async {
        let transport = StandInTransport()
        await transport.set(delay: .milliseconds(20))
        let queue = DICOMSendQueue()
        let tasks = (1...4).map { queue.enqueue(request([.init(patientName: nil, files: ["/s\($0)"])], most: 1), through: transport) }
        for task in tasks { _ = await task.value }
        #expect(await transport.mostRunning == 1)
        // Each enqueued send reaches the queue in its own task, so the order in
        // which they take the one slot is not fixed, as with the threads before.
        #expect(await transport.stored.map(\.files).sorted { $0.joined() < $1.joined() }
                == [["/s1"], ["/s2"], ["/s3"], ["/s4"]])
    }

    @Test func aCancelledPartStopsItsBatchAndTheRest() async {
        let transport = StandInTransport()
        await transport.set(outcomes: ["/a1": .cancelled], waits: ["/a3"])
        let queue = DICOMSendQueue()
        let sent = request([.init(patientName: "Alpha", files: files("a", 4)), .init(patientName: "Beta", files: ["/b1"])],
                           associations: 2)
        #expect(await queue.send(sent, through: transport) == .cancelled)
        let stored = await transport.stored.map(\.files)
        #expect(stored.count == 2 && !stored.contains(["/b1"]))
    }

    @Test func aFailedPartDoesNotStopTheNextBatch() async {
        let transport = StandInTransport()
        await transport.set(outcomes: ["/a1": .failed])
        let queue = DICOMSendQueue()
        let sent = request([.init(patientName: "Alpha", files: ["/a1"]), .init(patientName: "Beta", files: ["/b1"])])
        #expect(await queue.send(sent, through: transport) == .failed)
        #expect(await transport.stored.map(\.files) == [["/a1"], ["/b1"]])
    }

    @Test func cancellingTheTaskCancelsTheRunningPart() async {
        let transport = StandInTransport()
        await transport.set(waits: ["/w1"])
        let queue = DICOMSendQueue()
        let task = queue.enqueue(request([.init(patientName: nil, files: ["/w1"]), .init(patientName: nil, files: ["/w2"])]),
                                 through: transport)
        while await transport.stored.isEmpty { await Task.yield() }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(await transport.stored.map(\.files) == [["/w1"]])
    }

    @Test func aDICOMwebDestinationIsNeverSentByCStore() async {
        let transport = StandInTransport()
        let queue = DICOMSendQueue()
        let sent = request([.init(patientName: "Alpha", files: ["/w1"])], route: .dicomweb)
        #expect(await queue.send(sent, through: transport) == .sent)
        #expect(await transport.dicomweb == [sent])
        #expect(await transport.stored.isEmpty)
    }

    @Test func theDirectTransferFallsBackToCStoreOnlyWhenItFailed() async {
        let queue = DICOMSendQueue()
        for (direct, expectStore) in [(DICOMSendOutcome.sent, false), (.cancelled, false), (.failed, true)] {
            let transport = StandInTransport()
            await transport.set(direct: direct)
            let sent = request([.init(patientName: "Alpha", files: ["/d1"])], route: .directTransferFirst)
            let outcome = await queue.send(sent, through: transport)
            #expect(await transport.direct == [sent])
            #expect(await transport.stored.isEmpty == !expectStore)
            #expect(outcome == (expectStore ? .sent : direct))
        }
    }
}
