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

/// When the queue of incoming files is imported: the timer of the process, and
/// the passes each database asks for, one at a time per database.
///
/// One per process, in the process graph. A pass runs on a thread the port
/// gives it, never here, so the actor stays free while it lasts, and whoever
/// asks returns at once: a request that arrives during a pass is remembered, as
/// one, and answered by one more pass when it ends. What a pass moves stays the
/// port's; nothing here knows Core Data or DCMTK.
public actor IngestScheduler {
    /// How many passes of one database are running. Read without the actor, by
    /// a retrieve that must not wait for a long import to know that it is
    /// long. It counts passes that started, not passes asked for: a retrieve
    /// asks for one each time it looks, and it would never see the import idle.
    private final class Gauge: Sendable {
        private let passes = Atomic<Int>(0)

        var isActive: Bool { passes.load(ordering: .acquiring) != 0 }

        func started() {
            passes.add(1, ordering: .releasing)
        }

        func ended() {
            passes.subtract(1, ordering: .releasing)
        }
    }

    private let sleep: @Sendable (Duration) async throws -> Void
    private var timer: Task<Void, Never>?
    private var timerSeconds = 0
    /// The passes running, by `ingestIdentifier`.
    private var running: [String: Task<Void, Never>] = [:]
    /// The database of each request that arrived during a pass.
    private var wanted: [String: any IngestPassRunning] = [:]
    private var stopped = false
    private let gauges = Mutex<[String: Gauge]>([:])

    /// A scheduler that waits between the timer's ticks with `sleep`, which
    /// ends the timer by throwing. The clock stops while the Mac sleeps.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: nil, clock: .suspending) }) {
        self.sleep = sleep
    }

    /// Whether a pass over the database named `identifier` is running now.
    public nonisolated func isPassRunning(_ identifier: String) -> Bool {
        gauges.withLock { $0[identifier] }?.isActive ?? false
    }

    /// Starts a pass over `database`, now if none is running and it is ready,
    /// or once the one running has ended. Returns without waiting for it.
    public func request(_ database: any IngestPassRunning) {
        guard !stopped else { return }
        let identifier = database.ingestIdentifier
        guard running[identifier] == nil else {
            wanted[identifier] = database
            return
        }
        guard database.isReadyForPass() else { return }
        let gauge = gauges.withLock { gauges in
            if let gauge = gauges[identifier] { return gauge }
            let gauge = Gauge()
            gauges[identifier] = gauge
            return gauge
        }
        gauge.started()
        running[identifier] = Task {
            await database.runPass()
            gauge.ended()
            passEnded(identifier)
        }
    }

    private func passEnded(_ identifier: String) {
        running[identifier] = nil
        if let next = wanted.removeValue(forKey: identifier) {
            request(next)
        }
    }

    /// Follows the interval the preferences ask for, in seconds: `tick` runs
    /// after each one, and the next starts when it returns. Zero stops the
    /// timer; the same interval leaves it running and its time alone.
    public func syncTimer(seconds: Int, tick: @escaping @Sendable () async -> Void) {
        guard !stopped, seconds != timerSeconds else { return }
        timer?.cancel()
        timer = nil
        timerSeconds = seconds
        guard seconds > 0 else { return }
        timer = Task { [sleep] in
            while (try? await sleep(.seconds(seconds))) != nil, !Task.isCancelled {
                await tick()
            }
        }
    }

    /// Quitting: no pass starts from now on, the timer ends, and the passes
    /// running are cancelled. They end on their own threads.
    public func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        wanted.removeAll()
        for pass in running.values {
            pass.cancel()
        }
    }
}
