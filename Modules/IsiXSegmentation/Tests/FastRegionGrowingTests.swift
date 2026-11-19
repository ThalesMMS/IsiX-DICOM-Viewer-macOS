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
@testable import IsiXSegmentation

@Suite struct FastRegionGrowingTests {
    /// The volume, the seed and the threshold of case `number`, from the
    /// generator the reference values were made with.
    private static func scenario(_ number: Int) -> (volume: [Float], size: SIMD3<Int>, seed: SIMD3<Int>, above: Float) {
        var state = UInt64(1000 + number)
        func next() -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 33)
        }
        let w = 5 + Int(next() % 14), h = 5 + Int(next() % 14), d = 5 + Int(next() % 12)
        var volume = [Float](repeating: 0, count: w * h * d)
        let mode = next() % 3
        for i in volume.indices {
            volume[i] = mode == 0 ? Float(next() % 100) : mode == 1 ? ((next() % 10) < 7 ? 80 : 10) : ((next() % 10) < 5 ? 80 : 10)
        }
        let seed = SIMD3(Int(next() % UInt32(w + 2)) - 1, Int(next() % UInt32(h + 2)) - 1, Int(next() % UInt32(d + 2)) - 1)
        return (volume, SIMD3(w, h, d), seed, mode == 0 ? 40 : 50)
    }

    /// The seed brought inside the volume and the FNV-1a hash of the labels,
    /// as the C function of Horos gave them for the same volumes.
    @Test func labelsAreThoseOfTheFormerFunction() {
        let reference: [(Int, SIMD3<Int>, UInt64)] = [
        (0, SIMD3(3, 8, 4), 4901439644253111678),
        (1, SIMD3(10, 2, 6), 12875160727649170956),
        (2, SIMD3(2, 2, 6), 390133859323302293),
        (3, SIMD3(9, 14, 6), 449084284454706916),
        (4, SIMD3(6, 2, 5), 15029210653601286599),
        (5, SIMD3(2, 9, 2), 11282882688051287236),
        (6, SIMD3(2, 2, 4), 14106393172918406145),
        (7, SIMD3(13, 2, 2), 6625897257040730476)
        ]
        for (number, seed, hash) in reference {
            let scenario = Self.scenario(number)
            var moved = scenario.seed
            let labels = scenario.volume.withUnsafeBufferPointer {
                FastRegionGrowing.labels(volume: $0, width: scenario.size.x, height: scenario.size.y, depth: scenario.size.z,
                                         seed: &moved, above: scenario.above)
            }
            var found: UInt64 = 1469598103934665603
            for label in labels {
                found ^= UInt64(label)
                found = found &* 1099511628211
            }
            #expect(moved == seed, "case \(number)")
            #expect(found == hash, "case \(number)")
        }
    }

    /// A column of high voxels through a low volume is grown along its
    /// length, and the voxels around it are refused.
    @Test func aColumnGrowsAndItsNeighboursAreRefused() {
        let w = 7, h = 7, d = 7
        var volume = [Float](repeating: 0, count: w * h * d)
        for z in 0..<d { volume[4 + 3 * w + z * w * h] = 100 }
        var seed = SIMD3(3, 3, 3)
        let labels = volume.withUnsafeBufferPointer { FastRegionGrowing.labels(volume: $0, width: w, height: h, depth: d, seed: &seed, above: 50) }
        #expect(seed == SIMD3(3, 3, 3))
        #expect(labels[4 + 3 * w + 3 * w * h] == FastRegionGrowing.grown)
        #expect(labels[5 + 3 * w + 3 * w * h] == FastRegionGrowing.refused)
        #expect(labels[4 + 3 * w + 1 * w * h] != 0)
        #expect(labels[0] == 0)
    }

    @Test func aVolumeSmallerThanItsBufferSaysGivesNothing() {
        var seed = SIMD3(1, 1, 1)
        let volume = [Float](repeating: 1, count: 8)
        #expect(volume.withUnsafeBufferPointer { FastRegionGrowing.labels(volume: $0, width: 3, height: 3, depth: 3, seed: &seed, above: 0) }.isEmpty)
    }
}
