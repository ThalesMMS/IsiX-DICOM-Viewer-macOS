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

/// What the shared-database server accepts from the wire before it consumes,
/// allocates or converts anything.
///
/// Every length and count of this protocol is a 32-bit big-endian integer that
/// the server used as a signed `int`: a negative value asked for `length + 4`
/// bytes, which overflows, and a string was read from bytes that need not
/// contain a terminator. The rules are stated once, here, and the request
/// parser asks them.
///
/// The limits are sized from the commands the client really sends: an upload
/// carries whole files - one may reach the protocol's own 2 GiB bound - in
/// requests the client splits near 32 MiB; every other request is a few
/// strings, or one path per image of a selection.
public enum SharedDatabaseWire {

    /// One string: an object URI, a key, a value, a path, an album description.
    public static let maximumStringLength = 64 << 20

    /// Files in one upload, paths in one fetch or send.
    public static let maximumCount = 1 << 20

    /// One uploaded file: the protocol's length field is a signed 32-bit int.
    public static let maximumFileLength = Int(Int32.max)

    /// What may sit unconsumed in the receive buffer while a request is parsed.
    /// Receiving in blocks bounds each read, not the request: this bounds the
    /// request.
    public static let maximumBufferedBytesAwaitingCommand = 64 << 10
    public static let maximumBufferedBytesForUpload = Int(Int32.max) + (64 << 20)
    public static let maximumBufferedBytesForOtherRequests = 256 << 20

    /// A 32-bit big-endian length or count read as the server always has, as a
    /// signed value; -1 when it is negative or above `maximum`.
    public static func validated(_ bigEndian: UInt32, maximum: Int) -> Int {
        let value = Int(Int32(bitPattern: UInt32(bigEndian: bigEndian)))
        return value >= 0 && value <= maximum ? value : -1
    }

    /// The signed value of a 32-bit big-endian field, as a rejection reports it.
    public static func signedValue(_ bigEndian: UInt32) -> Int32 {
        Int32(bitPattern: UInt32(bigEndian: bigEndian))
    }

    /// Outcome of decoding one string payload (the bytes after its length).
    public enum StringStatus: Sendable, Equatable {
        case value
        /// Length zero: the client's encoding of nil, distinct from "".
        case null
        case unterminated
        case embeddedNull
        case invalidUTF8
    }

    /// Decodes a string exactly within `bytes`: the last byte must be the
    /// terminator, no earlier byte may be one, and the rest must be UTF-8.
    /// Nothing beyond `bytes` is read. The text is decoded by Foundation, as the
    /// server always decoded it, so a byte order mark is read the same way.
    public static func decodeString(_ bytes: UnsafeRawBufferPointer) -> (value: String?, status: StringStatus) {
        let length = bytes.count
        guard length > 0, let base = bytes.baseAddress else {
            return (nil, .null)
        }
        guard bytes[length - 1] == 0 else {
            return (nil, .unterminated)
        }
        if length > 1, memchr(base, 0, length - 1) != nil {
            return (nil, .embeddedNull)
        }
        guard let string = NSString(bytes: base, length: length - 1, encoding: String.Encoding.utf8.rawValue) else {
            return (nil, .invalidUTF8)
        }
        return (string as String, .value)
    }
}

/// The authorization envelope of the shared-database protocol, versioned per
/// connection: `AUTHR\0`, a 32-bit big-endian length, the password, then the
/// request it carries. It authenticates a request; the transport is not
/// encrypted.
public enum SharedDatabaseEnvelope {

    /// `AUTHR\0`.
    public static let header: [UInt8] = [65, 85, 84, 72, 82, 0]

    /// The longest password an envelope carries.
    public static let maximumPasswordLength = 4096

    private static let publicCommands: Set<String> = ["DBVER", "ISPWD", "PASWD", "AUTHV", "GETDI"]

    /// Whether a server that asks for a password still answers `command`
    /// without one.
    public static func isPublicCommand(_ command: String) -> Bool {
        publicCommands.contains(command)
    }

    /// `request` inside an envelope that carries `password`; nil for an empty
    /// or too long password, a request too short to hold a command, or one
    /// that is already an envelope.
    public static func authenticatedRequest(_ request: Data, password: String) -> Data? {
        let secret = Data(password.utf8)
        guard !secret.isEmpty, secret.count <= maximumPasswordLength, request.count >= 6,
              request.dropFirst(5).first == 0, !request.prefix(6).elementsEqual(header) else { return nil }
        var result = Data(header)
        let count = UInt32(secret.count)
        result.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 255),
                                   UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(secret)
        result.append(request)
        return result
    }

    /// The request an envelope carries, or the request itself when it has none
    /// or the envelope is incomplete. What a request does is decided by this
    /// inner command, not by the `AUTHR` in front of it.
    public static func requestInsideEnvelope(_ request: Data) -> Data {
        guard request.count >= 10, request.prefix(6).elementsEqual(header) else { return request }
        let start = request.startIndex
        let count = request[(start + 6)..<(start + 10)].reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumPasswordLength, request.count >= 10 + count + 6 else { return request }
        return request.subdata(in: (start + 10 + count)..<request.endIndex)
    }

    /// How much of `bytes` an envelope at their start takes: zero while more
    /// bytes are needed, -1 to refuse the request, otherwise the envelope's
    /// length. The six-byte command that follows must be there too before
    /// anything is decided.
    public static func authorizedPrefixLength(_ bytes: UnsafeRawBufferPointer, password: String?, required: Bool) -> Int {
        guard bytes.count >= 10 else { return 0 }
        guard bytes.prefix(6).elementsEqual(header) else { return -1 }
        let count = bytes[6..<10].reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumPasswordLength else { return -1 }
        guard bytes.count >= 10 + count + 6 else { return 0 }
        guard bytes[10 + count + 5] == 0 else { return -1 }
        if !required { return 10 + count }
        guard let password, !password.isEmpty else { return -1 }
        let expected = Array(password.utf8)
        guard expected.count == count else { return -1 }
        // In constant time for a password of the right length.
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ bytes[10 + index] }
        return difference == 0 ? 10 + count : -1
    }

    /// The same, for bytes held in `Data`.
    public static func authorizedPrefixLength(_ data: Data, password: String?, required: Bool) -> Int {
        data.withUnsafeBytes { authorizedPrefixLength($0, password: password, required: required) }
    }
}
