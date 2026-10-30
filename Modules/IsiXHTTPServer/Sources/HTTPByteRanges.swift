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

/// One range of bytes of a response body: `length` bytes from `location`.
public struct HTTPByteRange: Equatable, Sendable {
    public var location: UInt64
    public var length: UInt64

    public init(location: UInt64, length: UInt64) {
        self.location = location
        self.length = length
    }

    /// The offset just past the range.
    public var end: UInt64 { location &+ length }

    /// The `first-last` form of a Content-Range value.
    public var firstLastDescription: String {
        "\(location)-\(end &- 1)"
    }

    func overlaps(_ other: HTTPByteRange) -> Bool {
        // Ranges that only touch do not overlap; a range that ends before the
        // other starts, or starts after it ends, shares no byte with it.
        if end < other.location || other.end < location { return false }
        return min(end, other.end) > max(location, other.location)
    }
}

/// The byte ranges a Range request header asks of a body, as the portal has
/// always read them.
///
/// The unit must be `bytes` (in any case). Each comma-separated element is
/// `first-last`, `first-` (to the end), `-count` (the last bytes) or a single
/// offset (one byte). An element that is out of the body, ranges that overlap,
/// or a header that cannot be read make the whole header ignored: the body is
/// then sent whole. The ranges come back sorted by offset.
public enum HTTPByteRangeRequest {
    public static func ranges(fromHeader header: String, contentLength: UInt64) -> [HTTPByteRange]? {
        guard let equals = header.firstIndex(of: "=") else { return nil }
        let unit = header[..<equals].trimmingCharacters(in: .whitespaces)
        let value = header[header.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard unit.caseInsensitiveCompare("bytes") == .orderedSame else { return nil }

        var ranges: [HTTPByteRange] = []
        for element in value.components(separatedBy: ",") {
            guard let dash = element.firstIndex(of: "-") else {
                guard let offset = parseUInt64(element), offset < contentLength else { return nil }
                ranges.append(HTTPByteRange(location: offset, length: 1))
                continue
            }
            let first = parseUInt64(String(element[..<dash]))
            let last = parseUInt64(String(element[element.index(after: dash)...]))
            switch (first, last) {
            case (nil, nil):
                return nil
            case (nil, let count?):
                guard count <= contentLength else { return nil }
                ranges.append(HTTPByteRange(location: contentLength - count, length: count))
            case (let first?, nil):
                guard first < contentLength else { return nil }
                ranges.append(HTTPByteRange(location: first, length: contentLength - first))
            case (let first?, let last?):
                guard first <= last, last < contentLength else { return nil }
                ranges.append(HTTPByteRange(location: first, length: last - first + 1))
            }
        }
        guard !ranges.isEmpty else { return nil }
        for (index, range) in ranges.enumerated() {
            for other in ranges[(index + 1)...] where range.overlaps(other) {
                return nil
            }
        }
        return ranges.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
    }

    /// A decimal number as C's strtoull reads it: leading white space and a
    /// sign are accepted, and reading stops at the first other character. A
    /// string with no digit, or a number too large, is no number.
    public static func parseUInt64(_ string: String?) -> UInt64? {
        guard let string else { return nil }
        return string.withCString { pointer -> UInt64? in
            errno = 0
            let value = strtoull(pointer, nil, 10)
            return errno == 0 ? value : nil
        }
    }
}

/// The framing of a multiple-range (multipart/byteranges) body: each part's
/// header, the closing boundary and the length of the whole.
public struct HTTPMultipartByteRanges: Sendable {
    public let boundary: String
    public let ranges: [HTTPByteRange]
    public let contentLength: UInt64

    public init(ranges: [HTTPByteRange], contentLength: UInt64, boundary: String = UUID().uuidString) {
        self.boundary = boundary
        self.ranges = ranges
        self.contentLength = contentLength
    }

    /// The bytes that precede part `index`: its boundary and Content-Range.
    public func partHeader(_ index: Int) -> Data {
        let range = ranges[index]
        let text = "\r\n--\(boundary)\r\nContent-Range: bytes \(range.firstLastDescription)/\(contentLength)\r\n\r\n"
        return Data(text.utf8)
    }

    /// The bytes that close the body.
    public var closingBoundary: Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    /// The Content-Length of the multipart body.
    public var bodyLength: UInt64 {
        var total = UInt64(closingBoundary.count)
        for index in ranges.indices {
            total += UInt64(partHeader(index).count) + ranges[index].length
        }
        return total
    }

    /// The Content-Type of the multipart body.
    public var contentType: String {
        "multipart/byteranges; boundary=\(boundary)"
    }
}

/// The framing of a chunked (Transfer-Encoding: chunked) body.
public enum HTTPChunkedFraming {
    /// The line before a chunk: its length in hexadecimal.
    public static func sizeLine(_ length: Int) -> Data {
        Data((String(length, radix: 16) + "\r\n").utf8)
    }

    /// The line after a chunk that more chunks follow.
    public static let chunkEnd = Data("\r\n".utf8)

    /// What follows the last chunk: its end, the empty chunk and the end of
    /// the body.
    public static let footer = Data("\r\n0\r\n\r\n".utf8)
}
