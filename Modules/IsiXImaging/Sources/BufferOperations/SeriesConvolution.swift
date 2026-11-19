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

/// A convolution filter applied to a whole series, on several cores: the
/// "apply on source" of a 2D viewer, and of a volume rendering window on the
/// volume it keeps (filterVolume). Each slice is filtered in its own plane
/// (by the slices themselves, ImageConvolution), and a series that is a
/// volume is filtered again across its slices, one row of the volume at a
/// time. The work is split into one share per worker, the shares run at once
/// and the call returns when all are done; no two shares touch the same slice
/// or the same row.
public struct SeriesConvolution: Sendable {

    /// The number of shares the work is split into: one per core.
    public let workers: Int

    public init(workers: Int = ProcessInfo.processInfo.processorCount) {
        self.workers = max(1, workers)
    }

    /// The shares of `count` items: share `i` is `i·count/workers ..<
    /// (i+1)·count/workers`, so they cover every item once, some empty when
    /// there are fewer items than workers.
    public func shares(of count: Int) -> [Range<Int>] {
        (0..<workers).map { worker in
            (worker &* count) / workers ..< ((worker &+ 1) &* count) / workers
        }
    }

    /// Runs `body` on each share of `count` items at once, and returns when
    /// every share is done.
    public func perform(over count: Int, _ body: @Sendable (Range<Int>) -> Void) {
        let shares = shares(of: count)
        DispatchQueue.concurrentPerform(iterations: shares.count) { body(shares[$0]) }
    }

    /// The weights of the pass across the slices: the slices' 25 weights
    /// divided by their normalization, unless it is zero.
    public static func kernel(weights: UnsafePointer<Float>, normalization: Float) -> [Float] {
        (0..<25).map { normalization != 0 ? weights[$0] / normalization : weights[$0] }
    }

    /// Filters `volume`, `depth` slices of `width` × `height` floats one after
    /// the other, across its slices: for each row of the slices, the plane of
    /// that row in every slice goes through the `size` × `size` `kernel`,
    /// edges extended, and replaces itself.
    public func filterAcrossSlices(_ volume: UnsafeMutablePointer<Float>, width: Int, height: Int, depth: Int,
                                   kernel: [Float], size: Int) {
        let base = VolumeBase(address: volume)
        perform(over: height) { rows in
            Self.filterRows(rows, of: base.address, width: width, height: height, depth: depth, kernel: kernel, size: size)
        }
    }

    /// What "apply on source" ends with on a grey volume whose slices went
    /// through the filter in their own planes: the pass across the slices
    /// (filterAcrossSlices), then the first row of every slice takes `edge`,
    /// which keeps the edges free of NaN.
    public func finishGreyVolume(_ volume: UnsafeMutablePointer<Float>, width: Int, height: Int, depth: Int,
                                 kernel: [Float], size: Int, edge: Float) {
        filterAcrossSlices(volume, width: width, height: height, depth: depth, kernel: kernel, size: size)
        for slice in 0..<max(0, depth) {
            (volume + slice &* width &* height).update(repeating: edge, count: max(0, width))
        }
    }

    /// "Apply on source" on a volume handed whole, as a 2D viewer applies it to
    /// its series: `depth` slices of `width` × `height` pixels one after the
    /// other at `volume` (floats, or for a colour volume ARGB bytes in the
    /// same four bytes a pixel), `byteCount` bytes long. Each slice goes
    /// through `kernel` in its own plane (ImageConvolution); a grey volume then
    /// goes through it across its slices, and the first row of every slice
    /// takes the first pixel of the first slice, which keeps the edges free of
    /// NaN. False, with nothing changed, for a volume shorter than its slices.
    @discardableResult
    public func filterVolume(_ volume: UnsafeMutableRawPointer, byteCount: Int, width: Int, height: Int, depth: Int,
                             kernel: ConvolutionKernelBook.Kernel, colour: Bool) -> Bool {
        let slicePixels = width &* height
        let sliceBytes = slicePixels &* MemoryLayout<Float>.size
        guard width > 0, height > 0, depth > 0, byteCount >= sliceBytes &* depth else { return false }
        let base = VolumeBase(address: volume.assumingMemoryBound(to: Float.self))
        let first = base.address.pointee

        perform(over: depth) { slices in
            let filter = kernel.weights.withUnsafeBufferPointer {
                ImageConvolution(weights: $0.baseAddress!, size: kernel.size, normalization: kernel.normalization)
            }
            for slice in slices {
                let pixels = base.address + slice &* slicePixels
                let filtered = colour ? filter.filtered(argb: UnsafeRawPointer(pixels), width: width, height: height)
                    : filter.filtered(pixels, width: width, height: height).map { UnsafeMutableRawPointer($0) }
                guard let filtered else { continue }
                memcpy(pixels, filtered, sliceBytes)
                free(filtered)
            }
        }
        if colour { return true }

        let acrossSlices = kernel.weights.withUnsafeBufferPointer {
            Self.kernel(weights: $0.baseAddress!, normalization: kernel.normalization)
        }
        finishGreyVolume(base.address, width: width, height: height, depth: depth, kernel: acrossSlices, size: kernel.size, edge: first)
        return true
    }

    /// The rows `rows` of the pass across the slices, with a buffer of its own.
    private static func filterRows(_ rows: Range<Int>, of volume: UnsafeMutablePointer<Float>, width: Int, height: Int, depth: Int,
                                   kernel: [Float], size: Int) {
        guard let plane = malloc(depth &* width &* MemoryLayout<Float>.size) else { return }
        defer { free(plane) }
        var destination = vImage_Buffer(data: plane, height: vImagePixelCount(depth), width: vImagePixelCount(width),
                                         rowBytes: width &* MemoryLayout<Float>.size)
        let sliceBytes = width &* height &* MemoryLayout<Float>.size
        for row in rows {
            let first = UnsafeMutableRawPointer(volume + row &* width)
            var source = vImage_Buffer(data: first, height: vImagePixelCount(depth), width: vImagePixelCount(width), rowBytes: sliceBytes)
            let error = kernel.withUnsafeBufferPointer {
                vImageConvolve_PlanarF(&source, &destination, nil, 0, 0, $0.baseAddress, UInt32(truncatingIfNeeded: size),
                                       UInt32(truncatingIfNeeded: size), 0, vImage_Flags(kvImageDoNotTile + kvImageEdgeExtend))
            }
            if error != 0 {
                NSLog("Error applyConvolutionOnImage")
                continue
            }
            for slice in 0..<depth {
                memcpy(first + slice &* sliceBytes, plane + slice &* destination.rowBytes, destination.rowBytes)
            }
        }
    }

    /// The address of a volume handed to the shares: each share writes only
    /// its own rows, and the caller waits for all of them.
    private struct VolumeBase: @unchecked Sendable {
        let address: UnsafeMutablePointer<Float>
    }
}
