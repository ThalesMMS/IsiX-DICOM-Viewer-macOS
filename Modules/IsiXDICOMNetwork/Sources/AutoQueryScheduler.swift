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
import IsiXContracts

/// The window that shows the countdown of the automatic query, on the main
/// actor: the scheduler asks it each second whether to count, and tells it
/// what is left.
@MainActor public protocol AutoQueryCountdownDisplay: AnyObject, Sendable {
    /// Whether the countdown goes on this second; false holds every instance
    /// where it is (an edit in progress, or no query asked for yet).
    func shouldCountDown() -> Bool
    /// The seconds left before the next query of each instance that counts.
    func showCountdown(_ remaining: [UUID: Int])
}

/// When each instance of the automatic query runs, and what follows a query.
///
/// Once a second, every instance with an interval counts down; one whose time
/// has come is queued, and its countdown starts again from its own interval.
/// The queued instances run one at a time, in order: the query of the
/// instance, through `AutoQueryRunning`, and, when the instance retrieves
/// automatically, the choice of what to retrieve and its start, through
/// `AutoRetrieveStarting`. What is already here is read through
/// `LocalStudyReading`.
///
/// Each instance keeps its own interval and its own settings, by its `id`; an
/// instance already waiting in the queue is not queued twice. `stop()` cancels
/// the countdown and the run in progress. The window keeps the instances and
/// hands them over after each change; the scheduler only reads them.
public actor AutoQueryScheduler {
    /// The most instances that count down, as the window allows.
    public static let maximumInstances = 40
    /// The seconds left an instance gets when a refresh is asked for now.
    static let refreshDelay = 2

    private let querying: any AutoQueryRunning
    private let retrieving: any AutoRetrieveStarting
    private let localStudies: any LocalStudyReading
    private let rules: @Sendable () -> AutoRetrieveRules
    private let now: @Sendable () -> Date
    private let tickInterval: Duration
    private weak var display: (any AutoQueryCountdownDisplay)?

    private var instances: [AutoQueryInstance] = []
    private var remaining: [UUID: Int] = [:]
    private var queue: [UUID] = []
    private var running: UUID?
    private var recent = RecentAutoRetrieves()
    private var ticking: Task<Void, Never>?
    private var runner: Task<Void, Never>?
    private var runnerGeneration = 0

    /// A scheduler over these ports. `rules` is read at each retrieve, `now`
    /// dates the retrieves remembered, and `tickInterval` is the second that
    /// counts down.
    public init(querying: any AutoQueryRunning, retrieving: any AutoRetrieveStarting, localStudies: any LocalStudyReading,
                rules: @escaping @Sendable () -> AutoRetrieveRules,
                now: @escaping @Sendable () -> Date = { Date() },
                tickInterval: Duration = .seconds(1)) {
        self.querying = querying
        self.retrieving = retrieving
        self.localStudies = localStudies
        self.rules = rules
        self.now = now
        self.tickInterval = tickInterval
    }

    // MARK: What the window hands over

    /// The window that shows the countdown; held weakly.
    public func setDisplay(_ display: (any AutoQueryCountdownDisplay)?) {
        self.display = display
    }

    /// The instances, in the window's order. An instance keeps its countdown
    /// across calls; a new one starts from its full interval, and one that is
    /// gone leaves the queue.
    public func setInstances(_ instances: [AutoQueryInstance]) {
        self.instances = instances
        let ids = Set(instances.map(\.id))
        remaining = remaining.filter { ids.contains($0.key) }
        for instance in instances where remaining[instance.id] == nil {
            remaining[instance.id] = instance.refreshInterval ?? 0
        }
        queue.removeAll { !ids.contains($0) }
    }

    /// Starts the countdown of `id` again from its interval, as choosing an
    /// interval in the window does, and shows it.
    public func restartCountdown(of id: UUID) async {
        guard let instance = instances.first(where: { $0.id == id }) else { return }
        remaining[id] = instance.refreshInterval ?? 0
        let shown = remaining
        await display?.showCountdown(shown)
    }

    /// Runs every instance that counts within the next seconds: each gets two
    /// seconds left, and a second is counted at once.
    public func refreshNow() async {
        for instance in instances.prefix(Self.maximumInstances) {
            remaining[instance.id] = Self.refreshDelay
        }
        await tick()
    }

    // MARK: The countdown

    /// Starts counting once per `tickInterval`, until `stop()`. While it
    /// counts, the countdown keeps the scheduler, and with it its ports.
    public func start() {
        guard ticking == nil else { return }
        let interval = tickInterval
        ticking = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await self.tick()
            }
        }
    }

    /// Stops the countdown, empties the queue and cancels the run in progress.
    public func stop() {
        ticking?.cancel()
        ticking = nil
        queue.removeAll()
        runner?.cancel()
        runner = nil
        runnerGeneration += 1
        running = nil
    }

    /// Whether the countdown is running.
    public var isRunning: Bool { ticking != nil }

    /// The seconds left before the next query of `id`.
    public func secondsRemaining(for id: UUID) -> Int? { remaining[id] }

    /// The instances waiting for their turn, in order, and the one running.
    public var pending: [UUID] { (running.map { [$0] } ?? []) + queue }

    /// One second: unless the display holds the countdown, each instance with
    /// an interval counts down, and those whose time has come are queued; the
    /// display then shows what is left.
    func tick() async {
        let counts = await display?.shouldCountDown() ?? true
        if counts {
            for instance in instances.prefix(Self.maximumInstances) {
                guard let interval = instance.refreshInterval else { continue }
                let left = (remaining[instance.id] ?? interval) - 1
                if left <= 0 {
                    enqueue(instance.id)
                    remaining[instance.id] = interval
                } else {
                    remaining[instance.id] = left
                }
            }
        }
        let shown = remaining
        await display?.showCountdown(shown)
    }

    // MARK: The runs

    private func enqueue(_ id: UUID) {
        if !queue.contains(id) {
            queue.append(id)
        }
        guard runner == nil else { return }
        runnerGeneration += 1
        let generation = runnerGeneration
        runner = Task { await self.drain(generation) }
    }

    /// Runs the queued instances one at a time.
    private func drain(_ generation: Int) async {
        while generation == runnerGeneration, !Task.isCancelled, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let instance = instances.first(where: { $0.id == id }) else { continue }
            running = id
            await run(instance)
            if generation == runnerGeneration { running = nil }
        }
        if generation == runnerGeneration {
            runner = nil
        }
    }

    /// The query of `instance`, then the retrieve of what it found when the
    /// instance, as saved when its query started, retrieves automatically.
    private func run(_ instance: AutoQueryInstance) async {
        let found: [AutoQueryStudy]
        do {
            found = try await querying.runQuery(of: instance)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        // The query saved the instance shown before it ran: its settings are
        // the ones handed over since.
        let current = instances.first { $0.id == instance.id } ?? instance
        guard current.autoRetrieving, await retrieving.mayStartRetrieve(), !Task.isCancelled else { return }

        let choice = AutoRetrieveChoice(instance: current, rules: rules(), querying: querying, retrieving: retrieving,
                                        localStudies: localStudies, now: now())
        var recent = self.recent
        let chosen = await choice.choose(from: found, recent: &recent)
        self.recent = recent
        guard !chosen.isEmpty, !Task.isCancelled else { return }
        await retrieving.startRetrieve(of: chosen, for: current)
    }
}
