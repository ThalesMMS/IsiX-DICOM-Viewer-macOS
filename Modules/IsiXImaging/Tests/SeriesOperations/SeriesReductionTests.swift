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

@Suite struct SeriesReductionTests {

    private func reduction(_ first: Int, _ last: Int, _ step: Int, of count: Int) -> SeriesReduction? {
        try? SeriesReduction.make(first: first, last: last, step: step, sliceCount: count).get()
    }

    @Test func theDialogProposesTheWholeSeriesEverySecondSlice() {
        #expect(SeriesReduction.defaults(sliceCount: 120) == (1, 120, 2))
        #expect(reduction(1, 120, 2, of: 120)?.keptCount == 60)
    }

    @Test func theStepKeepsTheFirstSliceAndEveryStepAfterIt() {
        let r = reduction(3, 11, 3, of: 20)
        #expect(r?.keptImageNumbers == [3, 6, 9])
        #expect(r?.keptIndices(flipped: false) == [2, 5, 8])
        #expect(r?.keptCount == 3)
        // The last slice is kept when the step lands on it.
        #expect(reduction(1, 10, 3, of: 10)?.keptImageNumbers == [1, 4, 7, 10])
        // Step 1 keeps the whole range; a range of one slice keeps it.
        #expect(reduction(4, 7, 1, of: 10)?.keptIndices(flipped: false) == [3, 4, 5, 6])
        #expect(reduction(5, 5, 4, of: 10)?.keptIndices(flipped: false) == [4])
        // A step longer than the range keeps the first slice alone.
        #expect(reduction(2, 6, 50, of: 10)?.keptIndices(flipped: false) == [1])
        for count in 1...12 {
            for step in 1...5 {
                let r = reduction(1, count, step, of: count)
                #expect(r?.keptCount == r?.keptImageNumbers.count)
            }
        }
    }

    @Test func aFlippedSeriesIsCutWhereTheUserReadsIt() {
        // Ten slices shown flipped: image 1 is the slice at index 9.
        let r = reduction(1, 5, 2, of: 10)
        #expect(r?.keptIndices(flipped: true) == [5, 7, 9])
        #expect(reduction(1, 10, 1, of: 10)?.keptIndices(flipped: true) == Array(0..<10))
    }

    @Test func valuesOutsideTheSeriesAreRefused() {
        typealias P = SeriesReduction.Problem
        func problem(_ first: Int, _ last: Int, _ step: Int, _ count: Int) -> P? {
            if case .failure(let p) = SeriesReduction.make(first: first, last: last, step: step, sliceCount: count) { return p }
            return nil
        }
        #expect(problem(1, 1, 1, 0) == .emptySeries)
        #expect(problem(0, 5, 1, 10) == .firstOutOfRange)
        #expect(problem(11, 11, 1, 10) == .firstOutOfRange)
        #expect(problem(1, 11, 1, 10) == .lastOutOfRange)
        #expect(problem(1, 0, 1, 10) == .lastOutOfRange)
        #expect(problem(6, 5, 1, 10) == .lastBeforeFirst)
        #expect(problem(1, 10, 0, 10) == .stepTooSmall)
        #expect(problem(1, 10, -2, 10) == .stepTooSmall)
        #expect(problem(1, 10, 1, 10) == nil)
    }

    @Test func theReducedIntervalIsTheStepTimesTheOriginal() {
        #expect(reduction(1, 30, 3, of: 30)?.sliceInterval(original: 1.25) == 3.75)
        #expect(reduction(1, 30, 2, of: 30)?.sliceInterval(original: -2.5) == -5)
        #expect(reduction(1, 30, 1, of: 30)?.sliceInterval(original: 0.6) == 0.6)
    }

    /// A synthetic oblique stack, its slices kept by their indices: the
    /// interval between every two kept slices, read from their positions as
    /// the viewer reads it, is the reduced interval, and the kept positions are
    /// the original ones.
    @Test func theKeptPositionsMakeARegularStackOfTheReducedInterval() {
        let interval = 1.5
        // Rows along x, columns tilted between y and z; the normal is mostly z.
        let c = cos(0.2), s = sin(0.2)
        let orientation = [1, 0, 0, 0, c, -s, 0, s, c]
        let normal = Array(orientation[6...8])
        let origin0 = [-120.0, -80.0, 40.0]
        let origins = (0..<41).map { i in (0..<3).map { origin0[$0] + Double(i) * interval * normal[$0] } }
        let original = Double(SliceStack.interval(fromOrigin: origins[0], orientation: orientation,
                                                  toOrigin: origins[1], orientation: orientation))

        for (first, last, step, flipped) in [(1, 41, 2, false), (5, 33, 4, false), (2, 40, 3, true), (1, 41, 1, false)] {
            guard let r = reduction(first, last, step, of: origins.count) else {
                Issue.record("\(first)–\(last) every \(step) refused")
                continue
            }
            let kept = r.keptIndices(flipped: flipped).map { origins[$0] }
            let expected = r.sliceInterval(original: original)
            for (a, b) in zip(kept, kept.dropFirst()) {
                let measured = Double(SliceStack.interval(fromOrigin: a, orientation: orientation, toOrigin: b, orientation: orientation))
                #expect(abs(measured - expected) < 1e-4, "\(first)–\(last) every \(step): \(measured) for \(expected)")
                let distance = sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
                #expect(abs(distance - interval * Double(step)) < 1e-9)
            }
        }
    }

    @Test func theNewViewerOpensOnTheKeptSliceNearestTheOneShown() {
        let r = reduction(1, 20, 4, of: 20)    // indices 0, 4, 8, 12, 16
        #expect(r?.nearestKeptPosition(to: 0, flipped: false) == 0)
        #expect(r?.nearestKeptPosition(to: 9, flipped: false) == 2)
        #expect(r?.nearestKeptPosition(to: 10, flipped: false) == 2)   // a tie goes to the earlier one
        #expect(r?.nearestKeptPosition(to: 19, flipped: false) == 4)
        // Flipped: indices 3, 7, 11, 15, 19.
        #expect(r?.nearestKeptPosition(to: 18, flipped: true) == 4)
        #expect(r?.nearestKeptPosition(to: 0, flipped: true) == 0)
    }
}
