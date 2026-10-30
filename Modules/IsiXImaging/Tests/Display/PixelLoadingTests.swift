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
@testable import IsiXImaging

/// The rules DCMPix loads pixels with. Its behaviour as a whole, against the
/// Objective-C class, is tests/test-dcmpix-class.py.
struct VOILUTMappingTests {
    @Test func samplesAreClampedToTheTable() {
        let table: [UInt32] = [100, 200, 300, 70000]
        var samples: [UInt16] = [0, 10, 11, 12, 13, 50]
        let inside = table.withUnsafeBufferPointer { entries in
            samples.withUnsafeMutableBufferPointer {
                VOILUTMapping.apply(first: 10, number: 4, table: entries.baseAddress!, to: $0.baseAddress!, count: 6, signed: false)
            }
        }
        #expect(inside)
        #expect(samples == [100, 100, 200, 300, UInt16(truncatingIfNeeded: 70000), UInt16(truncatingIfNeeded: 70000)])
    }

    @Test func signedSamplesAndATableThatMapsNothing() {
        let table: [UInt32] = [5, 6]
        var samples: [UInt16] = [UInt16(bitPattern: -3), UInt16(bitPattern: -40)]
        let inside = table.withUnsafeBufferPointer { entries in
            samples.withUnsafeMutableBufferPointer {
                VOILUTMapping.apply(first: -2, number: 2, table: entries.baseAddress!, to: $0.baseAddress!, count: 2, signed: true)
            }
        }
        #expect(!inside)
        #expect(samples == [5, 5])
    }
}

struct RGBAToARGBTests {
    @Test func theAlphaMovesFirst() {
        let rgba: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        var argb = [UInt8](repeating: 0, count: 8)
        rgba.withUnsafeBufferPointer { source in
            argb.withUnsafeMutableBufferPointer { ColourChannels.argb(fromRGBA: source.baseAddress!, into: $0.baseAddress!, count: 2) }
        }
        #expect(argb == [4, 1, 2, 3, 8, 5, 6, 7])
    }
}
