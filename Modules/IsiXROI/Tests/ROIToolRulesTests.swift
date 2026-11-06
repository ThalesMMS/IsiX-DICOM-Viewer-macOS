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
@testable import IsiXROI

/// Identities for the candidates: one object per ROI or viewer.
private final class Token {}

@Suite struct ROIIntersliceSelectionTests {

    private let viewer = Token(), other = Token()
    private let a = Token(), b = Token(), c = Token(), alias = Token()

    private func candidate(_ roi: Token, _ slice: Int, selected: Bool = false, in viewer: Token? = nil) -> ROIIntersliceCandidate {
        ROIIntersliceCandidate(roi: ObjectIdentifier(roi), viewer: ObjectIdentifier(viewer ?? self.viewer), slice: slice, isSelected: selected)
    }

    @Test func distinctSlicesNeedAnotherROIOnAnotherSliceOrViewer() {
        #expect(!ROIIntersliceSelection.onDistinctSlices(candidate(a, 0), candidate(a, 3)))
        #expect(!ROIIntersliceSelection.onDistinctSlices(candidate(a, 2), candidate(b, 2)))
        #expect(ROIIntersliceSelection.onDistinctSlices(candidate(a, 2), candidate(b, 3)))
        #expect(ROIIntersliceSelection.onDistinctSlices(candidate(a, 2), candidate(b, 2, in: other)))
    }

    @Test func withoutSelectionTheFirstPairInOrder() {
        let candidates = [candidate(a, 1), candidate(b, 1), candidate(c, 4)]
        #expect(ROIIntersliceSelection.pair(of: candidates, preferred: nil).map { [$0.first, $0.second] } == [0, 2])
    }

    @Test func thePreferredROIGoesWithTheFirstOfThePool() {
        let candidates = [candidate(a, 0), candidate(alias, 1), candidate(b, 2), candidate(alias, 3)]
        // The alias's last candidate is the preferred one.
        #expect(ROIIntersliceSelection.pair(of: candidates, preferred: ObjectIdentifier(alias)).map { [$0.first, $0.second] } == [3, 0])
        #expect(ROIIntersliceSelection.pair(of: candidates, preferred: ObjectIdentifier(Token())).map { [$0.first, $0.second] } == [0, 1])
    }

    @Test func twoSelectedArePoolEvenOnOneSlice() {
        let candidates = [candidate(a, 0), candidate(b, 2, selected: true), candidate(c, 2, selected: true)]
        #expect(ROIIntersliceSelection.pair(of: candidates, preferred: nil) == nil)
        #expect(ROIIntersliceSelection.pair(of: candidates, preferred: ObjectIdentifier(a)).map { [$0.first, $0.second] } == [0, 1])
    }

    @Test func oneSelectedPairsWithAnyOther() {
        // Alone selected, b is the pool's only candidate on its slice: the
        // pool is every candidate, whose first pair is a and b.
        let candidates = [candidate(a, 0), candidate(b, 2, selected: true)]
        #expect(ROIIntersliceSelection.pair(of: candidates, preferred: nil).map { [$0.first, $0.second] } == [0, 1])
        #expect(ROIIntersliceSelection.pair(of: [candidate(a, 0, selected: true), candidate(a, 1)], preferred: nil) == nil)
        #expect(ROIIntersliceSelection.pair(of: [], preferred: nil) == nil)
    }
}

@Suite struct ROIBrushConversionTests {

    @Test func theFiltersOfTheMenuTags() {
        #expect((0 ..< 4).map { ROIBrushMorphology.action(forTag: $0) } == ["erode", "dilate", "close", "open"])
        #expect(ROIBrushMorphology.action(forTag: 4) == nil && ROIBrushMorphology.action(forTag: -1) == nil)
    }

    @Test func samplesSpreadAlongTheClosedContour() {
        let samples = ROIContourResampling.samples(contourCount: 7, numPoints: 3)
        #expect(samples.map(\.from) == [0, 2, 4])
        #expect(samples.map(\.to) == [1, 3, 5])
        #expect(samples[1].ratio == Float(7) / 3 - 2)
        // The last point goes back to the first.
        let around = ROIContourResampling.samples(contourCount: 4, numPoints: 8)
        #expect(around.last == ROIContourSample(from: 3, to: 0, ratio: 0.5))
        #expect(ROIContourResampling.samples(contourCount: 1, numPoints: 2) == [ROIContourSample(from: 0, to: 0, ratio: 0), ROIContourSample(from: 0, to: 0, ratio: 0.5)])
    }

    @Test func noPointsForNoneAsked() {
        #expect(ROIContourResampling.samples(contourCount: 9, numPoints: 0).isEmpty)
        #expect(ROIContourResampling.samples(contourCount: 9, numPoints: -3).isEmpty)
    }
}

@Suite struct ROIUndoQueuePolicyTests {

    @Test func aSizeOfZeroOrLessTurnsTheQueueOff() {
        #expect(!ROIUndoQueuePolicy(size: 0, recordsROIs: true).isEnabled)
        #expect(!ROIUndoQueuePolicy(size: -2, recordsROIs: true).isEnabled)
        #expect(ROIUndoQueuePolicy(size: 1, recordsROIs: false).isEnabled)
    }

    @Test func theOldestGoesBeyondTheSize() {
        let policy = ROIUndoQueuePolicy(size: 3, recordsROIs: true)
        #expect(!policy.dropsOldest(count: 3))
        #expect(policy.dropsOldest(count: 4))
    }
}
