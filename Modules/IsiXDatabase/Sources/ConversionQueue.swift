/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXContracts
import Synchronization

/// The files of the databases waiting to be converted, and the worker of each
/// database, one at a time.
///
/// One per process, in the process graph. A batch runs on a thread the port
/// gives it, never here, so the actor stays free while it lasts.
///
/// Asking and looking do not enter the actor. A scan and a retrieve are plain
/// threads: the scan must return, and a file it moved aside must count as work
/// from that moment on, not from when a task reaches the actor. So the batches
/// wait in a lane under a mutex, in the order they were asked for, the lane
/// lasts from the first batch to the end of the last one, and the actor only
/// says which worker runs. A lane keeps the worker it began with, and with it
/// the database, for as long as there is work. That reference is what keeps the
/// database open: the application registers a database by its folder only while
/// it lives, and opening one at a folder already open answers that same object,
/// or a database independent of it. So whoever asks while a lane lasts asks for
/// the database the lane converts in, never another one at the same path.
public actor ConversionQueue {
    private struct Lane {
        let runner: any ConversionRunning
        var waiting: [FileConversionBatch] = []
        var isRunning = false
        /// Whether the batch running is one the scan of the incoming folder moved.
        var isRunningScanned = false
        /// Those who wait for the lane to end.
        var idle: [DispatchSemaphore] = []
        /// Those who wait only for what the scan moved.
        var scannedIdle: [DispatchSemaphore] = []

        var waitingFiles: Int {
            waiting.reduce(0) { $0 + $1.files.count }
        }

        /// Whether a batch the scan moved is waiting or being converted.
        var hasScanned: Bool {
            isRunningScanned || waiting.contains { $0.isFromScan }
        }
    }

    private let lanes = Mutex<[String: Lane]>([:])
    /// The worker running, by `conversionIdentifier`.
    private var workers: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Queues `batch`, published before this returns. Any thread, and it never
    /// waits. What the scan moved joins what the scan moved before and has not
    /// started: the worker took everything queued at once, however many scans
    /// had added to it.
    public nonisolated func enqueue(_ batch: FileConversionBatch, runner: any ConversionRunning) {
        guard !batch.files.isEmpty else { return }
        let identifier = runner.conversionIdentifier
        let joined: (runner: any ConversionRunning, waitingFiles: Int)? = lanes.withLock { lanes in
            var lane = lanes[identifier] ?? Lane(runner: runner)
            let same = batch.isFromScan ? lane.waiting.firstIndex {
                $0.isFromScan && $0.mode == batch.mode && $0.destination == batch.destination
            } : nil
            if let same {
                lane.waiting[same].files += batch.files
            } else {
                lane.waiting.append(batch)
            }
            lanes[identifier] = lane
            return lane.isRunning ? (lane.runner, lane.waitingFiles) : nil
        }
        if let joined {
            joined.runner.filesQueued(joined.waitingFiles)
        }
        Task { await startNext(identifier) }
    }

    /// Whether a batch of the database named `identifier` is waiting or being
    /// converted now. From the batch's `enqueue` to the end of its `run`.
    public nonisolated func isConverting(_ identifier: String) -> Bool {
        lanes.withLock { $0[identifier] != nil }
    }

    /// Blocks the calling thread until nothing of `identifier` is waiting or
    /// being converted. Whether there was anything to wait for. Never from the
    /// thread of a batch of the same database, which would wait for itself.
    public nonisolated func waitUntilIdle(_ identifier: String) -> Bool {
        let ended = DispatchSemaphore(value: 0)
        let isBusy = lanes.withLock { lanes in
            guard lanes[identifier] != nil else { return false }
            lanes[identifier]?.idle.append(ended)
            return true
        }
        if isBusy { ended.wait() }
        return isBusy
    }

    /// Blocks the calling thread until no batch the scan of the incoming folder
    /// of `identifier` moved is waiting or being converted, the one running
    /// included; a request of a selection or of a plug-in does not hold it,
    /// unless it runs before such a batch. Whether there was anything to wait
    /// for. Never from the thread of a batch of the same database.
    public nonisolated func waitForScannedFiles(_ identifier: String) -> Bool {
        let ended = DispatchSemaphore(value: 0)
        let isBusy = lanes.withLock { lanes in
            guard lanes[identifier]?.hasScanned == true else { return false }
            lanes[identifier]?.scannedIdle.append(ended)
            return true
        }
        if isBusy { ended.wait() }
        return isBusy
    }

    private func startNext(_ identifier: String) {
        guard workers[identifier] == nil else { return }
        let next: (runner: any ConversionRunning, batch: FileConversionBatch)? = lanes.withLock { lanes in
            guard var lane = lanes[identifier], !lane.waiting.isEmpty else { return nil }
            let batch = lane.waiting.removeFirst()
            lane.isRunning = true
            lane.isRunningScanned = batch.isFromScan
            lanes[identifier] = lane
            return (lane.runner, batch)
        }
        guard let next else { return }
        workers[identifier] = Task {
            await next.runner.run(next.batch)
            batchEnded(identifier)
        }
    }

    private func batchEnded(_ identifier: String) {
        workers[identifier] = nil
        let released: [DispatchSemaphore] = lanes.withLock { lanes in
            guard var lane = lanes[identifier] else { return [] }
            lane.isRunning = false
            lane.isRunningScanned = false
            guard lane.waiting.isEmpty else {
                guard !lane.hasScanned else {
                    lanes[identifier] = lane
                    return []
                }
                let scannedIdle = lane.scannedIdle
                lane.scannedIdle = []
                lanes[identifier] = lane
                return scannedIdle
            }
            lanes[identifier] = nil
            return lane.idle + lane.scannedIdle
        }
        released.forEach { $0.signal() }
        startNext(identifier)
    }
}
