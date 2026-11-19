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
import Foundation

// The steps of the assistant that the plug-in SDK of Horos and OsiriX named as
// methods of their own, which the assistant itself does not call: the indices
// of a voxel, the cost of a step, the opening, and the first way the lumen's
// thresholds were found, on a histogram of ints the caller could also hold.
extension FlyPathAssistant {
    /// The position of the input voxel (x, y, z) in the volume's buffer.
    public func inputIndex(x: Int32, y: Int32, z: Int32) -> Int32 {
        Int32(truncatingIfNeeded: Int(x) + Int(y) * inputWidth + Int(z) * inputImageSize)
    }

    /// The position of the voxel (x, y, z) in the distance map.
    public func mapIndex(x: Int32, y: Int32, z: Int32) -> Int32 {
        Int32(truncatingIfNeeded: Int(x) + Int(y) * distmapWidth + Int(z) * distmapImageSize)
    }

    /// The cost of a step of the path search to the voxel `index` of the
    /// distance map: the further from the wall, the cheaper.
    public func stepCost(to index: Int) -> Float {
        expf(-distance(index))
    }

    /// Whether `p` is strictly inside a volume of x × y × z voxels.
    public static func isPoint(_ p: SIMD3<Float>, insideVolume size: SIMD3<Int32>) -> Bool {
        p.x > 0 && p.x < Float(size.x) && p.y > 0 && p.y < Float(size.y) && p.z > 0 && p.z < Float(size.z)
    }

    /// An opening (erosion, then dilation) of a planar float image by a kernel
    /// of ones, in place; the counterpart of `morphologicalClosing`.
    public func morphologicalOpening(_ buffer: inout vImage_Buffer, kernelHeight: Int, kernelWidth: Int) {
        guard buffer.data != nil, buffer.height > 0, buffer.rowBytes > 0, kernelHeight > 0, kernelWidth > 0 else { return }
        let bytes = buffer.rowBytes * Int(buffer.height)
        guard let scratch = malloc(bytes) else { return }
        defer { free(scratch) }
        var result = vImage_Buffer(data: scratch, height: buffer.height, width: buffer.width, rowBytes: buffer.rowBytes)
        let kernel = [Float](repeating: 1, count: kernelHeight * kernelWidth)
        var error = vImageErode_PlanarF(&buffer, &result, 0, 0, kernel, vImagePixelCount(kernelHeight),
                                        vImagePixelCount(kernelWidth), vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError {
            Self.log(error)
            return
        }
        error = vImageDilate_PlanarF(&result, &buffer, 0, 0, kernel, vImagePixelCount(kernelHeight),
                                     vImagePixelCount(kernelWidth), vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError { Self.log(error) }
    }

    /// The input's smallest and largest values as the former SDK found them:
    /// the largest starts at FLT_MIN, the smallest positive float, so a volume
    /// without a positive value reads FLT_MIN as its largest.
    public func determineInputMinMax() {
        var low = Float.greatestFiniteMagnitude, high = Float.leastNormalMagnitude
        for value in UnsafeBufferPointer(start: input, count: max(inputVolumeSize, 0)) {
            if value < low { low = value }
            if value > high { high = value }
        }
        inputMinValue = low
        inputMaxValue = high
    }

    /// One more in the bin of each input value, a unit a bin from the
    /// smallest value; a value past the last bin is left out, where the
    /// former loop wrote past the histogram's end.
    public func addSimpleHistogram(to histogram: UnsafeMutableBufferPointer<Int32>) {
        for value in UnsafeBufferPointer(start: input, count: max(inputVolumeSize, 0)) {
            let bin = cInt(value - inputMinValue)
            if histogram.indices.contains(bin) { histogram[bin] &+= 1 }
        }
    }

    /// `histogram` convolved with 1 2 4 … 2^window … 4 2 1 over its sum, from
    /// the bin `window` on, each bin taking the kernel centred `window` bins
    /// before it, as the former loop did.
    public static func smooth(_ histogram: UnsafeMutableBufferPointer<Int32>, window: Int) {
        let limit = histogram.count
        guard limit > 0, window >= 0, window < 31 else { return }
        var original = [Int32](repeating: 0, count: limit + 2 * window)
        for i in 0..<limit { original[i + window] = histogram[i] }
        for i in 0..<window {
            original[i] = histogram[0]
            // The former loop mirrored the far end from one past the last bin.
            if i > 0 { original[original.count - i] = histogram[limit - i] }
        }
        var i = window
        while i < limit {
            var sum = original[i] &<< Int32(window)
            var weight: Int32 = 1 &<< Int32(window)
            for j in stride(from: 1, through: window, by: 1) {
                sum = sum &+ ((original[i + j] &<< Int32(j)) &+ (original[i - j] &<< Int32(j)))
                weight = weight &+ (1 &<< Int32(j + 1))
            }
            histogram[i] = weight == 0 ? 0 : sum / weight
            i += 1
        }
    }

    /// The count of a bin of a caller's histogram; 0 outside it, where the
    /// former code read past its ends.
    private static func bin(_ histogram: UnsafeBufferPointer<Int32>, _ index: Int) -> Int32 {
        histogram.indices.contains(index) ? histogram[index] : 0
    }

    /// From `x`, `step` bins at a time while the count goes down by more than
    /// a sixteenth of the bins' number.
    public static func localMinimum(from x: Int32, on histogram: UnsafeBufferPointer<Int32>, step: Int32) -> Int32 {
        let maxi = Int32(truncatingIfNeeded: histogram.count), epsilon = maxi >> 4
        var x = x, previous: Int32
        repeat {
            previous = x
            x = x &+ step
        } while x < maxi && x >= 0 && bin(histogram, Int(previous)) >= bin(histogram, Int(x))
            && cAbs(bin(histogram, Int(previous)) &- bin(histogram, Int(x))) > epsilon
        return previous
    }

    /// From `x`, `step` bins at a time while the count does not go down.
    public static func localMaximum(from x: Int32, on histogram: UnsafeBufferPointer<Int32>, step: Int32) -> Int32 {
        let maxi = Int32(truncatingIfNeeded: histogram.count)
        var x = x, previous: Int32
        repeat {
            previous = x
            x = x &+ step
        } while x < maxi && x >= 0 && bin(histogram, Int(previous)) <= bin(histogram, Int(x))
        return previous
    }

    /// thresholdA and thresholdB from a caller's histogram: the local minima
    /// on either side of the bin `value`, `step` bins at a time. The former
    /// loop that left a peak took a count for a position and could run
    /// without end; it stops here after as many turns as the histogram has bins.
    public func determineThresholdInterval(from value: Int32, on histogram: UnsafeBufferPointer<Int32>, step delta: Int32) {
        var value = value
        let x = Self.bin(histogram, Int(value))
        var previous = Self.bin(histogram, Int(value &- delta))
        var next = Self.bin(histogram, Int(value &+ delta))
        var turns = histogram.count
        while previous <= x && next <= x && turns > 0 {
            previous = value
            value = next
            next = Self.bin(histogram, Int(value &+ delta))
            turns -= 1
        }
        let low: Int32, high: Int32
        if previous <= x {
            low = Self.localMinimum(from: value &- delta, on: histogram, step: -delta)
        } else {
            low = Self.localMinimum(from: Self.localMaximum(from: value &- delta, on: histogram, step: -delta), on: histogram, step: -delta)
        }
        if next <= x {
            high = Self.localMinimum(from: value &+ delta, on: histogram, step: delta)
        } else {
            high = Self.localMinimum(from: Self.localMaximum(from: value &+ delta, on: histogram, step: delta), on: histogram, step: delta)
        }
        thresholdA = Float(low) + inputMinValue
        thresholdB = Float(high) + inputMinValue
    }

    /// thresholdA and thresholdB around the value `v`, on a histogram of ints
    /// smoothed over 5 bins and searched 10 bins a step.
    public func autoComputeThreshold(fromValue v: Float) {
        determineInputMinMax()
        let range = inputMaxValue - inputMinValue
        let count = range.isFinite && range > 0 && range < 16_777_216 ? cInt(range) : 0
        guard count > 0 else { return }
        var histogram = [Int32](repeating: 0, count: count)
        var v = v
        histogram.withUnsafeMutableBufferPointer { bins in
            addSimpleHistogram(to: bins)
            Self.smooth(bins, window: 5)
            if v == inputMinValue {
                v += 1
            } else if v == Float(count - 1) - inputMinValue {
                v -= 1
            }
            determineThresholdInterval(from: Int32(truncatingIfNeeded: cInt(Float(cInt(v)) - inputMinValue)), on: UnsafeBufferPointer(bins), step: 10)
        }
    }

    /// The same around the value of the input voxel at `point`; nothing for a
    /// point outside the volume, where the former code read past the buffer.
    public func autoComputeThreshold(atVoxel point: SIMD3<Float>) {
        let x = cInt(point.x), y = cInt(point.y), z = cInt(point.z)
        guard x >= 0, x < inputWidth, y >= 0, y < inputHeight, z >= 0, z < inputDepth else { return }
        autoComputeThreshold(fromValue: input[z * inputWidth * inputHeight + y * inputWidth + x])
    }
}
