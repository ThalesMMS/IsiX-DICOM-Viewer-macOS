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

/// What the opening of a study waits for away from the main thread: studies
/// asked of a node and retrieved, on a thread of their own that the Activity
/// window lists with its Cancel button, so that the windows go on answering
/// meanwhile.
///
/// The opening goes on once, from the main run loop, when the work ends, when
/// its thread is cancelled in Activity (the work ends early then), or when
/// the time allowed runs out, whichever comes first. Work still running when
/// the time runs out, or when the opening is given up, is left to end in
/// Activity: a retrieve cut in the middle leaves part of a study in the
/// database, which nothing asks the node for again.
///
/// `waiting` is told when the wait begins and, once, when it is over, however
/// it ends and before the opening goes on: what shows that a study is being
/// opened is shown and taken away there.
@MainActor final class StudyOpeningWait {
    private var proceed: (@MainActor @Sendable () -> Void)?
    private var deadline: Task<Void, Never>?
    private let waiting: @MainActor @Sendable (Bool) -> Void

    /// Whether the opening still waits: it neither went on nor was given up.
    var isPending: Bool { proceed != nil }

    /// Starts `work` on a thread named `activity` and calls `proceed` when it
    /// ends or after `limit`.
    init(activity: String, limit: Duration, work: @escaping @Sendable () -> Void,
         waiting: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
         then proceed: @escaping @MainActor @Sendable () -> Void) {
        self.proceed = proceed
        self.waiting = waiting
        waiting(true)
        Task { [weak self] in
            await ActivityThread.run(name: activity, work)
            self?.finish()
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.finish()
        }
    }

    /// Gives the opening up: it does not go on. The work is not cancelled.
    func abandon() {
        deadline?.cancel()
        deadline = nil
        guard proceed != nil else { return }
        proceed = nil
        waiting(false)
    }

    private func finish() {
        guard proceed != nil else { return }
        deadline?.cancel()
        deadline = nil
        // Opening a study may show a sheet or an alert, and a modal run from a
        // main-actor task serves neither the main actor nor the main queue
        // until it is answered. An opening given up before the run loop comes
        // to this block does not go on either.
        onMainRunLoop {
            guard let proceed = self.proceed else { return }
            self.proceed = nil
            self.waiting(false)
            proceed()
        }
    }
}
