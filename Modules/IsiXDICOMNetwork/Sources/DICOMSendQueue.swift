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

/// How a send, or one association of it, ended.
public enum DICOMSendOutcome: Sendable, Hashable {
    case sent
    /// Files were not sent; the transport has told the user why.
    case failed
    /// Cancelled, from the activity that showed it or by the task.
    case cancelled
}

/// What carries the files of a send. Declared here so that the queue does not
/// reach the app; the app implements it over its DICOM toolkit, on threads
/// the activity window lists and cancels. A stand-in records what it is given.
public protocol DICOMSendTransport: Sendable {
    /// Sends one part of a batch over one association by C-STORE. Cancelling
    /// the task stops it.
    func store(_ part: DICOMStorePart) async -> DICOMSendOutcome

    /// Sends every file of the request to its DICOMweb node by STOW-RS.
    func sendByDICOMweb(_ request: DICOMSendRequest) async -> DICOMSendOutcome

    /// Sends every file of the request by the direct transfer of a Horos
    /// peer; `.failed` when the peer could not be reached that way and the
    /// files are to go by C-STORE.
    func sendByDirectTransfer(_ request: DICOMSendRequest) async -> DICOMSendOutcome
}

/// The DICOM sends of the process.
///
/// A send waits for a slot: it starts when none runs, or when it makes fewer
/// than the `mostConcurrentSends` of its options; the sends waiting start in
/// the order they came, as slots come back. Once started it goes by its
/// route; by C-STORE, its batches go one after the other, and the parts of a
/// batch at the same time. A part cancelled cancels the other parts of its
/// batch and the batches after it, as a send stopped from its activity did.
///
/// The work itself is the transport's; the queue only waits for it, and
/// holds no thread meanwhile.
public actor DICOMSendQueue {
    private struct Waiter {
        let mostConcurrentSends: Int
        let start: CheckedContinuation<Void, Never>
    }

    private var running = 0
    private var waiting: [Waiter] = []
    /// The sends queued or running, for any thread to read at once.
    private nonisolated let pending = Mutex(0)

    public init() {}

    /// The sends queued or running: those still waiting for a slot count, so
    /// that quitting can warn about them as well.
    public nonisolated var pendingSends: Int {
        pending.withLock { $0 }
    }

    /// Queues the send and returns at once; it counts as pending from now.
    @discardableResult
    public nonisolated func enqueue(_ request: DICOMSendRequest,
                                    through transport: any DICOMSendTransport) -> Task<DICOMSendOutcome, Never> {
        pending.withLock { $0 += 1 }
        return Task {
            let outcome = await self.perform(request, through: transport)
            self.pending.withLock { $0 -= 1 }
            return outcome
        }
    }

    /// Sends after the sends that hold the slots, and returns once it is done.
    public func send(_ request: DICOMSendRequest, through transport: any DICOMSendTransport) async -> DICOMSendOutcome {
        pending.withLock { $0 += 1 }
        defer { pending.withLock { $0 -= 1 } }
        return await perform(request, through: transport)
    }

    private func perform(_ request: DICOMSendRequest, through transport: any DICOMSendTransport) async -> DICOMSendOutcome {
        await takeSlot(mostConcurrentSends: request.options.mostConcurrentSends)
        defer { giveBackSlot() }

        switch request.route {
        case .dicomweb:
            return await transport.sendByDICOMweb(request)
        case .directTransferFirst:
            let outcome = await transport.sendByDirectTransfer(request)
            if outcome != .failed { return outcome }
        case .cStore:
            break
        }

        var result = DICOMSendOutcome.sent
        for batch in request.batches {
            if Task.isCancelled { return .cancelled }
            switch await store(request.parts(of: batch), through: transport) {
            case .cancelled: return .cancelled
            case .failed: result = .failed
            case .sent: break
            }
        }
        return result
    }

    /// The parts of one batch, at the same time; the first one cancelled
    /// cancels the others.
    private nonisolated func store(_ parts: [DICOMStorePart], through transport: any DICOMSendTransport) async -> DICOMSendOutcome {
        await withTaskGroup(of: DICOMSendOutcome.self) { group in
            for part in parts {
                group.addTask { await transport.store(part) }
            }
            var combined = DICOMSendOutcome.sent
            for await outcome in group {
                switch outcome {
                case .cancelled:
                    if combined != .cancelled { group.cancelAll() }
                    combined = .cancelled
                case .failed:
                    if combined == .sent { combined = .failed }
                case .sent:
                    break
                }
            }
            return combined
        }
    }

    private func fits(_ mostConcurrentSends: Int) -> Bool {
        running == 0 || running + 1 < mostConcurrentSends
    }

    private func takeSlot(mostConcurrentSends: Int) async {
        if waiting.isEmpty && fits(mostConcurrentSends) {
            running += 1
            return
        }
        // The slot is taken for it by giveBackSlot(), before it resumes.
        await withCheckedContinuation { start in
            waiting.append(Waiter(mostConcurrentSends: mostConcurrentSends, start: start))
        }
    }

    private func giveBackSlot() {
        running -= 1
        var index = 0
        while index < waiting.count {
            if fits(waiting[index].mostConcurrentSends) {
                running += 1
                waiting.remove(at: index).start.resume()
            } else {
                index += 1
            }
        }
    }
}
