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

/// Follows the bytes of a connection's requests to hold their headers to the
/// server's limits before the HTTP parser buffers them: a header line of more
/// than `HTTPServerLimits.headerLineLength` bytes, or more than
/// `HTTPServerLimits.headerLines` lines before the blank one, ends the
/// connection without an answer. A body announced by Content-Length is passed
/// over; after a chunked body (which the portal refuses, closing the
/// connection) nothing more is followed.
public struct HTTPRequestHeadScanner: Sendable {
    public enum Verdict: Equatable, Sendable {
        case withinLimits
        case lineTooLong
        case tooManyLines
    }

    private enum State: Sendable {
        case head
        case body(UInt64)
        case unlimited
    }

    private var state = State.head
    private var lineLength = 0
    private var lines = 0
    private var line: [UInt8] = []
    private var contentLength: UInt64 = 0
    private var chunked = false
    private let maximumLineLength: Int
    private let maximumLines: Int

    public init(maximumLineLength: Int = HTTPServerLimits.headerLineLength,
                maximumLines: Int = HTTPServerLimits.headerLines) {
        self.maximumLineLength = maximumLineLength
        self.maximumLines = maximumLines
    }

    /// Follows `bytes`, the next ones received.
    public mutating func scan(_ bytes: UnsafeRawBufferPointer) -> Verdict {
        var index = 0
        while index < bytes.count {
            switch state {
            case .unlimited:
                return .withinLimits
            case .body(let remaining):
                let skipped = min(remaining, UInt64(bytes.count - index))
                index += Int(skipped)
                state = remaining == skipped ? .head : .body(remaining - skipped)
            case .head:
                let byte = bytes[index]
                index += 1
                lineLength += 1
                if lineLength > maximumLineLength { return .lineTooLong }
                if byte == UInt8(ascii: "\n") {
                    if let verdict = endLine() { return verdict }
                } else if byte != UInt8(ascii: "\r") && line.count < 64 {
                    // Enough of a line to read its field name and a length.
                    line.append(byte)
                }
            }
        }
        return .withinLimits
    }

    private mutating func endLine() -> Verdict? {
        defer {
            line.removeAll(keepingCapacity: true)
            lineLength = 0
        }
        if line.isEmpty {
            // A blank line before any other is skipped; after them, it ends the head.
            guard lines > 0 else { return nil }
            state = chunked ? .unlimited : (contentLength > 0 ? .body(contentLength) : .head)
            lines = 0
            contentLength = 0
            chunked = false
            return nil
        }
        lines += 1
        if lines > maximumLines { return .tooManyLines }
        let text = String(decoding: line, as: UTF8.self)
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(text[text.index(after: colon)...])
        if name == "content-length" {
            contentLength = HTTPByteRangeRequest.parseUInt64(value) ?? 0
        } else if name == "transfer-encoding" && value.lowercased().contains("chunked") {
            chunked = true
        }
        return nil
    }
}
