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
import Testing
@testable import IsiXImaging

// "Apply on source" of a 2D viewer against the code it ran before
// SeriesConvolution: `formerAcrossSlicesWorker` is the body of the former
// -applyConvolutionZThread: worker, which the viewer started on one thread per
// core with the rows `from..<to` and waited for with a condition lock; here
// the former workers run one after the other, which gives the same bytes since
// no two of them touch the same row. The slices' own pass is
// ImageConvolution, unchanged, which both sides run the same way.

/// The former worker: the rows `from..<to` of one time point's volume.
private func formerAcrossSlicesWorker(volume: UnsafeMutablePointer<Float>?, pwidth: Int, pheight: Int, sliceCount: Int,
                                      kernelsize: Int16, fkernel: UnsafePointer<Float>, from: Int32, to: Int32) {
    var dstf = vImage_Buffer(), srcf = vImage_Buffer()
    srcf.height = vImagePixelCount(UInt(sliceCount))
    srcf.width = vImagePixelCount(UInt(bitPattern: pwidth))
    srcf.rowBytes = pwidth &* pheight &* MemoryLayout<Float>.size
    let t = malloc(Int(bitPattern: UInt(srcf.height &* srcf.width &* UInt(MemoryLayout<Float>.size))))
    guard let t else { return }
    dstf.height = vImagePixelCount(UInt(sliceCount))
    dstf.width = vImagePixelCount(UInt(bitPattern: pwidth))
    dstf.rowBytes = pwidth &* MemoryLayout<Float>.size
    dstf.data = t
    var y = from
    while y < to {
        let bytes: Int = volume.map { Int(bitPattern: $0) } ?? 0
        srcf.data = UnsafeMutableRawPointer(bitPattern: bytes &+ Int(y) &* pwidth &* MemoryLayout<Float>.size)
        if srcf.data != nil {
            let size = UInt32(truncatingIfNeeded: Int32(kernelsize))
            if vImageConvolve_PlanarF(&srcf, &dstf, nil, 0, 0, fkernel, size, size, 0, vImage_Flags(kvImageDoNotTile + kvImageEdgeExtend)) == 0 {
                var s = srcf.data!, d = dstf.data!
                var row: vImagePixelCount = 0
                while row < dstf.height {
                    memcpy(s, d, dstf.rowBytes)
                    s += srcf.rowBytes
                    d += dstf.rowBytes
                    row += 1
                }
            }
        }
        y += 1
    }
    free(t)
}

/// The former Z pass of one time point: one worker per core, each with its rows.
private func formerAcrossSlices(_ volume: UnsafeMutablePointer<Float>, width: Int, height: Int, depth: Int,
                                weights: [Float], normalization: Float, size: Int16, processors: Int32) {
    var fkernel = [Float](repeating: 0, count: 25)
    for i in 0..<25 { fkernel[i] = normalization != 0 ? weights[i] / normalization : weights[i] }
    let no = Int32(truncatingIfNeeded: height)
    for i in 0..<processors {
        formerAcrossSlicesWorker(volume: volume, pwidth: width, pheight: height, sliceCount: depth, kernelsize: size, fkernel: fkernel,
                                 from: (i &* no) / processors, to: ((i &+ 1) &* no) / processors)
    }
}

/// A volume of `depth` slices with values that change along every axis.
private func volume(width: Int, height: Int, depth: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<(width * height * depth)).map { index in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(index % 97) * 0.5 + Float(state >> 40) / Float(1 << 20)
    }
}

/// "Apply on source" of one time point as the viewer runs it: each slice
/// through its own convolution, then across the slices, then the first row of
/// every slice set to the first pixel the slices' pass left, which keeps the
/// edge free of NaN.
private func applyOnSource(_ data: inout [Float], width: Int, height: Int, depth: Int, weights: [Float], normalization: Float,
                           size: Int, acrossSlices: (UnsafeMutablePointer<Float>) -> Void) {
    data.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        let filter = weights.withUnsafeBufferPointer { ImageConvolution(weights: $0.baseAddress!, size: size, normalization: normalization) }
        for slice in 0..<depth {
            let pixels = base + slice * width * height
            let result = filter.filtered(pixels, width: width, height: height)!
            pixels.update(from: result, count: width * height)
            free(result)
        }
        let first = base.pointee
        acrossSlices(base)
        for slice in 0..<depth {
            (base + slice * width * height).update(repeating: first, count: width)
        }
    }
}

private let kernels: [(weights: [Float], normalization: Float, size: Int)] = [
    ([1, 2, 1, 2, 4, 2, 1, 2, 1] + [Float](repeating: 0, count: 16), 16, 3),
    ([0, -1, 0, -1, 5, -1, 0, -1, 0] + [Float](repeating: 0, count: 16), 0, 3),
    ((0..<25).map { Float(($0 * 7) % 5) - 1.5 }, 7.25, 5),
    ((0..<25).map { _ in 1 }, 25, 5),
]

@Test func acrossSlicesGivesTheFormerBytes() {
    for (width, height, depth) in [(7, 5, 4), (16, 11, 9), (3, 2, 2), (1, 1, 3)] {
        for kernel in kernels {
            for workers in [1, 2, 3, 8, ProcessInfo.processInfo.processorCount] {
                let original = volume(width: width, height: height, depth: depth, seed: UInt64(width * 31 + depth))
                var former = original, current = original
                applyOnSource(&former, width: width, height: height, depth: depth, weights: kernel.weights,
                              normalization: kernel.normalization, size: kernel.size) { base in
                    formerAcrossSlices(base, width: width, height: height, depth: depth, weights: kernel.weights,
                                       normalization: kernel.normalization, size: Int16(kernel.size), processors: Int32(workers))
                }
                applyOnSource(&current, width: width, height: height, depth: depth, weights: kernel.weights,
                              normalization: kernel.normalization, size: kernel.size) { base in
                    let weights = kernel.weights.withUnsafeBufferPointer {
                        SeriesConvolution.kernel(weights: $0.baseAddress!, normalization: kernel.normalization)
                    }
                    SeriesConvolution(workers: workers).filterAcrossSlices(base, width: width, height: height, depth: depth,
                                                                           kernel: weights, size: kernel.size)
                }
                let same = former.withUnsafeBytes { a in current.withUnsafeBytes { b in a.elementsEqual(b) } }
                #expect(same, "\(width)×\(height)×\(depth), \(kernel.size)×\(kernel.size) /\(kernel.normalization), \(workers) workers")
                #expect(former != original)
            }
        }
    }
}

/// The VR window's filter of the volume it kept after a change of plane is the
/// 2D viewer's "apply on source", byte for byte.
@Test func filterVolumeIsTheViewersApplyOnSource() {
    for (width, height, depth) in [(7, 5, 4), (16, 11, 9), (3, 2, 2), (1, 1, 3)] {
        for kernel in kernels {
            for workers in [1, 3, ProcessInfo.processInfo.processorCount] {
                let original = volume(width: width, height: height, depth: depth, seed: UInt64(width * 17 + depth))
                var viewer = original, window = original
                applyOnSource(&viewer, width: width, height: height, depth: depth, weights: kernel.weights,
                              normalization: kernel.normalization, size: kernel.size) { base in
                    let weights = kernel.weights.withUnsafeBufferPointer {
                        SeriesConvolution.kernel(weights: $0.baseAddress!, normalization: kernel.normalization)
                    }
                    SeriesConvolution(workers: workers).filterAcrossSlices(base, width: width, height: height, depth: depth,
                                                                           kernel: weights, size: kernel.size)
                }
                let filter = ConvolutionKernelBook.Kernel(size: kernel.size, normalization: kernel.normalization,
                                                          weights: Array(kernel.weights.prefix(kernel.size * kernel.size)))
                let done = window.withUnsafeMutableBytes {
                    SeriesConvolution(workers: workers).filterVolume($0.baseAddress!, byteCount: $0.count, width: width, height: height,
                                                                     depth: depth, kernel: filter, colour: false)
                }
                #expect(done)
                let same = viewer.withUnsafeBytes { a in window.withUnsafeBytes { b in a.elementsEqual(b) } }
                #expect(same, "\(width)×\(height)×\(depth), \(kernel.size)×\(kernel.size) /\(kernel.normalization), \(workers) workers")
                #expect(window != original)
            }
        }
    }
}

/// A colour volume: each slice in its own plane, as ARGB, and nothing across
/// the slices nor on the first rows.
@Test func filterVolumeOfColourFiltersEachSliceOnly() {
    let width = 6, height = 5, depth = 3
    var state: UInt64 = 7
    let original: [UInt8] = (0..<(width * height * depth * 4)).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 56)
    }
    let filter = ConvolutionKernelBook.Kernel(size: 3, normalization: 16, weights: [1, 2, 1, 2, 4, 2, 1, 2, 1])
    var expected = original
    expected.withUnsafeMutableBytes { buffer in
        let convolution = filter.weights.withUnsafeBufferPointer {
            ImageConvolution(weights: $0.baseAddress!, size: filter.size, normalization: filter.normalization)
        }
        for slice in 0..<depth {
            let pixels = buffer.baseAddress! + slice * width * height * 4
            let result = convolution.filtered(argb: UnsafeRawPointer(pixels), width: width, height: height)!
            memcpy(pixels, result, width * height * 4)
            free(result)
        }
    }
    var window = original
    let done = window.withUnsafeMutableBytes {
        SeriesConvolution(workers: 2).filterVolume($0.baseAddress!, byteCount: $0.count, width: width, height: height, depth: depth,
                                                   kernel: filter, colour: true)
    }
    #expect(done)
    #expect(window == expected)
    #expect(window != original)
}

/// A volume shorter than its slices is left as it is.
@Test func filterVolumeRefusesAShortVolume() {
    let original = volume(width: 4, height: 4, depth: 3, seed: 3)
    var window = original
    let filter = ConvolutionKernelBook.Kernel(size: 3, normalization: 9, weights: [Float](repeating: 1, count: 9))
    let done = window.withUnsafeMutableBytes {
        SeriesConvolution().filterVolume($0.baseAddress!, byteCount: $0.count - 4, width: 4, height: 4, depth: 3,
                                         kernel: filter, colour: false)
    }
    #expect(!done)
    #expect(window == original)
}

@Test func sharesCoverEveryItemOnce() {
    for workers in [1, 2, 3, 7, 16] {
        let convolution = SeriesConvolution(workers: workers)
        for count in [0, 1, 2, 5, 16, 100] {
            let shares = convolution.shares(of: count)
            #expect(shares.count == workers)
            #expect(shares.flatMap { Array($0) } == Array(0..<count))
            // The former split: (i·no)/mp ..< ((i+1)·no)/mp, in 32-bit integers.
            let former = (0..<Int32(workers)).map { i in
                Int((i &* Int32(count)) / Int32(workers)) ..< Int(((i &+ 1) &* Int32(count)) / Int32(workers))
            }
            #expect(shares == former)
        }
    }
}

@Test func performRunsEveryShareBeforeReturning() {
    let counter = Counter()
    SeriesConvolution(workers: 6).perform(over: 50) { share in
        for index in share { counter.add(index) }
    }
    #expect(counter.values.sorted() == Array(0..<50))
}

@Test func kernelDividesByANonZeroNormalization() {
    let weights = (0..<25).map { Float($0) }
    weights.withUnsafeBufferPointer { buffer in
        #expect(SeriesConvolution.kernel(weights: buffer.baseAddress!, normalization: 4) == weights.map { $0 / 4 })
        #expect(SeriesConvolution.kernel(weights: buffer.baseAddress!, normalization: 0) == weights)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    func add(_ value: Int) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// What a 2D viewer's "apply on source" and the 3D window's end with on a grey
/// volume: the pass across the slices, then the first row of every slice at
/// the edge value handed, and nothing else of the volume touched after it.
@Test func aGreyVolumeEndsWithThePassAcrossItsSlicesAndItsEdgeRows() {
    for (width, height, depth) in [(7, 5, 4), (3, 2, 2), (1, 1, 3)] {
        for kernel in kernels {
            let weights = kernel.weights.withUnsafeBufferPointer {
                SeriesConvolution.kernel(weights: $0.baseAddress!, normalization: kernel.normalization)
            }
            let original = volume(width: width, height: height, depth: depth, seed: UInt64(width * 13 + depth))
            var across = original, finished = original
            across.withUnsafeMutableBufferPointer {
                SeriesConvolution(workers: 3).filterAcrossSlices($0.baseAddress!, width: width, height: height, depth: depth,
                                                                 kernel: weights, size: kernel.size)
            }
            finished.withUnsafeMutableBufferPointer {
                SeriesConvolution(workers: 3).finishGreyVolume($0.baseAddress!, width: width, height: height, depth: depth,
                                                               kernel: weights, size: kernel.size, edge: -7.5)
            }
            for slice in 0..<depth {
                let start = slice * width * height
                #expect(finished[start..<start + width].allSatisfy { $0 == -7.5 })
                #expect(finished[(start + width)..<(start + width * height)] == across[(start + width)..<(start + width * height)])
            }
        }
    }
}
