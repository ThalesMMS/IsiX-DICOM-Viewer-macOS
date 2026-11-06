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
import Synchronization

/// How many receptions each thread is running, for the Dock's receiving arrow,
/// which shows while any thread has one.
///
/// The listener and import threads start and end receptions; any thread may
/// ask. A thread is counted under its identity, and the counter keeps a strong
/// reference to it while it has an entry: the identity of a thread that ended
/// could otherwise be given to a new one, which would then find the old count.
/// The reference goes with the entry, once, whatever the number of receptions.
public final class ReceivingThreadCounter: Sendable {

    /// A thread held only to keep it alive: nothing reads it, so the reference
    /// may cross threads although Thread does not say it is Sendable.
    private final class KeptThread: @unchecked Sendable {
        let thread: Thread
        init(_ thread: Thread) { self.thread = thread }
    }

    private struct Entry: Sendable {
        /// Held while the thread has an entry, so that its identity is not reused.
        let kept: KeptThread
        var receptions: Int
    }

    private let entries = Mutex<[ObjectIdentifier: Entry]>([:])

    public init() {}

    /// `thread` starts a reception. Answers how many threads are receiving.
    @discardableResult
    public func begin(on thread: Thread = .current) -> Int {
        let kept = KeptThread(thread)
        return entries.withLock { entries in
            let key = ObjectIdentifier(kept.thread)
            if entries[key] == nil {
                entries[key] = Entry(kept: kept, receptions: 1)
            } else {
                entries[key]!.receptions += 1
            }
            return entries.count
        }
    }

    /// `thread` ends a reception; an end without a start changes nothing. The
    /// thread is let go with its last reception. Answers how many threads are
    /// receiving.
    @discardableResult
    public func end(on thread: Thread = .current) -> Int {
        let key = ObjectIdentifier(thread)
        return entries.withLock { entries in
            if var entry = entries[key] {
                entry.receptions -= 1
                entries[key] = entry.receptions > 0 ? entry : nil
            }
            return entries.count
        }
    }

    /// How many threads are receiving.
    public var receivingThreads: Int {
        entries.withLock { $0.count }
    }

    /// The receptions `thread` is running.
    public func receptions(on thread: Thread) -> Int {
        let key = ObjectIdentifier(thread)
        return entries.withLock { $0[key]?.receptions ?? 0 }
    }
}
