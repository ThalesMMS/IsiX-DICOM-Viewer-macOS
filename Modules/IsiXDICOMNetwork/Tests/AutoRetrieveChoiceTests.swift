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

/// What the automatic query retrieves of what an instance found: the rules of
/// the former -autoRetrieve:instance: and -addStudyIfNotAvailable:toArray:,
/// run through the scheduler with stand-ins of the ports.
@Suite(.serialized) struct AutoRetrieveChoiceTests {

    /// Runs `instance` once and returns what the retrieve was asked for.
    private func retrieved(_ instance: AutoQueryInstance, found: [AutoQueryStudy], local: [String: Int] = [:],
                           rules: AutoRetrieveRules = AutoRetrieveRules(maximumStudies: 10),
                           patients: [String: [AutoQueryStudy]] = [:], retrieve: StandInRetrieve = StandInRetrieve(),
                           queries: StandInQueries = StandInQueries()) async -> [[String]] {
        await queries.set(answers: [instance.name ?? "": found], patients: patients)
        let s = scheduler(queries, retrieve, local: local, rules: rules)
        await s.setInstances([instance])
        await s.refreshNow()
        await s.tick()
        await settle(s)
        return await retrieve.startedUIDs
    }

    @Test func onlyAnInstanceThatRetrievesStartsARetrieveAndOnlyWhenOneMayStart() async {
        let found = [study("1.1"), study("1.2")]
        #expect(await retrieved(instance("A", refresh: -1), found: found).isEmpty)
        #expect(await retrieved(instance("A", refresh: -1, retrieving: true), found: found) == [["1.1", "1.2"]])
        let busy = StandInRetrieve()
        await busy.set(allowed: false)
        #expect(await retrieved(instance("A", refresh: -1, retrieving: true), found: found, retrieve: busy).isEmpty)
        #expect(await retrieved(instance("A", refresh: -1, retrieving: true), found: []).isEmpty)
    }

    @Test func whatIsHereOrInTransferIsNotRetrievedAgain() async {
        let found = [study("1.1", images: 10), study("1.2", images: 10), study("1.3", images: nil), study("1.4", images: nil),
                     study("1.5", images: 0), study("1.6", images: 8)]
        let retrieve = StandInRetrieve()
        await retrieve.set(inTransfer: ["1.6": 8])
        let uids = await retrieved(instance("A", refresh: -1, retrieving: true), found: found,
                                   local: ["1.1": 10, "1.2": 4, "1.4": 3], retrieve: retrieve)
        // 1.1 is here; 1.2 is partly here; 1.3 reports no number and nothing
        // is here; 1.4 reports none and something is; 1.5 reports 0; 1.6 is
        // being retrieved for the same number.
        #expect(uids == [["1.2", "1.3"]])
        #expect(await retrieve.inTransfer == ["1.2": 10, "1.3": 1, "1.6": 8])

        let zero = await retrieved(instance("A", refresh: -1, retrieving: true), found: [study("1.5", images: 0)],
                                   rules: AutoRetrieveRules(maximumStudies: 10, countsZeroImagesAsUnknown: true))
        #expect(zero == [["1.5"]])
    }

    @Test func anEarlierRetrieveThatStillMatchesDecides() async {
        let retrieve = StandInRetrieve()
        await retrieve.set(inventories: ["1.1": AutoQueryRetrieveInventory(expected: 10, imported: 10, isSatisfied: false),
                                         "1.2": AutoQueryRetrieveInventory(expected: 10, imported: 7, isSatisfied: true),
                                         "1.3": AutoQueryRetrieveInventory(expected: 10, imported: 7, isSatisfied: false)])
        let uids = await retrieved(instance("A", refresh: -1, retrieving: true),
                                   found: [study("1.1"), study("1.2"), study("1.3")], local: [:], retrieve: retrieve)
        #expect(uids == [["1.3"]])
    }

    @Test func theMostStudiesAndTheDuplicateAccessionNumbers() async {
        let found = [study("1.1", accession: "A1"), study("1.2", accession: "A1"), study("1.3", accession: nil),
                     study("1.4", accession: nil), study("1.5", accession: "A2")]
        #expect(await retrieved(instance("A", refresh: -1, retrieving: true), found: found,
                                rules: AutoRetrieveRules(maximumStudies: 3)) == [["1.1", "1.2", "1.3"]])
        #expect(await retrieved(instance("A", refresh: -1, retrieving: true), found: found,
                                rules: AutoRetrieveRules(skipsDuplicateAccessionNumbers: true, maximumStudies: 3))
                == [["1.1", "1.3", "1.4"]])
        // A maximum of 0 still lets the first study through, as before.
        #expect(await retrieved(instance("A", refresh: -1, retrieving: true), found: found,
                                rules: AutoRetrieveRules(maximumStudies: 0)) == [["1.1"]])
    }

    @Test func aStudyRetrievedInTheLastHourIsSkipped() {
        var recent = RecentAutoRetrieves()
        func skips(_ study: AutoQueryStudy, _ mammography: Bool, _ now: Date) -> Bool {
            recent.skips(study, skipsMammography: mammography, now: now)
        }
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let ct = study("1.1", images: 10, accession: "A1", description: "CT HEAD")
        #expect(!skips(ct, true, start))
        recent.remember(ct, now: start)
        recent.remember(study("1.9", images: 3, accession: nil), now: start)
        #expect(recent.entries.last?.numberOfImages == nil)

        let soon = start.addingTimeInterval(30 * 60)
        #expect(skips(ct, false, soon))
        #expect(!skips(study("1.1", images: 11, accession: "A1"), false, soon))
        #expect(!skips(study("1.2", images: 10, accession: "A2", description: "MG BILATERAL"), false, soon))
        #expect(skips(study("1.2", images: 10, accession: "A2", description: "MG bilateral"), true, soon))
        #expect(skips(study("1.3", accession: "A3", description: "US seins droit"), true, soon))

        let later = start.addingTimeInterval(61 * 60)
        #expect(!skips(ct, true, later))
        #expect(recent.entries.isEmpty)
    }

    @Test func theRecentRetrievesAreRememberedAcrossRuns() async {
        let queries = StandInQueries(), retrieve = StandInRetrieve()
        let found = [study("1.1", images: 10, accession: "A1")]
        await queries.set(answers: ["A": found])
        let s = scheduler(queries, retrieve, rules: AutoRetrieveRules(skipsRecentRetrieves: true, maximumStudies: 10))
        await s.setInstances([instance("A", refresh: -1, retrieving: true)])
        await s.tick(); await settle(s)
        // The study is no longer in transfer, yet it was retrieved this hour.
        await retrieve.set(inTransfer: [:])
        await s.tick(); await settle(s)
        #expect(await retrieve.startedUIDs == [["1.1"]])
    }

    @Test func theEarlierStudiesOfThePatientComeAfterNewestFirst() async {
        let current = study("2.0", accession: "C", patient: "P1", modality: "CT\\SR", description: "CT HEAD", date: 500)
        let history = [study("2.1", patient: "P1", modality: "MR", description: "MR KNEE", date: 100),
                       study("2.2", patient: "P1", modality: "SR", description: "x", date: 400),
                       study("2.3", patient: "P1", modality: "CT", description: "y", date: 300),
                       study("2.4", patient: "P1", modality: "CT", description: "y", date: nil),
                       study("2.5", patient: "P1", modality: "MR", description: "CT HEAD WITHOUT", date: 300, time: 50),
                       study("2.0", patient: "P1", modality: "CT", description: "CT HEAD", date: 500)]
        let both = instance("A", refresh: -1, retrieving: true, previous: 2, sameModality: true, sameDescription: true)
        #expect(await retrieved(both, found: [current], local: ["2.3": 0], patients: ["P1": history])
                == [["2.0", "2.5", "2.3"]])

        let modality = instance("A", refresh: -1, retrieving: true, previous: 5, sameModality: true)
        #expect(await retrieved(modality, found: [current], local: ["2.3": 10], patients: ["P1": history])
                == [["2.0", "2.4"]])

        let description = instance("A", refresh: -1, retrieving: true, previous: 1, sameDescription: true)
        let queries = StandInQueries()
        #expect(await retrieved(description, found: [current], patients: ["P1": history], queries: queries) == [["2.0", "2.5"]])
        #expect(await queries.patientQueries == ["P1"])

        let none = instance("A", refresh: -1, retrieving: true, previous: 0, sameModality: true)
        let noQueries = StandInQueries()
        #expect(await retrieved(none, found: [current], patients: ["P1": history], queries: noQueries) == [["2.0"]])
        #expect(await noQueries.patientQueries.isEmpty)
    }

    @Test func newestFirstPutsStudiesWithoutADateLastAndKeepsTies() {
        let sorted = AutoRetrieveChoice.newestFirst([study("a", date: 1), study("b", date: nil), study("c", date: 2, time: 1),
                                                     study("d", date: 2, time: 5), study("e", date: 2), study("f", date: 1)])
        #expect(sorted.map(\.studyInstanceUID) == ["d", "c", "e", "a", "f", "b"])
    }
}
