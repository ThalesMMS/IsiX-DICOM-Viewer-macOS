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
import IsiXDICOMNetwork

/// What the Query window shares with the threads that query and retrieve for
/// it, each value read and written under one lock.
///
/// The window's own state stays on the main actor. What is here is what those
/// threads genuinely share with it: the query manager of the query under way,
/// the answers shown while its C-FIND runs (the C-FIND reports them on its own
/// thread), whether a C-FIND runs and which threads query, the copy of the
/// window that work off the main thread reads, and the local side of the
/// results. The query manager and the answers are Objective-C objects that the
/// query nodes already share across threads; the lock guards only which ones
/// the window holds, and is never held while one of them is called.
final class QueryWindowWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var manager: QueryArrayController?
    private var liveAnswers = LiveQueryAnswers<AnyObject>()
    private var performingCFind = false
    private var queryThreads: [Thread] = []
    private var window = QueryWindowState()
    private var snapshot: HorosLocalQuerySnapshot?
    /// The study each series of a retrieve was listed under, by the series,
    /// which it does not keep.
    private let seriesStudies = NSMapTable<AnyObject, AnyObject>.weakToStrongObjects()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The query manager of the last query asked, reachable by KVC as the
    /// window's queryManager.
    var queryManager: QueryArrayController? {
        get { locked { manager } }
        set { locked { manager = newValue } }
    }

    /// The copy of the window that work off the main thread reads.
    var windowState: QueryWindowState {
        get { locked { window } }
        set { locked { window = newValue } }
    }

    /// The local side of the results, read off the main thread by the window.
    var localSnapshot: HorosLocalQuerySnapshot? {
        get { locked { snapshot } }
        set { locked { snapshot = newValue } }
    }

    /// Keeps the study a series row was listed under, for its retrieve at
    /// series level (WADO), which runs off the main thread.
    func recordStudy(_ study: AnyObject, ofSeries series: AnyObject) {
        locked { seriesStudies.setObject(study, forKey: series) }
    }

    func study(ofSeries series: AnyObject) -> AnyObject? {
        locked { seriesStudies.object(forKey: series) }
    }

    // MARK: A C-FIND under way

    /// Whether a C-FIND of the window runs; the window's outline does not
    /// start another meanwhile.
    var isPerformingCFind: Bool {
        get { locked { performingCFind } }
        set { locked { performingCFind = newValue } }
    }

    /// Cancels every thread querying for the window.
    func cancelQueryThreads() {
        for thread in locked({ queryThreads }) {
            thread.setIsCancelled(true)
        }
    }

    /// Starts a C-FIND on `thread` unless one runs: whether it may.
    func beginCFind(on thread: Thread) -> Bool {
        locked {
            guard !performingCFind else { return false }
            performingCFind = true
            if !queryThreads.contains(where: { $0 === thread }) { queryThreads.append(thread) }
            return true
        }
    }

    func endCFind(on thread: Thread) {
        locked {
            performingCFind = false
            queryThreads.removeAll { $0 === thread }
        }
    }

    // MARK: The answers shown while a C-FIND runs

    /// A query starts: its answers are shown as they come, or not (`showing`
    /// false: a query off the main thread shows them only at its end). The
    /// lists of the queries before it are not shown any more.
    func beginRealtimeAnswers(showing: Bool) {
        locked { liveAnswers.begin(showing: showing) }
    }

    /// The query is over and its complete list is shown: a list made while
    /// it ran, still on its way to the window, is not shown after it.
    func endRealtimeAnswers() {
        locked { liveAnswers.end() }
    }

    /// Whether the next answers are the first node's: they replace the list
    /// instead of joining it.
    var isFirstNode: Bool {
        get { locked { liveAnswers.isFirstNode } }
        set { locked { liveAnswers.isFirstNode = newValue } }
    }

    /// Forgets when the answers were last shown, so the next ones show now.
    func resetRealtimeUpdate() {
        locked { liveAnswers.forgetLastUpdate() }
    }

    /// Whether answers may be shown now: a list is shown and the last answers
    /// were shown more than a second ago.
    func realtimeAnswersAreDue(now: TimeInterval) -> Bool {
        locked { liveAnswers.isDue(now: now) }
    }

    /// Joins `answers`, those of the C-FIND of a node under way, to the list
    /// shown, at most once a second: the list to show and its turn, nil when
    /// it is not time or no list is shown.
    func realtimeAnswers(adding answers: [AnyObject], now: TimeInterval,
                         merge: ([AnyObject], inout [AnyObject]) -> Void)
        -> (answers: [AnyObject], turn: LiveQueryAnswers<AnyObject>.Turn)? {
        locked { liveAnswers.add(answers, now: now, merge: merge) }
    }

    /// Whether the list handed out with `turn` may be shown now; main thread,
    /// right before it is shown.
    func takeRealtimeTurn(_ turn: LiveQueryAnswers<AnyObject>.Turn) -> Bool {
        locked { liveAnswers.takeTurn(turn) }
    }
}
