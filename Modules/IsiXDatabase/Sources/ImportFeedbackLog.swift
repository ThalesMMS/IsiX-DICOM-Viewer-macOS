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

/// What the imports of one database have told the person, which the window
/// reads whichever context imported: the files the last import refused, and
/// whether the volume being too full to import into was said. A main database
/// shares its log with its independent databases, so that two contexts neither
/// lose a refusal nor say the same full volume twice.
public final class ImportFeedbackLog: Sendable {
    private struct State {
        var refusalSummary: String?
        var storageWarningShown = false
    }

    private let state = Mutex(State())

    public init() {}

    /// What the last import refused, its refusals joined by "; ".
    public var refusalSummary: String? {
        state.withLock { $0.refusalSummary }
    }

    /// Adds the refusals of one batch: the scan of the incoming folder
    /// imports batch after batch, and a clean batch must not erase the
    /// refusals of the one before. An empty summary adds nothing.
    public func addRefusals(_ summary: String?) {
        guard let summary, !summary.isEmpty else { return }
        state.withLock { state in
            if let current = state.refusalSummary, !current.isEmpty {
                state.refusalSummary = current + "; " + summary
            } else {
                state.refusalSummary = summary
            }
        }
    }

    /// Replaces the refusals: nil when an import with files of its own starts.
    public func setRefusalSummary(_ summary: String?) {
        state.withLock { $0.refusalSummary = summary }
    }

    /// Whether the full volume was said and not yet followed by room again.
    public var storageWarningShown: Bool {
        state.withLock { $0.storageWarningShown }
    }

    /// Records whether the volume is too full now; answers whether that
    /// changed, which starts or ends an episode of the warning.
    public func recordStorage(unavailable: Bool) -> Bool {
        state.withLock { state in
            let changed = state.storageWarningShown != unavailable
            state.storageWarningShown = unavailable
            return changed
        }
    }
}
