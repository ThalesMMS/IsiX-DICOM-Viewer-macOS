//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Testing
import IsiXROI

/// The brush filters, the merge of brushes and the polygon a brush becomes.
struct BrushROIOperationsTests {

    @Test func theMenuTagsNameTheFourFilters() {
        #expect(BrushROIOperations.Morphology(tag: 0) == .erode)
        #expect(BrushROIOperations.Morphology(tag: 1) == .dilate)
        #expect(BrushROIOperations.Morphology(tag: 2) == .close)
        #expect(BrushROIOperations.Morphology(tag: 3) == .open)
        #expect(BrushROIOperations.Morphology(tag: 4) == nil)
        #expect(BrushROIOperations.Morphology(rawValue: "dilate") == .dilate)
    }

    @Test func theLastBrushReceivesTheOthersAndTheOtherROIsAreLeftAlone() {
        let plan = BrushROIOperations.mergePlan(isBrush: [true, false, true, true])
        #expect(plan?.target == 3)
        #expect(plan?.merged == [0, 2])
        #expect(BrushROIOperations.mergePlan(isBrush: [true])?.merged == [])
        #expect(BrushROIOperations.mergePlan(isBrush: [false, false]) == nil)
        #expect(BrushROIOperations.mergePlan(isBrush: []) == nil)
    }

    @Test func thePolygonIsSpreadAlongTheContourMovedByTheMaskCorner() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 2)]
        let points = BrushROIOperations.polygonPoints(contour: square, maskCorner: (10, 20), numPoints: 8)
        #expect(points.count == 8)
        #expect(points[0] == CGPoint(x: 10, y: 20))
        #expect(points[1] == CGPoint(x: 11, y: 20))
        #expect(points[2] == CGPoint(x: 12, y: 20))
        // The last one is between the last contour point and the first.
        #expect(points[7] == CGPoint(x: 10, y: 21))
        #expect(BrushROIOperations.polygonPoints(contour: [], maskCorner: (0, 0), numPoints: 8).isEmpty)
    }
}
