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

/// Where a propagation of ROIs goes, and the fills of the Set Pixels sheet.
struct ROIPropagationPlanTests {

    func range(_ current: Int, _ imageNumber: Int, _ count: Int, flipped: Bool = false) -> Range<Int> {
        ROIPropagationPlan.imageRange(current: current, imageNumber: imageNumber, count: count, flipped: flipped)
    }

    @Test func theRangeReachesTheImageThePanelNamesInBothDirections() {
        // From index 5 of 10, "Im: 6/10", or "Im: 5/10" with flipped data.
        #expect(range(5, -3, 10) == 0..<6)
        #expect(range(5, 0, 10) == 0..<6)
        #expect(range(5, 3, 10) == 2..<6)
        #expect(range(5, 9, 10) == 5..<9)
        #expect(range(5, 40, 10) == 5..<10)
        #expect(range(5, 8, 10, flipped: true) == 2..<6)
        #expect(range(5, 2, 10, flipped: true) == 5..<9)
        #expect(range(5, 40, 10, flipped: true) == 0..<6)
        #expect(range(5, -3, 10, flipped: true) == 5..<10)
        #expect(range(0, 1, 0).isEmpty)
    }

    @Test func theSlabRunsFromTheCurrentImageToItsFarEnd() {
        #expect(ROIPropagationPlan.slabRange(current: 5, farEnd: 7) == 5..<8)
        #expect(ROIPropagationPlan.slabRange(current: 5, farEnd: 3) == 3..<6)
        #expect(ROIPropagationPlan.slabRange(current: 0, farEnd: 0) == 0..<1)
        #expect(ROIPropagationPlan.slabRange(current: 5, farEnd: -1).isEmpty)
    }

    @Test func theTimePointStaysInsideTheListsAndTheirFirstSlot() {
        #expect(ROIPropagationPlan.movieIndex(2, movieCount: 0) == 0)
        #expect(ROIPropagationPlan.movieIndex(7, movieCount: 3) == 2)
        #expect(ROIPropagationPlan.movieIndex(-4, movieCount: 3) == 0)
        #expect(ROIPropagationPlan.movieIndex(1, movieCount: 3) == 1)
    }

    @Test func thePlansLeaveOutTheCurrentImage() {
        let series = ROIPropagationPlan.series(movie: 1, current: 3, range: 2..<6, copies: false)
        #expect(series.destinations.map(\.slice) == [2, 4, 5])
        #expect(series.destinations.allSatisfy { $0.movie == 1 })
        #expect(!series.copies && series.unaliasesCopies)
        let slab = ROIPropagationPlan.slab(movie: 0, current: 5, range: 5..<8)
        #expect(slab.destinations.map(\.slice) == [6, 7] && slab.copies && slab.unaliasesCopies)
        let times = ROIPropagationPlan.timePoints(movie: 1, movieCount: 4, slice: 9, copies: true)
        #expect(times.destinations == [.init(movie: 0, slice: 9), .init(movie: 2, slice: 9), .init(movie: 3, slice: 9)])
        #expect(times.copies && !times.unaliasesCopies)
    }
}

struct ROISetPixelsJobTests {
    typealias Fill = ROISetPixelsJob.Fill

    func job(_ scope: ROISetPixelsJob.Scope, in4D: Bool = false, outside: Bool = false) -> ROISetPixelsJob {
        ROISetPixelsJob(scope: scope, propagateIn4D: in4D, outside: outside, minValue: -1, maxValue: 1, newValue: 0, revert: false)
    }

    @Test func theSheetsTagsAreTheScopes() {
        #expect(ROISetPixelsJob.Scope(tag: 0) == .sameNameAsSelected)
        #expect(ROISetPixelsJob.Scope(tag: 1) == .everyROI)
        #expect(ROISetPixelsJob.Scope(tag: 2) == .everyPixel)
        #expect(ROISetPixelsJob.Scope(tag: 5) == .sameNameAsSelected)
    }

    @Test func theROIsWithTheSelectedNameAreFilled() {
        let names: [[String?]] = [["Liver", "Kidney"], [], [nil, "Liver"]]
        #expect(job(.sameNameAsSelected).fills(movie: 1, movieCount: 3, roiNames: names, selectedName: "Liver")
                == [Fill(movie: 1, slice: 0, roi: 0), Fill(movie: 1, slice: 2, roi: 1)])
        #expect(job(.sameNameAsSelected).fills(movie: 0, movieCount: 1, roiNames: names, selectedName: nil).isEmpty)
        #expect(job(.everyROI).fills(movie: 0, movieCount: 1, roiNames: names, selectedName: nil)
                == [Fill(movie: 0, slice: 0, roi: 0), Fill(movie: 0, slice: 0, roi: 1), Fill(movie: 0, slice: 2, roi: 0),
                    Fill(movie: 0, slice: 2, roi: 1)])
    }

    @Test func namesAreComparedAsTheyAreWritten() {
        // A precomposed and a decomposed "é" are two names.
        #expect(job(.sameNameAsSelected).fills(movie: 0, movieCount: 1, roiNames: [["f\u{E9}mur"]], selectedName: "fe\u{301}mur").isEmpty)
    }

    @Test func everyPixelFillsEachImageOfTheCurrentTimePointWhole() {
        #expect(job(.everyPixel, in4D: true).fills(movie: 1, movieCount: 3, roiNames: [["a"], []], selectedName: "a")
                == [Fill(movie: 1, slice: 0, roi: nil), Fill(movie: 1, slice: 1, roi: nil)])
    }

    @Test func inFourDimensionsEachROIFillsTheSameImageOfEveryTimePoint() {
        #expect(job(.everyROI, in4D: true).fills(movie: 1, movieCount: 2, roiNames: [["a"]], selectedName: nil)
                == [Fill(movie: 0, slice: 0, roi: 0), Fill(movie: 1, slice: 0, roi: 0)])
    }

    @Test func outsideAnImageWithoutAROIIsFilledWhole() {
        let names: [[String?]] = [["a"], ["b"]]
        #expect(job(.sameNameAsSelected, outside: true).fills(movie: 0, movieCount: 1, roiNames: names, selectedName: "a")
                == [Fill(movie: 0, slice: 0, roi: 0), Fill(movie: 0, slice: 1, roi: nil)])
        #expect(job(.sameNameAsSelected, in4D: true, outside: true).fills(movie: 0, movieCount: 2, roiNames: names, selectedName: "a")
                == [Fill(movie: 0, slice: 0, roi: 0), Fill(movie: 1, slice: 0, roi: 0),
                    Fill(movie: 0, slice: 1, roi: nil), Fill(movie: 1, slice: 1, roi: nil)])
    }
}
