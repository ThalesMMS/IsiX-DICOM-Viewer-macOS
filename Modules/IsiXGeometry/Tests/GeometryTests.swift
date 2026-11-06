//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import QuartzCore
import XCTest
@testable import IsiXGeometry

final class GeometryTests: XCTestCase {

    func testFusedProductsRoundOnce() {
        // (1 + e)(1 - e) - 1 is -e^2 with the product fused into the
        // subtraction, and 0 when the product is rounded first.
        let e = 0x1p-30
        XCTAssertEqual(Vector3(1 + e, 1, 0).dotProduct(Vector3(1 - e, -1, 0)), -e * e)
        XCTAssertEqual(Vector3(0, 1 + e, 1).crossProduct(Vector3(0, 1, 1 - e)).x, -e * e)
    }

    func testVectorBasics() {
        XCTAssertEqual(Vector3(3, 4, 0).length, 5)
        XCTAssertEqual(Vector3.zero.normalized, .zero)
        XCTAssertEqual(Vector3(0, 0, 2).normalized, Vector3(0, 0, 1))
        XCTAssertEqual(Vector3(1, 0, 0).crossProduct(Vector3(0, 1, 0)), Vector3(0, 0, 1))
        XCTAssertEqual(Vector3(1, 2, 3).interpolated(to: Vector3(3, 2, 1), at: 0.5), Vector3(2, 2, 2))
        // The projection scales by the dot product over the length, not its square.
        XCTAssertEqual(Vector3(1, 1, 0).projected(onto: Vector3(2, 0, 0)), Vector3(2, 0, 0))
        XCTAssertEqual(Vector3.zero.inverted.x.sign, .plus)
        let normal = Vector3(1, 2, 3).anyNormal
        XCTAssertEqual(normal.dotProduct(Vector3(1, 2, 3)), 0, accuracy: 1e-12)
        XCTAssertEqual(normal.length, 1, accuracy: 1e-12)
    }

    func testAngleAndBend() {
        let angle = Vector3(1, 0, 0).angle(to: Vector3(0, 1, 0), around: Vector3(0, 0, 1))
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-12)
        let back = Vector3(0, 1, 0).angle(to: Vector3(1, 0, 0), around: Vector3(0, 0, 1))
        XCTAssertEqual(back, 3 * .pi / 2, accuracy: 1e-12)
        let bent = Vector3(0, 0, 1).bent(from: Vector3(1, 0, 0), to: Vector3(0, 1, 0))
        XCTAssertEqual(bent.z, 1, accuracy: 1e-12)
        let turned = Vector3(1, 0, 0).bent(from: Vector3(1, 0, 0), to: Vector3(0, 1, 0))
        XCTAssertEqual(turned.y, 1, accuracy: 1e-12)
    }

    func testLinesAndPlanes() {
        let line = Line3(from: Vector3(0, 0, -1), to: Vector3(0, 0, 1))
        XCTAssertEqual(line.intersection(with: .zZero), .zero)
        XCTAssertTrue(line.intersects(.zZero))
        XCTAssertFalse(Line3.xAxis.intersects(Plane3(point: Vector3(0, 0, 1), normal: Vector3(0, 0, 1))))
        XCTAssertGreaterThan(Line3.xAxis.intersection(with: Plane3(point: Vector3(0, 0, 1), normal: Vector3(0, 0, 1))).length, 1e290)
        let closest = Line3.xAxis.closestPoints(to: Line3(point: Vector3(0, 0, 2), direction: Vector3(0, 1, 0)))
        XCTAssertEqual(closest.distance, 2)
        XCTAssertEqual(closest.onSelf, .zero)
        XCTAssertEqual(closest.onLine, Vector3(0, 0, 2))
        let parallel = Line3.xAxis.closestPoints(to: Line3(point: Vector3(0, 3, 0), direction: Vector3(1, 0, 0)))
        XCTAssertEqual(parallel.distance, 3)
        XCTAssertNil(parallel.onSelf)
        XCTAssertEqual(Vector3(5, 3, 0).distance(to: Line3.xAxis), 3)
        XCTAssertTrue(Plane3.zZero.isBetween(Vector3(0, 0, 1), Vector3(0, 0, -1)))
        XCTAssertFalse(Plane3.zZero.isBetween(Vector3(0, 0, 1), Vector3(0, 0, 2)))
        let meet = Plane3.xZero.intersection(with: .yZero)
        XCTAssertEqual(meet.direction, Vector3(0, 0, 1))
        XCTAssertEqual(meet.point, .zero)
        XCTAssertEqual(Plane3.leastSquares(through: [.zero, Vector3(1, 0, 0), Vector3(0, 1, 0)]), .invalid)
        XCTAssertEqual(Plane3.leastSquares(through: [.zero, Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)]).normal, Vector3(0, 0, 1))
    }

    func testTransforms() {
        let translation = CATransform3DMakeTranslation(1, 2, 3)
        XCTAssertEqual(Vector3(1, 1, 1).applying(translation), Vector3(2, 3, 4))
        XCTAssertEqual(Vector3(1, 1, 1).applyingToDirection(translation), Vector3(1, 1, 1))
        let scale = CATransform3DMakeScale(2, 3, 4)
        XCTAssertEqual(scale.determinant, 24)
        XCTAssertTrue(scale.isRectilinear)
        XCTAssertFalse(CATransform3DMakeRotation(0.3, 0, 0, 1).isRectilinear)
        let both = scale.concatenating(translation)
        XCTAssertEqual(Vector3(1, 1, 1).applying(both), Vector3(3, 5, 7))
        XCTAssertEqual(Vector3(3, 5, 7).applying(both.inverted).x, 1, accuracy: 1e-12)
        XCTAssertEqual(both.inverted.m44, 1)
        XCTAssertEqual(translation.transposed.m14, 1)
        let plane = Plane3.zZero.applying(CATransform3DMakeTranslation(0, 0, 5))
        XCTAssertEqual(plane.point, Vector3(0, 0, 5))
        XCTAssertEqual(plane.normal, Vector3(0, 0, 1))
    }

    func testPackedVectors() {
        var values: [Double] = [1, 2, 3, 4, 5, 6]
        values.withUnsafeMutableBufferPointer { PackedVectors.scale($0.baseAddress!, count: 2, by: 2) }
        XCTAssertEqual(values, [2, 4, 6, 8, 10, 12])
        let others: [Double] = [1, 1, 1, 1, 1, 1]
        values.withUnsafeMutableBufferPointer { PackedVectors.add(others, to: $0.baseAddress!, count: 2) }
        XCTAssertEqual(values, [3, 5, 7, 9, 11, 13])
        values.withUnsafeMutableBufferPointer { PackedVectors.apply(CATransform3DMakeTranslation(1, 0, -1), to: $0.baseAddress!, count: 2) }
        XCTAssertEqual(values, [4, 5, 6, 10, 11, 12])
    }
}
