//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// An address that is unique for the life of the process and is only ever
/// compared, never read or written: the context of a KVO observation or the key
/// of an associated object.
///
/// The address is kept as an integer, so the token is a `Sendable` constant and
/// a global `let` of it is safe from any thread. A global of type
/// `UnsafeMutableRawPointer`, or a `var` whose address is taken with `&`, holds
/// the same value but is not `Sendable`.
struct IdentityToken: Sendable, Equatable {
    private let address: UInt

    /// Reserves one byte that is never freed, so no other allocation can reuse
    /// the address while the token exists.
    init() {
        address = UInt(bitPattern: UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    }

    /// The address as a KVO context.
    var pointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: address)! }

    /// The address as an associated-object key.
    var key: UnsafeRawPointer { UnsafeRawPointer(bitPattern: address)! }
}
