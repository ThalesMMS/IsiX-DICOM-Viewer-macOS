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

/// The limits of the app's HTTP servers (the web portal and XML-RPC).
public enum HTTPServerLimits {
    /// The longest request header line, in bytes, with its CRLF.
    public static let headerLineLength = 8190
    /// The most lines of a request header, its request line included.
    public static let headerLines = 100
    /// The most response body bytes read ahead of the network: more is read
    /// from the response only as what was written leaves.
    public static let responseReadAhead = 512 * 1024
    /// The web portal hands an upload to its page code in pieces of this many
    /// bytes (the last one may be shorter): its multipart reader finds the
    /// form's header in the first piece and the closing boundary at the end of
    /// a piece, so the pieces keep this size.
    public static let portalRequestBodyPiece = 2 * 1024 * 1024
    /// How long the portal waits for a response header, or an error response,
    /// to be written before it closes the connection. Body writes, and reads,
    /// have no deadline.
    public static let portalHeaderWriteDeadline: TimeInterval = 240
    /// How long an XML-RPC connection may stay open, from its first byte to
    /// its answer.
    public static let xmlRPCConnectionDeadline: TimeInterval = 10
}

/// What a server does with a request whose header is complete, before its body.
public enum HTTPRequestBodyDecision: Equatable, Sendable {
    /// Read this many body bytes, then answer.
    case readBody(UInt64)
    /// Answer now: the request has no body.
    case noBody
    /// The header is invalid: answer 400 and close the connection.
    case badRequest
    /// The method is not served: answer 405 and close the connection.
    case methodNotAllowed
}

/// The portal's rules for a request header: which methods carry a body and how
/// its Content-Length is read.
public enum HTTPRequestRules {
    /// POST and PUT carry a body; other methods do not.
    public static func expectsBody(method: String) -> Bool {
        method == "POST" || method == "PUT"
    }

    /// A method that carries a body needs a readable Content-Length; another
    /// method may only announce an empty body. Then a method the server does
    /// not serve is refused.
    public static func decision(method: String, contentLength: String?, isSupported: Bool) -> HTTPRequestBodyDecision {
        let expectsBody = expectsBody(method: method)
        var length: UInt64 = 0
        if expectsBody {
            guard let value = HTTPByteRangeRequest.parseUInt64(contentLength) else { return .badRequest }
            length = value
        } else if let contentLength {
            guard let value = HTTPByteRangeRequest.parseUInt64(contentLength), value == 0 else { return .badRequest }
        }
        guard isSupported else { return .methodNotAllowed }
        return expectsBody ? .readBody(length) : .noBody
    }

    /// The pieces an upload of `length` bytes is handed over in.
    public static func bodyPieceLengths(total length: UInt64, piece: Int = HTTPServerLimits.portalRequestBodyPiece) -> [Int] {
        var pieces: [Int] = []
        var remaining = length
        while remaining > 0 {
            let next = min(remaining, UInt64(piece))
            pieces.append(Int(next))
            remaining -= next
        }
        return pieces
    }
}

/// The Date header of a response.
public enum HTTPDateHeader {
    public static func string(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM y HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
