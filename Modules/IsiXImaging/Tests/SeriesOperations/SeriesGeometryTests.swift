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

@Suite struct OrientationToolTests {

    @Test func stackedOrientationsNameTheirTool() {
        #expect(SliceStackOrientation.axialNegative.tool == .axial)
        #expect(SliceStackOrientation.coronalPositive.tool == .coronal)
        #expect(SliceStackOrientation.sagittalNegative.tool == .sagittal)
        for orientation in [SliceStackOrientation.axialPositive, .axialNegative, .coronalPositive, .coronalNegative,
                            .sagittalPositive, .sagittalNegative] {
            #expect(orientation.tool.rawValue == orientation.orthogonalTag)
        }
    }

    @Test func everyChangeReslicesThenStandsTheSlicesUp() {
        let table: [(OrientationTool, OrientationTool, Int, [SeriesReorientation.Step])] = [
            (.axial, .coronal, 0, []), (.axial, .sagittal, 1, []),
            (.coronal, .axial, 0, [.flipVertically]), (.coronal, .sagittal, 1, [.rotateClockwise]),
            (.sagittal, .axial, 0, [.rotateClockwise, .flipHorizontally]),
            (.sagittal, .coronal, 1, [.rotateClockwise, .flipHorizontally]),
        ]
        for (from, to, direction, steps) in table {
            let change = SeriesReorientation(from: from, to: to)
            #expect(change?.resliceDirection == direction && change?.steps == steps, "\(from) → \(to)")
            #expect(SeriesReorientation(from: Int(from.rawValue), to: Int(to.rawValue)) == change)
        }
        for tool in OrientationTool.allCases { #expect(SeriesReorientation(from: tool, to: tool) == nil) }
    }

    @Test func tagsThatAreNotToolsReslicesNothing() {
        #expect(SeriesReorientation(from: -1, to: 1) == nil)
        #expect(SeriesReorientation(from: 0, to: 3) == nil)
        #expect(SeriesReorientation(from: 65536, to: 1) == nil)
    }

    @Test func flipsTurnTheirAxisAndMoveTheOriginToTheOtherEnd() {
        let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(SeriesReorientation.orientation(axial, after: .flipVertically) == [1, 0, 0, -0.0, -1, -0.0, 0, 0, 1])
        #expect(SeriesReorientation.orientation(axial, after: .flipHorizontally) == [-1, -0.0, -0.0, 0, 1, 0, 0, 0, 1])
        #expect(SeriesReorientation.orientation(axial, after: .rotateClockwise) == nil)
        #expect(SeriesReorientation.originPixel(after: .flipVertically, width: 4, height: 3)! == (0, -2))
        #expect(SeriesReorientation.originPixel(after: .flipHorizontally, width: 4, height: 3)! == (-3, 0))
        #expect(SeriesReorientation.originPixel(after: .rotateClockwise, width: 4, height: 3) == nil)
    }
}

@Suite struct SliceIntervalCorrectionTests {

    let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    @Test func aDescendingStackIsReversedOnlyWhenItFlipsNow() throws {
        let later = try #require(SliceIntervalCorrection(orientation1: axial, orientation2: axial, origin1: [0, 0, 10], origin2: [0, 0, 7.5],
                                                         firstOrigin: [0, 0, 12.5], spacingBetweenSlices: 0, flipNow: false))
        #expect(later.spacing.orientation == .axialPositive && later.interval == -2.5 && !later.stacksWithoutPosition)
        #expect(!later.reversesStack && later.sliceInterval == -2.5)
        let now = try #require(SliceIntervalCorrection(orientation1: axial, orientation2: axial, origin1: [0, 0, 10], origin2: [0, 0, 7.5],
                                                       firstOrigin: [0, 0, 12.5], spacingBetweenSlices: 0, flipNow: true))
        #expect(now.reversesStack && now.reversedSliceInterval == 2.5)
    }

    @Test func anObliqueStepGivesTheThreeDimensionalInterval() throws {
        let correction = try #require(SliceIntervalCorrection(orientation1: axial, orientation2: axial, origin1: [0, 0, 0], origin2: [3, 0, 4],
                                                              firstOrigin: [0, 0, -4], spacingBetweenSlices: 0, flipNow: true))
        #expect(correction.interval == 4 && correction.interval3D == 5 && correction.sliceInterval == 5 && !correction.reversesStack)
    }

    @Test func slicesOfOtherOrientationsAreLeftAlone() {
        let coronal: [Double] = [1, 0, 0, 0, 0, -1, 0, 1, 0]
        #expect(SliceIntervalCorrection(orientation1: axial, orientation2: coronal, origin1: [0, 0, 0], origin2: [0, 0, 1],
                                        firstOrigin: [0, 0, 0], spacingBetweenSlices: 2, flipNow: true) == nil)
    }

    @Test func slicesWithoutAPositionAreStackedByTheirSpacing() throws {
        let zero = [Double](repeating: 0, count: 3)
        let correction = try #require(SliceIntervalCorrection(orientation1: axial, orientation2: axial, origin1: zero, origin2: zero,
                                                              firstOrigin: zero, spacingBetweenSlices: 1.5, flipNow: false))
        #expect(correction.stacksWithoutPosition && correction.interval == 1.5 && correction.interval3D == -1.5)
        // The 3D interval is the negated spacing, as the viewer has always set it.
        #expect(correction.sliceInterval == -1.5)
        let unspaced = try #require(SliceIntervalCorrection(orientation1: axial, orientation2: axial, origin1: zero, origin2: zero,
                                                            firstOrigin: zero, spacingBetweenSlices: 0, flipNow: false))
        #expect(!unspaced.stacksWithoutPosition && unspaced.interval == 0)
        #expect(SliceIntervalCorrection.originsWithoutPosition(count: 3, interval: 0.1) == [[0, 0, 0], [0, 0, 0.1], [0, 0, Float(Double(Float(0.1)) + 0.1)]])
    }

    @Test func gantryTiltAgainstTheTolerance() {
        let degree = Double(Float(Double.pi / 180.0))
        #expect(SliceIntervalCorrection.gantryTilt(angle: 3.5 * degree, tolerance: 0.2) == .tilted(degrees: 3.5))
        #expect(SliceIntervalCorrection.gantryTilt(angle: -0.1 * degree, tolerance: 0.2) == .tolerated(degrees: 0.1))
        #expect(SliceIntervalCorrection.gantryTilt(angle: 90 * degree, tolerance: 0.2) == .none)
        #expect(SliceIntervalCorrection.gantryTilt(angle: 3.5 * degree, tolerance: 0.2).isTilted)
        #expect(SliceIntervalCorrection.GantryTilt.none.degrees == nil)
    }

    @Test func theSheetChecksItsFieldsAndStacksAlongTheNormal() throws {
        let vectors: [Float?] = [1, 0, 0, 0, 0, -1]
        #expect(SliceIntervalCorrection.Sheet(interval: 2, spacingX: 0, spacingY: 1, vectors: vectors, origin: [0, 0, 0], sliceCount: 4) == nil)
        #expect(SliceIntervalCorrection.Sheet(interval: 0, spacingX: 1, spacingY: 1, vectors: vectors, origin: [0, 0, 0], sliceCount: 4) == nil)
        #expect(SliceIntervalCorrection.Sheet(interval: 2, spacingX: 1, spacingY: 1, vectors: [1, 0, 0, 0, nil, -1], origin: [0, 0, 0], sliceCount: 4) == nil)
        #expect(SliceIntervalCorrection.Sheet(interval: nil, spacingX: 1, spacingY: 1, vectors: vectors, origin: [0, 0, 0], sliceCount: 1) == nil)
        #expect(SliceIntervalCorrection.Sheet(interval: 0, spacingX: 1, spacingY: 1, vectors: vectors, origin: [0, 0, 0], sliceCount: 1) != nil)

        let sheet = try #require(SliceIntervalCorrection.Sheet(interval: 2, spacingX: 0.5, spacingY: 1, vectors: vectors, origin: [1, 2, 3], sliceCount: 4))
        #expect(sheet.orientation == [1, 0, 0, 0, 0, -1, 0, 1, 0] && sheet.axis == 1 && sheet.pixelRatio == 2)
        #expect(sheet.origins(sliceCounts: [2, 1]) == [[[1, 2, 3], [1, 4, 3]], [[1, 6, 3]]])
    }
}

@Suite struct SeriesResliceWorkerTests {

    /// A stack of `count` slices of width×height floats, each value naming its slice, row and column.
    func stack(_ count: Int, _ width: Int, _ height: Int) -> UnsafeMutablePointer<Float> {
        let base = UnsafeMutablePointer<Float>.allocate(capacity: count * width * height)
        for s in 0..<count { for y in 0..<height { for x in 0..<width { base[(s * height + y) * width + x] = Float(s * 10000 + y * 100 + x) } } }
        return base
    }

    func volume(_ plan: SeriesReslicePlan) -> (UnsafeMutablePointer<Float>, [UnsafeMutablePointer<Float>]) {
        let floats = plan.width * plan.height
        let base = UnsafeMutablePointer<Float>.allocate(capacity: plan.sliceCount * floats)
        base.initialize(repeating: -1, count: plan.sliceCount * floats)
        return (base, (0..<plan.sliceCount).map { base + $0 * floats })
    }

    @Test func rowsAreGatheredAsTheLoopOfTheViewerDid() async {
        let count = 6, width = 8, height = 10
        let source = stack(count, width, height)
        defer { source.deallocate() }
        for interval in [3.0, 0.5] {
            let plan = SeriesReslicePlan(direction: 0, sliceCount: count, width: width, height: height, spacingX: 1, spacingY: 1, sliceInterval: interval)
            let slices = (0..<count).map { UnsafePointer(source + $0 * width * height) }
            let (expected, expectedSlices) = volume(plan)
            let (waited, waitedSlices) = volume(plan)
            let (awaited, awaitedSlices) = volume(plan)
            defer { expected.deallocate(); waited.deallocate(); awaited.deallocate() }
            for (i, destination) in expectedSlices.enumerated() {
                SeriesReslice.gatherRows(slices, row: i, sourceWidth: width, width: plan.width, into: destination, sign: 1)
                if plan.square { SeriesReslice.scaleRows(destination, rows: count, newRows: plan.height, width: plan.width) }
            }
            SeriesResliceWorker().gatherAndWait(.rows(of: slices, sourceWidth: width, plan: plan, sign: 1, into: waitedSlices))
            await SeriesResliceWorker().gather(.rows(of: slices, sourceWidth: width, plan: plan, sign: 1, into: awaitedSlices))
            let floats = plan.sliceCount * plan.width * plan.height
            #expect(memcmp(expected, waited, floats * 4) == 0 && memcmp(expected, awaited, floats * 4) == 0, "interval \(interval)")
            #expect(expected[0] != -1)
        }
    }

    @Test func columnsAreGatheredAsTheThreadsOfTheViewerDid() {
        let count = 6, width = 8, height = 10
        let source = stack(count, width, height)
        defer { source.deallocate() }
        for interval in [3.0, 0.5] {
            let plan = SeriesReslicePlan(direction: 1, sliceCount: count, width: width, height: height, spacingX: 1, spacingY: 1, sliceInterval: interval)
            let base = UnsafePointer(source + (count - 1) * width * height)
            let (expected, expectedSlices) = volume(plan)
            let (waited, waitedSlices) = volume(plan)
            defer { expected.deallocate(); waited.deallocate() }
            for (i, destination) in expectedSlices.enumerated() {
                SeriesReslice.gatherColumns(base, column: i, count: count, sliceFloatCount: width * height, rowFloats: width, width: plan.width,
                                            into: destination, sign: 1)
                if plan.square { SeriesReslice.scaleRows(destination, rows: count, newRows: plan.height, width: plan.width) }
            }
            SeriesResliceWorker().gatherAndWait(.columns(from: base, count: count, sliceFloatCount: width * height,
                                                              rowFloats: width, plan: plan, sign: 1, into: waitedSlices))
            #expect(memcmp(expected, waited, plan.sliceCount * plan.width * plan.height * 4) == 0, "interval \(interval)")
        }
    }

    /// A squared reslice of an odd stack takes its even number of slices, and
    /// scales only the rows they gave: the row of the slice left out is never
    /// written, so whatever the new volume held there must not reach the
    /// result. The new volume starts full of NaN, as memory that held one
    /// may.
    @Test func anOddStackScalesOnlyTheRowsItGathered() {
        let stackCount = 13, count = 12, width = 25, height = 21, value: Float = 100
        let uniform = UnsafeMutablePointer<Float>.allocate(capacity: stackCount * width * height)
        uniform.initialize(repeating: value, count: stackCount * width * height)
        let ramp = stack(stackCount, width, height)
        defer { uniform.deallocate(); ramp.deallocate() }
        for direction in [0, 1] {
            let plan = SeriesReslicePlan(direction: direction, sliceCount: stackCount, width: width, height: height,
                                         spacingX: 0.75, spacingY: 0.5, sliceInterval: 1.5)
            #expect(plan.square && plan.height > stackCount)
            let floats = plan.sliceCount * plan.width * plan.height

            func job(_ source: UnsafeMutablePointer<Float>, into slices: [UnsafeMutablePointer<Float>]) -> SeriesResliceJob {
                if direction == 0 {
                    let rows = (0..<count).map { UnsafePointer(source + $0 * width * height) }
                    return .rows(of: rows, sourceWidth: width, plan: plan, sign: 1, into: slices)
                }
                return .columns(from: UnsafePointer(source + (count - 1) * width * height), count: count,
                                sliceFloatCount: width * height, rowFloats: width, plan: plan, sign: 1, into: slices)
            }

            // A stack of one value stays that value once squared, to the
            // rounding of the resampling.
            let (flat, flatSlices) = volume(plan)
            defer { flat.deallocate() }
            flat.update(repeating: .nan, count: floats)
            SeriesResliceWorker().gatherAndWait(job(uniform, into: flatSlices))
            let off = (0..<floats).filter { !(abs(flat[$0] - value) <= value * 1e-4) }
            #expect(off.isEmpty, "direction \(direction): \(off.count) of \(floats) values are not \(value), first \(off.first.map { flat[$0] } ?? 0)")

            // Any stack gives what gathering its even slices into clean
            // memory and scaling their rows gives.
            let (expected, expectedSlices) = volume(plan)
            let (got, gotSlices) = volume(plan)
            defer { expected.deallocate(); got.deallocate() }
            for (i, destination) in expectedSlices.enumerated() {
                if direction == 0 {
                    SeriesReslice.gatherRows((0..<count).map { UnsafePointer(ramp + $0 * width * height) }, row: i, sourceWidth: width,
                                             width: plan.width, into: destination, sign: 1)
                } else {
                    SeriesReslice.gatherColumns(ramp + (count - 1) * width * height, column: i, count: count, sliceFloatCount: width * height,
                                                rowFloats: width, width: plan.width, into: destination, sign: 1)
                }
                SeriesReslice.scaleRows(destination, rows: count, newRows: plan.height, width: plan.width)
            }
            got.update(repeating: .nan, count: floats)
            SeriesResliceWorker().gatherAndWait(job(ramp, into: gotSlices))
            #expect(!(0..<floats).contains { got[$0].isNaN }, "direction \(direction)")
            #expect(memcmp(expected, got, floats * 4) == 0, "direction \(direction)")
        }
    }
}
