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

/// The volume of the ROIs of one name, in values.
struct ROIVolumeJobTests {

    @Test func aROIWithoutAreaStopsTheJob() throws {
        var job = ROIVolumeJob()
        try job.addROI(onImage: 2, area: 1.5)
        #expect(throws: ROIVolumeJob.Failure.zeroArea) { try job.addROI(onImage: 3, area: 0) }
        #expect(ROIVolumeJob.Failure.zeroArea.message == "One ROI has an area equal to ZERO!")
    }

    @Test func anImageWithoutROIBetweenTwoIsMissing() throws {
        var job = ROIVolumeJob()
        try job.addROI(onImage: 2, area: 1)
        try job.addROI(onImage: 2, area: 1)
        try job.addROI(onImage: 3, area: 1)
        #expect(!job.hasMissingImage)
        try job.addROI(onImage: 5, area: 1)
        #expect(job.hasMissingImage)
        #expect(job.roiCount == 4)
        #expect(job.occupiedImages == [2, 3, 5])
    }

    @Test func aVolumeNeedsTwoPlanesAndNoZero() {
        #expect(ROIVolumeJob.failure(volumeCm3: nil, occupiedPlaneCount: 0) == .singleROI)
        #expect(ROIVolumeJob.failure(volumeCm3: 3, occupiedPlaneCount: 1) == .singleROI)
        #expect(ROIVolumeJob.failure(volumeCm3: 0, occupiedPlaneCount: 2) == .noVolume)
        #expect(ROIVolumeJob.failure(volumeCm3: 3, occupiedPlaneCount: 2) == nil)
    }

    @Test func theSurfaceIsClosedOneImageFurtherOutWithThreePoints() throws {
        #expect(ROIVolumeJob.capImages(first: 0, last: 9, imageCount: 10) == (0, 9))
        #expect(ROIVolumeJob.capImages(first: 3, last: 5, imageCount: 10) == (2, 6))
        var job = ROIVolumeJob()
        #expect(job.surfaceFailure == .noVolume)
        job.addContour([ROIVolumeJob.Point(1, 1, 1)])
        job.addCap(around: ROIVolumeJob.Point(10, 20, 30))
        #expect(job.points == [ROIVolumeJob.Point(1, 1, 1), ROIVolumeJob.Point(9, 19, 30),
                               ROIVolumeJob.Point(9, 21, 30), ROIVolumeJob.Point(10, 20, 30)])
        #expect(job.surfaceFailure == nil)
        #expect(job.countFailure == nil)
        try job.addROI(onImage: 0, area: 1)
        #expect(job.countFailure == .singleROI)
    }

    @Test func theRendererIsGivenEveryNthPointPastTheLimit() {
        var job = ROIVolumeJob()
        job.addContour((0..<(ROIVolumePoints.displayLimit * 3)).map { ROIVolumeJob.Point(Float($0), 0, 0) })
        #expect(job.displayedPoints.count == ROIVolumePoints.displayLimit)
        #expect(job.displayedPoints[1] == ROIVolumeJob.Point(3, 0, 0))
        var small = ROIVolumeJob()
        small.addContour([ROIVolumeJob.Point(1, 2, 3)])
        #expect(small.displayedPoints == small.points)
    }

    @Test func theStatisticsOfNoValuesAreZero() {
        #expect(ROIVolumeJob.statistics(of: []) == ROIValueStatistics(min: 0, max: 0, mean: 0, total: 0, deviation: 0))
        let statistics = ROIVolumeJob.statistics(of: [1, 3])
        #expect(statistics.mean == 2)
        #expect(statistics.total == 4)
        #expect(statistics.min == 1)
        #expect(statistics.max == 3)
    }
}
