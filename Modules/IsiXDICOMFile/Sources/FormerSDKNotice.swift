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

/// What a selector of the plugin SDK of Horos and OsiriX says, once for the
/// process, when it answers a plugin built for that SDK and has nothing to do:
/// the feature behind it is gone, or the work is done another way.
public enum FormerSDKNotice {
    private static let reported = Mutex<Set<String>>([])

    public static func inert(_ type: String, _ selector: String, because reason: String) {
        guard reported.withLock({ $0.insert(type + " " + selector).inserted }) else { return }
        NSLog("%@", "[\(type) \(selector)] is answered for plugins built for Horos or OsiriX and does nothing: \(reason)")
    }
}
