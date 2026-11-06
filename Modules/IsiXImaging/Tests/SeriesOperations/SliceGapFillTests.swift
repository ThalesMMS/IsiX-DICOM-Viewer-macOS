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

// The empty slices that make a stack with missing positions regular, on
// synthetic positions: stacks with one or several slices missing, ascending
// and descending, written with rounding, and the stacks that cannot be filled.

@Suite struct SliceGapFillTests {

    /// Positions 1.25 mm apart from `start`, without the indices in `missing`.
    private func stack(_ count: Int, step: Double = 1.25, start: Double = 0, missing: Set<Int>) -> [Double] {
        (0..<count).filter { !missing.contains($0) }.map { start + Double($0) * step }
    }

    private func filled(_ outcome: SliceGapFill.Outcome) -> SliceGapFill? {
        if case .fill(let fill) = outcome { return fill }
        return nil
    }

    /// The positions of the filled stack.
    private func positions(_ fill: SliceGapFill, _ original: [Double]) -> [Double] {
        fill.slices.map { slice in
            switch slice {
            case .original(let index): return original[index]
            case let .empty(_, _, position): return position
            }
        }
    }

    @Test func oneMissingSliceGetsOneEmptySlice() throws {
        let original = stack(20, missing: [7])
        let fill = try #require(filled(SliceGapFill.plan(positions: original)))
        #expect(abs(fill.step - 1.25) < 1e-9)
        #expect(fill.slices.count == 20 && fill.emptyCount == 1)
        #expect(fill.slices[7] == .empty(after: 6, fraction: 0.5, position: 8.75))
        #expect(fill.slices[6] == .original(6) && fill.slices[8] == .original(7))
        let regular = positions(fill, original)
        for i in 1..<regular.count { #expect(abs(regular[i] - regular[i - 1] - 1.25) < 1e-9) }
    }

    @Test func aWideGapGetsAllItsMissingSlices() throws {
        // Three slices missing in one place, two in another.
        let original = stack(40, missing: [10, 11, 12, 30, 31])
        let fill = try #require(filled(SliceGapFill.plan(positions: original)))
        #expect(fill.slices.count == 40 && fill.emptyCount == 5)
        let empty = fill.slices.indices.filter { fill.slices[$0].isEmpty }
        #expect(empty == [10, 11, 12, 30, 31])
        #expect(fill.slices[11] == .empty(after: 9, fraction: 0.5, position: 13.75))
        let regular = positions(fill, original)
        for i in 1..<regular.count { #expect(abs(regular[i] - regular[i - 1] - 1.25) < 1e-9) }
    }

    @Test func aDescendingStackIsFilledDownwards() throws {
        let original = stack(15, step: -2.5, start: 100, missing: [4, 9])
        let fill = try #require(filled(SliceGapFill.plan(positions: original)))
        #expect(abs(fill.step - 2.5) < 1e-9 && fill.emptyCount == 2)
        let regular = positions(fill, original)
        for i in 1..<regular.count { #expect(abs(regular[i] - regular[i - 1] + 2.5) < 1e-9) }
    }

    @Test func positionsWrittenWithRoundingAreTolerated() throws {
        // 0.625 mm written with two decimals: intervals of 0.62 and 0.63.
        let original = stack(60, step: 0.625, missing: [25]).map { ($0 * 100).rounded() / 100 }
        let fill = try #require(filled(SliceGapFill.plan(positions: original)))
        #expect(fill.emptyCount == 1 && fill.slices[25].isEmpty)
        #expect(abs(fill.step - 0.625) < 0.005)
    }

    @Test func theStepIsTheMostCommonIntervalNotTheSmallest() throws {
        // Two slices almost on top of each other would make the smallest
        // interval tiny; the most common one, 2 mm, is the step.
        var original = stack(12, step: 2, missing: [6])
        original.insert(original[3] + 0.05, at: 4)
        let outcome = SliceGapFill.plan(positions: original)
        guard case .refused(.notMultiple(_, let step)) = outcome else {
            Issue.record("expected a refusal, got \(outcome)"); return
        }
        #expect(abs(step - 2) < 0.01)
    }

    @Test func aRegularStackHasNoGaps() {
        #expect(SliceGapFill.plan(positions: stack(30, missing: [])) == .noGaps(step: 1.25))
    }

    @Test func stacksThatCannotBeFilledAreRefused() {
        #expect(SliceGapFill.plan(positions: [0, 1.25]) == .refused(.tooFewSlices))
        #expect(SliceGapFill.plan(positions: [0, 1.25, .nan]) == .refused(.tooFewSlices))
        #expect(SliceGapFill.plan(positions: [0, 1.25, 1.25, 2.5]) == .refused(.coincidentSlices))
        #expect(SliceGapFill.plan(positions: [0, 1.25, 2.5, 1.25 * 4, 2.5]) == .refused(.notMonotonic))
        // A gap of 1.5 steps: no number of slices makes it regular.
        let outcome = SliceGapFill.plan(positions: [0, 1, 2, 3, 4.5, 5.5, 6.5])
        guard case .refused(.notMultiple(let interval, let step)) = outcome else {
            Issue.record("expected a refusal, got \(outcome)"); return
        }
        #expect(abs(interval - 1.5) < 1e-9 && abs(step - 1) < 1e-9)
    }

    @Test func positionsAreMeasuredAlongTheNormal() {
        // A tilted normal: the origins move along it and sideways.
        let normal = SIMD3<Double>(0, 0.6, 0.8)
        let sideways = SIMD3<Double>(0, 0.8, -0.6)
        let origins = [0.0, 1, 3].enumerated().map { i, along in SIMD3<Double>(5, 0, 0) + along * normal + Double(i) * sideways }
        let along = SliceGapFill.positions(origins: origins, normal: normal)
        #expect(zip(along, [0.0, 1, 3]).allSatisfy { abs($0 - $1) < 1e-9 })
        // Without a normal, the direction from the first slice to the last.
        let unoriented = SliceGapFill.positions(origins: [SIMD3(0, 0, 0), SIMD3(0, 2, 0), SIMD3(0, 6, 0)], normal: .zero)
        #expect(unoriented == [0, 2, 6])
    }

    @Test func anEmptySliceLiesBetweenItsNeighbours() {
        let origins = [SIMD3<Double>(0, 0, 0), SIMD3<Double>(2, 4, 6)]
        let empty = SliceGapFill.Slice.empty(after: 0, fraction: 0.25, position: 0)
        #expect(SliceGapFill.origin(of: empty, origins: origins) == SIMD3(0.5, 1, 1.5))
        #expect(SliceGapFill.origin(of: .original(1), origins: origins) == origins[1])
    }

    @Test func theVolumeKeepsTheOriginalsAndFillsTheEmptySlices() throws {
        // Four slices of 2 × 2, the third missing from a stack of five.
        let original = stack(5, missing: [2])
        let fill = try #require(filled(SliceGapFill.plan(positions: original)))
        let source: [Float] = (0..<16).map(Float.init)
        var volume = [Float](repeating: .nan, count: 20)
        source.withUnsafeBufferPointer { s in
            volume.withUnsafeMutableBufferPointer { v in
                fill.fillVolume(source: s.baseAddress!, sliceFloatCount: 4, into: v.baseAddress!, fillValue: -1024)
            }
        }
        #expect(volume == [0, 1, 2, 3, 4, 5, 6, 7, -1024, -1024, -1024, -1024, 8, 9, 10, 11, 12, 13, 14, 15])
    }
}
