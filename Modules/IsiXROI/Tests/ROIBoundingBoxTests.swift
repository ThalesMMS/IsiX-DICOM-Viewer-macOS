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

/// A rectangle keeps origin and size; an oval keeps centre and radii.
@Suite struct ROIBoundingBoxTests {
    @Test func rectangleKeepsOriginAndSize() {
        let rect = ROIBoundingBox.rect(corner: CGPoint(x: 48, y: 40), corner: CGPoint(x: 16, y: 8), oval: false)
        #expect(rect == CGRect(x: 16, y: 8, width: 32, height: 32))
        let corners = ROIBoundingBox.corners(of: rect, oval: false)
        #expect(corners.lower == CGPoint(x: 16, y: 8) && corners.upper == CGPoint(x: 48, y: 40))
    }

    @Test func ovalKeepsCentreAndRadii() {
        // The middle half of a 64 x 64 image: centre (32, 32), radii 16 and 12.
        let rect = ROIBoundingBox.rect(corner: CGPoint(x: 16, y: 20), corner: CGPoint(x: 48, y: 44), oval: true)
        #expect(rect == CGRect(x: 32, y: 32, width: 16, height: 12))
        let corners = ROIBoundingBox.corners(of: rect, oval: true)
        #expect(corners.lower == CGPoint(x: 16, y: 20) && corners.upper == CGPoint(x: 48, y: 44))
    }

    @Test func ovalDrawnByTheUserReadsBack() {
        // ROI.m keeps radii; a negative size from a drag is still a radius.
        let corners = ROIBoundingBox.corners(of: CGRect(x: 10, y: 10, width: -4, height: 3), oval: true)
        #expect(corners.lower == CGPoint(x: 6, y: 7) && corners.upper == CGPoint(x: 14, y: 13))
    }
}
