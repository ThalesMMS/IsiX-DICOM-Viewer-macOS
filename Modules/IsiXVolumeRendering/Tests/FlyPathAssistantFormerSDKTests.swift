//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import Testing
@testable import IsiXVolumeRendering

/// The steps of the assistant the former plug-in SDK named. The histograms and
/// their expected values come from the C++ of Horos, run on the same bins.
struct FlyPathAssistantFormerSDKTests {
    private static let bins: [Int32] = [332, 306, 368, 174, 31, 133, 34, 290, 485, 181, 213, 2131, 2130, 2142, 2017, 2322, 2185, 2154,
                                        2418, 2228, 2020, 2467, 2079, 2426, 2061, 124, 139, 41, 242, 378, 241, 410, 318, 258, 348, 335,
                                        23, 200, 292, 176]
    private static let smoothed: [Int32] = [332, 306, 368, 299, 243, 252, 190, 201, 274, 167, 182, 664, 828, 1006, 1417, 1514, 1734,
                                            2127, 2237, 2198, 2137, 2312, 2202, 2227, 2288, 1709, 1536, 1403, 939, 919, 597, 237, 262,
                                            226, 323, 331, 235, 283, 281, 202]

    private func assistant(_ volume: [Float], _ size: SIMD3<Int>) -> FlyPathAssistant {
        volume.withUnsafeBufferPointer {
            FlyPathAssistant(volume: $0.baseAddress!, width: size.x, height: size.y, depth: size.z,
                             spacing: SIMD3(repeating: 1), resampleVoxelSize: 1)!
        }
    }

    @Test func aCallersHistogramIsSmoothedAsTheFormerLoopDid() {
        var bins = Self.bins
        bins.withUnsafeMutableBufferPointer { FlyPathAssistant.smooth($0, window: 3) }
        #expect(bins == Self.smoothed)

        var empty: [Int32] = []
        empty.withUnsafeMutableBufferPointer { FlyPathAssistant.smooth($0, window: 3) }
        #expect(empty.isEmpty)
    }

    @Test func localExtremaStopWhereTheFormerSearchesDid() {
        Self.smoothed.withUnsafeBufferPointer { bins in
            #expect(FlyPathAssistant.localMinimum(from: 20, on: bins, step: 2) == 20)
            #expect(FlyPathAssistant.localMinimum(from: 20, on: bins, step: -2) == 20)
            #expect(FlyPathAssistant.localMaximum(from: 5, on: bins, step: 3) == 23)
            #expect(FlyPathAssistant.localMaximum(from: 35, on: bins, step: -3) == 35)
            // Past either end the searches stop instead of reading on.
            #expect(FlyPathAssistant.localMaximum(from: 38, on: bins, step: 5) == 38)
            #expect(FlyPathAssistant.localMinimum(from: 1, on: bins, step: -5) == 1)
        }
    }

    @Test func indicesCostAndBoundsFollowTheVolume() {
        let volume = [Float](repeating: 0, count: 4 * 5 * 6)
        let fly = assistant(volume, SIMD3(4, 5, 6))
        #expect(fly.inputIndex(x: 3, y: 2, z: 1) == 3 + 2 * 4 + 1 * 20)
        #expect(fly.mapIndex(x: 1, y: 1, z: 1) == Int32(1 + fly.distmapWidth + fly.distmapWidth * fly.distmapHeight))
        // Without a distance, a step costs exp(0).
        #expect(fly.stepCost(to: 0) == 1)
        #expect(fly.stepCost(to: -5) == 1)
        #expect(FlyPathAssistant.isPoint(SIMD3(1, 1, 1), insideVolume: SIMD3(4, 5, 6)))
        #expect(!FlyPathAssistant.isPoint(SIMD3(0, 1, 1), insideVolume: SIMD3(4, 5, 6)))
        #expect(!FlyPathAssistant.isPoint(SIMD3(1, 5, 1), insideVolume: SIMD3(4, 5, 6)))
    }

    @Test func theSimpleHistogramCountsEachValueOnce() {
        var volume = [Float](repeating: 10, count: 3 * 3 * 3)
        volume[0] = 12
        volume[1] = 14
        let fly = assistant(volume, SIMD3(3, 3, 3))
        fly.determineInputMinMax()
        #expect(fly.inputMinValue == 10)
        #expect(fly.inputMaxValue == 14)
        var bins = [Int32](repeating: 0, count: 4)
        bins.withUnsafeMutableBufferPointer { fly.addSimpleHistogram(to: $0) }
        // The largest value falls past the last bin, as it did.
        #expect(bins == [25, 0, 1, 0])
    }

    @Test func anOpeningRemovesAnIsolatedPixel() {
        var pixels = [Float](repeating: 0, count: 25)
        pixels[12] = 1
        let fly = assistant([Float](repeating: 0, count: 27), SIMD3(3, 3, 3))
        pixels.withUnsafeMutableBytes { bytes in
            var buffer = vImage_Buffer(data: bytes.baseAddress, height: 5, width: 5, rowBytes: 5 * MemoryLayout<Float>.size)
            fly.morphologicalOpening(&buffer, kernelHeight: 3, kernelWidth: 3)
        }
        #expect(pixels.allSatisfy { $0 == 0 })
    }

    @Test func thresholdsAroundAValueDoNotReadOutsideTheVolume() {
        var volume = [Float](repeating: 0, count: 8 * 8 * 8)
        for i in volume.indices { volume[i] = Float(i % 200) }
        let fly = assistant(volume, SIMD3(8, 8, 8))
        fly.autoComputeThreshold(fromValue: 100)
        #expect(fly.thresholdA <= fly.thresholdB)
        let before = (fly.thresholdA, fly.thresholdB)
        fly.autoComputeThreshold(atVoxel: SIMD3(-1, 0, 0))
        fly.autoComputeThreshold(atVoxel: SIMD3(0, 0, 99))
        #expect(before == (fly.thresholdA, fly.thresholdB))
    }
}
