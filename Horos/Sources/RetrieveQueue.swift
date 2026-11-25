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
/// Move to Top, in Activity, starts a waiting retrieve ahead of one under
/// way: that one cancels its transfer, goes back to the line without leaving
/// Activity, and asks again in its next turn for what is still missing.
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
    ///
    /// A retrieve put ahead of those under way (`startAhead`) waits first in
    /// line, among the others put ahead, until one under way has yielded: the
    /// one started last. That one counts as under way until its transfer has
    /// stopped (`yielded`), then waits right behind the retrieves put ahead,
    /// to resume.
    struct State {
        /// The retrieves under way, in the order they started.
        private(set) var running: [Int] = []
        private(set) var waiting: [(id: Int, explicitlyQueued: Bool)] = []
        /// The retrieves under way asked to yield, in the order they were asked.
        private(set) var yielding: [Int] = []
        /// The waiting retrieves put ahead of those under way: the first of the line.
        private(set) var ahead: Set<Int> = []
        /// The waiting retrieves that yielded, and resume in their turn.
        private(set) var interrupted: Set<Int> = []

        /// A new retrieve: true when it starts now, false when it waits. In
        /// Parallel without a limit a click starts at once, even with
        /// retrieves queued with Command waiting.
        mutating func submit(_ id: Int, explicitlyQueued: Bool, policy: Policy) -> Bool {
            let capacity = policy.capacity(explicitlyQueued: explicitlyQueued)
            if (waiting.isEmpty || capacity == Int.max) && running.count < capacity {
                running.append(id)
                return true
            }
            waiting.append((id, explicitlyQueued))
            return false
        }

        /// A retrieve ended, failed or was cancelled, under way or waiting.
        /// Returns those that start in its place.
        mutating func remove(_ id: Int, policy: Policy) -> [Int] {
            running.removeAll { $0 == id }
            waiting.removeAll { $0.id == id }
            interrupted.remove(id)
            return promote(policy: policy)
        }

        /// Starts the first waiting retrieves while there is room; also after
        /// the preferences change.
        mutating func promote(policy: Policy) -> [Int] {
            var started: [Int] = []
            while let first = waiting.first, running.count < policy.capacity(explicitlyQueued: first.explicitlyQueued) {
                waiting.removeFirst()
                running.append(first.id)
                interrupted.remove(first.id)
                started.append(first.id)
            }
            balance()
            return started
        }

        func isRunning(_ id: Int) -> Bool { running.contains(id) }

        /// A waiting retrieve's place in line, from 1; nil when it is under
        /// way or gone.
        func position(_ id: Int) -> Int? {
            waiting.firstIndex { $0.id == id }.map { $0 + 1 }
        }

        /// Puts a waiting retrieve at `index` of the line, kept within it; the
        /// retrieves under way do not move. Returns whether its place changed.
        /// The retrieves put ahead of those under way stay first: another one
        /// goes no further up than right behind them, and one of them moved
        /// behind another retrieve waits its turn as that one does.
        mutating func move(_ id: Int, to index: Int) -> Bool {
            guard let from = waiting.firstIndex(where: { $0.id == id }) else { return false }
            var to = min(max(index, 0), waiting.count - 1)
            if ahead.contains(id) {
                if to >= ahead.count { ahead.remove(id) }
            } else {
                to = max(to, ahead.count)
            }
            guard to != from else { return false }
            waiting.insert(waiting.remove(at: from), at: to)
            balance()
            return true
        }

        /// Whether `startAhead` would change anything for this retrieve: it
        /// waits, and is not already the first to start.
        func canStartAhead(_ id: Int) -> Bool {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
            return index > 0 || !ahead.contains(id)
        }

        /// Starts a waiting retrieve ahead of those under way. In Parallel
        /// without a limit it starts at once and nothing yields. Otherwise it
        /// goes first in line and starts if there is room; if there is none,
        /// the retrieve started last is asked to yield (`mustYield`) and this
        /// one starts when it has (`yielded`). Returns whether anything changed.
        mutating func startAhead(_ id: Int, policy: Policy) -> Bool {
            guard canStartAhead(id), let from = waiting.firstIndex(where: { $0.id == id }) else { return false }
            let entry = waiting.remove(at: from)
            if policy.capacity(explicitlyQueued: false) == Int.max {
                interrupted.remove(id)
                running.append(id)
                balance()
                return true
            }
            waiting.insert(entry, at: 0)
            ahead.insert(id)
            _ = promote(policy: policy)
            return true
        }

        /// Whether a retrieve under way was asked to yield: it cancels its
        /// transfer and then says `yielded`.
        func mustYield(_ id: Int) -> Bool { yielding.contains(id) }

        /// Whether a waiting retrieve yielded, and resumes in its turn.
        func isInterrupted(_ id: Int) -> Bool { interrupted.contains(id) }

        /// A retrieve under way has stopped its transfer to yield: it waits
        /// right behind the retrieves put ahead, to resume, and they start in
        /// its place. Asked to yield or not: one that stopped after the
        /// request was withdrawn waits first, and starts again if there is
        /// room. Returns those that start.
        mutating func yielded(_ id: Int, policy: Policy) -> [Int] {
            guard let index = running.firstIndex(of: id) else { return [] }
            running.remove(at: index)
            let stillAhead = waiting.prefix { ahead.contains($0.id) }.count
            waiting.insert((id, false), at: stillAhead)
            interrupted.insert(id)
            return promote(policy: policy)
        }

        /// One retrieve under way yields for each retrieve put ahead that
        /// still waits: the ones started last. A request no longer needed, as
        /// when another retrieve ended meanwhile, is withdrawn.
        private mutating func balance() {
            let inLine = Set(waiting.map { $0.id })
            ahead.formIntersection(inLine)
            yielding.removeAll { !running.contains($0) }
            while yielding.count > ahead.count { yielding.removeLast() }
            while yielding.count < ahead.count, let next = running.last(where: { !yielding.contains($0) }) {
                yielding.append(next)
            }
        }
    }

    /// What a queued retrieve asks for, and which of it has ended: a retrieve
    /// of several studies or series that yielded resumes with the ones that
    /// had not ended, and does not ask again for the others.
    ///
    /// @unchecked Sendable: `ended` is read and written only under `lock`, by
    /// the retrieve's thread and the thread of each of its transfers.
    final class Turns: @unchecked Sendable {
        private let lock = NSLock()
        private let items: [AnyObject]
        private var ended: Set<ObjectIdentifier> = []

        init(_ items: [Any]) {
            self.items = items.map { $0 as AnyObject }
        }

        /// The transfer of `item` ended without being cancelled.
        func markEnded(_ item: AnyObject) {
            lock.lock(); defer { lock.unlock() }
            ended.insert(ObjectIdentifier(item))
        }

        func hasEnded(_ item: AnyObject) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return ended.contains(ObjectIdentifier(item))
        }

        /// What is still to be asked for, in order.
        var remaining: [Any] {
            lock.lock(); defer { lock.unlock() }
            return items.filter { !ended.contains(ObjectIdentifier($0)) }
        }
    }

    /// The rows of Activity with the waiting retrieves in the order of the
    /// line: they trade the places they hold among themselves, and every other
    /// row, a retrieve under way or another task, stays where it is.
    /// `position` is a row's place in line, nil when it does not wait.
    static func arranged<Row>(_ rows: [Row], position: (Row) -> Int?) -> [Row] {
        let waiting = rows.enumerated().compactMap { entry in position(entry.element).map { (slot: entry.offset, position: $0) } }
        guard waiting.count > 1 else { return rows }
        var arranged = rows
        for (slot, source) in zip(waiting.map(\.slot), waiting.sorted { $0.position < $1.position }.map(\.slot)) {
            arranged[slot] = rows[source]
        }
        return arranged
    }

    /// The place in line, from 0, of a waiting row dropped above `row`: the
    /// waiting rows above the gap, the dragged one aside. `waits` says which
    /// rows wait.
    static func index(ofRow dragged: Int, droppedAbove row: Int, waits: [Bool]) -> Int {
        waits.prefix(max(row, 0)).enumerated().filter { $0.element && $0.offset != dragged }.count
    }

    /// Where Activity moves a waiting retrieve in the line; to the top, it
    /// also starts ahead of the retrieves under way.
    @objc(HorosRetrieveQueueMove)
    public enum Move: Int {
        case top, up, down
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

    /// The key of a retrieve's ticket in its thread's dictionary, where
    /// Activity finds it from the row.
    @objc public static let threadKey = "HorosRetrieveQueueTicket"

    private let condition = NSCondition()
    private var state = State()
    private var nextID = 0
    /// The names the user gave retrieves in Activity, until they end.
    private var labels: [Int: String] = [:]

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
        waitForTurn(ticket, whileWaiting: nil)
    }

    /// As waitForTurn:, telling `whileWaiting` the retrieve's place in line
    /// each time it changes, from the retrieve's thread and outside the lock.
    @objc(waitForTurn:whileWaiting:)
    public func waitForTurn(_ ticket: Ticket, whileWaiting: ((Int) -> Void)?) -> Bool {
        var told: Int?
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
            if let whileWaiting, let position = state.position(ticket.id), position != told {
                told = position
                condition.unlock()
                whileWaiting(position)
                condition.lock()
                continue
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
        return true
    }

    /// The retrieve's place in line, from 1; 0 when it is under way or gone.
    @objc(positionOf:)
    public func position(of ticket: Ticket) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return state.position(ticket.id) ?? 0
    }

    /// On the retrieve's thread, in its turn: runs `transfer` on a thread of
    /// its own and waits for it. A transfer is stopped by cancelling its
    /// thread and a cancelled thread stays cancelled, so the thread Activity
    /// lists, which lasts through every turn, is not the one that transfers.
    /// `start` makes that thread, hands it to its first argument before it
    /// starts, starts it and returns it. `whileRunning` is given the
    /// transfer's thread at each look, to show on the retrieve's thread what
    /// it reports, until the retrieve is asked to yield. Cancelling the retrieve cancels
    /// the transfer. When the retrieve must yield, `willYield` is called, the
    /// transfer is cancelled and, once it has stopped, the retrieve is back
    /// in line, unless `resumes` says nothing is left to ask for. Returns
    /// whether it is back in line: the caller then waits for its turn again.
    func runTurn(_ ticket: Ticket, pollInterval: TimeInterval = 0.1,
                 start: (_ configure: (Thread) -> Void, _ transfer: @escaping @Sendable () -> Void) -> Thread,
                 willYield: () -> Void = {}, whileRunning: (Thread) -> Void = { _ in }, resumes: () -> Bool = { true },
                 transfer: @escaping @Sendable () -> Void) -> Bool {
        let retrieve = Thread.current
        let thread = start({ $0.threadDictionary[RetrieveQueue.threadKey] = ticket }, transfer)
        var asked = false
        while !thread.isFinished {
            if retrieve.isCancelled {
                thread.cancel()
            } else if !asked && mustYield(ticket) {
                asked = true
                willYield()
                thread.cancel()
            }
            if !asked { whileRunning(thread) }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if !asked { whileRunning(thread) }
        guard asked, !retrieve.isCancelled, resumes() else { return false }
        condition.lock()
        defer { condition.unlock() }
        _ = state.yielded(ticket.id, policy: .current())
        condition.broadcast()
        return true
    }

    /// Whether a retrieve under way was asked to yield to one put ahead of it.
    @objc(mustYield:)
    public func mustYield(_ ticket: Ticket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state.mustYield(ticket.id)
    }

    /// Whether a waiting retrieve yielded, and resumes in its turn.
    @objc(isInterrupted:)
    public func isInterrupted(_ ticket: Ticket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state.isInterrupted(ticket.id)
    }

    /// Whether Move to Top does anything for this retrieve: it waits, and is
    /// not already the first to start.
    @objc(canMoveToTop:)
    public func canMoveToTop(_ ticket: Ticket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state.canStartAhead(ticket.id)
    }

    /// How many retrieves wait in line.
    @objc public var waitingCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return state.waiting.count
    }

    /// Moves a waiting retrieve in the line. Up and down, the ones under way
    /// go on, and a retrieve moved first may start at once, if its capacity
    /// allows it. To the top, it starts ahead of them: at once in Parallel
    /// without a limit, and otherwise as soon as the retrieve started last
    /// has yielded, which resumes afterwards.
    @discardableResult
    @objc(move:ticket:)
    public func move(_ move: Move, _ ticket: Ticket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let position = state.position(ticket.id) else { return false }
        let index: Int
        switch move {
        case .top:
            guard state.startAhead(ticket.id, policy: .current()) else { return false }
            condition.broadcast()
            return true
        case .up: index = position - 2
        case .down: index = position
        }
        guard state.move(ticket.id, to: index) else { return false }
        _ = state.promote(policy: .current())
        condition.broadcast()
        return true
    }

    /// Puts a waiting retrieve at `index` of the line, from 0, as a row
    /// dragged in Activity asks. Returns whether its place changed.
    @discardableResult
    @objc(moveTicket:toIndex:)
    public func move(_ ticket: Ticket, toIndex index: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard state.move(ticket.id, to: index) else { return false }
        _ = state.promote(policy: .current())
        condition.broadcast()
        return true
    }

    /// The name the user gave the retrieve, or nil.
    @objc(labelOf:)
    public func label(of ticket: Ticket) -> String? {
        condition.lock()
        defer { condition.unlock() }
        return labels[ticket.id]
    }

    /// Names the retrieve until it ends; an empty name removes it.
    @objc(setLabel:of:)
    public func setLabel(_ label: String?, of ticket: Ticket) {
        condition.lock()
        defer { condition.unlock() }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        labels[ticket.id] = trimmed.isEmpty ? nil : trimmed
    }

    /// The ticket of a queued retrieve's thread, or nil.
    @objc(ticketOfThread:)
    public static func ticket(of thread: Thread) -> Ticket? {
        thread.threadDictionary[threadKey] as? Ticket
    }

    /// The retrieve has ended, however it ended: the next ones may start.
    @objc(finish:)
    public func finish(_ ticket: Ticket) {
        condition.lock()
        defer { condition.unlock() }
        _ = state.remove(ticket.id, policy: .current())
        labels[ticket.id] = nil
        condition.broadcast()
    }
}
