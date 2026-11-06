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

/// When a notification of the application reaches the Notification Center.
///
/// A study arrives in many batches and each batch reports itself. Posted under a
/// new identifier every time, that made hundreds of notifications per study, which
/// the Notification Center kept and saved again at each arrival until usernoted
/// ran at 220% CPU. Each kind now has one identifier, so a notification replaces
/// the previous one of its kind, and a burst is delivered at most once every
/// `interval` seconds with the latest text. Only a notification that comes
/// `quietSound` seconds or more after the previous delivery of its kind makes a
/// sound, so a burst makes one at most.
///
/// The policy only decides; whoever holds it delivers, and asks `flush` when a
/// delivery it was told to make later is due.
public struct NotificationBurstPolicy: Sendable {

    /// The text of a notification.
    public struct Notice: Sendable, Equatable {
        public let title: String?
        public let body: String?

        public init(title: String?, body: String?) {
            self.title = title
            self.body = body
        }
    }

    /// What to do with a notification just posted.
    public enum Decision: Sendable, Equatable {
        /// Deliver it now, with a sound or without.
        case deliverNow(sound: Bool)
        /// It is the first of a burst too close to the last delivery: ask
        /// `flush` after this many seconds, which hands back the latest text.
        case deliverLater(after: TimeInterval)
        /// A later delivery of its kind is already due; it replaced the text
        /// that delivery will show.
        case replacedPending
    }

    /// The shortest time between two deliveries of one kind.
    public let interval: TimeInterval
    /// How long a kind stays silent before its next delivery makes a sound.
    public let quietSound: TimeInterval

    /// When each kind was last delivered (seconds since the reference date).
    private var delivered: [String: TimeInterval] = [:]
    /// The latest text of each kind whose delivery is due later.
    private var pending: [String: Notice] = [:]

    public init(interval: TimeInterval = 10, quietSound: TimeInterval = 60) {
        self.interval = interval
        self.quietSound = quietSound
    }

    /// The kind a notification name stands for: the name, or "horos" for none.
    public static func kind(of name: String?) -> String {
        if let name, !name.isEmpty { return name }
        return "horos"
    }

    /// A notification of `kind` posted at `now`.
    public mutating func post(_ notice: Notice, kind: String, at now: TimeInterval) -> Decision {
        let last = delivered[kind]
        let wait = last.map { $0 + interval - now } ?? 0
        if wait > 0 {
            let scheduled = pending[kind] != nil
            pending[kind] = notice
            return scheduled ? .replacedPending : .deliverLater(after: wait)
        }
        delivered[kind] = now
        return .deliverNow(sound: last.map { now - $0 >= quietSound } ?? true)
    }

    /// The delivery of `kind` told to be made later is due at `now`: the latest
    /// text posted since, delivered without a sound; nil when nothing waits.
    public mutating func flush(kind: String, at now: TimeInterval) -> Notice? {
        guard let notice = pending.removeValue(forKey: kind) else { return nil }
        delivered[kind] = now
        return notice
    }
}
