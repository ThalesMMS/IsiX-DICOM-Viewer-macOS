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
@testable import IsiXImaging

@Suite struct TextTruncationTests {
    private func cut(_ text: String, _ length: UInt32, _ direction: UInt32) -> String {
        TextTruncation.truncate(text as NSString, toLength: length, direction: direction, ellipsis: "...") as String
    }

    @Test func eachDirection() {
        #expect(cut("abcdefghij", 6, 0) == "abc...")
        // The middle keeps one unit less than half before the ellipsis, as
        // the Objective-C did: the result is one unit longer than asked.
        #expect(cut("abcdefghij", 6, 1) == "a...hij")
        #expect(cut("abcdefghij", 6, 2) == "...hij")
    }

    @Test func shortTextsAndUnknownDirections() {
        #expect(cut("abc", 6, 0) == "abc")
        #expect(cut("abcdef", 6, 1) == "abcdef")
        #expect(cut("abcdefghij", 6, 7) == "")
    }
}

@Suite struct DatabaseRefreshPlanTests {
    @Test func noListRebuildsTheSeriesList() {
        let plan = DatabaseRefreshPlan.plan(newImages: nil as [Int]?, showsAnImage: true,
                                            isOfOpenSeries: { _ in true }, isOfSamePatient: { _ in true })
        #expect(plan == DatabaseRefreshPlan(rebuildSeriesList: true, reloadSeries: false))
    }

    @Test func openSeriesAndSamePatient() {
        var read = 0
        let plan = DatabaseRefreshPlan.plan(newImages: [1, 2, 3], showsAnImage: true,
                                            isOfOpenSeries: { read += 1; return $0 == 1 }, isOfSamePatient: { $0 == 2 })
        #expect(plan == DatabaseRefreshPlan(rebuildSeriesList: true, reloadSeries: true))
        // Read until both are asked.
        #expect(read == 2)
    }

    @Test func otherPatientsOnlyWhenTheViewerIsEmpty() {
        let shown = DatabaseRefreshPlan.plan(newImages: [5], showsAnImage: true,
                                             isOfOpenSeries: { _ in false }, isOfSamePatient: { _ in false })
        #expect(shown == DatabaseRefreshPlan(rebuildSeriesList: false, reloadSeries: false))
        let empty = DatabaseRefreshPlan.plan(newImages: [5], showsAnImage: false,
                                             isOfOpenSeries: { _ in false }, isOfSamePatient: { _ in false })
        #expect(empty == DatabaseRefreshPlan(rebuildSeriesList: true, reloadSeries: false))
    }
}
