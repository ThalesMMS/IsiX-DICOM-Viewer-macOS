/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The loads in progress of the files a cache keeps parsed, and the wait of
/// what must run while there is none: a load is counted for as long as it may
/// take an entry of the cache, and the purge of the cache waits, for a limited
/// time, until no load is counted, then runs with the count held at zero.
///
/// The count is the condition of a lock, taken once to count a load in and
/// once to count it out. What is counted runs under the guard the application
/// gives: an NSException unwinds Swift frames without running their `defer`,
/// so the guard catches what the body raises and hands it back, the load is
/// counted out, and the caller raises it again. A load left counted would
/// make every later purge wait its whole limit and drop nothing.
@objc(IsiXLoadsInProgress)
public final class LoadsInProgress: NSObject, Sendable {

    /// Runs `body` and answers what it raised; nil when it returned.
    public typealias ExceptionGuard = @Sendable (_ body: () -> Void) -> NSException?

    /// What became of a body that waits for no load to be in progress.
    public enum Wait: Equatable {
        /// It ran, with no load in progress and none started meanwhile, and
        /// raised `raised`, which the caller raises again.
        case ran(raised: NSException?)
        /// The limit passed with `inProgress` loads still counted: it did not run.
        case gaveUp(inProgress: Int)
    }

    /// How long a purge waits for the loads in progress, in seconds.
    public static let purgeLimit: TimeInterval = 10

    /// The number of loads in progress, as its condition.
    private let count = NSConditionLock(condition: 0)
    private let caught: ExceptionGuard
    private let limit: TimeInterval

    /// `caught` is the application's exception guard; `limit` is how long
    /// whenNoneInProgress(_:) waits, in seconds.
    public init(waitingAtMost limit: TimeInterval = LoadsInProgress.purgeLimit, guardedBy caught: @escaping ExceptionGuard) {
        self.limit = limit
        self.caught = caught
        super.init()
    }

    /// The number of loads in progress.
    @objc public var inProgress: Int { count.condition }

    private func countIn() {
        count.lock()
        count.unlock(withCondition: count.condition + 1)
    }

    private func countOut() {
        count.lock()
        count.unlock(withCondition: count.condition - 1)
    }

    /// Runs `body` counted as one load in progress, under the guard: the load
    /// is counted out once on every way out of `body`, its return or what it
    /// raised, which is answered for the caller to raise again.
    public func counted(_ body: () -> Void) -> NSException? {
        countIn()
        let raised = caught(body)
        countOut()
        return raised
    }

    /// Runs `body` once no load is in progress, waiting the limit at most,
    /// and keeps loads from starting while it runs. With no load counted it
    /// does not wait. The count is left when `body` raises too.
    public func whenNoneInProgress(_ body: () -> Void) -> Wait {
        guard count.lock(whenCondition: 0, before: Date(timeIntervalSinceNow: limit)) else {
            return .gaveUp(inProgress: count.condition)
        }
        let raised = caught(body)
        count.unlock()
        return .ran(raised: raised)
    }
}
