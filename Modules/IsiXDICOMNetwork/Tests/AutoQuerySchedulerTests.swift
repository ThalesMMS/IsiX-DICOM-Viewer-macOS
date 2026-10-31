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
import IsiXContracts
@testable import IsiXDICOMNetwork

// MARK: Stand-ins of the ports

/// The queries: each run is recorded with the instance it was given, and
/// answers with the studies set for that instance's name. A run can be made to
/// wait until it is cancelled.
actor StandInQueries: AutoQueryRunning {
    var runs: [AutoQueryInstance] = []
    var answers: [String: [AutoQueryStudy]] = [:]
    var patients: [String: [AutoQueryStudy]] = [:]
    var patientQueries: [String] = []
    var waitsForCancellation = false
    var cancelled = 0

    func set(answers: [String: [AutoQueryStudy]] = [:], patients: [String: [AutoQueryStudy]] = [:], waits: Bool = false) {
        self.answers = answers
        self.patients = patients
        waitsForCancellation = waits
    }

    func runQuery(of instance: AutoQueryInstance) async throws -> [AutoQueryStudy] {
        runs.append(instance)
        if waitsForCancellation {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled += 1
                throw error
            }
        }
        return answers[instance.name ?? ""] ?? []
    }

    func studies(ofPatientID patientID: String) async -> [AutoQueryStudy] {
        patientQueries.append(patientID)
        return patients[patientID] ?? []
    }

    var names: [String] { runs.map { $0.name ?? "?" } }
}

/// The retrieve: what was started, which studies are in transfer, and the
/// inventories of earlier retrieves.
actor StandInRetrieve: AutoRetrieveStarting {
    var allowed = true
    var inventories: [String: AutoQueryRetrieveInventory] = [:]
    var inTransfer: [String: Int] = [:]
    var started: [(studies: [String], instance: String)] = []

    func set(allowed: Bool = true, inventories: [String: AutoQueryRetrieveInventory] = [:], inTransfer: [String: Int] = [:]) {
        self.allowed = allowed
        self.inventories = inventories
        self.inTransfer = inTransfer
    }

    func mayStartRetrieve() async -> Bool { allowed }

    func retrieveInventory(of study: AutoQueryStudy) async -> AutoQueryRetrieveInventory? {
        inventories[study.studyInstanceUID]
    }

    func claimTransfer(of study: AutoQueryStudy, expectedFiles: Int) async -> Bool {
        guard inTransfer[study.studyInstanceUID] != expectedFiles else { return false }
        inTransfer[study.studyInstanceUID] = expectedFiles
        return true
    }

    func startRetrieve(of studies: [AutoQueryStudy], for instance: AutoQueryInstance) async {
        started.append((studies.map(\.studyInstanceUID), instance.name ?? "?"))
    }

    var startedUIDs: [[String]] { started.map(\.studies) }
}

/// The local database: files here by Study Instance UID.
struct StandInLocalStudies: LocalStudyReading {
    let files: [String: Int]

    func studies(withInstanceUIDs studyInstanceUIDs: Set<String>) async throws -> [LocalStudySnapshot] {
        files.filter { studyInstanceUIDs.contains($0.key) }.map {
            LocalStudySnapshot(identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://S/Study/\($0.key)")!),
                               studyInstanceUID: $0.key, fileCount: $0.value, state: nil, comment: nil)
        }
    }
}

/// The window: whether it lets the countdown go on, and what it was shown.
@MainActor final class StandInDisplay: AutoQueryCountdownDisplay {
    var counts = true
    var shown: [[UUID: Int]] = []
    func shouldCountDown() -> Bool { counts }
    func showCountdown(_ remaining: [UUID: Int]) { shown.append(remaining) }
}

func instance(_ name: String, refresh: Int, modality: String = "", retrieving: Bool = false, previous: Int = 0,
              sameModality: Bool = false, sameDescription: Bool = false) -> AutoQueryInstance {
    var values: [String: PropertyListValue] = ["instanceName": .string(name), "autoRefreshQueryResults": .integer(refresh),
                                               "autoRetrieving": .boolean(retrieving),
                                               "NumberOfPreviousStudyToRetrieve": .integer(previous),
                                               "retrieveSameModality": .boolean(sameModality),
                                               "retrieveSameDescription": .boolean(sameDescription)]
    if !modality.isEmpty { values["modalityStrings"] = .array([.string(modality)]) }
    return AutoQueryInstance(values: values)
}

func study(_ uid: String, images: Int? = 10, accession: String? = nil, patient: String? = "P1", modality: String? = "CT",
           description: String? = nil, date: Double? = nil, time: Double? = nil, handle: Int = 0) -> AutoQueryStudy {
    AutoQueryStudy(handle: handle, studyInstanceUID: uid, patientID: patient, accessionNumber: accession, modality: modality,
                   studyDescription: description, numberOfImages: images,
                   date: date.map { Date(timeIntervalSinceReferenceDate: $0) }, time: time.map { Date(timeIntervalSinceReferenceDate: $0) })
}

/// Waits until the scheduler has run everything it queued.
func settle(_ scheduler: AutoQueryScheduler) async {
    for _ in 0..<2000 {
        if await scheduler.pending.isEmpty {
            for _ in 0..<5 { await Task.yield() }
            if await scheduler.pending.isEmpty { return }
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

func scheduler(_ queries: StandInQueries, _ retrieve: StandInRetrieve, local: [String: Int] = [:],
               rules: AutoRetrieveRules = AutoRetrieveRules(maximumStudies: 10), now: Date = Date(timeIntervalSinceReferenceDate: 0),
               tick: Duration = .seconds(1)) -> AutoQueryScheduler {
    AutoQueryScheduler(querying: queries, retrieving: retrieve, localStudies: StandInLocalStudies(files: local),
                       rules: { rules }, now: { now }, tickInterval: tick)
}

// MARK: The countdown

/// When each instance of the automatic query runs: its own interval, its own
/// settings, one run at a time, and cancellation.
@Suite(.serialized) struct AutoQuerySchedulerTests {

    @Test func eachInstanceCountsItsOwnIntervalAndQueriesWithItsOwnSettings() async {
        // Negative intervals are seconds; C does not query by itself.
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let s = scheduler(queries, retrieve)
        let all = [instance("A", refresh: -3, modality: "CT"), instance("B", refresh: -5, modality: "MR"),
                   instance("C", refresh: 0, modality: "US"), instance("D", refresh: -2, modality: "CR")]
        await s.setInstances(all)

        var launches: [String] = []
        for second in 1...6 {
            let before = await queries.runs.count
            await s.tick()
            await settle(s)
            let runs = await queries.runs
            for run in runs[before...] {
                let own = all.first { $0.id == run.id }
                #expect(own?.modalities == run.modalities && own?.name == run.name, "\(run.name ?? "?") ran with other settings")
                launches.append("\(second):\(run.name ?? "?")")
            }
        }
        #expect(launches == ["2:D", "3:A", "4:D", "5:B", "6:A", "6:D"])
        #expect(await s.secondsRemaining(for: all[2].id) == 0)
        #expect(await s.secondsRemaining(for: all[0].id) == 3)
    }

    @Test func minutesCountSixtySecondsAndOnlyTheFirstFortyInstancesCount() async {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let s = scheduler(queries, retrieve)
        let many = (0..<41).map { instance("I\($0)", refresh: -1) } + [instance("M", refresh: 2)]
        await s.setInstances(many)
        #expect(await s.secondsRemaining(for: many[41].id) == 120)
        await s.tick()
        await settle(s)
        #expect(await queries.runs.count == 40)
        #expect(!(await queries.names).contains("I40"))
        #expect(await s.secondsRemaining(for: many[41].id) == 120)
    }

    @Test func anInstanceKeepsItsCountdownWhenTheListChanges() async {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let s = scheduler(queries, retrieve)
        let a = instance("A", refresh: -10), b = instance("B", refresh: -4)
        await s.setInstances([a, b])
        await s.tick(); await s.tick()
        #expect(await s.secondsRemaining(for: a.id) == 8)

        // The window saved A with new filters, deleted B and added C.
        let c = instance("C", refresh: -7)
        await s.setInstances([a.adding(["searchFieldName": "X"]), c])
        #expect(await s.secondsRemaining(for: a.id) == 8)
        #expect(await s.secondsRemaining(for: b.id) == nil)
        #expect(await s.secondsRemaining(for: c.id) == 7)

        await s.restartCountdown(of: a.id)
        #expect(await s.secondsRemaining(for: a.id) == 10)
    }

    @Test func aRefreshRunsEveryInstanceWithAnIntervalOneSecondLater() async {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let s = scheduler(queries, retrieve)
        await s.setInstances([instance("A", refresh: 30), instance("B", refresh: -600), instance("C", refresh: 0)])
        await s.refreshNow()
        await settle(s)
        #expect(await queries.runs.isEmpty)
        await s.tick()
        await settle(s)
        #expect(await queries.names == ["A", "B"])
    }

    @Test func theDisplayHoldsTheCountdownAndIsShownWhatIsLeft() async {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let s = scheduler(queries, retrieve)
        let display = StandInDisplay()
        await s.setDisplay(display)
        let a = instance("A", refresh: -3)
        await s.setInstances([a])
        await MainActor.run { display.counts = false }
        await s.tick(); await s.tick(); await s.tick()
        #expect(await s.secondsRemaining(for: a.id) == 3)
        await MainActor.run { display.counts = true }
        await s.tick()
        let shown = await MainActor.run { display.shown.map { $0[a.id] } }
        #expect(shown == [3, 3, 3, 2])
    }

    @Test func runsOneAtATimeAndQueuesAnInstanceOnce() async {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        await queries.set(waits: true)
        let s = scheduler(queries, retrieve)
        let a = instance("A", refresh: -1), b = instance("B", refresh: -1)
        await s.setInstances([a, b])
        await s.tick()
        for _ in 0..<100 where await queries.runs.isEmpty { await Task.yield() }
        await s.tick()
        await s.tick()
        // A runs; B waits once, and A once more, however many seconds pass.
        #expect(await queries.names == ["A"])
        #expect(await s.pending == [a.id, b.id, a.id])
        await s.stop()
        for _ in 0..<1000 where await queries.cancelled == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(await queries.cancelled == 1)
        #expect(await s.pending.isEmpty)
        #expect(await queries.names == ["A"])
    }

    @Test func startCountsByItselfAndStopCancelsTheRunInProgress() async throws {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let s = scheduler(queries, retrieve, tick: .milliseconds(5))
        let a = instance("A", refresh: -1, retrieving: true)
        await queries.set(answers: ["A": [study("1.1")]])
        await s.setInstances([a])
        await s.start()
        #expect(await s.isRunning)
        for _ in 0..<2000 where await queries.runs.count < 3 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await queries.runs.count >= 3)

        await queries.set(answers: ["A": [study("1.1")]], waits: true)
        let before = await queries.runs.count
        for _ in 0..<2000 where await queries.runs.count == before { try await Task.sleep(for: .milliseconds(1)) }
        await s.stop()
        #expect(!(await s.isRunning))
        for _ in 0..<2000 where await queries.cancelled == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await queries.cancelled == 1)
        let after = await queries.runs.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(await queries.runs.count == after)
        // Only the runs that finished started a retrieve, and only the first:
        // the study was in transfer since, for the same number of images.
        #expect(await retrieve.startedUIDs == [["1.1"]])

        // Started again, it counts on from where it was.
        await queries.set(answers: [:])
        await s.start()
        for _ in 0..<2000 where await queries.runs.count == after { try await Task.sleep(for: .milliseconds(1)) }
        await s.stop()
        #expect(await queries.runs.count > after)
    }
}
