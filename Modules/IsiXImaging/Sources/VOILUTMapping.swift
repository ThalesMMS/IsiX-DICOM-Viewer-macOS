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
    ///
    /// The standard gives every input value an output, so a frame that lies
    /// wholly below the table, wholly above it or on its first entry is mapped
    /// as rightly as one inside it: where the samples fall says nothing of
    /// whether the table is sound. A table of no entry maps nothing.
    ///
    /// The table's input is the output of the modality LUT (C.11.2.1.1): with a
    /// rescale `slope` and `offset` that are not the identity, the entry of a
    /// sample is that of its rescaled value, rounded to the nearest integer.
    public static func apply(first: Int, number: Int, table: UnsafePointer<UInt32>, to samples: UnsafeMutablePointer<UInt16>,
                             count: Int, signed: Bool, slope: Double = 1, offset: Double = 0) {
        guard number > 0 else { return }
        let last = number - 1
        let rescales = slope != 1 || offset != 0
        var i = count
        while i > 0 {
            i -= 1
            var value = signed ? Int(Int16(bitPattern: samples[i])) : Int(samples[i])
            if rescales { value = modalityValue(ofStored: value, slope: slope, offset: offset) }
            samples[i] = UInt16(truncatingIfNeeded: table[min(max(value - first, 0), last)])
        }
    }

    /// What the modality LUT makes of a stored value, as the integer a table is
    /// entered with: the nearest one, held within what no table reaches. A
    /// rescale that gives no number gives 0.
    static func modalityValue(ofStored stored: Int, slope: Double, offset: Double) -> Int {
        let value = (Double(stored) * slope + offset).rounded()
        guard value.isFinite else { return value.isNaN ? 0 : (value < 0 ? -farthest : farthest) }
        return Int(min(max(value, Double(-farthest)), Double(farthest)))
    }

    /// Past any first mapped value and any table: both are 16-bit quantities.
    private static let farthest = 1 << 30
}
