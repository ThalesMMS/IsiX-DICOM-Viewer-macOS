//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// The samples of a frame through a VOI LUT (PS 3.3 C.11.2), in place.
public enum VOILUTMapping {
    /// Each of `count` 16-bit samples, read signed or unsigned, replaced by the
    /// table's entry for it: the first entry for a sample at or below `first`,
    /// the last for one at or past `first + number - 1`, truncated to 16 bits.
    /// Returns whether any sample fell inside the table: a table that maps
    /// nothing is taken for a corrupted one.
    public static func apply(first: Int, number: Int, table: UnsafePointer<UInt32>, to samples: UnsafeMutablePointer<UInt16>,
                             count: Int, signed: Bool) -> Bool {
        var inside = false
        var i = count
        while i > 0 {
            i -= 1
            let value = signed ? Int(Int16(bitPattern: samples[i])) : Int(samples[i])
            var index = value - first
            if index <= 0 {
                index = 0
            } else if index >= number {
                index = number - 1
            } else {
                inside = true
            }
            samples[i] = UInt16(truncatingIfNeeded: table[index])
        }
        return inside
    }
}
