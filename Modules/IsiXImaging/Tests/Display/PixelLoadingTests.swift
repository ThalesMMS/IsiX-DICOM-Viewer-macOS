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
    private func mapped(_ samples: [UInt16], first: Int, table: [UInt32], signed: Bool = false,
                        slope: Double = 1, offset: Double = 0) -> [UInt16] {
        var samples = samples
        table.withUnsafeBufferPointer { entries in
            samples.withUnsafeMutableBufferPointer {
                VOILUTMapping.apply(first: first, number: entries.count, table: entries.baseAddress!, to: $0.baseAddress!,
                                    count: $0.count, signed: signed, slope: slope, offset: offset)
            }
        }
        return samples
    }

    /// The table's input is the output of the modality LUT.
    @Test func aRescaledSampleEntersTheTableByItsRescaledValue() {
        let table: [UInt32] = [1000, 1010, 1020, 1030]
        // 2 x - 1024: the stored values 562, 563 and 564 are 100, 102 and 104.
        #expect(mapped([0, 562, 563, 564, 4000], first: 100, table: table, slope: 2, offset: -1024) == [1000, 1000, 1020, 1030, 1030])
        // Signed samples and a negative first value: -3 and 1 are -1001 and -997.
        #expect(mapped([UInt16(bitPattern: -3), 0, 1], first: -1000, table: table, signed: true, slope: 1, offset: -998)
                == [1000, 1020, 1030])
        // The nearest integer: 100.4, 101.5 and 102.6.
        #expect(mapped([1004, 1015, 1026], first: 100, table: table, slope: 0.1, offset: 0) == [1000, 1020, 1030])
    }

    @Test func aRescaleThatGivesNoNumberStaysWithinTheTable() {
        #expect(VOILUTMapping.modalityValue(ofStored: 5, slope: .nan, offset: 0) == 0)
        #expect(VOILUTMapping.modalityValue(ofStored: 5, slope: .infinity, offset: 0) > 1 << 20)
        #expect(VOILUTMapping.modalityValue(ofStored: 5, slope: -.infinity, offset: 0) < -(1 << 20))
        #expect(VOILUTMapping.modalityValue(ofStored: 60000, slope: 1e30, offset: 0) > 1 << 20)
        #expect(mapped([5], first: 0, table: [1, 2, 3], slope: 1e30, offset: 0) == [3])
    }

    @Test func samplesAreClampedToTheTable() {
        let last = UInt16(truncatingIfNeeded: 70000)
        #expect(mapped([0, 10, 11, 12, 13, 50], first: 10, table: [100, 200, 300, 70000]) == [100, 100, 200, 300, last, last])
    }

    /// PS 3.3 C.11.2.1.1: a value at or below the first one mapped takes the
    /// first entry, one past the last takes the last. A frame of nothing else
    /// is mapped all the same.
    @Test func aFrameOnTheFirstEntryOrWhollyOutsideTheTableIsMapped() {
        let table: [UInt32] = [1000, 1010, 1020, 1030]
        #expect(mapped([100, 100, 100], first: 100, table: table) == [1000, 1000, 1000])
        #expect(mapped([0, 50, 99], first: 100, table: table) == [1000, 1000, 1000])
        #expect(mapped([104, 4095, 65535], first: 100, table: table) == [1030, 1030, 1030])
    }

    @Test func aTableOfOneEntryAnswersItForEveryValue() {
        #expect(mapped([0, 300, 301, 65535], first: 300, table: [777]) == [777, 777, 777, 777])
    }

    @Test func signedSamplesBelowASignedFirstValue() {
        #expect(mapped([UInt16(bitPattern: -3), UInt16(bitPattern: -40), UInt16(bitPattern: -2), UInt16(bitPattern: -1), 7],
                       first: -2, table: [5, 6], signed: true) == [5, 5, 5, 6, 6])
    }

    @Test func aTableOfNoEntryLeavesTheSamples() {
        var samples: [UInt16] = [1, 2, 3]
        var nothing: UInt32 = 0
        samples.withUnsafeMutableBufferPointer {
            VOILUTMapping.apply(first: 0, number: 0, table: &nothing, to: $0.baseAddress!, count: 3, signed: false)
        }
        #expect(samples == [1, 2, 3])
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
