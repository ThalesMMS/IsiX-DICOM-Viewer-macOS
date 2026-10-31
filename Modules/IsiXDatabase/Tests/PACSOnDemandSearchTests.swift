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
import IsiXPreferences
import Synchronization
import Testing
@testable import IsiXDatabase

/// A gate the nodes wait at until the test opens it; a waiter whose task is
/// cancelled is counted and lets go at once.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Nodes that record what they are asked and answer as the test says, held
/// at the gate when it is given one.
private final class Nodes: DistantStudyQuerying {
    struct Record: Sendable {
        var filters: [[String: PropertyListValue]] = []
        var patients: [String] = []
        var activities: [String] = []
        var cancelled = 0
        var running = 0
        var mostRunning = 0
    }

    let record = Mutex(Record())
    let gate: Gate?
    let answer: @Sendable ([String: PropertyListValue]) -> [String]

    init(gate: Gate? = nil, answer: @escaping @Sendable ([String: PropertyListValue]) -> [String] = { _ in [] }) {
        self.gate = gate
        self.answer = answer
    }

    var snapshot: Record { record.withLock { $0 } }

    private func held() async {
        record.withLock {
            $0.running += 1
            $0.mostRunning = max($0.mostRunning, $0.running)
        }
        if let gate {
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                record.withLock { $0.cancelled += 1 }
            }
        }
        record.withLock { $0.running -= 1 }
    }

    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] {
        record.withLock {
            $0.filters.append(filters)
            $0.activities.append(activity)
        }
        await held()
        return answer(filters).map { summary($0) }
    }

    func patientStudies(of patient: String, activity: String) async -> [DistantStudySummary] {
        record.withLock {
            $0.patients.append(patient)
            $0.activities.append(activity)
        }
        await held()
        return answer(["patient": .string(patient)]).map { summary($0) }
    }
}

private func summary(_ uid: String, date: Date? = nil, files: Int32 = 0, rawFiles: Int32 = 0) -> DistantStudySummary {
    DistantStudySummary(studyInstanceUID: uid, date: date, files: files, rawFiles: rawFiles, node: uid)
}

private func uids(_ answer: DistantListAnswer?) -> [String?]? {
    answer?.studies?.map(\.studyInstanceUID)
}

/// Waits, a millisecond at a time and at most two seconds, for `condition`.
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private let asked: @Sendable () async -> Bool = { true }
private let noRawFiles: @Sendable ([Int]) async -> [Int: Int32] = { _ in [:] }

@Suite struct PACSOnDemandSearchTests {

    @Test func theLastQuestionOfTheListWinsAndSupersededOnesAreNeverAsked() async {
        let gate = Gate()
        let nodes = Nodes(gate: gate) { filters in [filters["PatientsName"]?.stringValue ?? "?"] }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())

        let first = Task { await search.studies(forSearch: "AAA", type: 1, modality: nil, activity: "a", stillAsked: asked) }
        await eventually { nodes.snapshot.running == 1 }

        // The second question cancels the first one's query and waits for the nodes.
        let secondAsked = Mutex(false)
        let second = Task {
            await search.studies(forSearch: "BBB", type: 0, modality: nil, activity: "b") {
                secondAsked.withLock { $0 = true }
                return true
            }
        }
        await eventually { nodes.snapshot.cancelled == 1 }
        #expect(nodes.snapshot.cancelled == 1, "a new question cancels the query of the one before")

        // A third one supersedes the second while it waits.
        let third = Task { await search.studies(forSearch: "CCC", type: 0, modality: nil, activity: "c", stillAsked: asked) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.open()

        #expect(await first.value == nil, "a cancelled question hands nothing back")
        #expect(await second.value == nil, "a superseded question is not asked")
        #expect(uids(await third.value) == ["CCC*"])
        #expect(secondAsked.withLock { $0 } == false, "the browser is not even asked about a superseded question")
        let record = nodes.snapshot
        #expect(record.filters.count == 2)
        #expect(record.activities == ["a", "c"])
        #expect(record.mostRunning == 1, "the nodes answer one question at a time")
    }

    @Test func aQuestionTheBrowserNoLongerAsksIsNotAsked() async {
        let nodes = Nodes { _ in ["X"] }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())
        let answer = await search.studies(from: Date(timeIntervalSince1970: 0), to: nil, modality: nil, activity: "i") { false }
        #expect(answer == nil)
        #expect(nodes.snapshot.filters.isEmpty)

        let noStart = await search.studies(from: nil, to: nil, modality: nil, activity: "i", stillAsked: asked)
        #expect(noStart == nil, "a time interval without a start is not asked")
        #expect(nodes.snapshot.filters.isEmpty)
    }

    @Test func theHistoryWaitsForTheListWithoutCancellingIt() async {
        let gate = Gate()
        let nodes = Nodes(gate: gate) { filters in [filters["patient"]?.stringValue ?? "list"] }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())

        let list = Task { await search.studies(forSearch: "123", type: 1, modality: nil, activity: "l", stillAsked: asked) }
        await eventually { nodes.snapshot.running == 1 }
        let history = Task {
            await search.history(of: "P1", local: [], activity: "Search History: P1", inRetrieveQueue: { _ in false }, rawFiles: noRawFiles, stillShown: asked)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(nodes.snapshot.patients.isEmpty, "the history waits while the nodes answer the list")
        await gate.open()

        #expect(uids(await list.value) == ["list"], "the history does not supersede the list")
        let members = await history.value?.members ?? []
        #expect(members.count == 1)
        if case .distant(let study)? = members.first { #expect(study.studyInstanceUID == "P1") }
        #expect(nodes.snapshot.cancelled == 0)
        #expect(nodes.snapshot.activities == ["l", "Search History: P1"])
    }

    @Test func aNewHistoryCancelsTheOneTheNodesAreAnswering() async {
        let gate = Gate()
        let nodes = Nodes(gate: gate) { filters in [filters["patient"]?.stringValue ?? "?"] }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())

        let first = Task { await search.history(of: "P1", local: [], activity: "h1", inRetrieveQueue: { _ in false }, rawFiles: noRawFiles, stillShown: asked) }
        await eventually { nodes.snapshot.running == 1 }
        let second = Task { await search.history(of: "P2", local: [], activity: "h2", inRetrieveQueue: { _ in false }, rawFiles: noRawFiles, stillShown: asked) }
        await eventually { nodes.snapshot.cancelled == 1 }
        await gate.open()

        #expect(await first.value == nil)
        let members = await second.value?.members ?? []
        if case .distant(let study)? = members.first { #expect(study.studyInstanceUID == "P2") } else { Issue.record("no history") }
        #expect(nodes.snapshot.patients == ["P1", "P2"])
    }

    @Test func cancellingAllSupersedesTheRunningAndTheWaitingQuestions() async {
        let gate = Gate()
        let nodes = Nodes(gate: gate) { _ in ["X"] }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())

        let list = Task { await search.studies(forSearch: "AAA", type: 1, modality: nil, activity: "l", stillAsked: asked) }
        await eventually { nodes.snapshot.running == 1 }
        let history = Task {
            await search.history(of: "P1", local: [], activity: "h", inRetrieveQueue: { _ in false }, rawFiles: noRawFiles, stillShown: asked)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        search.cancelAll()
        #expect(nodes.snapshot.cancelled == 1, "the query the nodes are answering is cancelled at once")
        await gate.open()

        #expect(await list.value == nil)
        #expect(await history.value == nil)
        #expect(nodes.snapshot.patients.isEmpty, "a waiting question is never asked")

        // A question asked after it is answered.
        #expect(uids(await search.studies(forSearch: "BBB", type: 1, modality: nil, activity: "l", stillAsked: asked)) == ["X"])
    }

    @Test func aPatientNameOfSeveralWordsIsAskedASecondTimeAndOnlyNewStudiesJoin() async {
        let nodes = Nodes { filters in
            filters["PatientsName"]?.stringValue == "DOE^JOHN*" ? ["2", "3"] : ["1", "2"]
        }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())
        let answer = await search.studies(forSearch: "DOE, JOHN", type: 0, modality: "MR", activity: "s", stillAsked: asked)
        #expect(uids(answer) == ["1", "2", "3"])
        let filters = nodes.snapshot.filters
        #expect(filters.map { $0["PatientsName"]?.stringValue } == ["DOE JOHN*", "DOE^JOHN*"])
        #expect(filters.first?["modality"] == .array([.string("MR")]))

        // A single word, or another field, is asked once.
        _ = await search.studies(forSearch: "DOE", type: 7, modality: nil, activity: "s", stillAsked: asked)
        _ = await search.studies(forSearch: "DOE JOHN", type: 1, modality: nil, activity: "s", stillAsked: asked)
        #expect(nodes.snapshot.filters.count == 4)
        #expect(nodes.snapshot.filters.last?["PatientID"] == .string("DOE JOHN"))

        // A series description finds nothing, without asking.
        let series = await search.studies(forSearch: "AXIAL", type: DistantSearch.seriesDescriptionType, modality: nil, activity: "s",
                                          stillAsked: asked)
        #expect(series?.studies?.isEmpty == true)
        #expect(nodes.snapshot.filters.count == 4)
    }

    @Test func aSmartAlbumIsAskedWithItsActivatedEntry() async {
        let entries: [Any] = [
            ["name": "MR", "activated": false, "modality": ["CT"]],
            ["name": "MR", "activated": true, "modality": ["MR"], "date": 5],
        ]
        let nodes = Nodes { _ in ["S"] }
        let search = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences(["smartAlbumStudiesDICOMNodes": entries]))

        #expect(uids(await search.studies(forSmartAlbum: "MR", activity: "m", stillAsked: asked)) == ["S"])
        #expect(nodes.snapshot.filters.first?["modality"] == .array([.string("MR")]))
        #expect(nodes.snapshot.filters.first?["date"] == .integer(5))

        let none = await search.studies(forSmartAlbum: "CT", activity: "m", stillAsked: asked)
        #expect(none != nil && none?.studies == nil, "an album without an activated entry has no distant studies")
        #expect(nodes.snapshot.filters.count == 1)
    }

    @Test func theHistoryMergesLatestFirstAndRetrievesWhatHasMoreImages() {
        let day = { (d: Double) in Date(timeIntervalSinceReferenceDate: d * 86_400) }
        let local = [LocalHistoryStudy(studyInstanceUID: "a", date: day(10)),
                     LocalHistoryStudy(studyInstanceUID: "b", date: nil),
                     LocalHistoryStudy(studyInstanceUID: "c", date: day(5))]
        let rawFiles: [Int32] = [2, 4, 4]
        let distant = [summary("d", date: day(7), files: 2), summary("a", date: day(10), files: 5, rawFiles: 5),
                       summary("c", date: day(5), files: 9)]

        let history = DistantStudyMerge.patientHistory(local: local, distant: distant, preferMoreImages: true,
                                                       retrievePartial: true, inRetrieveQueue: { $0.studyInstanceUID == "c" },
                                                       localRawFiles: { rawFiles[$0] })
        let order = history.members.map { member -> String in
            switch member {
            case .local(let i): return "local " + (local[i].studyInstanceUID ?? "")
            case .distant(let study): return "distant " + (study.studyInstanceUID ?? "")
            }
        }
        #expect(order == ["distant a", "distant d", "local c", "local b"],
                "more images take the row, a study being retrieved does not, undated last")
        #expect(history.retrieved.map(\.studyInstanceUID) == ["a"])

        let kept = DistantStudyMerge.patientHistory(local: local, distant: distant, preferMoreImages: false,
                                                    retrievePartial: true, inRetrieveQueue: { _ in false },
                                                    localRawFiles: { rawFiles[$0] })
        #expect(kept.retrieved.isEmpty)
        #expect(kept.members.count == 4)
    }

    @Test func theMergeReadsItsRulesFromThePreferences() {
        let local = [LocalHistoryStudy(studyInstanceUID: "a", date: nil)]
        let distant = [summary("a", files: 3)]
        let prefer = PACSOnDemandSearch(nodes: Nodes(), preferences: MemoryPreferences(["preferStudyWithMoreImages": true]))
        let history = prefer.mergedHistory(local: local, distant: distant, inRetrieveQueue: { _ in false }, localRawFiles: { _ in 1 })
        if case .distant? = history.members.first {} else { Issue.record("the distant study with more images is not shown") }
        #expect(history.retrieved.isEmpty, "partial studies are not retrieved unless the preference says so")
    }

    @Test func theHistoryCountsOnlyTheLocalStudiesADistantOneIsComparedWith() async {
        let nodes = Nodes { _ in ["b", "z"] }
        let preferences = MemoryPreferences(["preferStudyWithMoreImages": true, "automaticallyRetrievePartialStudies": true])
        let search = PACSOnDemandSearch(nodes: nodes, preferences: preferences)
        let local = ["a", "b", "c"].map { LocalHistoryStudy(studyInstanceUID: $0, date: nil) }
        let asked = Mutex<[[Int]]>([])
        let history = await search.history(of: "P", local: local, activity: "h", inRetrieveQueue: { _ in false },
                                           rawFiles: { positions in
                                               asked.withLock { $0.append(positions) }
                                               return [1: -1]
                                           }, stillShown: { true })
        #expect(asked.withLock { $0 } == [[1]], "only the study a distant one shares its UID with is counted")
        #expect(history?.retrieved.map(\.studyInstanceUID) == ["b"], "the distant study with more images is retrieved")
        #expect(history?.members.count == 4)

        let quiet = PACSOnDemandSearch(nodes: nodes, preferences: MemoryPreferences())
        _ = await quiet.history(of: "P", local: local, activity: "h", inRetrieveQueue: { _ in false },
                                rawFiles: { positions in
                                    asked.withLock { $0.append(positions) }
                                    return [:]
                                }, stillShown: { true })
        #expect(asked.withLock { $0 }.count == 1, "nothing is counted when more images are not preferred")
    }

    @Test func latestFirstKeepsTheOrderOfEqualDates() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let items: [(String, Date?)] = [("x", nil), ("a", date), ("b", date), ("c", date.addingTimeInterval(1)), ("y", nil)]
        #expect(DistantStudyMerge.latestFirst(items, date: { $0.1 }).map { $0.0 } == ["c", "a", "b", "x", "y"])
    }

    @Test func theComparativeNodesAreTheChosenOnesInTheirOrder() {
        func chosen(_ description: String, _ address: String) -> PropertyListValue {
            .dictionary(["server": .dictionary(["Description": .string(description), "Address": .string(address)])])
        }
        let candidates: [(description: Any?, address: Any?)] = [("PACS", "10.0.0.1"), ("Other", "10.0.0.2"), ("Web", "http://w")]
        let found = DistantSearch.comparativeNodes(chosen: [chosen("Web", "http://w"), chosen("PACS", "10.0.0.1"), .string("x")],
                                                   candidates: candidates)
        #expect(found.servers == [2, 0])
        #expect(found.incomplete == false)

        let incomplete = DistantSearch.comparativeNodes(chosen: [.dictionary(["server": .dictionary(["Description": .string("PACS")])])],
                                                        candidates: candidates)
        #expect(incomplete.servers.isEmpty && incomplete.incomplete)
        #expect(DistantSearch.comparativeNodes(chosen: nil, candidates: candidates).servers.isEmpty)
    }

    @Test func theListKeepsTheLastStudiesItWasGiven() {
        let studies = DistantListStudies()
        #expect(studies.studies == nil)
        studies.replace(with: [summary("1")])
        #expect(studies.studies?.map(\.studyInstanceUID) == ["1"])
        studies.replace(with: nil)
        #expect(studies.studies == nil)
    }
}
