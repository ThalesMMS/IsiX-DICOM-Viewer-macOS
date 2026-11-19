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
@testable import IsiXROI

@Suite struct ROIContourJoinTests {
    /// The ROIs of a series by image: a name and the overlap the finished
    /// contour has with it, which stands for its contour here.
    private func name(current: String?, around image: Int, imageCount: Int, rois: [Int: [(String, Double)]],
                      asked: inout [Int], distances: inout [[Int]]) -> String? {
        var askedImages: [Int] = [], givenDistances: [[Int]] = []
        let name = ROIContourJoin.name(
            current: current,
            neighbours: ROIEditingSession.joinedImages(around: image, imageCount: imageCount, roiListCount: imageCount),
            candidates: { image in
                askedImages.append(image)
                return (rois[image] ?? []).map { (name: $0.0, contour: $0.1) }
            },
            chosen: { overlaps, distances in
                givenDistances.append(distances)
                // The larger overlap, the first of two equal ones, none under a tenth.
                var best = -1
                for (index, overlap) in overlaps.enumerated() where overlap >= 0.1 && (best < 0 || overlap > overlaps[best]) {
                    best = index
                }
                return best
            })
        asked = askedImages
        distances = givenDistances
        return name
    }

    @Test func theNearestDistanceWithACoveredROIDecides() {
        var asked: [Int] = [], distances: [[Int]] = []
        // Image 11 covers all of "Polygon 1" on image 1 and a part of
        // "Lesion C" on image 8: the nearer one names it, and the images
        // further away are not asked for their ROIs.
        let rois: [Int: [(String, Double)]] = [1: [("Polygon 1", 1.0)], 8: [("Lesion C", 0.3)]]
        #expect(name(current: "Polygon 4", around: 11, imageCount: 12, rois: rois, asked: &asked, distances: &distances) == "Lesion C")
        #expect(asked == [10, 9, 8])
        #expect(distances == [[], [], [3]])
    }

    @Test func theImagesOfOneDistanceAreComparedTogether() {
        var asked: [Int] = [], distances: [[Int]] = []
        let rois: [Int: [(String, Double)]] = [2: [("Before", 0.4)], 6: [("After", 0.2), ("After too", 0.9)], 3: [("Touching", 0.05)]]
        #expect(name(current: "Oval 9", around: 4, imageCount: 8, rois: rois, asked: &asked, distances: &distances) == "After too")
        // Distance 1 has a ROI the contour does not cover, so distance 2 is
        // asked: the image before first, then the image after.
        #expect(asked == [3, 5, 2, 6])
        #expect(distances == [[1], [2, 2, 2]])
    }

    @Test func aContourThatCoversNothingKeepsItsName() {
        var asked: [Int] = [], distances: [[Int]] = []
        let rois: [Int: [(String, Double)]] = [0: [("Oval 1", 0.0)], 3: [("Oval 2", 0.09)]]
        #expect(name(current: "Oval 3", around: 1, imageCount: 4, rois: rois, asked: &asked, distances: &distances) == nil)
        #expect(asked == [0, 2, 3])
        #expect(name(current: "Oval 3", around: 0, imageCount: 1, rois: [:], asked: &asked, distances: &distances) == nil)
        #expect(asked.isEmpty && distances.isEmpty)
    }

    @Test func aContourAlreadyNamedAsTheChosenROIStopsThere() {
        var asked: [Int] = [], distances: [[Int]] = []
        // The nearest covered ROI has the contour's name: nothing changes, and
        // the ROI further away, of another name, does not rename it.
        let rois: [Int: [(String, Double)]] = [2: [("Lesion", 0.8)], 0: [("Other", 1.0)]]
        #expect(name(current: "Lesion", around: 3, imageCount: 5, rois: rois, asked: &asked, distances: &distances) == nil)
        #expect(asked == [2, 4])
        #expect(name(current: nil, around: 3, imageCount: 5, rois: rois, asked: &asked, distances: &distances) == "Lesion")
    }
}
