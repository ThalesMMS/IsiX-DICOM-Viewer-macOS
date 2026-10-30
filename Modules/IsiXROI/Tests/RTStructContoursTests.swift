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
import Foundation
import Testing
@testable import IsiXROI

/// The geometry of RT STRUCT contours on its own. The comparison with the
/// Objective-C it replaced, ROI by ROI, is tests/test-dcmpix-annotations-documents-rtstruct.py.
struct RTStructContoursTests {
    @Test func planarOutlinesAndPointsAreRead() {
        for type in ["CLOSED_PLANAR", "INTERPOLATED_PLANAR", "POINT"] {
            #expect(RTStructContours.isSupported(type))
        }
        for type in ["OPEN_PLANAR", "OPEN_NONPLANAR", "", nil] as [String?] {
            #expect(!RTStructContours.isSupported(type))
        }
    }

    @Test func theDeclaredPointCountMustMatchTheCoordinates() {
        #expect(RTStructContours.pointCountMatches(declared: 2, coordinates: 6))
        #expect(!RTStructContours.pointCountMatches(declared: 2, coordinates: 7))
        #expect(!RTStructContours.pointCountMatches(declared: 3, coordinates: 6))
        #expect(!RTStructContours.pointCountMatches(declared: 0, coordinates: 0))
    }

    @Test func displayColoursBecomeSixteenBitComponents() {
        #expect(RTStructContours.colour(0) == 0)
        #expect(RTStructContours.colour(255) == 65279)
        #expect(RTStructContours.colour(128) == 32767)
        // Out of range, as the int the Objective-C made kept to 16 bits.
        #expect(RTStructContours.colour(-1) == 65281)
        #expect(RTStructContours.colour(.nan) == 0)
    }

    @Test func progressGoesFromTenToOneHundredPercent() {
        #expect(RTStructContours.progress(after: 0, of: 4) == Double(Float(10)) / 100)
        #expect(RTStructContours.progress(after: 2, of: 4) == Double(Float(55)) / 100)
        #expect(RTStructContours.progress(after: 4, of: 4) == 1)
    }

    @Test func aPlaneHoldsThePointsNearIt() throws {
        let plane = try #require(RTStructContours.Plane(position: [-40.5, -30.25, 10], orientation: [1, 0, 0, 0, 1, 0],
                                                         rowSpacing: 0.75, columnSpacing: 0.8, thickness: 2.5))
        #expect(plane.orientation[6...] == [0, 0, 1])
        #expect(plane.criterion == 1)
        #expect(plane.origin == CGPoint(x: -40.5, y: -30.25))
        #expect(plane.contains(0, 0, 10.9))
        #expect(!plane.contains(0, 0, 11.1))
        let points = plane.points([-32.5, -22.75, 10, -40.5, -30.25, 10], count: 2)
        #expect(points.count == 2)
        #expect(abs(points[0].x - 10.5) < 1e-5 && abs(points[0].y - 10.5) < 1e-5)
        #expect(points[1] == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func aPlaneWithoutThicknessOrPixelSizeIsTakenCareOf() {
        let thin = RTStructContours.Plane(position: [0, 0, 0], orientation: [1, 0, 0, 0, 1, 0], rowSpacing: 1, columnSpacing: 1, thickness: 0)
        #expect(thin?.criterion == 0.1)
        #expect(RTStructContours.Plane(position: [0, 0, 0], orientation: [1, 0, 0, 0, 1, 0], rowSpacing: 1, columnSpacing: 0, thickness: 1) == nil)
        #expect(RTStructContours.Plane(position: [0, 0], orientation: [1, 0, 0, 0, 1, 0], rowSpacing: 1, columnSpacing: 1, thickness: 1) == nil)
    }
}
