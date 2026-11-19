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

/// The end of the launch, and what waits for it to be shown.
///
/// A link may be what launched the application, and it is handed over only as
/// the launch ends. A modal window asked for during the launch, while the main
/// nib loads, would keep that link waiting for an answer with it. Such a
/// window is given here instead: it is kept until the launch has ended and
/// then run from the main run loop, not from the main queue or the main actor,
/// which the link's request uses and which go on being served while the
/// window is unanswered.
///
/// Once the launch has ended nothing is kept: the caller shows its window
/// where it is, as it did.
@MainActor
enum LaunchEnd {
    /// Whether the launch has ended.
    private(set) static var reached = false

    /// What waits, in the order it was asked for, each under its name.
    private static var waiting: [(name: String, show: @MainActor @Sendable () -> Void)] = []

    /// Keeps `show` for the end of the launch and answers true; false once the
    /// launch has ended, when the caller goes on by itself. What is asked for
    /// again under a name that already waits is kept once.
    static func keeps(_ name: String, _ show: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard !reached else { return false }
        if !waiting.contains(where: { $0.name == name }) {
            waiting.append((name, show))
        }
        return true
    }

    /// The launch has ended: what waited is run from the main run loop, one
    /// after the other in the order it was asked for, after this returns.
    static func reach() {
        guard !reached else { return }
        reached = true
        let kept = waiting.map(\.show)
        waiting = []
        guard !kept.isEmpty else { return }
        onMainRunLoop {
            for show in kept { show() }
        }
    }
}
