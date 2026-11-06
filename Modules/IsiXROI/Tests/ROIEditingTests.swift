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
@testable import IsiXROI

@Suite struct ROIEditingTests {

    @Test func xmlShapeFollowsThePointCount() {
        #expect(ROIEditing.xmlShape(pointCount: 1) == .point)
        #expect(ROIEditing.xmlShape(pointCount: 2) == .length)
        #expect(ROIEditing.xmlShape(pointCount: 0) == .polygon)
        #expect(ROIEditing.xmlShape(pointCount: 3) == .polygon)
        #expect(ROIEditing.xmlShape(pointCount: 40) == .polygon)
    }

    @Test func clipboardTextSeparatesROIsWithCarriageReturns() {
        #expect(ROIEditing.clipboardText([]) == "")
        #expect(ROIEditing.clipboardText(["a\t1"]) == "a\t1")
        #expect(ROIEditing.clipboardText(["a\t1", "b\t2", "c"]) == "a\t1\rb\t2\rc")
    }

    @Test func planePointProjectsOnTheImageAxes() {
        // An axial image at z = 10, origin (-5, 7, 10): rows along x, columns along y.
        let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(ROIEditing.planePoint((3, 9, 10), origin: (-5, 7, 10), orientation: axial) == CGPoint(x: 8, y: 2))
        // Out of the plane, the normal component is dropped.
        #expect(ROIEditing.planePoint((3, 9, 42), origin: (-5, 7, 10), orientation: axial) == CGPoint(x: 8, y: 2))
        // A sagittal image: rows along y, columns along -z.
        let sagittal: [Double] = [0, 1, 0, 0, 0, -1, 1, 0, 0]
        #expect(ROIEditing.planePoint((4, 6, -3), origin: (0, 1, 2), orientation: sagittal) == CGPoint(x: 5, y: 5))
    }

    @Test func planePointFusesAsTheObjectiveCDid() {
        // v1·o1 rounded, then v0·o0 and v2·o2 added each in one rounding.
        let o: [Double] = [0.1, 0.7, 0.3, 0.2, 0.9, 0.4, 0, 0, 0]
        let v = (1.0 / 3.0, 2.0 / 7.0, 5.0 / 11.0)
        let p = ROIEditing.planePoint(v, origin: (0, 0, 0), orientation: o)
        let x: Double = (v.1 * o[1]).addingProduct(v.0, o[0]).addingProduct(v.2, o[2])
        let y: Double = (v.1 * o[4]).addingProduct(v.0, o[3]).addingProduct(v.2, o[5])
        #expect(Double(p.x).bitPattern == x.bitPattern)
        #expect(Double(p.y).bitPattern == y.bitPattern)
    }
}
