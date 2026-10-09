//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import ObjectiveC

/// How far an activity is, in items: «123/1.234» when the total is known,
/// «123» when it is not.
///
/// The count goes into the thread's progress details, which the activity
/// list shows on the right of the task's name and the progress window under
/// its bar. A retrieve, a send or an import reports one item at a time, and
/// thousands of them would each redraw the activity list: the details change
/// at most `minimumInterval` apart, except for the first and the last item.
@objc(HorosActivityProgressCount)
public final class ActivityProgressCount: NSObject {
    @objc public static let minimumInterval: TimeInterval = 0.25

    private static let formatterKey = "HorosActivityProgressCountFormatter"

    /// One formatter per thread: the counts are written by the threads that
    /// do the work, and a formatter is not shared between threads here.
    private static func formatter(locale: Locale) -> NumberFormatter {
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[formatterKey] as? NumberFormatter, formatter.locale == locale {
            return formatter
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        formatter.locale = locale
        dictionary[formatterKey] = formatter
        return formatter
    }

    /// `done/total`, grouped as the locale groups digits; `done` alone when
    /// the total is unknown (0 or less). A peer that reports more items than
    /// it announced shows the larger number as the total, never «5/3».
    @objc(textWithDone:total:locale:)
    public static func text(done: Int, total: Int, locale: Locale) -> String {
        let formatter = formatter(locale: locale)
        func format(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        let done = max(done, 0)
        guard total > 0 else { return format(done) }
        return "\(format(done))/\(format(max(done, total)))"
    }

    @objc(textWithDone:total:)
    public static func text(done: Int, total: Int) -> String {
        text(done: done, total: total, locale: .current)
    }

    /// Whether a count may be shown now: the first one, the last one, and
    /// otherwise one every `minimumInterval`.
    @objc(shouldUpdateWithDone:total:now:last:)
    public static func shouldUpdate(done: Int, total: Int, now: TimeInterval, last: TimeInterval) -> Bool {
        if last <= 0 || (total > 0 && done >= total) {
            return true
        }
        return now - last >= minimumInterval
    }

    /// What a thread last showed and what waits to be shown, under `lock`.
    private final class State: @unchecked Sendable {
        var last: TimeInterval = 0
        var pending: (done: Int, total: Int, setsProgress: Bool)?
        var flushScheduled = false
        var received = 0
    }

    private static let stateKey = IdentityToken()
    private static let lock = NSLock()

    /// Called with `lock` held.
    private static func state(of thread: Thread) -> State {
        if let state = objc_getAssociatedObject(thread, stateKey.key) as? State {
            return state
        }
        let state = State()
        objc_setAssociatedObject(thread, stateKey.key, state, .OBJC_ASSOCIATION_RETAIN)
        return state
    }

    /// Called with `lock` held, so that a count written late never replaces a
    /// newer one.
    private static func show(done: Int, total: Int, setsProgress: Bool, on thread: Thread) {
        thread.progressDetails = text(done: done, total: total)
        if setsProgress && total > 0 {
            thread.progress = CGFloat(min(Double(max(done, 0)) / Double(total), 1))
        }
    }

    /// Shows `done` of `total` items on the thread. With `setsProgress`, the
    /// bar follows the count too; otherwise it stays with the code that
    /// already moves it. A count held back by the interval is shown when the
    /// interval ends, so the last one of a burst is never lost.
    @objc(setDone:total:setsProgress:onThread:)
    public static func set(done: Int, total: Int, setsProgress: Bool, on thread: Thread?) {
        guard let thread else { return }
        lock.lock()
        defer { lock.unlock() }
        let state = state(of: thread)
        let now = ProcessInfo.processInfo.systemUptime
        if shouldUpdate(done: done, total: total, now: now, last: state.last) {
            state.last = now
            state.pending = nil
            show(done: done, total: total, setsProgress: setsProgress, on: thread)
            return
        }
        state.pending = (done, total, setsProgress)
        if !state.flushScheduled {
            state.flushScheduled = true
            let wait = max(minimumInterval - (now - state.last), 0.01)
            // NSThread's properties are atomic and its observers hop to the
            // main thread; the thread is only written to under `lock`.
            nonisolated(unsafe) let target = thread
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) {
                flush(target)
            }
        }
    }

    private static func flush(_ thread: Thread) {
        lock.lock()
        defer { lock.unlock() }
        let state = state(of: thread)
        state.flushScheduled = false
        guard let pending = state.pending else { return }
        state.pending = nil
        state.last = ProcessInfo.processInfo.systemUptime
        show(done: pending.done, total: pending.total, setsProgress: pending.setsProgress, on: thread)
    }

    @objc(setDone:total:onThread:)
    public static func set(done: Int, total: Int, on thread: Thread?) {
        set(done: done, total: total, setsProgress: false, on: thread)
    }

    /// One more item received by a thread that has no total (an incoming
    /// C-STORE association), and the count shown.
    @objc(countOneOnThread:)
    public static func countOne(on thread: Thread?) {
        guard let thread else { return }
        lock.lock()
        let state = state(of: thread)
        state.received += 1
        let received = state.received
        lock.unlock()
        set(done: received, total: 0, on: thread)
    }
}
