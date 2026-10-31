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

/// Batches handed over in order, and worked on one at a time while the next
/// are being prepared: the work never runs beside itself, and a batch waits for
/// the one before it however long that takes.
///
/// Cancelling nothing is the point: what was delivered is worked on, also when
/// whoever prepares the batches stops early. `work` runs on the cooperative
/// pool, so it hands whatever blocks to a thread of its own and awaits it.
public final class IngestBatchLane<Batch: Sendable>: Sendable {
    private let batches: AsyncStream<Batch>.Continuation
    private let worker: Task<Void, Never>

    public init(_ work: @escaping @Sendable (Batch) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Batch.self)
        batches = continuation
        worker = Task {
            for await batch in stream {
                await work(batch)
            }
        }
    }

    /// Any thread, and it returns at once. Batches delivered after `finish`
    /// are not worked on.
    public func deliver(_ batch: Batch) {
        batches.yield(batch)
    }

    /// Takes no more batches, and returns when the last delivered has ended.
    public func finish() async {
        batches.finish()
        await worker.value
    }

    /// `finish`, for a thread of its own that has nothing else to do: it blocks
    /// the calling thread, so never the cooperative pool's.
    public func finishAndWait() {
        let ended = DispatchSemaphore(value: 0)
        Task {
            await finish()
            ended.signal()
        }
        ended.wait()
    }
}
