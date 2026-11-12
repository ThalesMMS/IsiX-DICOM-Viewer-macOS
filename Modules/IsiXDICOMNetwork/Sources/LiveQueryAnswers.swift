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

/// The answers the Query window lists while the C-FINDs of one query run, and
/// which of those lists may still be shown.
///
/// A C-FIND reports each match on its own thread, and the window lists what
/// has come at most once a second: the first node's answers as they are, a
/// later node's joined to them. Each such list is partial, and it reaches the
/// window later than it was made, through the main queue. The thread that
/// asked shows the complete list itself as soon as the last C-FIND ends,
/// which can be before the main queue hands over a partial list made a moment
/// earlier. Shown then, the partial list would replace the complete one, and
/// the window would list the first match of a query that found a dozen.
///
/// So every partial list is handed out with a turn, and is shown only if
/// `takeTurn` grants it: the query it belongs to is still the one running,
/// and no list made after it was shown before. `end()` closes the query once
/// its complete list is shown, and `begin(showing:)` opens the next one;
/// either refuses every turn handed out before.
///
/// A value: the owner keeps it under its own lock.
public struct LiveQueryAnswers<Answer> {
    /// The place of a partial list among those handed out.
    public struct Turn: Equatable, Sendable {
        let query: Int
        let order: Int
    }

    /// The most answers a later node may have for them to join the list: more
    /// wait for the complete list.
    public static var largestJoinedAnswer: Int { 4000 }

    /// The list shown, nil when none is: a query off the main thread shows its
    /// answers at its end only.
    private var list: [Answer]?
    private var lastUpdate: TimeInterval = 0
    private var query = 0
    private var handedOut = 0
    private var shown = 0

    /// Whether the next answers are the first node's: they replace the list
    /// instead of joining it.
    public var isFirstNode = false

    public init() {}

    /// A query starts: its answers are listed as they come when `showing`.
    /// No list of the queries before it is shown any more.
    public mutating func begin(showing: Bool) {
        query += 1
        list = showing ? [] : nil
    }

    /// The query is over and its complete list is the one to show: no partial
    /// list is shown any more.
    public mutating func end() {
        query += 1
        list = nil
    }

    /// Forgets when answers were last listed, so that the next ones are
    /// listed at once.
    public mutating func forgetLastUpdate() {
        lastUpdate = 0
    }

    /// Whether answers may be listed now: a list is shown, and the last one
    /// was made more than a second ago.
    public func isDue(now: TimeInterval) -> Bool {
        list != nil && now - lastUpdate > 1
    }

    /// Joins `answers`, those of the C-FIND of a node under way, to the list,
    /// at most once a second: the list to show with its turn, nil when it is
    /// not time or no list is shown. The first node's answers replace the
    /// list; a later node's join it, through `merge`, unless there are
    /// `largestJoinedAnswer` or more.
    public mutating func add(_ answers: [Answer], now: TimeInterval,
                             merge: ([Answer], inout [Answer]) -> Void) -> (answers: [Answer], turn: Turn)? {
        guard var joined = list, now - lastUpdate > 1 else { return nil }
        if isFirstNode {
            joined = answers
        } else if answers.count < Self.largestJoinedAnswer {
            merge(answers, &joined)
        }
        list = joined
        lastUpdate = now
        handedOut += 1
        return (joined, Turn(query: query, order: handedOut))
    }

    /// Whether the list handed out with `turn` may be shown now, on the thread
    /// that shows: its query still runs, and no list made after it was shown.
    /// Granted, the turn is taken, and the lists made before it are refused.
    public mutating func takeTurn(_ turn: Turn) -> Bool {
        guard list != nil, turn.query == query, turn.order > shown else { return false }
        shown = turn.order
        return true
    }
}
