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

/// What a window does after a pause, on the main actor: a refresh once the
/// database is quiet, a fit to the window once the layout has settled, a
/// retry while a dialog is up. Each call has a name, and cancelling a name
/// cancels every call of it still waiting.
///
/// It keeps the behaviour of `perform(_:with:afterDelay:)` and
/// `cancelPreviousPerformRequests(withTarget:selector:object:)`, which it
/// replaces: a call is not merged with another of the same name, it runs
/// from a timer of the main run loop, in the default mode unless told
/// otherwise, and so never while a modal panel or a menu holds the run loop
/// in its own mode. Running from the run loop and not from a block of the
/// main queue, a call may open a modal panel itself.
@MainActor
final class DeferredCalls {
    private struct Waiting {
        let timer: Timer
        let body: @MainActor () -> Void
    }

    private var waiting: [String: [UInt64: Waiting]] = [:]
    private var lastNumber: UInt64 = 0

    /// Made anywhere, so that an object of any isolation can keep one.
    nonisolated init() {}

    /// Runs `body` after `delay` seconds, unless `name` is cancelled first.
    func perform(_ name: String, after delay: TimeInterval, inModes modes: [RunLoop.Mode] = [.default],
                 _ body: @escaping @MainActor () -> Void) {
        lastNumber += 1
        let number = lastNumber
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.run(name, number) }
        }
        waiting[name, default: [:]][number] = Waiting(timer: timer, body: body)
        for mode in modes { RunLoop.main.add(timer, forMode: mode) }
    }

    /// Cancels every call of `name` still waiting.
    func cancel(_ name: String) {
        for call in (waiting.removeValue(forKey: name) ?? [:]).values { call.timer.invalidate() }
    }

    /// Cancels every call still waiting.
    func cancelAll() {
        for name in Array(waiting.keys) { cancel(name) }
    }

    /// Whether a call of `name` is still waiting.
    func isWaiting(_ name: String) -> Bool {
        !(waiting[name]?.isEmpty ?? true)
    }

    private func run(_ name: String, _ number: UInt64) {
        guard let call = waiting[name]?.removeValue(forKey: number) else { return }
        if waiting[name]?.isEmpty == true { waiting[name] = nil }
        call.body()
    }
}
