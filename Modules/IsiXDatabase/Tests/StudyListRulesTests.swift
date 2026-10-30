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
@testable import IsiXDatabase

@Suite struct StudyListRulesTests {

    @Test func entireDatabaseResultShowsTheLargerCount() {
        #expect(EntireDatabaseResult.shownCount(distant: 0, local: 0, displayed: 0) == nil)
        #expect(EntireDatabaseResult.shownCount(distant: 3, local: 9, displayed: 4) == 9)
        #expect(EntireDatabaseResult.shownCount(distant: 4, local: 4, displayed: 4) == nil)
        // A negative count compared with the list's count is a huge unsigned one.
        #expect(EntireDatabaseResult.shownCount(distant: -1, local: 0, displayed: 3) == 0)
    }

    @Test func listPredicateAddsEachFilterInFront() {
        let start = Date(timeIntervalSinceReferenceDate: 10), end = Date(timeIntervalSinceReferenceDate: 20)
        let made = StudyListPredicate.make(start: start, end: end, modality: "CT", filter: NSPredicate(format: "name == 'a'"), test: nil)
        #expect(made.filtered)
        #expect(made.predicate.predicateFormat.hasPrefix("name == \"a\" AND (modality CONTAINS \"CT\""))
        let none = StudyListPredicate.make(start: nil, end: nil, modality: nil, filter: nil, test: nil)
        #expect(none.predicate.predicateFormat == "TRUEPREDICATE" && !none.filtered)
    }

    @Test func listMergeAddsReplacesAndRetrieves() {
        let merge = DistantStudyMerge.list(localUIDs: ["1", "2"], distantUIDs: ["3", "2", nil], preferMoreImages: true,
                                           autoretrieve: false, retrievePartial: false, inRetrieveQueue: { _ in false },
                                           localRawFiles: { _ in 1 }, distantRawFiles: { _ in 5 }, distantFiles: { _ in 5 })
        #expect(merge.added == [0, 2])
        #expect(merge.replaced == [DistantStudyMerge.Replacement(row: 1, distant: 1)])
        #expect(merge.retrieved.isEmpty)
    }

    @Test func historyMergeKeepsTheStudyBeingRetrieved() {
        let merge = DistantStudyMerge.history(localUIDs: ["1"], distantUIDs: ["1", "2", "2"], preferMoreImages: true,
                                              retrievePartial: true, inRetrieveQueue: { $0 == 0 },
                                              localRawFiles: { _ in 0 }, distantRawFiles: { _ in 3 }, distantFiles: { _ in 3 })
        #expect(merge.members == [.local(0), .distant(1)])
        #expect(merge.retrieved.isEmpty)
    }

    @Test func groupingInsertsOtherStudiesWithinTheLimit() {
        let rows = StudyListOrder.groupedByPatient(uids: ["a", "b"], limit: 1) { index in
            index == 0 ? ["c", "d"] : ["a"]
        }
        #expect(rows == [.study(0), .related(of: 0, 0), .study(1)])
    }

    @Test func sortDescriptorsDefaultToNameThenDate() {
        let defaults = StudyListOrder.descriptors(nil)
        #expect(defaults.map(\.key) == ["name", "date"])
        let byDate = NSSortDescriptor(key: "date", ascending: true)
        #expect(StudyListOrder.descriptors([byDate]) == [byDate])
    }

    @Test func studyImagesWalk() {
        var walk = SelectionImages.Walk(preferred: SelectionImages.firstForFirst)
        #expect(walk.next(hasThumbnail: { true }) == SelectionImages.firstForFirst)
        #expect(walk.next(hasThumbnail: { true }) == SelectionImages.firstForFirst)
        #expect(walk.next(hasThumbnail: { true }) == SelectionImages.any)
        #expect(walk.next(hasThumbnail: { false }) == SelectionImages.middle)
        #expect(SelectionImages.middleIndex(count: 6) == 2 && SelectionImages.middleIndex(count: 1) == 0)
        #expect(SelectionImages.middleIndex(count: 0) == nil)
    }

    @Test func searchFiltersAndSecondNameQuery() {
        let search = DistantSearch.searchFilters("smith, john", type: 0, modality: "MR")
        #expect(search.filters["PatientsName"] as? String == "smith john*")
        #expect(search.filters["modality"] as? [String] == ["MR"])
        #expect(DistantSearch.alternatePatientName(search.name, type: 0) == "smith^john*")
        #expect(DistantSearch.alternatePatientName("smith", type: 0) == nil)
        #expect(DistantSearch.intervalFilters(from: nil, to: Date(), modality: nil) == nil)
    }

    @Test func processLocks() {
        #expect(ProcessLocks.pid(forFileName: "lock_process-42") == 42)
        #expect(ProcessLocks.pid(forFileName: "other") == nil)
        #expect(ProcessLocks.isStale(sinceNow: -3700) && !ProcessLocks.isStale(sinceNow: -3500))
    }
}
