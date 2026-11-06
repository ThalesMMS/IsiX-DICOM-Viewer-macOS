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

/// The banded vImage conversion on its own. The comparison with the
/// Objective-C threads it replaced is tests/test-browser-controller-class-equivalence.py.
struct ParallelImageConversionTests {
    @Test func theBandsCoverEveryRowOnce() {
        for (height, parts) in [(53, 8), (3, 10), (64, 4), (1, 1), (0, 3)] {
            let bands = ParallelImageConversion.bands(height: height, parts: parts)
            #expect(bands.count == parts)
            #expect(bands.first?.from == 0)
            #expect(bands.last?.to == height)
            for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.to == b.from) }
        }
    }

    @Test func onlyTheTwoNamedKindsConvert() {
        #expect(ParallelImageConversion.Kind(name: "FTo16U") == .floatToUInt16)
        #expect(ParallelImageConversion.Kind(name: "16UToF") == .uint16ToFloat)
        #expect(ParallelImageConversion.Kind(name: "FTo8") == nil)
        #expect(ParallelImageConversion.Kind(name: nil) == nil)
    }

    @Test func aConversionMatchesOneCallOfVImageOverTheWholeImage() {
        let width = 31, height = 47
        var floats = (0..<(width * height)).map { Float(($0 * 7919) % 6000) - 1000 + 0.25 }
        var banded = [UInt16](repeating: 0, count: width * height)
        var whole = [UInt16](repeating: 0, count: width * height)
        floats.withUnsafeMutableBytes { f in
            banded.withUnsafeMutableBytes { b in
                whole.withUnsafeMutableBytes { w in
                    var src = vImage_Buffer(data: f.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
                    var one = vImage_Buffer(data: w.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
                    ParallelImageConversion.convert(.floatToUInt16, src: &src, dst: &dst, offset: 1000, scale: 1 / 1.5)
                    _ = vImageConvert_FTo16U(&src, &one, 1000, 1 / 1.5, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        #expect(banded == whole)
    }

    @Test func anUnknownKindLeavesTheImageAndIsToldOncePerBand() {
        let counter = Counter()
        var source: [Float] = [1, 2, 3, 4]
        var destination: [UInt16] = [9, 9, 9, 9]
        source.withUnsafeMutableBytes { s in
            destination.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: 2, width: 2, rowBytes: 8)
                var dst = vImage_Buffer(data: d.baseAddress, height: 2, width: 2, rowBytes: 4)
                ParallelImageConversion.convert(nil, src: &src, dst: &dst, offset: 0, scale: 1) { _ in counter.add() }
            }
        }
        #expect(destination == [9, 9, 9, 9])
        #expect(counter.value == ProcessInfo.processInfo.processorCount)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
