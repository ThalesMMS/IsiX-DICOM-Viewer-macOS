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

/// Colour tables as the Metal renderer takes them: RGBA bytes, opaque, from
/// the colours VTK evaluates in [0, 1].
public enum VolumeColourTable {

    /// One colour channel in [0, 1] as a byte: rounded, clamped, NaN as 0.
    @inline(__always) public static func byte(_ channel: Double) -> UInt8 {
        UInt8(fmin(255, fmax(0, channel * 255 + 0.5)))
    }

    /// `count` RGBA entries from `colours`, three doubles an entry, `stride`
    /// doubles apart (3 for VTK's tables, 3 for a C `double[n][3]` too).
    /// The view's table is made at every frame: pointers and a plain loop,
    /// because the module is not optimized in Debug, where indexing an array
    /// cost a tenth of a millisecond for 256 entries.
    public static func rgba(colours: UnsafePointer<Double>, count: Int, stride: Int = 3) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: 4 * count) { buffer, initialized in
            var output = buffer.baseAddress!, input = colours, i = 0
            while i < count {
                output[0] = byte(input[0])
                output[1] = byte(input[1])
                output[2] = byte(input[2])
                output[3] = 255
                output += 4
                input += stride
                i += 1
            }
            initialized = 4 * count
        }
    }

    /// An RGB volume's three component colour tables, one after the other, 256
    /// entries each over the byte's 0…255: `colours[c]` holds VTK's table of
    /// component c + 1, three doubles an entry.
    public static func componentTables(_ colours: [[Double]]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 3 * 256 * 4)
        for component in 0..<3 {
            let table = colours[component]
            for i in 0..<256 {
                for channel in 0..<3 { bytes[4 * (256 * component + i) + channel] = byte(table[3 * i + channel]) }
                bytes[4 * (256 * component + i) + 3] = 255
            }
        }
        return bytes
    }
}
