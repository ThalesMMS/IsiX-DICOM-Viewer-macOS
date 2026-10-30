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

/// The conversions of a C cast from a floating-point value to an integer as
/// the 3D view's former Objective-C compiled them on arm64 (FCVTZS): toward
/// zero, saturated at the type's bounds, NaN to 0. Swift's own initialisers
/// stop the process on a value out of range or NaN, which a C cast never did.
public enum CConversion {

    /// `(long) value`.
    @inlinable
    public static func long(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= 9.223372036854775807e18 { return Int.max }
        if value <= -9.223372036854775808e18 { return Int.min }
        return Int(value)
    }

    /// `(long) value` of a float.
    @inlinable
    public static func long(_ value: Float) -> Int { long(Double(value)) }

    /// `(int) value`.
    @inlinable
    public static func int(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= 2147483647.0 { return Int32.max }
        if value <= -2147483648.0 { return Int32.min }
        return Int32(value)
    }

    /// `(int) value` of a float.
    @inlinable
    public static func int(_ value: Float) -> Int32 { int(Double(value)) }

    /// `(short) value`: the conversion to int, then its low 16 bits, as an
    /// int-to-short C conversion keeps them.
    @inlinable
    public static func short(_ value: Double) -> Int16 { Int16(truncatingIfNeeded: int(value)) }
}
