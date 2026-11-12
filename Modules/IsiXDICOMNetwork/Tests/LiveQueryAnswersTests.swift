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
import Testing
@testable import IsiXDICOMNetwork

/// The lists the Query window shows while a C-FIND runs, and the order they
/// may be shown in.
struct LiveQueryAnswersTests {
    private func join(_ answers: [String], _ list: inout [String]) {
        list.append(contentsOf: answers.filter { !list.contains($0) })
    }

    /// The mutating calls, made outside the expectation macros.
    private func add(_ answers: [String], at now: TimeInterval,
                     to live: inout LiveQueryAnswers<String>) -> (answers: [String], turn: LiveQueryAnswers<String>.Turn)? {
        live.add(answers, now: now, merge: join)
    }

    private func shows(_ turn: LiveQueryAnswers<String>.Turn, _ live: inout LiveQueryAnswers<String>) -> Bool {
        live.takeTurn(turn)
    }

    private func started(firstNode: Bool = true) -> LiveQueryAnswers<String> {
        var live = LiveQueryAnswers<String>()
        live.begin(showing: true)
        live.isFirstNode = firstNode
        return live
    }

    // MARK: What is listed

    @Test func theFirstAnswersAreListedAtOnceAndTheNextOnesASecondLater() {
        var live = started()
        #expect(live.isDue(now: 100))
        let first = add(["a"], at: 100, to: &live)
        #expect(first?.answers == ["a"])
        #expect(!live.isDue(now: 100.9))
        let early = add(["a", "b"], at: 100.9, to: &live)
        #expect(early == nil)
        #expect(live.isDue(now: 101.1))
        let later = add(["a", "b", "c"], at: 101.1, to: &live)
        #expect(later?.answers == ["a", "b", "c"])
    }

    @Test func aLaterNodeJoinsTheListUnlessItHasTooManyAnswers() {
        var live = started()
        _ = add(["a", "b"], at: 100, to: &live)
        live.isFirstNode = false
        live.forgetLastUpdate()
        let joined = add(["b", "c"], at: 100.1, to: &live)
        #expect(joined?.answers == ["a", "b", "c"])

        let many = (0..<LiveQueryAnswers<String>.largestJoinedAnswer).map { "m\($0)" }
        let kept = add(many, at: 102, to: &live)
        #expect(kept?.answers == ["a", "b", "c"])
    }

    @Test func aQueryThatShowsNothingWhileItRunsListsNothing() {
        var live = LiveQueryAnswers<String>()
        live.begin(showing: false)
        live.isFirstNode = true
        #expect(!live.isDue(now: 100))
        let listed = add(["a"], at: 100, to: &live)
        #expect(listed == nil)
    }

    @Test func forgettingTheLastUpdateListsTheNextAnswersAtOnce() {
        var live = started()
        _ = add(["a"], at: 100, to: &live)
        #expect(!live.isDue(now: 100.2))
        live.forgetLastUpdate()
        #expect(live.isDue(now: 100.2))
    }

    // MARK: What may still be shown

    /// The first match of a C-FIND is listed on its thread and handed to the
    /// main queue; the C-FIND ends and the thread that asked shows all twelve
    /// matches before the main queue hands the first one over.
    @Test func aPartialListThatArrivesAfterTheCompleteOneIsNotShown() throws {
        var live = started()
        let partial = try #require(add(["study 1"], at: 100, to: &live))
        // The complete list is shown by the thread that asked; the query ends.
        live.end()
        let shown = shows(partial.turn, &live)
        #expect(!shown)
    }

    @Test func aPartialListIsShownWhileItsQueryRuns() throws {
        var live = started()
        let first = try #require(add(["a"], at: 100, to: &live))
        let firstShown = shows(first.turn, &live)
        #expect(firstShown)
        let second = try #require(add(["a", "b"], at: 102, to: &live))
        let secondShown = shows(second.turn, &live)
        #expect(secondShown)
    }

    @Test func aListMadeBeforeTheOneShownIsNotShownAfterIt() throws {
        var live = started()
        let first = try #require(add(["a"], at: 100, to: &live))
        // The node's C-FIND ends: the thread that asked lists all of its
        // answers itself, before the main queue hands the first list over.
        live.forgetLastUpdate()
        let whole = try #require(add(["a", "b", "c"], at: 100.2, to: &live))
        let wholeShown = shows(whole.turn, &live)
        let firstShown = shows(first.turn, &live)
        let wholeShownTwice = shows(whole.turn, &live)
        #expect(wholeShown)
        #expect(!firstShown)
        #expect(!wholeShownTwice)
    }

    @Test func aPartialListOfAnEarlierQueryIsNotShownDuringTheNext() throws {
        var live = started()
        let earlier = try #require(add(["earlier patient"], at: 100, to: &live))
        live.end()

        live.begin(showing: true)
        live.isFirstNode = true
        let beforeAnyAnswer = shows(earlier.turn, &live)
        let current = try #require(add(["this patient"], at: 102, to: &live))
        let afterAnAnswer = shows(earlier.turn, &live)
        let currentShown = shows(current.turn, &live)
        #expect(!beforeAnyAnswer)
        #expect(!afterAnAnswer)
        #expect(currentShown)
    }

    @Test func aQueryThatStartsWithoutTheOneBeforeEndingRefusesItsLists() throws {
        var live = started()
        let earlier = try #require(add(["a"], at: 100, to: &live))
        // A second query takes over, as one asked while another still runs.
        live.begin(showing: true)
        let duringAShownQuery = shows(earlier.turn, &live)
        live.begin(showing: false)
        let duringASilentQuery = shows(earlier.turn, &live)
        #expect(!duringAShownQuery)
        #expect(!duringASilentQuery)
    }
}
