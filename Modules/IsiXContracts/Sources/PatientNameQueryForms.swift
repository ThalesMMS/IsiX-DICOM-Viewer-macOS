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

/// How a patient name typed in a search is asked of a node, by C-FIND or by
/// QIDO, in the Query window and in the browser's distant search (PACS
/// On-Demand) alike.
///
/// A node compares the name it is sent as it is, component by component: one
/// that keeps «NOWAK^JAN» finds nothing for «Nowak Jan», since a space does
/// not separate the components, nor for «Jan Nowak», since the family name
/// comes first. So the name is asked in steps, each one only when every step
/// before it found nothing:
///
/// 1. the name as typed;
/// 2. each other spelling of it the caller gives, one step each (the Query
///    window's: in capitals, then in capitals without diacritics);
/// 3. with `anyWordOrder`, the word orders of the name as typed, then those of
///    each other spelling, one step each: each word in turn as the family
///    name, «^», then the other words, in the order typed, as the given names;
///    for three words or more, also every word but the last as the family
///    name, which a compound family name («Da Silva Maria») needs.
///
/// Every term of a step is asked, and their answers are merged by
/// StudyInstanceUID. A term an earlier step asked is not asked again. A name of
/// one word has no word orders: it is asked once, then in its other spellings.
/// A query the node did not answer, failed or given up, ends the search: the
/// next one would fail or be given up again, each with its own notice. The
/// caller sends each term with a trailing wildcard, as the name as typed
/// always was.
public enum PatientNameQueryForms {
    /// What one query of the name answered.
    public struct Answer<Study> {
        /// The studies it found, those of a failed query included.
        public var studies: [Study]
        /// Whether the node answered it: false when the query failed or was
        /// given up (Escape, the progress window's Stop, a cancelled search).
        public var answered: Bool

        public init(_ studies: [Study], answered: Bool = true) {
            self.studies = studies
            self.answered = answered
        }
    }

    /// The words of `typed`: what spaces, commas and «^» separate. A word made
    /// only of `*` narrows nothing and is left out; a wildcard inside a word
    /// stays in it.
    public static func words(of typed: String) -> [String] {
        typed.split { $0.isWhitespace || $0 == "," || $0 == "^" }
            .map(String.init)
            .filter { word in word.contains { $0 != "*" } }
    }

    /// The name with «^» between the family name and the given names, in every
    /// order the search tries: each word as the family name, the others after
    /// it in the order typed; then, for three words or more, every word but
    /// the last as the family name and the last as the given name, the form
    /// the browser's distant search always asked a name of several words in.
    /// None for a name of fewer than two words.
    public static func wordOrders(of typed: String) -> [String] {
        let words = words(of: typed)
        guard words.count > 1 else { return [] }
        var orders: [String] = []
        for index in words.indices {
            var given = words
            let family = given.remove(at: index)
            let order = family + "^" + given.joined(separator: " ")
            if !orders.contains(order) { orders.append(order) }
        }
        let compound = words.dropLast().joined(separator: " ") + "^" + words[words.count - 1]
        if !orders.contains(compound) { orders.append(compound) }
        return orders
    }

    /// The terms to ask, step by step, for the name `typed` (without the white
    /// space around it), given its other `spellings` in the order they are
    /// tried. Empty when nothing was typed.
    public static func steps(for typed: String, spellings: [String], anyWordOrder: Bool) -> [[String]] {
        guard !typed.isEmpty else { return [] }
        var asked: Set<String> = []
        var steps: [[String]] = []
        func add(_ terms: [String]) {
            var step: [String] = []
            for term in terms where !term.isEmpty && !asked.contains(term) {
                asked.insert(term)
                step.append(term)
            }
            if !step.isEmpty { steps.append(step) }
        }
        add([typed])
        for spelling in spellings { add([spelling]) }
        if anyWordOrder {
            for spelling in [typed] + spellings { add(wordOrders(of: spelling)) }
        }
        return steps
    }

    /// What the steps find: the terms of each step asked in turn with `ask`,
    /// until a step finds something, a query is not answered, or `stops` says
    /// to stop, which it is asked before every query but the first. The
    /// answers of the terms of a step are merged by `uid`: a study an earlier
    /// term of the step found is kept once, as it was first found, and one
    /// without a UID is always kept. The answer of one query is kept whole,
    /// since the node's own answer may hold a UID twice on purpose (the
    /// preference that keeps duplicate StudyInstanceUIDs). Also how many
    /// queries were asked.
    public static func answers<Study>(of steps: [[String]], stops: () -> Bool = { false },
                                      ask: (String) -> Answer<Study>, uid: (Study) -> String?) -> (studies: [Study], queries: Int) {
        var merge = Merge<Study>()
        for step in steps {
            merge.startStep()
            for term in step {
                if merge.queries > 0 && stops() { return merge.result }
                guard merge.add(ask(term), uid: uid) else { return merge.result }
            }
            if !merge.studies.isEmpty { break }
        }
        return merge.result
    }

    /// The same, for a search whose queries suspend: `stops` is checked as
    /// above, and the task's cancellation too.
    public static func answers<Study>(of steps: [[String]], stops: () -> Bool = { false },
                                      ask: (String) async -> Answer<Study>, uid: (Study) -> String?) async -> (studies: [Study], queries: Int) {
        var merge = Merge<Study>()
        for step in steps {
            merge.startStep()
            for term in step {
                if merge.queries > 0 && (stops() || Task.isCancelled) { return merge.result }
                guard merge.add(await ask(term), uid: uid) else { return merge.result }
            }
            if !merge.studies.isEmpty { break }
        }
        return merge.result
    }

    /// The studies the queries of a search found, merged as `answers` says.
    private struct Merge<Study> {
        var studies: [Study] = []
        var queries = 0
        /// The UIDs the earlier queries of the step found.
        private var stepUIDs: Set<String> = []

        var result: (studies: [Study], queries: Int) { (studies, queries) }

        mutating func startStep() {
            stepUIDs = []
        }

        /// Adds what one more query found; whether the node answered it.
        mutating func add(_ answer: Answer<Study>, uid: (Study) -> String?) -> Bool {
            queries += 1
            var found: Set<String> = []
            for study in answer.studies {
                if let key = uid(study) {
                    if stepUIDs.contains(key) { continue }
                    found.insert(key)
                }
                studies.append(study)
            }
            stepUIDs.formUnion(found)
            return answer.answered
        }
    }
}

extension PatientNameQueryForms.Answer: Sendable where Study: Sendable {}
