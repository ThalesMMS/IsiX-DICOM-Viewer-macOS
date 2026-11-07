//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
import IsiXROI

/// The ROI lists of a series copied for a duplicate viewer.
struct ROISliceListCopyTests {

    final class Mark {
        let name: String
        let isCopy: Bool
        init(_ name: String, isCopy: Bool = false) { self.name = name; self.isCopy = isCopy }
    }

    func copies(_ slices: [[Mark]], skipping skipped: Set<String> = []) -> (lists: [[Mark]], made: Int) {
        var made = 0
        let lists = ROISliceListCopy.copy(slices) { mark in
            if skipped.contains(mark.name) { return nil }
            made += 1
            return Mark(mark.name, isCopy: true)
        }
        return (lists, made)
    }

    @Test func eachImageKeepsItsROIsInTheirOrderAsNewObjects() {
        let a = Mark("a"), b = Mark("b"), c = Mark("c")
        let source = [[a, b], [], [c]]
        let (lists, made) = copies(source)
        #expect(lists.map { $0.map(\.name) } == [["a", "b"], [], ["c"]])
        let allCopies = lists.joined().allSatisfy { $0.isCopy }
        #expect(allCopies)
        #expect(made == 3)
        for (copied, original) in zip(lists.joined(), source.joined()) { #expect(copied !== original) }
    }

    @Test func aROIOnEveryImageStaysOneROI() {
        let alias = Mark("alias"), own = Mark("own")
        let (lists, made) = copies([[alias], [own, alias], [alias]])
        #expect(made == 2)
        #expect(lists[0][0] === lists[1][1] && lists[1][1] === lists[2][0])
        #expect(lists[1][0] !== lists[1][1])
    }

    @Test func aROIWithNoCopyIsLeftOutEverywhere() {
        let length = Mark("length"), plain = Mark("plain")
        let (lists, made) = copies([[length, plain], [length]], skipping: ["length"])
        #expect(lists.map { $0.map(\.name) } == [["plain"], []])
        #expect(made == 1)
    }

    @Test func noImagesNoLists() {
        #expect(copies([]).lists.isEmpty)
    }
}
