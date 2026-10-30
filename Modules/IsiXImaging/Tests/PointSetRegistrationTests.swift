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

/// The similarity that carries the model points onto the sensor points.
struct PointSetRegistrationTests {

    private func apply(_ m: [Double], _ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
              m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
              m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])
    }

    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        abs(a.x - b.x) < 1e-5 && abs(a.y - b.y) < 1e-5 && abs(a.z - b.z) < 1e-5
    }

    @Test func aRotationScaleAndShiftIsFound() throws {
        let model: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 10, 0), SIMD3(0, 10, 5)]
        // A quarter turn about z, twice the size, then (5, -3, 2).
        let sensor = model.map { SIMD3(-2 * $0.y + 5, 2 * $0.x - 3, 2 * $0.z + 2) }
        let matrix = try #require(PointSetRegistration.similarity(model: model, sensor: sensor))
        for (from, to) in zip(model, sensor) { #expect(close(apply(matrix, from), to)) }
        #expect(Array(matrix[12...]) == [0, 0, 0, 1])
    }

    @Test func fewPointsAreTranslationsOrNothing() throws {
        #expect(PointSetRegistration.similarity(model: [], sensor: []) == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(PointSetRegistration.similarity(model: [SIMD3(1, 2, 3)], sensor: [SIMD3(4, 4, 4)])
                == [1, 0, 0, 3, 0, 1, 0, 2, 0, 0, 1, 1, 0, 0, 0, 1])
        #expect(PointSetRegistration.similarity(model: [SIMD3(1, 2, 3)], sensor: []) == nil)
        // All the model points at one place: only the centroids move.
        let same = try #require(PointSetRegistration.similarity(model: [SIMD3(1, 1, 1), SIMD3(1, 1, 1)],
                                                                sensor: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)]))
        #expect(same == [1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 1, -1, 0, 0, 0, 1])
    }

    @Test func twoPointsTakeTheSmallestRotation() throws {
        let model: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let sensor: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0, 3, 0)]
        let matrix = try #require(PointSetRegistration.similarity(model: model, sensor: sensor))
        for (from, to) in zip(model, sensor) { #expect(close(apply(matrix, from), to)) }
        // A half turn turns about an axis perpendicular to the segment.
        let opposite = try #require(PointSetRegistration.similarity(model: model, sensor: [SIMD3(0, 0, 0), SIMD3(-1, 0, 0)]))
        #expect(close(apply(opposite, SIMD3(1, 0, 0)), SIMD3(-1, 0, 0)))
    }

    @Test func theViewerTakesTheRotationThenTheTranslation() {
        let matrix: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 0, 1]
        #expect(PointSetRegistration.rotationAndTranslation(matrix) == [1, 2, 3, 5, 6, 7, 9, 10, 11, 4, 8, 12])
    }
}
