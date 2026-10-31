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
import IsiXPreferences
@testable import IsiXDatabase

@Suite struct AutoCleanupPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86400

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

    /// A study of `patient` that the date rule of `datePreferences` would take.
    private func study(_ id: Int, patient: String? = "A", age: Double = 100, opened: Date? = nil, added: Date?? = .none,
                       locked: Bool = false, album: Bool = false, comment: String? = nil, comment4: String? = nil) -> CleanupStudyRow {
        CleanupStudyRow(id: id, patientUID: patient, date: daysAgo(age), dateOpened: opened, dateAdded: added ?? daysAgo(age),
                        isLocked: locked, isInAlbum: album, comment: comment, comment4: comment4)
    }

    private var datePreferences: AutoCleanupPreferences {
        var preferences = AutoCleanupPreferences()
        preferences.dateRuleEnabled = true
        preferences.usesDateProduced = true
        preferences.producedDays = 30
        preferences.openedDays = 30
        return preferences
    }

    private func dateIDs(_ rows: [CleanupStudyRow], _ preferences: AutoCleanupPreferences? = nil) throws -> [Int] {
        try AutoCleanupPolicy.dateCandidates(in: rows, preferences: preferences ?? datePreferences, now: now).map { $0.id }
    }

    private func spaceIDs(_ rows: [CleanupStudyRow], _ preferences: AutoCleanupPreferences = AutoCleanupPreferences()) throws -> [Int] {
        try AutoCleanupPolicy.spaceCandidates(in: rows, preferences: preferences, now: now).rows.map { $0.id }
    }

    // MARK: Date rule

    @Test func thePatientsLatestStudyDecidesForAllOfThem() throws {
        #expect(try dateIDs([study(0, age: 100), study(1, age: 40)]) == [0, 1])
        #expect(try dateIDs([study(0, age: 100), study(1, age: 10)]) == [])
    }

    @Test func patientsAreTheSameWhateverTheCaseAccentsOrWidth() throws {
        let rows = [study(0, patient: "JOSE", age: 100), study(1, patient: "josé", age: 10), study(2, patient: "ＪＯＳＥ", age: 100)]
        #expect(try dateIDs(rows) == [])
    }

    private func permutations<Element>(_ items: [Element]) -> [[Element]] {
        if items.count < 2 { return [items] }
        return items.indices.flatMap { index in
            permutations(Array(items[..<index] + items[(index + 1)...])).map { [items[index]] + $0 }
        }
    }

    @Test func aUIDThatSortsBetweenTwoSpellingsDoesNotSplitThePatient() throws {
        // By -[NSString compare:] the order is JOSE-1-, JOSEF-2-, JOSÉ-1-.
        for (older, recent) in [("JOSE-1-", "JOSÉ-1-"), ("JOSÉ-1-", "JOSE-1-"), ("jose-1-", "ＪＯＳＥ-1-")] {
            for rows in permutations([study(0, patient: older, age: 100), study(1, patient: "JOSEF-2-", age: 100), study(2, patient: recent, age: 10)]) {
                #expect(try dateIDs(rows) == [1])
            }
        }
        // A patient with nothing recent still goes, as one group.
        let rows = [study(0, patient: "JOSE-1-", age: 100), study(1, patient: "JOSEF-2-", age: 10), study(2, patient: "JOSÉ-1-", age: 40)]
        #expect(try dateIDs(rows) == [0, 2])
    }

    @Test func aStudyWithNoPatientUIDStaysOutOfAPatientWithSeveralSpellings() throws {
        let rows = [study(0, patient: "JOSE-1-", age: 100), study(1, patient: "JOSEF-2-", age: 100), study(2, patient: nil, age: 100), study(3, patient: "JOSÉ-1-", age: 10)]
        #expect(try dateIDs(rows) == [2, 1])
        #expect(try dateIDs([study(0, patient: nil, age: 10), study(1, patient: "JOSE-1-"), study(2, patient: "JOSÉ-1-")]) == [1, 2])
    }

    @Test func aStudyWithNoDateDoesNotGoOnTheDateOfAnotherSpelling() throws {
        func undated(_ id: Int, _ patient: String) -> CleanupStudyRow {
            CleanupStudyRow(id: id, patientUID: patient, date: nil, dateOpened: daysAgo(100), dateAdded: daysAgo(100), isLocked: false, isInAlbum: false)
        }
        let joined = [study(0, patient: "JOSE-1-"), study(1, patient: "JOSEF-2-"), undated(2, "JOSÉ-1-")]
        // Alone it never went, and with it nothing of the patient goes.
        for rows in permutations(joined) { #expect(try dateIDs(rows) == [1]) }

        // The condition that does not read that date is not held back by it.
        var preferences = datePreferences
        preferences.usesDateProduced = false
        preferences.usesDateOpened = true
        #expect(Set(try dateIDs(joined, preferences)) == [0, 1, 2])

        // Neither opened nor added: the opened condition cannot judge it.
        let unopened = CleanupStudyRow(id: 2, patientUID: "JOSÉ-1-", date: daysAgo(100), dateOpened: nil, dateAdded: nil, isLocked: false, isInAlbum: false)
        #expect(Set(try dateIDs([study(0, patient: "JOSE-1-"), study(1, patient: "JOSEF-2-"), unopened], preferences)) == [1])
    }

    @Test func aStudyWithNoDateKeepsItsPatientWhateverTheOrder() throws {
        func undated(_ id: Int) -> CleanupStudyRow {
            CleanupStudyRow(id: id, patientUID: "A", date: nil, dateOpened: daysAgo(100), dateAdded: daysAgo(100), isLocked: false, isInAlbum: false)
        }
        for rows in permutations([study(0), undated(1), study(2, age: 40)]) { #expect(try dateIDs(rows) == []) }

        // The condition that does not read that date judges them by the others.
        var preferences = datePreferences
        preferences.usesDateProduced = false
        preferences.usesDateOpened = true
        for rows in permutations([study(0), undated(1)]) { #expect(Set(try dateIDs(rows, preferences)) == [0, 1]) }

        // Neither opened nor added: it keeps the patient, and the date added of
        // the last study read does not stand in for the latest of the patient.
        let unread = CleanupStudyRow(id: 0, patientUID: "A", date: daysAgo(100), dateOpened: nil, dateAdded: nil, isLocked: false, isInAlbum: false)
        for rows in permutations([unread, study(1, age: 100), study(2, age: 10)]) { #expect(try dateIDs(rows, preferences) == []) }
    }

    /// Whatever the order, the same studies go.
    @Test func theOrderOfTheRowsDecidesNothing() throws {
        var state: UInt64 = 11
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let patients: [String?] = [nil, "A", "a", "Á", "B"]
        let dates = [nil, daysAgo(10), daysAgo(100), daysAgo(200)]
        var preferences = [datePreferences, datePreferences, datePreferences]
        preferences[1].usesDateOpened = true
        preferences[2].usesDateProduced = false
        preferences[2].usesDateOpened = true

        for round in 0..<300 {
            let rows = (0..<(2 + next(4))).map { id in
                CleanupStudyRow(id: id, patientUID: patients[next(patients.count)], date: dates[next(dates.count)],
                                dateOpened: dates[next(dates.count)], dateAdded: dates[next(dates.count)],
                                isLocked: false, isInAlbum: false)
            }
            let chosen = preferences[round % preferences.count]
            let first = Set(try dateIDs(rows, chosen))
            for other in permutations(rows) { #expect(Set(try dateIDs(other, chosen)) == first) }
        }
    }

    /// Whatever goes with the spellings joined also goes with each spelling
    /// judged apart, which is the least the former order ever joined.
    @Test func joiningSpellingsNeverTakesAStudyMore() throws {
        var state: UInt64 = 7
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let patients: [String?] = [nil, "AA", "aa", "ÁA", "ＡＡ", "AB", "AAB", "aab", "B", "b"]
        let dates = [nil, daysAgo(10), daysAgo(29.5), daysAgo(30.5), daysAgo(100), daysAgo(200)]
        var preferences = [datePreferences, datePreferences, datePreferences]
        preferences[1].usesDateOpened = true
        preferences[2].usesDateProduced = false
        preferences[2].usesDateOpened = true

        var sparedSomething = false
        for round in 0..<3000 {
            let rows = (0..<(1 + next(30))).map { id in
                CleanupStudyRow(id: id, patientUID: patients[next(patients.count)], date: dates[next(dates.count)],
                                dateOpened: dates[next(dates.count)], dateAdded: dates[next(dates.count)],
                                isLocked: next(8) == 0, isInAlbum: next(8) == 0)
            }
            let chosen = preferences[round % preferences.count]
            var apart = Set<Int>()
            for spelling in Set(rows.map { $0.patientUID }) {
                apart.formUnion(try dateIDs(rows.filter { $0.patientUID == spelling && spelling != nil }, chosen))
            }
            for row in rows where row.patientUID == nil { apart.formUnion(try dateIDs([row], chosen)) }
            let together = Set(try dateIDs(rows, chosen))
            #expect(together.isSubset(of: apart))
            if together.count < apart.count { sparedSomething = true }
        }
        #expect(sparedSomething)
    }

    @Test func theLimitFollowsTheOrderOfTheGroupsAndOnlyPutsOffTheRest() throws {
        // By -[NSString compare:], "a" came after every "B"; now it comes first.
        var rows = (0..<55).map { study($0, patient: String(format: "B%03d", $0)) }
        rows += [study(55, patient: "a"), study(56, patient: "JOSE-1-"), study(57, patient: "JOSÉ-1-", age: 10)]
        let first = try dateIDs(rows)
        #expect(first == [55] + Array(0..<49))

        // Pass after pass, the rule ends where it would without a limit, and
        // the recent study goes on protecting its patient.
        var left = rows.filter { !first.contains($0.id) }
        while case let found = try dateIDs(left), !found.isEmpty {
            left.removeAll { found.contains($0.id) }
        }
        #expect(left.map { $0.id } == [56, 57])
    }

    @Test func aStudyWithNoDateKeepsItsPatientOutOfTheProducedCondition() throws {
        let undated = CleanupStudyRow(id: 1, patientUID: "A", date: nil, dateOpened: nil, dateAdded: daysAgo(100), isLocked: false, isInAlbum: false)
        #expect(try dateIDs([undated]) == [])
        #expect(try dateIDs([undated, study(0, age: 100)]) == [])
        #expect(try dateIDs([study(0, age: 100), undated]) == [])
    }

    /// A study with no patient UID and none of the dates the rule reads.
    private func anonymous(_ id: Int, date: Date? = nil, opened: Date? = nil, added: Date? = nil) -> CleanupStudyRow {
        CleanupStudyRow(id: id, patientUID: nil, date: date, dateOpened: opened, dateAdded: added, isLocked: false, isInAlbum: false)
    }

    @Test func aStudyWithNoPatientUIDLeavesTheOthersToTheirOwnDates() throws {
        // Sorted first, it used to take every study after it for one patient.
        let rows = [study(0, patient: nil), study(1, patient: "B"), study(2, patient: "C", age: 10)]
        #expect(try dateIDs(rows) == [0, 1])
        // Neither a recent study nor one with no date holds the others back.
        #expect(try dateIDs([study(0, patient: nil, age: 10), study(1, patient: "B")]) == [1])
        #expect(try dateIDs([anonymous(0, added: daysAgo(100)), study(1, patient: "B")]) == [1])
    }

    @Test func aStudyWithNoPatientUIDKeepsAPatientsStudiesTogether() throws {
        let rows = [study(0, patient: "A", age: 100), study(1, patient: nil), study(2, patient: "A", age: 10)]
        #expect(try dateIDs(rows) == [1])
    }

    @Test func aStudyWithNoPatientUIDIsJudgedOnItsOwnDates() throws {
        #expect(try dateIDs([study(0, patient: nil, age: 100)]) == [0])
        #expect(try dateIDs([study(0, patient: nil, age: 10)]) == [])
        // No date to compare is never old enough.
        #expect(try dateIDs([anonymous(0, added: daysAgo(100))]) == [])

        var preferences = datePreferences
        preferences.usesDateProduced = false
        preferences.usesDateOpened = true
        #expect(try dateIDs([study(0, patient: nil, opened: daysAgo(40))], preferences) == [0])
        #expect(try dateIDs([study(0, patient: nil, opened: daysAgo(10))], preferences) == [])
        #expect(try dateIDs([study(0, patient: nil, opened: nil, added: daysAgo(10))], preferences) == [])
        #expect(try dateIDs([anonymous(0, date: daysAgo(100))], preferences) == [])

        preferences.usesDateProduced = true
        #expect(try dateIDs([study(0, patient: nil, age: 100, opened: daysAgo(10))], preferences) == [])
    }

    @Test func everyProtectionHoldsForAStudyWithNoPatientUID() throws {
        #expect(try dateIDs([study(0, patient: nil, locked: true)]) == [])
        #expect(try dateIDs([study(0, patient: nil, album: true)]) == [])
        #expect(try dateIDs([study(0, patient: nil, added: daysAgo(6.9))]) == [])
        #expect(try dateIDs([anonymous(0, date: daysAgo(100))]) == [])

        var preferences = datePreferences
        preferences.keepsStudiesWithComments = true
        #expect(try dateIDs([study(0, patient: nil, comment4: "keep")], preferences) == [])

        preferences = datePreferences
        preferences.commentFilterEnabled = true
        preferences.commentFilterText = "keep"
        #expect(try dateIDs([study(0, patient: nil, comment: "keep")], preferences) == [0])
        #expect(try dateIDs([study(0, patient: nil, comment: "other")], preferences) == [])
    }

    @Test func twoStudiesWithNoPatientUIDAreNotOnePatient() throws {
        #expect(try dateIDs([study(0, patient: nil, age: 100), study(1, patient: nil, age: 10)]) == [0])
        #expect(try dateIDs([study(0, patient: nil, age: 10), study(1, patient: nil, age: 100)]) == [1])
        #expect(try dateIDs([study(0, patient: nil, age: 100), study(1, patient: nil, age: 100)]) == [0, 1])
        // The missing date of the first one does not carry over to the second.
        #expect(try dateIDs([anonymous(0, added: daysAgo(100)), study(1, patient: nil, age: 100)]) == [1])
    }

    @Test func anEmptyUIDIsStillAnIdentifier() throws {
        // Judged together, as ever: the side that keeps studies, and it reaches
        // no one else. The identifiers of the database are never empty.
        #expect(try dateIDs([study(0, patient: "", age: 100), study(1, patient: "", age: 10)]) == [])
        #expect(try dateIDs([study(0, patient: "", age: 100), study(1, patient: "", age: 40)]) == [0, 1])
        #expect(try dateIDs([study(0, patient: "", age: 100), study(1, patient: "B", age: 10)]) == [0])
        #expect(try dateIDs([study(0, patient: "", age: 10), study(1, patient: "B", age: 100)]) == [1])
        // Neither is it the same as no UID at all, on either side.
        #expect(try dateIDs([study(0, patient: nil, age: 10), study(1, patient: "", age: 100)]) == [1])
        #expect(try dateIDs([study(0, patient: nil, age: 100), study(1, patient: "", age: 10)]) == [0])
    }

    /// The whole of the difference: what goes is what would go without those
    /// studies, and each of them that would go alone. Below the limit of a pass.
    @Test func theCandidatesAreThoseOfTheOthersAndEachStudyWithNoUIDAlone() throws {
        var state: UInt64 = 42
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let patients: [String?] = [nil, nil, nil, "", "A", "a", "Á", "AB", "B", "C", "D"]
        let dates = [nil, daysAgo(10), daysAgo(29.5), daysAgo(30.5), daysAgo(100)]
        var preferences = [datePreferences, datePreferences, datePreferences]
        preferences[1].usesDateOpened = true
        preferences[2].usesDateProduced = false
        preferences[2].usesDateOpened = true

        for round in 0..<3000 {
            let rows = (0..<(1 + next(30))).map { id in
                CleanupStudyRow(id: id, patientUID: patients[next(patients.count)], date: dates[next(dates.count)],
                                dateOpened: dates[next(dates.count)], dateAdded: dates[next(dates.count)],
                                isLocked: next(8) == 0, isInAlbum: next(8) == 0, comment: next(8) == 0 ? "keep" : nil)
            }
            let chosen = preferences[round % preferences.count]
            var alone: [Int] = []
            for row in rows where row.patientUID == nil { alone += try dateIDs([row], chosen) }
            let others = try dateIDs(rows.filter { $0.patientUID != nil }, chosen)
            #expect(try dateIDs(rows, chosen) == alone + others)
        }
    }

    @Test func studiesWithNoUIDComeFirstInTheLimitAndTheRestGoNextPass() throws {
        let rows = (0..<60).map { study($0, patient: $0 < 3 ? nil : String(format: "P%03d", $0)) }
        let first = try dateIDs(rows)
        #expect(first == Array(0..<50))
        #expect(try dateIDs(rows.filter { !first.contains($0.id) }) == Array(50..<60))
    }

    @Test func theOpenedConditionUsesTheLatestOpenedOrAdded() throws {
        var preferences = datePreferences
        preferences.usesDateProduced = false
        preferences.usesDateOpened = true
        #expect(try dateIDs([study(0, opened: daysAgo(40))], preferences) == [0])
        #expect(try dateIDs([study(0, opened: daysAgo(10))], preferences) == [])
        #expect(try dateIDs([study(0, opened: nil, added: daysAgo(10))], preferences) == [])
        #expect(try dateIDs([study(0, opened: daysAgo(40)), study(1, opened: nil, added: daysAgo(10))], preferences) == [])
    }

    @Test func bothConditionsMustMatch() throws {
        var preferences = datePreferences
        preferences.usesDateOpened = true
        #expect(try dateIDs([study(0, age: 100, opened: daysAgo(10))], preferences) == [])
        #expect(try dateIDs([study(0, age: 100, opened: daysAgo(40))], preferences) == [0])
    }

    @Test func noConditionTakesEveryPatient() throws {
        var preferences = datePreferences
        preferences.usesDateProduced = false
        #expect(try dateIDs([study(0, age: 100, added: daysAgo(10))], preferences) == [0])
    }

    @Test func aLockedStudyStaysAndTheRestOfItsPatientGoes() throws {
        #expect(try dateIDs([study(0, locked: true), study(1)]) == [1])
    }

    /// No setting lets either rule delete a study in an album: not the key the
    /// window once wrote, whatever it holds, nor any other preference.
    @Test func aStudyInAnAlbumNeverGoesWhateverTheOldKeyHolds() throws {
        let rows = [study(0, album: true), study(1), study(2, patient: nil, album: true), study(3, patient: nil)]
        for stored: Any in [true, false, 0, "NO"] {
            let defaults = MemoryPreferences(["dontDeleteStudiesIfInAlbum": stored])
            for keepsComments in [false, true] {
                var preferences = AutoCleanupPreferences(defaults: defaults)
                preferences.dateRuleEnabled = true
                preferences.usesDateProduced = true
                preferences.usesDateOpened = false
                preferences.producedDays = 30
                preferences.commentFilterEnabled = false
                preferences.keepsStudiesWithComments = keepsComments
                preferences.spaceMode = 0
                #expect(try dateIDs(rows, preferences) == [3, 1])
                #expect(try spaceIDs(rows, preferences).sorted() == [1, 3])
            }
        }
    }

    @Test func aStudyWithCommentsStaysOnlyWhenThePreferenceSaysSo() throws {
        let rows = [study(0, comment4: "keep"), study(1, comment: ""), study(2)]
        #expect(try dateIDs(rows) == [0, 1, 2])
        var preferences = datePreferences
        preferences.keepsStudiesWithComments = true
        #expect(try dateIDs(rows, preferences) == [1, 2])
    }

    @Test func aStudyAddedThisWeekStays() throws {
        #expect(try dateIDs([study(0, added: daysAgo(6.9)), study(1, added: daysAgo(7.1))]) == [1])
    }

    @Test func aStudyWithNoDateAddedCountsAsAddedNow() throws {
        let row = CleanupStudyRow(id: 0, patientUID: "A", date: daysAgo(100), dateOpened: nil, dateAdded: nil, isLocked: false, isInAlbum: false)
        #expect(try dateIDs([row]) == [])
    }

    @Test func theCommentFilterLooksAtTheFirstCommentOnly() throws {
        let rows = [study(0, comment: "Keep me"), study(1, comment: "other"), study(2), study(3, comment4: "keep")]
        var preferences = datePreferences
        preferences.commentFilterEnabled = true
        preferences.commentFilterText = "KEEP"
        #expect(try dateIDs(rows, preferences) == [0])
        preferences.commentFilterMode = 1
        #expect(try dateIDs(rows, preferences) == [1, 2, 3])
        preferences.commentFilterMode = 2
        #expect(try dateIDs(rows, preferences) == [0, 1, 2, 3])
    }

    @Test func noCommentFilterTextStopsTheRuleOnlyWhenThereIsAStudyToFilter() throws {
        var preferences = datePreferences
        preferences.commentFilterEnabled = true
        #expect(throws: AutoCleanupPolicyError.missingCommentFilterText) { try dateIDs([study(0)], preferences) }
        #expect(try dateIDs([study(0, locked: true)], preferences) == [])
    }

    @Test func atMostFiftyStudiesGoInPatientOrder() throws {
        let rows = (0..<60).reversed().map { study($0, patient: String(format: "P%03d", $0)) }
        #expect(try dateIDs(rows) == Array(0..<50))
    }

    @Test func theLimitComesAfterEveryFilter() throws {
        let rows = (0..<60).map { study($0, patient: String(format: "P%03d", $0), locked: $0 < 5) }
        #expect(try dateIDs(rows) == Array(5..<55))
    }

    @Test func studiesWithTheSameUIDKeepTheirOrder() throws {
        #expect(try dateIDs([study(7), study(3), study(5)]) == [7, 3, 5])
    }

    @Test func theDaysAreMultipliedAs32BitNumbers() throws {
        var preferences = datePreferences
        preferences.producedDays = 25
        #expect(try dateIDs([study(0, age: 10)], preferences) == [])
        // 40000 days in seconds wraps to a date in the future, which every
        // study is older than.
        preferences.producedDays = 40000
        #expect(try dateIDs([study(0, age: 10)], preferences) == [0])
    }

    // MARK: Space rule

    @Test func theSpaceRuleLeavesLockedStudiesAlbumsAndRecentlyAdded() throws {
        let rows = [study(0, locked: true), study(1, album: true), study(2, added: now.addingTimeInterval(-3600)), study(3)]
        let found = try AutoCleanupPolicy.spaceCandidates(in: rows, preferences: AutoCleanupPreferences(), now: now)
        #expect(found.rows.map { $0.id } == [3])
        #expect(found.leftOutRecentlyAdded)
    }

    @Test func aStudyLeftOutForAnotherReasonIsNotCountedAsRecentlyAdded() throws {
        let rows = [study(0, added: now.addingTimeInterval(-3600), locked: true), study(1, added: now.addingTimeInterval(-3600), album: true)]
        #expect(try !AutoCleanupPolicy.spaceCandidates(in: rows, preferences: AutoCleanupPreferences(), now: now).leftOutRecentlyAdded)
    }

    @Test func aStudyWithNoDateAddedIsRecentForTheSpaceRule() throws {
        let row = CleanupStudyRow(id: 0, patientUID: "A", date: daysAgo(100), dateOpened: nil, dateAdded: nil, isLocked: false, isInAlbum: false)
        let found = try AutoCleanupPolicy.spaceCandidates(in: [row], preferences: AutoCleanupPreferences(), now: now)
        #expect(found.rows.isEmpty && found.leftOutRecentlyAdded)
    }

    @Test func theSpaceRuleKeepsCommentedStudiesOnlyWhenAsked() throws {
        let rows = [study(0, comment4: "keep"), study(1)]
        #expect(try Set(spaceIDs(rows)) == [0, 1])
        var preferences = AutoCleanupPreferences()
        preferences.keepsStudiesWithComments = true
        #expect(try spaceIDs(rows, preferences) == [1])
    }

    @Test func theModeChoosesTheDateThatOrders() throws {
        let rows = [CleanupStudyRow(id: 0, patientUID: "A", date: daysAgo(10), dateOpened: daysAgo(30), dateAdded: daysAgo(20), isLocked: false, isInAlbum: false),
                    CleanupStudyRow(id: 1, patientUID: "A", date: daysAgo(20), dateOpened: daysAgo(10), dateAdded: daysAgo(30), isLocked: false, isInAlbum: false),
                    CleanupStudyRow(id: 2, patientUID: "A", date: daysAgo(30), dateOpened: nil, dateAdded: daysAgo(20), isLocked: false, isInAlbum: false)]
        var preferences = AutoCleanupPreferences()
        preferences.spaceMode = 0
        #expect(try spaceIDs(rows, preferences) == [2, 1, 0])
        preferences.spaceMode = 1
        #expect(try spaceIDs(rows, preferences) == [0, 2, 1])
        preferences.spaceMode = 2
        #expect(try spaceIDs(rows, preferences) == [1, 0, 2])
    }

    @Test func aModeOfNoKnownDateKeepsTheOrderTheyCameIn() throws {
        var preferences = AutoCleanupPreferences()
        preferences.spaceMode = 7
        #expect(try spaceIDs([study(2, age: 10), study(0, age: 100), study(1, age: 50)], preferences) == [2, 0, 1])
    }

    @Test func undatedStudiesGoLastInTheOrderTheyCameIn() throws {
        func undated(_ id: Int) -> CleanupStudyRow {
            CleanupStudyRow(id: id, patientUID: "A", date: nil, dateOpened: nil, dateAdded: daysAgo(100), isLocked: false, isInAlbum: false)
        }
        #expect(try spaceIDs([undated(5), study(1, age: 20), undated(4), study(0, age: 30)]) == [0, 1, 5, 4])
    }

    @Test func equalDatesKeepTheOrderTheyCameIn() throws {
        #expect(try spaceIDs([study(9), study(3), study(6)]) == [9, 3, 6])
    }

    @Test func anUnreadableModeStopsTheSpaceRule() throws {
        var preferences = AutoCleanupPreferences()
        preferences.spaceMode = nil
        #expect(throws: AutoCleanupPolicyError.unreadableSpaceMode) { try spaceIDs([study(0)], preferences) }
    }

    @Test func thePreviewLeavesWhatTheDateRuleTakesAndStopsAtFifty() {
        let rows = (0..<60).map { study($0) }
        let listed = AutoCleanupPolicy.previewSpaceCandidates(rows, leaving: Array(rows[..<3]))
        #expect(listed.map { $0.id } == Array(3..<53))
    }

    @Test func theThresholdIsMegabytesOrAPercentageOfTheVolume() {
        let gigabyte: UInt64 = 1000 * 1048576
        #expect(AutoCleanupPolicy.cleanupThreshold(setting: 300, capacity: gigabyte) == 300)
        #expect(AutoCleanupPolicy.cleanupThreshold(setting: -10, capacity: gigabyte) == 100)
        for setting in [0, .infinity, -.infinity, .nan, 1e30] {
            #expect(AutoCleanupPolicy.cleanupThreshold(setting: setting, capacity: gigabyte) == 0)
        }
    }

    @Test func theTriggerCleansBelowTheLimitAndWarnsWithin20Percent() {
        #expect(AutoCleanupPolicy.spaceTrigger(free: 99, requested: 100) == .clean)
        #expect(AutoCleanupPolicy.spaceTrigger(free: 100, requested: 100) == .limitSoonReached)
        #expect(AutoCleanupPolicy.spaceTrigger(free: 120, requested: 100) == .limitSoonReached)
        #expect(AutoCleanupPolicy.spaceTrigger(free: 121, requested: 100) == .enough)
    }

    @Test func theSpaceRuleStopsWithEnoughSpaceOrAtFiftyStudies() {
        #expect(!AutoCleanupPolicy.spaceRuleStops(free: 99, requested: 100, deleted: 49))
        #expect(AutoCleanupPolicy.spaceRuleStops(free: 100, requested: 100, deleted: 1))
        #expect(AutoCleanupPolicy.spaceRuleStops(free: 99, requested: 100, deleted: 50))
    }

    @Test func logEntriesAreCutOffByTheirOwnDays() {
        var preferences = AutoCleanupPreferences()
        preferences.logRetentionDays = 30
        #expect(AutoCleanupPolicy.logCutoff(preferences: preferences, now: now) == daysAgo(30))
    }

    // MARK: Preferences

    @Test func theRetentionPeriodsMustBeMoreThanOneDay() {
        var preferences = AutoCleanupPreferences()
        preferences.logRetentionDays = 2
        preferences.producedRetentionDays = 2
        preferences.openedRetentionDays = 2
        #expect(preferences.retentionPeriodsAreValid)
        preferences.openedRetentionDays = 1
        #expect(!preferences.retentionPeriodsAreValid)
    }

    @Test func theDateRuleNeedsItsSwitchAndACondition() {
        var preferences = AutoCleanupPreferences()
        preferences.usesDateOpened = true
        #expect(!preferences.runsDateRule)
        preferences.dateRuleEnabled = true
        #expect(preferences.runsDateRule)
        preferences.usesDateOpened = false
        #expect(!preferences.runsDateRule)
    }

    /// Preferences in memory: no domain is written.
    @Test func thePreferencesAreReadWithTheirKeysAndConversions() {
        let defaults = MemoryPreferences()
        defaults.register(defaults: [
            "LOGCLEANINGDAYS": 30, "AUTOCLEANINGDATEPRODUCEDDAYS": "45", "AUTOCLEANINGDATEOPENEDDAYS": 60,
            "AUTOCLEANINGDATE": true, "AUTOCLEANINGDATEPRODUCED": true, "AUTOCLEANINGDATEOPENED": true,
            "AUTOCLEANINGCOMMENTS": true, "AUTOCLEANINGCOMMENTSTEXT": "text", "AUTOCLEANINGDONTCONTAIN": 1,
            "dontDeleteStudiesWithComments": true, "AUTOCLEANINGDELETEORIGINAL": true,
            "AUTOCLEANINGSPACE": true, "AUTOCLEANINGSPACESIZE": "-12.5", "AutocleanSpaceMode": "2"])
        var preferences = AutoCleanupPreferences(defaults: defaults)
        #expect(preferences.logRetentionDays == 30)
        #expect(preferences.producedRetentionDays == 45 && preferences.producedDays == 45)
        #expect(preferences.openedRetentionDays == 60 && preferences.openedDays == 60)
        #expect(preferences.dateRuleEnabled && preferences.usesDateProduced && preferences.usesDateOpened)
        #expect(preferences.commentFilterEnabled && preferences.commentFilterText == "text" && preferences.commentFilterMode == 1)
        #expect(preferences.keepsStudiesWithComments && preferences.deletesLinkedOriginals)
        #expect(preferences.spaceRuleEnabled && preferences.spaceSizeSetting == -12.5)
        #expect(preferences.spaceMode == 2 && preferences.spaceModeSetting == 2)

        defaults.register(defaults: ["AutocleanSpaceMode": 1])
        preferences = AutoCleanupPreferences(defaults: defaults)
        #expect(preferences.spaceMode == 1)

        defaults.register(defaults: ["AutocleanSpaceMode": ["not", "a", "mode"]])
        preferences = AutoCleanupPreferences(defaults: defaults)
        #expect(preferences.spaceMode == nil)
    }
}
