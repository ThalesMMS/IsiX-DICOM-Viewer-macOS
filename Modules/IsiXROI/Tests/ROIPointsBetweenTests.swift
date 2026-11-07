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
import simd
import Testing
@testable import IsiXROI

// Synthetic stacks, regular and oblique, with the points of a line between
// two points worked out from the geometry independently of the rule.
@Suite struct ROIPointsBetweenTests {
    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }
    static func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-9) -> Bool { simd_length(a - b) <= tolerance }

    /// An axial stack: `count` slices `interval` mm apart from z = 0, 0.5 mm pixels, the first pixel at (-50, -50).
    static func axialStack(count: Int, interval: Double) -> [ROISlicePlane] {
        (0..<count).map { index in
            ROISlicePlane(origin: SIMD3(-50, -50, Double(index) * interval), rowDirection: SIMD3(1, 0, 0),
                          columnDirection: SIMD3(0, 1, 0), columnSpacing: 0.5, rowSpacing: 0.5)
        }
    }

    /// A stack tilted 20° about the patient's x axis, as a gantry tilt gives
    /// it, `interval` mm apart along its normal, each slice shifted in its
    /// plane too, with anisotropic pixels.
    static let tilt = 20.0 * Double.pi / 180
    static let tiltedColumn = SIMD3(0, cos(tilt), sin(tilt))
    static let tiltedNormal = SIMD3(0, -sin(tilt), cos(tilt))
    static func obliqueStack(count: Int, interval: Double) -> [ROISlicePlane] {
        (0..<count).map { index in
            let origin = SIMD3<Double>(-120, -100, -40) + tiltedNormal * (Double(index) * interval) + tiltedColumn * (Double(index) * 0.7)
            return ROISlicePlane(origin: origin, rowDirection: SIMD3(1, 0, 0), columnDirection: tiltedColumn,
                                 columnSpacing: 0.8, rowSpacing: 0.6)
        }
    }

    @Test func planeConvertsPixelsBothWays() {
        let plane = Self.obliqueStack(count: 3, interval: 3)[2]
        #expect(Self.close(simd_length(plane.normal), 1))
        #expect(Self.close(plane.normal, Self.tiltedNormal))
        let point = plane.patientPoint(column: 12.25, row: 40.5)
        let pixel = plane.pixel(of: point)
        #expect(Self.close(pixel.column, 12.25) && Self.close(pixel.row, 40.5))
        #expect(Self.close(plane.distance(to: point), 0))
        // Off the plane, the pixel is the projection's and the distance runs along the normal.
        let lifted = point + plane.normal * 1.75
        #expect(Self.close(plane.distance(to: lifted), 1.75))
        let projected = plane.pixel(of: lifted)
        #expect(Self.close(projected.column, 12.25) && Self.close(projected.row, 40.5))
    }

    @Test func planeWithoutOrientationOrSpacingIsAxialAtOneMillimetre() {
        let plane = ROISlicePlane(origin: SIMD3(1, 2, 3), rowDirection: .zero, columnDirection: .zero,
                                  columnSpacing: 0, rowSpacing: .nan)
        #expect(plane.normal == SIMD3(0, 0, 1))
        #expect(plane.columnSpacing == 1 && plane.rowSpacing == 1)
        #expect(plane.patientPoint(column: 4, row: 5) == SIMD3(5, 7, 3))
    }

    @Test func pointsEveryMillimetreWithoutTheEnds() {
        let start = SIMD3<Double>(0, 0, 0)
        // 3 mm: 1 and 2; the point at 3 mm would be the end again.
        let three = ROIPointsBetween.positions(from: start, to: SIMD3(0, 3, 0))
        #expect(three.count == 2)
        #expect(Self.close(three[0], SIMD3(0, 1, 0)) && Self.close(three[1], SIMD3(0, 2, 0)))
        #expect(ROIPointsBetween.positions(from: start, to: SIMD3(0, 0, 3.5)).count == 3)
        #expect(ROIPointsBetween.positions(from: start, to: SIMD3(0.6, 0, 0)).isEmpty)
        #expect(ROIPointsBetween.positions(from: start, to: SIMD3(1, 0, 0)).isEmpty)
        #expect(ROIPointsBetween.positions(from: start, to: start).isEmpty)
        #expect(ROIPointsBetween.positions(from: start, to: SIMD3(.nan, 0, 0)).isEmpty)
        #expect(ROIPointsBetween.positions(from: start, to: SIMD3(.infinity, 0, 0)).isEmpty)
        // Consecutive points are one millimetre apart, along the line.
        let end = SIMD3<Double>(7.3, -4.1, 12.9)
        let points = ROIPointsBetween.positions(from: start, to: end)
        #expect(points.count == Int(simd_length(end)))
        for (index, point) in points.enumerated() {
            #expect(Self.close(simd_length(point - start), Double(index + 1)))
            #expect(Self.close(simd_length(simd_cross(point - start, end - start)), 0, 1e-9))
        }
    }

    @Test func alongTheStackEveryPointLandsOnItsSlice() {
        // 1 mm slices and a line through the same pixel from slice 0 to slice 5.
        let planes = Self.axialStack(count: 8, interval: 1)
        let start = planes[0].patientPoint(column: 20, row: 30), end = planes[5].patientPoint(column: 20, row: 30)
        let placements = ROIPointsBetween.placements(from: start, to: end, planes: planes)
        #expect(placements.map(\.slice) == [1, 2, 3, 4])
        for placement in placements {
            #expect(Self.close(placement.column, 20) && Self.close(placement.row, 30))
            #expect(Self.close(placement.distanceFromPlane, 0))
        }
    }

    @Test func regularStack() {
        let planes = Self.axialStack(count: 20, interval: 2.5)
        let start = planes[10].patientPoint(column: 30, row: 60)   // (-35, -20, 25)
        let end = planes[2].patientPoint(column: 10, row: 20)      // (-45, -40, 5), 30 mm away
        let placements = ROIPointsBetween.placements(from: start, to: end, planes: planes)
        #expect(placements.count == 29)
        for (index, placement) in placements.enumerated() {
            let k = Double(index + 1)
            let expected = start + (end - start) / 30 * k
            #expect(Self.close(placement.position, expected))
            // The nearest of slices 2.5 mm apart from z = 0, on a tie the lower one.
            let z = expected.z
            let nearest = (0..<planes.count).min { abs(Double($0) * 2.5 - z) < abs(Double($1) * 2.5 - z) }!
            #expect(placement.slice == nearest)
            #expect(Self.close(placement.distanceFromPlane, z - Double(nearest) * 2.5))
            #expect(abs(placement.distanceFromPlane) <= 1.25 + 1e-9)
            #expect(Self.close(placement.column, (expected.x + 50) / 0.5) && Self.close(placement.row, (expected.y + 50) / 0.5))
        }
        #expect(placements.first?.slice == 10 && placements.last?.slice == 2)
        let slices = placements.map(\.slice)
        #expect(zip(slices, slices.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func obliqueStack() {
        let interval = 3.0
        let planes = Self.obliqueStack(count: 25, interval: interval)
        let start = planes[3].patientPoint(column: 100, row: 50)
        let end = planes[21].patientPoint(column: 40, row: 210)
        let placements = ROIPointsBetween.placements(from: start, to: end, planes: planes)
        let length = simd_length(end - start)
        #expect(placements.count == Int(length.rounded(.down)))
        for (index, placement) in placements.enumerated() {
            let expected = start + (end - start) / length * Double(index + 1)
            #expect(Self.close(placement.position, expected))
            // The planes are parallel: the nearest is the one whose offset
            // along the common normal is nearest, worked out from the first.
            let along = simd_dot(expected - planes[0].origin, Self.tiltedNormal) / interval
            #expect(placement.slice == Int(along.rounded()))
            #expect(abs(placement.distanceFromPlane) <= interval / 2 + 1e-9)
            // The pixel and the distance give the point back.
            let plane = planes[placement.slice]
            let back = plane.patientPoint(column: placement.column, row: placement.row) + plane.normal * placement.distanceFromPlane
            #expect(Self.close(back, expected, 1e-9))
        }
        #expect(placements.first?.slice == 3 && placements.last?.slice == 21)
    }

    @Test func planesThatAreNotParallel() {
        // An axial plane through z = 0 and a sagittal one through x = 10; each
        // point goes to whichever is nearer, the first on a tie.
        let axial = ROISlicePlane(origin: .zero, rowDirection: SIMD3(1, 0, 0), columnDirection: SIMD3(0, 1, 0),
                                  columnSpacing: 1, rowSpacing: 1)
        let sagittal = ROISlicePlane(origin: SIMD3(10, 0, 0), rowDirection: SIMD3(0, 1, 0), columnDirection: SIMD3(0, 0, -1),
                                     columnSpacing: 1, rowSpacing: 1)
        let placements = ROIPointsBetween.placements(from: SIMD3(0, 5, 0), to: SIMD3(10, 5, 10), planes: [axial, sagittal])
        for placement in placements {
            let toAxial = abs(placement.position.z), toSagittal = abs(placement.position.x - 10)
            #expect(placement.slice == (toAxial <= toSagittal ? 0 : 1))
        }
        #expect(placements.first?.slice == 0 && placements.last?.slice == 1)
        #expect(ROIPointsBetween.nearestPlane(to: SIMD3(5, 0, 5), among: [axial, sagittal])?.index == 0)
        #expect(ROIPointsBetween.nearestPlane(to: SIMD3(5, 0, 5), among: []) == nil)
        #expect(ROIPointsBetween.placements(from: .zero, to: SIMD3(0, 0, 5), planes: []).isEmpty)
    }
}
