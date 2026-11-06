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

/// When the automatic cleanup runs: the timer of the process, one pass at a
/// time per database, and the one warning that the space limit is near.
///
/// One per process. A pass runs on a thread the port gives it, never here, so
/// the actor stays free while it lasts.
///
/// The space rule of an import does not come through here. It runs on the
/// import's thread, which may hold the database's writer gate or wait on a
/// context's queue, and a thread like that must not wait for an actor whose
/// work may need the same things. It only tells the actor what it found,
/// without waiting for the answer.
public actor CleanupScheduler {
    /// The time between two passes of the timer.
    public static let passInterval: Duration = .milliseconds(15 * 60 * 1000 + 2500)

    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var timer: Task<Void, Never>?
    /// The databases with a pass under way, by `cleaningIdentifier`.
    private var cleaning: Set<String> = []
    private var limitWarningClaimed = false

    /// A scheduler that waits `interval` between passes with `sleep`, which
    /// ends the timer by throwing. The clock stops while the Mac sleeps.
    public init(interval: Duration = CleanupScheduler.passInterval,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: nil, clock: .suspending) }) {
        self.interval = interval
        self.sleep = sleep
    }

    /// Starts the timer, once: databases open on several threads, each asks,
    /// and only the first makes it. It is never stopped. `pass` runs after each
    /// interval, and the next interval starts when it returns.
    public func startTimer(pass: @escaping @Sendable () async -> Void) {
        guard timer == nil else { return }
        timer = Task { [interval, sleep] in
            while (try? await sleep(interval)) != nil {
                await pass()
            }
        }
    }

    /// Starts a pass over `database`, unless one is under way or something
    /// else is cleaning it. Returns without waiting for the pass.
    public func initiate(_ database: any DatabaseCleaning) {
        let identifier = database.cleaningIdentifier
        guard !cleaning.contains(identifier), database.isIdleForCleaning() else {
            NSLog("Warning: couldn't initiate clean")
            return
        }
        cleaning.insert(identifier)
        Task {
            await database.runCleanupPass()
            finished(identifier)
        }
    }

    private func finished(_ identifier: String) {
        cleaning.remove(identifier)
    }

    /// True the first time it is asked: the warning that the space limit is
    /// near shows once per process, whichever database finds it first.
    public func claimLimitWarning() -> Bool {
        defer { limitWarningClaimed = true }
        return !limitWarningClaimed
    }
}
