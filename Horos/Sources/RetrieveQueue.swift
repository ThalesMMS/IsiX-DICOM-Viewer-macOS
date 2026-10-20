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

/// The queue of the retrieves started from the Query & Retrieve window.
///
/// Each click on a download arrow, or on Retrieve, starts its own retrieve,
/// and all of them used to transfer at once. Settings › Locations now chooses
/// between Parallel and Sequential, and in Parallel an optional limit of
/// simultaneous retrieves; Command held over the arrows queues a retrieve
/// behind the ones under way. A retrieve over the limit still starts its
/// thread at once, so Activity lists it and its Stop button works, but waits
/// for its turn before it transfers anything.
///
/// Retrieve & View and the automatic retrieves do not go through the queue
/// and do not count in it.
///
/// The state is read and written only under `condition`'s lock, from the main
/// thread and from the retrieves' threads: that is what makes it Sendable.
@objc(HorosRetrieveQueue)
public final class RetrieveQueue: NSObject, @unchecked Sendable {

    /// The preferences, as Settings › Locations writes them.
    @objc public static let modeKey = "QueryRetrieveDownloadMode"
    @objc public static let limitEnabledKey = "QueryRetrieveQueueAboveLimit"
    @objc public static let limitKey = "QueryRetrieveSimultaneousDownloads"
    @objc public static let defaultLimit = 4

    /// How many retrieves may transfer at once.
    struct Policy: Equatable {
        var sequential: Bool
        /// Parallel with a limit; nil is Parallel without one.
        var limit: Int?

        /// How many retrieves may be under way for this one to start: one in
        /// Sequential, the limit in Parallel with a limit, and in Parallel
        /// without one, no bound for a click, and one for a retrieve queued
        /// with Command, which waits for every retrieve under way to end.
        func capacity(explicitlyQueued: Bool) -> Int {
            if sequential { return 1 }
            if let limit { return max(limit, 1) }
            return explicitlyQueued ? 1 : Int.max
        }

        static func current(_ defaults: UserDefaults = .standard) -> Policy {
            let sequential = defaults.integer(forKey: RetrieveQueue.modeKey) == 1
            guard defaults.bool(forKey: RetrieveQueue.limitEnabledKey) else { return Policy(sequential: sequential, limit: nil) }
            let limit = defaults.integer(forKey: RetrieveQueue.limitKey)
            return Policy(sequential: sequential, limit: limit > 0 ? limit : RetrieveQueue.defaultLimit)
        }
    }

    /// The rule alone: which retrieves are under way and which wait, in
    /// order. A waiting retrieve starts when it is first in line and fewer
    /// retrieves are under way than its capacity.
    struct State {
        private(set) var running: Set<Int> = []
        private(set) var waiting: [(id: Int, explicitlyQueued: Bool)] = []

        /// A new retrieve: true when it starts now, false when it waits. In
        /// Parallel without a limit a click starts at once, even with
        /// retrieves queued with Command waiting.
        mutating func submit(_ id: Int, explicitlyQueued: Bool, policy: Policy) -> Bool {
            let capacity = policy.capacity(explicitlyQueued: explicitlyQueued)
            if (waiting.isEmpty || capacity == Int.max) && running.count < capacity {
                running.insert(id)
                return true
            }
            waiting.append((id, explicitlyQueued))
            return false
        }

        /// A retrieve ended, failed or was cancelled, under way or waiting.
        /// Returns those that start in its place.
        mutating func remove(_ id: Int, policy: Policy) -> [Int] {
            running.remove(id)
            waiting.removeAll { $0.id == id }
            return promote(policy: policy)
        }

        /// Starts the first waiting retrieves while there is room; also after
        /// the preferences change.
        mutating func promote(policy: Policy) -> [Int] {
            var started: [Int] = []
            while let first = waiting.first, running.count < policy.capacity(explicitlyQueued: first.explicitlyQueued) {
                waiting.removeFirst()
                running.insert(first.id)
                started.append(first.id)
            }
            return started
        }

        func isRunning(_ id: Int) -> Bool { running.contains(id) }
    }

    /// One retrieve's place in the queue, made on the main thread when the
    /// user asks for it and handed to the retrieve's thread.
    @objc(HorosRetrieveQueueTicket)
    public final class Ticket: NSObject, Sendable {
        let id: Int
        fileprivate init(id: Int) { self.id = id }
    }

    @objc(sharedQueue)
    public static let shared = RetrieveQueue()

    private let condition = NSCondition()
    private var state = State()
    private var nextID = 0

    /// A place in the queue for a retrieve the user asks for now, explicitly
    /// queued when Command is held.
    @objc(ticketExplicitlyQueued:)
    public func ticket(explicitlyQueued: Bool) -> Ticket {
        condition.lock()
        defer { condition.unlock() }
        nextID += 1
        let ticket = Ticket(id: nextID)
        _ = state.submit(ticket.id, explicitlyQueued: explicitlyQueued, policy: .current())
        return ticket
    }

    /// Whether the retrieve may transfer now.
    @objc(isRunning:)
    public func isRunning(_ ticket: Ticket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state.isRunning(ticket.id)
    }

    /// On the retrieve's thread: waits for its turn. Returns false when the
    /// thread is cancelled first; the retrieve then leaves the queue.
    @objc(waitForTurn:)
    public func waitForTurn(_ ticket: Ticket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !state.isRunning(ticket.id) {
            if Thread.current.isCancelled {
                _ = state.remove(ticket.id, policy: .current())
                condition.broadcast()
                return false
            }
            // A preference changed meanwhile can make room: look again.
            if !state.promote(policy: .current()).isEmpty { condition.broadcast(); continue }
            condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
        return true
    }

    /// The retrieve has ended, however it ended: the next ones may start.
    @objc(finish:)
    public func finish(_ ticket: Ticket) {
        condition.lock()
        defer { condition.unlock() }
        _ = state.remove(ticket.id, policy: .current())
        condition.broadcast()
    }
}
