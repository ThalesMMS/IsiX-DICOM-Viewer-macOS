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

/// How many requests a node is sent at the same time, by every retrieve of
/// this application together: two retrieves of one node share its limit
/// instead of each having its own, and another node has a limit of its own.
///
/// A request takes a slot before it is sent and gives it back once it has
/// ended, whatever the outcome; a limit of 1 sends one request after the
/// other. Each node's limit is its own setting, from 1 to 16
/// (`NodeRequestLimiter.range`).
///
/// In the automatic mode a node's effective limit, its window, moves between
/// 1 and the node's limit with what its answers show (`AdaptiveWindow`); in the
/// fixed mode it is the limit. Either way one window per node, shared by its
/// retrieves.
///
/// @unchecked Sendable: `active`, `peaks` and `windows` are read and written
/// only while `condition` is locked.
@objc(HorosNodeRequestLimiter)
public final class NodeRequestLimiter: NSObject, @unchecked Sendable {
    @objc public static let shared = NodeRequestLimiter()

    /// The limits a node may be given.
    @objc public static let minimum = 1
    @objc public static let maximum = 16
    static var range: ClosedRange<Int> { minimum...maximum }

    /// The key of a WADO-URI node's limit in `SERVERS`. A DICOMweb node keeps
    /// its own in `DICOMwebNode.maximumRequests`.
    @objc public static let wadoKey = "WADOMaxRequests"
    /// The former setting of every WADO-URI node, read for a node without its own.
    @objc public static let legacyWADOKey = "WADOMaximumConcurrentDownloads"

    private let condition = NSCondition()
    private var active: [String: Int] = [:]
    private var peaks: [String: Int] = [:]
    private var windows: [String: AdaptiveWindow] = [:]
    /// The clock: replaced by tests.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The key of a WADO-URI node's mode in `SERVERS`; a DICOMweb node keeps
    /// its own in `DICOMwebNode.adaptiveRequests`.
    @objc public static let wadoAdaptiveKey = "WADOAdaptiveRequests"

    /// A stored limit, made valid: a number or numeric text is clamped into
    /// 1...16; anything else gives `fallback`, itself clamped.
    @objc(limitForStoredValue:fallback:)
    public static func limit(forStoredValue value: Any?, fallback: Int) -> Int {
        let number: Int?
        if let value = value as? NSNumber { number = value.intValue }
        else if let value = value as? String, let parsed = Int(value.trimmingCharacters(in: .whitespaces)) { number = parsed }
        else { number = nil }
        return min(max(number ?? fallback, minimum), maximum)
    }

    /// A WADO-URI node's limit: its own, or the former global setting.
    @objc(WADOLimitForServer:defaults:)
    public static func wadoLimit(forServer server: [AnyHashable: Any]?, defaults: UserDefaults) -> Int {
        let legacy = defaults.object(forKey: legacyWADOKey) == nil ? 10 : defaults.integer(forKey: legacyWADOKey)
        return limit(forStoredValue: server?[wadoKey], fallback: legacy)
    }

    /// The key a WADO-URI node is limited under: where its requests go.
    @objc(WADOKeyForServer:)
    public static func wadoKey(forServer server: [AnyHashable: Any]?) -> String {
        let field = { (name: String) in (server?[name]).map { "\($0)" } ?? "" }
        return ["WADO", field("Address"), field("WADOPort"), field("WADOUrl"), field("WADOhttps")].joined(separator: " ")
    }

    /// Waits for one of `limit` slots of `node`, and takes it. Returns NO,
    /// without a slot, as soon as `cancelled` says so.
    @objc(acquireNode:limit:cancelled:)
    public func acquire(node: String, limit: Int, cancelled: () -> Bool) -> Bool {
        acquire(node: node, limit: limit, adaptive: false, cancelled: cancelled)
    }

    /// The same, in the node's mode: automatic, a slot of its window, and
    /// not while the node has asked to wait (Retry-After or backoff).
    @objc(acquireNode:limit:adaptive:cancelled:)
    public func acquire(node: String, limit: Int, adaptive: Bool, cancelled: () -> Bool) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while !free(node, limit: limit, adaptive: adaptive) {
            if cancelled() { return false }
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        if cancelled() { return false }
        take(node)
        return true
    }

    /// Takes a slot if one of `limit` is free, without waiting.
    @objc(tryAcquireNode:limit:)
    public func tryAcquire(node: String, limit: Int) -> Bool {
        tryAcquire(node: node, limit: limit, adaptive: false)
    }

    @objc(tryAcquireNode:limit:adaptive:)
    public func tryAcquire(node: String, limit: Int, adaptive: Bool) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard free(node, limit: limit, adaptive: adaptive) else { return false }
        take(node)
        return true
    }

    // Called with the condition locked: whether a request may start now.
    private func free(_ node: String, limit: Int, adaptive: Bool) -> Bool {
        let cap = min(max(limit, Self.minimum), Self.maximum)
        guard adaptive else {
            windows[node] = nil
            return active[node, default: 0] < cap
        }
        let time = now()
        var window = windows[node] ?? AdaptiveWindow(ceiling: cap, at: time)
        window.refresh(ceiling: cap, at: time)
        windows[node] = window
        return active[node, default: 0] < window.size && !window.paused(at: time)
    }

    /// What one request of a node in the automatic mode showed; a node in
    /// the fixed mode ignores it. `retryAfter` is the answer's Retry-After
    /// header, if any. Returns the node's window after it.
    @objc(reportNode:outcome:latency:retryAfter:)
    @discardableResult
    public func report(node: String, outcome: RequestOutcome, latency: TimeInterval, retryAfter: String?) -> Int {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        guard var window = windows[node] else { return 0 }
        let before = window.size
        window.record(outcome, latency: latency, retryAfter: retryAfter, at: now())
        windows[node] = window
        if window.size != before {
            NSLog("---- requests at once to one node, automatic: %d -> %d (%@)", before, window.size, outcome.label)
        }
        return window.size
    }

    /// The node's window in the automatic mode, 0 in the fixed mode.
    @objc(windowForNode:)
    public func window(node: String) -> Int { condition.lock(); defer { condition.unlock() }; return windows[node]?.size ?? 0 }

    /// How long the node has asked to wait from now, 0 when it has not.
    @objc(pauseForNode:)
    public func pause(node: String) -> TimeInterval {
        condition.lock(); defer { condition.unlock() }
        guard let window = windows[node] else { return 0 }
        return max(0, (window.pausedUntil ?? 0) - now())
    }

    /// The outcome of an HTTP status, for the automatic mode.
    @objc(outcomeForStatus:)
    public static func outcome(forStatus status: Int) -> RequestOutcome { RequestOutcome.of(status: status) }

    /// A node's mode, from its setting.
    @objc(adaptiveForStoredValue:)
    public static func adaptive(forStoredValue value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? ((value as? String).map { ["1", "yes", "true"].contains($0.lowercased()) } ?? false)
    }

    @objc public static var adaptiveHelp: String {
        NSLocalizedString("Automatic: fewer requests at once while the node answers that it is busy (HTTP 429 or 503) or slows down, honoring its Retry-After, then gradually back up to the Parallel Requests limit. Authentication, certificate and other errors never raise it. Off: always the Parallel Requests limit.", comment: "automatic request limit")
    }

    // Called with the condition locked.
    private func take(_ node: String) {
        let count = active[node, default: 0] + 1
        active[node] = count
        peaks[node] = max(peaks[node, default: 0], count)
    }

    /// Gives back a slot taken by `acquire` or `tryAcquire`.
    @objc(releaseNode:)
    public func release(node: String) {
        condition.lock()
        active[node] = max(0, active[node, default: 0] - 1)
        if active[node] == 0 { active[node] = nil }
        condition.broadcast()
        condition.unlock()
    }

    /// The requests of `node` in flight now, and the most there were at once
    /// since the last `resetPeak`: the effective concurrency.
    @objc(activeForNode:)
    public func active(node: String) -> Int { condition.lock(); defer { condition.unlock() }; return active[node, default: 0] }

    @objc(peakForNode:)
    public func peak(node: String) -> Int { condition.lock(); defer { condition.unlock() }; return peaks[node, default: 0] }

    @objc(resetPeakForNode:)
    public func resetPeak(node: String) { condition.lock(); peaks[node] = active[node, default: 0]; condition.unlock() }
}

/// What a request's answer says to the automatic mode.
@objc(HorosRequestOutcome)
public enum RequestOutcome: Int {
    /// Answered: its latency counts.
    case success
    /// The node said it is busy: HTTP 429 or 503.
    case throttled
    /// Timed out, cut short or another 5xx: worth asking again, later.
    case transient
    /// Says nothing about the node's capacity: authentication, certificate,
    /// configuration, an object refused, cancellation.
    case neutral

    var label: String { ["answered", "busy", "transient failure", "neutral"][rawValue] }

    /// The outcome of an HTTP status, 0 when there was none.
    public static func of(status: Int) -> RequestOutcome {
        switch status {
        case 200..<300: return .success
        case 429, 503: return .throttled
        case 408, 425, 500..<600: return .transient
        default: return .neutral
        }
    }

}

/// One node's window in the automatic mode. Deterministic, for a given order
/// of outcomes and times:
///
/// - it starts at the node's limit, the operator's ceiling, and never goes
///   above it or below 1;
/// - a busy or transient answer halves it, at most once per `cooldown`, so a
///   burst of answers to requests sent together counts once; it also makes the
///   node wait: a valid Retry-After (seconds or an HTTP date, at most
///   `maximumPause`), otherwise 1, 2, 4... seconds with each answer in a row,
///   at most `maximumBackoff`;
/// - a latency of more than `slowFactor` times the best seen takes one off,
///   at most once per `cooldown`;
/// - `window` answers in a row, none busy or slow for `cooldown`, add one, up
///   to the limit: it grows back gradually;
/// - neutral answers change nothing;
/// - after `expiry` without a request it starts over.
struct AdaptiveWindow {
    static let cooldown: TimeInterval = 5
    static let maximumPause: TimeInterval = 60
    static let maximumBackoff: TimeInterval = 30
    static let slowFactor = 4.0
    static let expiry: TimeInterval = 300

    private(set) var ceiling: Int
    private(set) var size: Int
    private(set) var pausedUntil: TimeInterval?
    private var answeredInRow = 0
    private var busyInRow = 0
    private var lastDecrease: TimeInterval?
    private var bestLatency: TimeInterval?
    private var lastActivity: TimeInterval

    init(ceiling: Int, at time: TimeInterval) {
        self.ceiling = max(1, ceiling)
        size = self.ceiling
        lastActivity = time
    }

    func paused(at time: TimeInterval) -> Bool { (pausedUntil ?? 0) > time }

    mutating func refresh(ceiling: Int, at time: TimeInterval) {
        if time - lastActivity > Self.expiry { self = AdaptiveWindow(ceiling: ceiling, at: time); return }
        self.ceiling = max(1, ceiling)
        size = min(size, self.ceiling)
        lastActivity = time
    }

    mutating func record(_ outcome: RequestOutcome, latency: TimeInterval, retryAfter: String?, at time: TimeInterval) {
        lastActivity = time
        switch outcome {
        case .neutral:
            return
        case .throttled, .transient:
            answeredInRow = 0
            busyInRow += 1
            if pastCooldown(at: time) { size = max(1, size / 2); lastDecrease = time }
            let wait = Self.retryAfter(retryAfter, at: Date()) ?? min(pow(2, Double(busyInRow - 1)), Self.maximumBackoff)
            pausedUntil = max(pausedUntil ?? 0, time + wait)
        case .success:
            busyInRow = 0
            if latency > 0 {
                if let best = bestLatency, latency > best * Self.slowFactor {
                    answeredInRow = 0
                    if pastCooldown(at: time), size > 1 { size -= 1; lastDecrease = time }
                    return
                }
                bestLatency = min(bestLatency ?? latency, latency)
            }
            answeredInRow += 1
            if answeredInRow >= size, size < ceiling, pastCooldown(at: time) {
                size += 1
                answeredInRow = 0
            }
        }
    }

    // Whether the last decrease is at least a cooldown ago: the window moves
    // again, down or up, only then.
    private func pastCooldown(at time: TimeInterval) -> Bool {
        guard let last = lastDecrease else { return true }
        return time - last >= Self.cooldown
    }

    /// A Retry-After header's wait: seconds, or an HTTP date from `now`; nil
    /// when it is absent or not valid, and at most `maximumPause`.
    static func retryAfter(_ value: String?, at now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.allSatisfy(\.isNumber), let seconds = Double(value) { return min(seconds, maximumPause) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maximumPause)
    }
}
