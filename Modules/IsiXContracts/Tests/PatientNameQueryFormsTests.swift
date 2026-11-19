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
@testable import IsiXContracts

/// A study a node answers: its UID and the term that found it.
private struct Found: Equatable {
    let uid: String?
    let term: String
}

@Suite struct PatientNameQueryFormsTests {
    typealias Forms = PatientNameQueryForms

    // The Query window's other spellings of a name typed in lower case.
    private let capitals = ["KOWALSKI JAN"]

    @Test func twoWordsAreAskedAsTypedThenInCapitalsThenInBothOrders() {
        #expect(Forms.wordOrders(of: "Kowalski Jan") == ["Kowalski^Jan", "Jan^Kowalski"])
        #expect(Forms.steps(for: "Kowalski Jan", spellings: capitals, anyWordOrder: true) == [
            ["Kowalski Jan"],
            ["KOWALSKI JAN"],
            ["Kowalski^Jan", "Jan^Kowalski"],
            ["KOWALSKI^JAN", "JAN^KOWALSKI"],
        ])
        #expect(Forms.steps(for: "Jan Kowalski", spellings: [], anyWordOrder: true) == [
            ["Jan Kowalski"],
            ["Jan^Kowalski", "Kowalski^Jan"],
        ])
    }

    @Test func threeWordsTakeEachWordAsTheFamilyNameWithTheOthersInTheOrderTyped() {
        #expect(Forms.wordOrders(of: "Jan Maria Kowalski") ==
                ["Jan^Maria Kowalski", "Maria^Jan Kowalski", "Kowalski^Jan Maria", "Jan Maria^Kowalski"])
        #expect(Forms.steps(for: "Jan Maria Kowalski", spellings: [], anyWordOrder: true).last?.count == 4)
        // A word typed twice gives its order once.
        #expect(Forms.wordOrders(of: "Jan Jan") == ["Jan^Jan"])
    }

    @Test func aCompoundFamilyNameIsAskedAsTheBrowsersDistantSearchAlwaysAskedIt() {
        // DA SILVA^MARIA: no single word is the family name, every word but
        // the last is, as the last space made «^» in the browser's search.
        #expect(Forms.wordOrders(of: "Da Silva Maria").last == "Da Silva^Maria")
        #expect(Forms.steps(for: "Da Silva Maria", spellings: ["DA SILVA MARIA"], anyWordOrder: true) == [
            ["Da Silva Maria"],
            ["DA SILVA MARIA"],
            ["Da^Silva Maria", "Silva^Da Maria", "Maria^Da Silva", "Da Silva^Maria"],
            ["DA^SILVA MARIA", "SILVA^DA MARIA", "MARIA^DA SILVA", "DA SILVA^MARIA"],
        ])
        // Typed with its «^», it is not asked again among the word orders.
        #expect(Forms.steps(for: "Da Silva^Maria", spellings: [], anyWordOrder: true).last ==
                ["Da^Silva Maria", "Silva^Da Maria", "Maria^Da Silva"])
        // Two words have it already, as their first order.
        #expect(Forms.wordOrders(of: "Silva Maria") == ["Silva^Maria", "Maria^Silva"])
    }

    @Test func aCommaSeparatesWordsAsASpaceDoes() {
        #expect(Forms.words(of: "Kowalski, Jan") == ["Kowalski", "Jan"])
        #expect(Forms.wordOrders(of: "Kowalski,Jan") == ["Kowalski^Jan", "Jan^Kowalski"])
        #expect(Forms.steps(for: "Kowalski, Jan", spellings: [], anyWordOrder: true) == [
            ["Kowalski, Jan"],
            ["Kowalski^Jan", "Jan^Kowalski"],
        ])
    }

    @Test func aCaretAlreadyTypedSeparatesWordsAndItsOrderIsNotAskedTwice() {
        #expect(Forms.wordOrders(of: "Kowalski^Jan") == ["Kowalski^Jan", "Jan^Kowalski"])
        #expect(Forms.steps(for: "Kowalski^Jan", spellings: ["KOWALSKI^JAN"], anyWordOrder: true) == [
            ["Kowalski^Jan"],
            ["KOWALSKI^JAN"],
            ["Jan^Kowalski"],
            ["JAN^KOWALSKI"],
        ])
    }

    @Test func aWildcardTypedStaysInItsWordAndAWordOfWildcardsIsLeftOut() {
        #expect(Forms.wordOrders(of: "Kowal* Jan") == ["Kowal*^Jan", "Jan^Kowal*"])
        #expect(Forms.wordOrders(of: "J?n Kowalski") == ["J?n^Kowalski", "Kowalski^J?n"])
        #expect(Forms.words(of: "Kowalski *") == ["Kowalski"])
        #expect(Forms.wordOrders(of: "Kowalski *").isEmpty)
        #expect(Forms.wordOrders(of: "* Kowalski ** Jan") == ["Kowalski^Jan", "Jan^Kowalski"])
    }

    @Test func oneWordIsAskedOnceThenInItsOtherSpellingsOnly() {
        #expect(Forms.wordOrders(of: "Kowalski").isEmpty)
        #expect(Forms.steps(for: "kowalski", spellings: ["KOWALSKI"], anyWordOrder: true) == [["kowalski"], ["KOWALSKI"]])
        #expect(Forms.steps(for: "KOWALSKI", spellings: [], anyWordOrder: true) == [["KOWALSKI"]])
        #expect(Forms.steps(for: "", spellings: [], anyWordOrder: true).isEmpty)
    }

    @Test func withoutAnyWordOrderTheNameIsAskedAsTypedThenInItsOtherSpellings() {
        #expect(Forms.steps(for: "żółw jan", spellings: ["ŻÓŁW JAN", "ZOLW JAN"], anyWordOrder: false) ==
                [["żółw jan"], ["ŻÓŁW JAN"], ["ZOLW JAN"]])
        // A spelling that repeats an earlier term is not asked again.
        #expect(Forms.steps(for: "ZOLW", spellings: ["ZOLW"], anyWordOrder: false) == [["ZOLW"]])
    }

    @Test func theAnswersOfAStepAreMergedByStudyInstanceUIDAndTheFirstStepThatFindsEnds() {
        let steps = Forms.steps(for: "Jan Kowalski", spellings: ["JAN KOWALSKI"], anyWordOrder: true)
        var asked: [String] = []
        let found = Forms.answers(of: steps, ask: { term -> Forms.Answer<Found> in
            asked.append(term)
            switch term {
            // The node keeps KOWALSKI^JAN: one form in each order finds it,
            // and a study without a UID is never taken for another.
            case "Jan^Kowalski": return .init([Found(uid: "1.2", term: term), Found(uid: nil, term: term)])
            case "Kowalski^Jan": return .init([Found(uid: "1.2", term: term), Found(uid: "1.3", term: term), Found(uid: nil, term: term)])
            default: return .init([])
            }
        }, uid: \.uid)
        #expect(asked == ["Jan Kowalski", "JAN KOWALSKI", "Jan^Kowalski", "Kowalski^Jan"],
                "the capitals of the word orders are not asked once the word orders found something")
        #expect(found.queries == 4)
        #expect(found.studies == [Found(uid: "1.2", term: "Jan^Kowalski"), Found(uid: nil, term: "Jan^Kowalski"),
                                  Found(uid: "1.3", term: "Kowalski^Jan"), Found(uid: nil, term: "Kowalski^Jan")])
    }

    @Test func aNameFoundAsTypedIsAskedOnce() {
        var asked = 0
        let found = Forms.answers(of: Forms.steps(for: "Kowalski Jan", spellings: ["KOWALSKI JAN"], anyWordOrder: true),
                                  ask: { term -> Forms.Answer<Found> in asked += 1; return .init([Found(uid: "1", term: term)]) }, uid: \.uid)
        #expect(asked == 1 && found.queries == 1 && found.studies.count == 1)
    }

    @Test func aStopEndsTheSearchBeforeTheNextQuery() async {
        var stopping = false
        var asked: [String] = []
        let found = Forms.answers(of: [["a"], ["b", "c"], ["d"]], stops: { stopping }, ask: { term -> Forms.Answer<Found> in
            asked.append(term)
            if term == "b" { stopping = true }
            return .init([])
        }, uid: \.uid)
        #expect(asked == ["a", "b"] && found.queries == 2)

        // The form whose queries suspend asks in the same order.
        let order = AskedTerms()
        let suspended = await Forms.answers(of: Forms.steps(for: "Jan Kowalski", spellings: [], anyWordOrder: true),
                                            ask: { term -> Forms.Answer<Found> in
                                                await order.add(term)
                                                return .init(term.contains("^") ? [Found(uid: "9", term: term)] : [])
                                            }, uid: \.uid)
        #expect(await order.terms == ["Jan Kowalski", "Jan^Kowalski", "Kowalski^Jan"])
        #expect(suspended.studies == [Found(uid: "9", term: "Jan^Kowalski")] && suspended.queries == 3)
    }

    @Test func aQueryTheNodeDidNotAnswerEndsTheSearch() async {
        let steps = Forms.steps(for: "jan kowalski", spellings: ["JAN KOWALSKI"], anyWordOrder: true)
        // A node that cannot be reached, or a query given up with Escape: the
        // name is asked once, not in each of its six forms.
        var asked: [String] = []
        let unreachable = Forms.answers(of: steps, ask: { term -> Forms.Answer<Found> in
            asked.append(term)
            return .init([], answered: false)
        }, uid: \.uid)
        #expect(asked == ["jan kowalski"] && unreachable.queries == 1 && unreachable.studies.isEmpty)

        // A query that fails inside a step ends it there, with what it and
        // the queries before it found.
        asked = []
        let failing = Forms.answers(of: steps, ask: { term -> Forms.Answer<Found> in
            asked.append(term)
            switch term {
            case "jan^kowalski": return .init([Found(uid: "1", term: term)], answered: false)
            default: return .init([])
            }
        }, uid: \.uid)
        #expect(asked == ["jan kowalski", "JAN KOWALSKI", "jan^kowalski"])
        #expect(failing.studies == [Found(uid: "1", term: "jan^kowalski")] && failing.queries == 3)

        // The same for the search whose queries suspend.
        let order = AskedTerms()
        let suspended = await Forms.answers(of: steps, ask: { term -> Forms.Answer<Found> in
            await order.add(term)
            return .init([], answered: term != "JAN KOWALSKI")
        }, uid: \.uid)
        #expect(await order.terms == ["jan kowalski", "JAN KOWALSKI"] && suspended.queries == 2)
    }

    @Test func aStudyIsMergedWithTheEarlierQueriesOfItsStepOnlyNotWithinItsOwnAnswer() {
        // The node answers 1.2 twice on purpose (the preference that keeps
        // duplicate StudyInstanceUIDs): both stay; the next order finding 1.2
        // again adds nothing, and 1.4 is new.
        let found = Forms.answers(of: [["Jan^Kowalski", "Kowalski^Jan"]], ask: { term -> Forms.Answer<Found> in
            switch term {
            case "Jan^Kowalski": return .init([Found(uid: "1.2", term: term), Found(uid: "1.2", term: term + " again")])
            default: return .init([Found(uid: "1.2", term: term), Found(uid: "1.4", term: term)])
            }
        }, uid: \.uid)
        #expect(found.studies == [Found(uid: "1.2", term: "Jan^Kowalski"), Found(uid: "1.2", term: "Jan^Kowalski again"),
                                  Found(uid: "1.4", term: "Kowalski^Jan")])
        // A later step is reached only when the earlier found nothing, so it
        // has nothing to merge with.
        #expect(found.queries == 2)
    }
}

private actor AskedTerms {
    var terms: [String] = []
    func add(_ term: String) { terms.append(term) }
}
