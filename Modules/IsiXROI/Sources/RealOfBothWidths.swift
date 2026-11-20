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

/// A real number answered so that a caller that reads a double and one that
/// reads a float both read it.
///
/// The former plugin SDK declares the median of a ROI a double, and later
/// headers of the SDK declare the same selector a float. A method has one
/// type: a plugin built with the other declaration reads the register it
/// expects and finds the low half of a double, which is no number it can
/// use. Both registers are the same one, though, and a float is read in its
/// low 32 bits, which in a double are the low end of the fraction. So the
/// double is answered with those 32 bits replaced by the bits of the same
/// value as a float: who reads a float reads it exactly, and who reads a
/// double reads the value within one part in a million (2^-20). An infinite
/// value is answered as it is, since a double is infinite only with a
/// fraction of zero; a value that is no number stays none in both readings.
public enum RealOfBothWidths {

    /// `value` as both readings find it.
    public static func answered(_ value: Double) -> Double {
        guard !value.isInfinite else { return value }
        return Double(bitPattern: (value.bitPattern & 0xFFFF_FFFF_0000_0000) | UInt64(Float(value).bitPattern))
    }

    /// The value a caller gave, whichever of the two it passed. On arm64 a
    /// float is passed in the low 32 bits of the register with the rest
    /// zero, which as a double is a number below 1e-300 that no measure is:
    /// such a value is read as the float. On other processors the rest of the
    /// register is not defined when a float is passed, and the value is read
    /// as the double the former SDK declares.
    public static func taken(_ raw: Double) -> Double {
        #if arch(arm64)
        let bits = raw.bitPattern
        if bits >> 32 == 0 && bits != 0 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))) }
        #endif
        return raw
    }
}
