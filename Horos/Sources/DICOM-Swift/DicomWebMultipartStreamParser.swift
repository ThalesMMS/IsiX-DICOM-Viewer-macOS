// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: a part
// without Content-Length ends only at a whole delimiter line (CRLF, the
// boundary, "--" for the last one, blanks, a line break). Bytes that only
// begin like a delimiter, such as "--boundary--X" inside PixelData, stay
// payload instead of failing the response.
// Original: DICOM-Swift, DicomCore/DicomWebMultipartStreamParser.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public enum DicomWebMultipartEvent: Equatable, Sendable {
    case partHeaders([String: String], isRoot: Bool)
    case payload(Data)
    case partEnd
    case epilogue(Data)
}

public struct DicomWebMultipartLimits: Equatable, Sendable {
    public var maximumHeaderBytes: Int
    public var maximumPartBytes: Int
    public var maximumPartCount: Int
    public var maximumTotalBytes: Int

    public init(maximumHeaderBytes: Int = 64 * 1024, maximumPartBytes: Int = 128 * 1024 * 1024,
                maximumPartCount: Int = 10_000, maximumTotalBytes: Int = 1024 * 1024 * 1024) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumPartBytes = maximumPartBytes
        self.maximumPartCount = maximumPartCount
        self.maximumTotalBytes = maximumTotalBytes
    }
}

public enum DicomWebMultipartStreamError: Error, Equatable, Sendable {
    case limitExceeded(String, limit: Int)
    case invalidBoundary
    case malformedHeaders
    case invalidContentLength
    case missingFinalDelimiter
    case missingRoot
    case duplicateRoot
    case invalidState
}

/// Incremental MIME decoder. Data events use deterministic 16 KiB blocks and a final remainder.
/// A declared Content-Length takes precedence over delimiter-looking bytes inside the payload.
public struct DicomWebMultipartStreamParser: Sendable {
    private enum State { case preamble, headers, payload, delimiter, epilogue, finished }
    private var state: State = .preamble
    private var buffer = Data()
    private var pendingPayload = Data()
    private var pendingEpilogue = Data()
    private let marker: Data
    private let limits: DicomWebMultipartLimits
    private let rootID: String?
    private var foundRoot = false
    private var total = 0
    private var count = 0
    private var partBytes = 0
    private var remaining: Int?
    private var preambleLineStart = true

    public init(boundary: String, start: String? = nil, limits: DicomWebMultipartLimits = .init()) throws {
        guard !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || "'()+_,-./:=? ".utf8.contains($0) }),
              !boundary.hasSuffix(" ") else { throw DicomWebMultipartStreamError.invalidBoundary }
        marker = Data("--\(boundary)".utf8)
        rootID = start
        self.limits = limits
    }

    public init(contentType: String, limits: DicomWebMultipartLimits = .init()) throws {
        let media = try DicomWebMediaType(contentType)
        guard media.type == "multipart/related", let boundary = media.parameters["boundary"] else {
            throw DicomWebMultipartStreamError.invalidBoundary
        }
        try self.init(boundary: boundary, start: media.parameters["start"], limits: limits)
    }

    public mutating func feed(_ chunk: Data) throws -> [DicomWebMultipartEvent] {
        try Task.checkCancellation()
        guard state != .finished else { throw DicomWebMultipartStreamError.invalidState }
        try check(total, adding: chunk.count, limit: limits.maximumTotalBytes, name: "maximumTotalBytes")
        total += chunk.count
        var events: [DicomWebMultipartEvent] = []
        // Never copy an arbitrarily large caller chunk into the carry buffer.
        for offset in stride(from: 0, to: chunk.count, by: 16 * 1024) {
            try Task.checkCancellation()
            let start = chunk.index(chunk.startIndex, offsetBy: offset)
            let end = chunk.index(start, offsetBy: min(16 * 1024, chunk.count - offset))
            buffer.append(chunk[start..<end])
            try drain(into: &events, finishing: false)
        }
        return events
    }

    public mutating func finish() throws -> [DicomWebMultipartEvent] {
        try Task.checkCancellation()
        var events: [DicomWebMultipartEvent] = []
        try drain(into: &events, finishing: true)
        guard state == .epilogue else { throw DicomWebMultipartStreamError.missingFinalDelimiter }
        guard rootID == nil || foundRoot else { throw DicomWebMultipartStreamError.missingRoot }
        if !pendingEpilogue.isEmpty { events.append(.epilogue(pendingEpilogue)); pendingEpilogue = Data() }
        state = .finished
        return events
    }

    public static func parts(from data: Data, contentType: String,
                             limits: DicomWebMultipartLimits = .init()) throws -> [DicomWebMultipartPart] {
        var parser = try Self(contentType: contentType, limits: limits)
        var parts: [DicomWebMultipartPart] = []
        for event in try parser.feed(data) + parser.finish() {
            switch event {
            case .partHeaders(let headers, let isRoot):
                var part = DicomWebMultipartPart(headers: headers, body: Data())
                part.isRoot = isRoot
                parts.append(part)
            case .payload(let bytes): parts[parts.count - 1].body.append(bytes)
            default: break
            }
        }
        return parts
    }

    private func check(_ value: Int, adding: Int, limit: Int, name: String) throws {
        guard value <= limit, adding <= limit - value else {
            throw DicomWebMultipartStreamError.limitExceeded(name, limit: limit)
        }
    }

    private mutating func consume(_ n: Int) { buffer = Data(buffer.dropFirst(n)) }

    private mutating func emit(_ n: Int, into events: inout [DicomWebMultipartEvent]) throws {
        guard n > 0 else { return }
        try check(partBytes, adding: n, limit: limits.maximumPartBytes, name: "maximumPartBytes")
        partBytes += n
        pendingPayload.append(buffer.prefix(n))
        while pendingPayload.count >= 16 * 1024 {
            events.append(.payload(Data(pendingPayload.prefix(16 * 1024))))
            pendingPayload = Data(pendingPayload.dropFirst(16 * 1024))
        }
        consume(n)
    }

    /// Whether the bytes after a CRLF-boundary at `index` complete a delimiter
    /// line; nil while more bytes are needed to tell.
    private func delimiterLine(after index: Data.Index, finishing: Bool) -> Bool? {
        var position = index
        let closing = buffer[position...].starts(with: [45, 45])
        if closing { position += 2 }
        while position < buffer.endIndex, buffer[position] == 32 || buffer[position] == 9 {
            position += 1
            if position - index > limits.maximumHeaderBytes { return false }
        }
        guard position < buffer.endIndex else {
            if !finishing { return nil }
            return closing
        }
        if buffer[position] == 10 { return true }
        guard buffer[position] == 13 else { return false }
        guard position + 1 < buffer.endIndex else { return finishing ? false : nil }
        return buffer[position + 1] == 10
    }

    private mutating func drain(into events: inout [DicomWebMultipartEvent], finishing: Bool) throws {
        while true {
            switch state {
            case .preamble:
                if preambleLineStart, buffer.starts(with: marker) {
                    state = .delimiter
                    continue
                }
                if preambleLineStart, buffer.count < marker.count, marker.starts(with: buffer) { return }
                if let newline = buffer.firstIndex(of: 10) {
                    consume(newline - buffer.startIndex + 1)
                    preambleLineStart = true
                } else {
                    if !buffer.isEmpty { preambleLineStart = false; buffer.removeAll(keepingCapacity: true) }
                    return
                }
            case .delimiter:
                guard buffer.count >= marker.count + 2 else { return }
                guard buffer.starts(with: marker) else { throw DicomWebMultipartStreamError.invalidContentLength }
                let tail = buffer.dropFirst(marker.count)
                let closing = tail.starts(with: [45, 45])
                if let newline = tail.firstIndex(of: 10) {
                    let line = tail[..<newline]
                    let suffix = closing ? line.dropFirst(2) : line[...]
                    guard suffix.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) else {
                        throw DicomWebMultipartStreamError.missingFinalDelimiter
                    }
                    consume(newline - buffer.startIndex + 1)
                } else if closing, finishing, tail.dropFirst(2).allSatisfy({ $0 == 32 || $0 == 9 }) {
                    buffer.removeAll()
                } else {
                    try check(0, adding: buffer.count, limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                    return
                }
                if closing { state = .epilogue } else { state = .headers }
            case .headers:
                let crlf = buffer.range(of: Data([13, 10, 13, 10]))
                let lf = buffer.range(of: Data([10, 10]))
                guard let separator = [crlf, lf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else {
                    try check(0, adding: max(0, buffer.count - 3), limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                    return
                }
                try check(0, adding: separator.lowerBound - buffer.startIndex,
                          limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                guard let text = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
                    throw DicomWebMultipartStreamError.malformedHeaders
                }
                var headers: [String: String] = [:]
                for line in text.components(separatedBy: "\n") {
                    let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else { throw DicomWebMultipartStreamError.malformedHeaders }
                    let name = String(pair[0])
                    guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), headers.dicomWebHeaderValue(name) == nil else {
                        throw DicomWebMultipartStreamError.malformedHeaders
                    }
                    headers[name] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard headers.dicomWebHeaderValue("Content-Type") != nil else { throw DicomWebMultipartStreamError.malformedHeaders }
                remaining = nil
                if let value = headers.dicomWebHeaderValue("Content-Length") {
                    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(value) else {
                        throw DicomWebMultipartStreamError.invalidContentLength
                    }
                    try check(0, adding: n, limit: limits.maximumPartBytes, name: "maximumPartBytes")
                    remaining = n
                }
                try check(count, adding: 1, limit: limits.maximumPartCount, name: "maximumPartCount")
                count += 1
                let isRoot = rootID.map { headers.dicomWebHeaderValue("Content-ID") == $0 } ?? (count == 1)
                if isRoot {
                    guard !foundRoot else { throw DicomWebMultipartStreamError.duplicateRoot }
                    foundRoot = true
                }
                events.append(.partHeaders(headers, isRoot: isRoot))
                consume(separator.upperBound - buffer.startIndex)
                partBytes = 0
                state = .payload
            case .payload:
                if let n = remaining {
                    let available = min(n, buffer.count)
                    try emit(available, into: &events)
                    remaining = n - available
                    if remaining != 0 { return }
                    guard let first = buffer.first else { return }
                    let framing = first == 13 ? 2 : 1
                    guard buffer.count >= framing else { return }
                    guard buffer.prefix(framing) == Data(framing == 2 ? [13, 10] : [10]) else {
                        throw DicomWebMultipartStreamError.invalidContentLength
                    }
                    consume(framing)
                    if !pendingPayload.isEmpty { events.append(.payload(pendingPayload)); pendingPayload = Data() }
                    events.append(.partEnd)
                    state = .delimiter
                } else {
                    let framed = Data([10]) + marker
                    var search = buffer.startIndex
                    var match: Range<Data.Index>?
                    var undecided: Range<Data.Index>?
                    while let range = buffer.range(of: framed, in: search..<buffer.endIndex) {
                        // Only a whole delimiter line ends the part: the boundary, "--" for the
                        // last one, blanks, then a line break. Anything else is payload.
                        switch delimiterLine(after: range.upperBound, finishing: finishing) {
                        case .some(true): match = range
                        case .none: undecided = range
                        case .some(false): search = range.upperBound; continue
                        }
                        break
                    }
                    if match == nil, let undecided {
                        // Keep the candidate until the bytes after it decide what it is.
                        let hasCR = undecided.lowerBound > buffer.startIndex && buffer[undecided.lowerBound - 1] == 13
                        try emit(undecided.lowerBound - buffer.startIndex - (hasCR ? 1 : 0), into: &events)
                        return
                    }
                    if let match {
                        let hasCR = match.lowerBound > buffer.startIndex && buffer[match.lowerBound - 1] == 13
                        let n = match.lowerBound - buffer.startIndex - (hasCR ? 1 : 0)
                        try emit(n, into: &events)
                        consume(hasCR ? 2 : 1)
                        if !pendingPayload.isEmpty { events.append(.payload(pendingPayload)); pendingPayload = Data() }
                        events.append(.partEnd)
                        state = .delimiter
                    } else {
                        // boundary bytes + CRLF + leading '--'; two suffix bytes are retained too.
                        let carry = marker.count + 4
                        try emit(max(0, buffer.count - carry), into: &events)
                        return
                    }
                }
            case .epilogue:
                pendingEpilogue.append(buffer)
                buffer = Data()
                while pendingEpilogue.count >= 16 * 1024 {
                    events.append(.epilogue(Data(pendingEpilogue.prefix(16 * 1024))))
                    pendingEpilogue = Data(pendingEpilogue.dropFirst(16 * 1024))
                }
                return
            case .finished: throw DicomWebMultipartStreamError.invalidState
            }
        }
    }
}
