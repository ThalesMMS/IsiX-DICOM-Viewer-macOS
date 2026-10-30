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
@testable import IsiXVolumeRendering

/// The quaternion of the fly-path's view scan. Its arithmetic against the
/// former C++ class, bit for bit, is tests/test-fly-path-equivalence.py; these
/// are the rotations it must give: by degrees about the axis, an axis of any
/// length, the Hamilton product, lengths that are norms.
struct FlyQuaternionTests {
    private let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0), z = SIMD3<Double>(0, 0, 1)

    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-5) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.z - b.z) < tolerance
    }

    private func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }

    @Test func knownRotationsComeOut() {
        #expect(near(FlyQuaternion(axis: z, degrees: 90).rotate(x), y))
        #expect(near(FlyQuaternion(axis: x, degrees: 180).rotate(y), -y))
        let diagonal = FlyQuaternion(axis: SIMD3(1, 1, 1), degrees: 120)
        #expect(near(diagonal.rotate(x), y))
        #expect(near(diagonal.rotate(y), z))
        let full = FlyQuaternion(axis: SIMD3(0.3, -0.4, 0.5), degrees: 360)
        #expect(near(full.rotate(SIMD3(1, 2, 3)), SIMD3(1, 2, 3), 1e-4))
    }

    @Test func theComponentsAreHalfAngles() {
        var q = FlyQuaternion()
        q.set(axisX: 0, y: 1, z: 0, degrees: 60)
        #expect(abs(q.w - cosf(.pi / 6)) < 1e-5 && abs(q.y - sinf(.pi / 6)) < 1e-5 && abs(q.x) < 1e-5 && abs(q.z) < 1e-5)
    }

    @Test func theAxisLengthDoesNotChangeTheRotation() {
        #expect(near(FlyQuaternion(axis: SIMD3(0, 0, 2.5), degrees: 90).rotate(x), y))
        let v = SIMD3<Double>(1, 2, 3)
        let slanted = FlyQuaternion(axis: SIMD3(-0.5, 1, 0), degrees: -45).rotate(v)
        let unit = FlyQuaternion(axis: SIMD3(-0.5 / 1.25.squareRoot(), 1 / 1.25.squareRoot(), 0), degrees: -45).rotate(v)
        #expect(near(slanted, unit))
        #expect(abs(length(slanted) - length(v)) < 1e-4)
    }

    @Test func aProductOfRotationsIsTheirComposition() {
        let xRot = FlyQuaternion(axis: SIMD3(-2, 1, 0), degrees: -45), yRot = FlyQuaternion(axis: SIMD3(-3, 0, 1), degrees: -45)
        let d = SIMD3<Double>(1, 2, 3)
        let composed = (yRot * xRot).rotate(d)
        #expect(near(composed, yRot.rotate(xRot.rotate(d)), 1e-4))
        #expect(abs(length(composed) - length(d)) < 1e-4)
    }

    @Test func theHamiltonProduct() {
        let i = FlyQuaternion(x: 1, y: 0, z: 0, w: 0), j = FlyQuaternion(x: 0, y: 1, z: 0, w: 0)
        #expect(i * j == FlyQuaternion(x: 0, y: 0, z: 1, w: 0))
        let ji = j * i
        #expect(ji.z == -1 && ji.w == 0)
        let ii = i * i
        #expect(ii.w == -1 && ii.x == 0)
    }

    @Test func lengthsAreNorms() {
        #expect(abs(FlyQuaternion(x: 1, y: 2, z: 2, w: 4).length - 5) < 1e-5)
        var three = FlyQuaternion(x: 3, y: 0, z: 0, w: 4)
        three.normalize()
        #expect(abs(three.length - 1) < 1e-5 && abs(three.x - 0.6) < 1e-5 && abs(three.w - 0.8) < 1e-5)
        var zero = FlyQuaternion()
        zero.normalize()
        #expect(zero == FlyQuaternion())
    }
}
