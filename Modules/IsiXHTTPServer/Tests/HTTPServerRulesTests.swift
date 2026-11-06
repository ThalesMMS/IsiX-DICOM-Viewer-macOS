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
import Testing
@testable import IsiXHTTPServer

/// The HTTP rules of the portal and XML-RPC servers. Their use on the wire,
/// over SwiftNIO, is tests/test-web-portal-http-policy.py.
struct HTTPServerRulesTests {

    private func r(_ location: UInt64, _ length: UInt64) -> HTTPByteRange {
        HTTPByteRange(location: location, length: length)
    }

    @Test func rangesOfEachFormAreRead() {
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=0-9", contentLength: 100) == [r(0, 10)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=90-", contentLength: 100) == [r(90, 10)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=-5", contentLength: 100) == [r(95, 5)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=7", contentLength: 100) == [r(7, 1)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: " BYTES = 1-2 ", contentLength: 100) == [r(1, 2)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=-100", contentLength: 100) == [r(0, 100)])
    }

    @Test func severalRangesAreSortedAndMustNotOverlap() {
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=50-59, 0-9", contentLength: 100) == [r(0, 10), r(50, 10)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=0-9,10-19", contentLength: 100) == [r(0, 10), r(10, 10)])
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=0-10,10-19", contentLength: 100) == nil)
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=0-50,-60", contentLength: 100) == nil)
    }

    @Test func anUnreadableOrOutOfBodyHeaderIsIgnored() {
        for header in ["bytes", "items=0-1", "bytes=-", "bytes=9-1", "bytes=0-100", "bytes=100-", "bytes=-101",
                       "bytes=100", "bytes=x-y", "bytes=0-1,"] {
            #expect(HTTPByteRangeRequest.ranges(fromHeader: header, contentLength: 100) == nil, "\(header)")
        }
        #expect(HTTPByteRangeRequest.ranges(fromHeader: "bytes=0-", contentLength: 0) == nil)
    }

    @Test func numbersAreReadAsStrtoullReadsThem() {
        #expect(HTTPByteRangeRequest.parseUInt64("42") == 42)
        #expect(HTTPByteRangeRequest.parseUInt64(" 7") == 7)
        #expect(HTTPByteRangeRequest.parseUInt64("5x") == 5)
        #expect(HTTPByteRangeRequest.parseUInt64("") == nil)
        #expect(HTTPByteRangeRequest.parseUInt64("x") == nil)
        #expect(HTTPByteRangeRequest.parseUInt64(nil) == nil)
        #expect(HTTPByteRangeRequest.parseUInt64("99999999999999999999999") == nil)
    }

    @Test func multipartFramingAddsUp() {
        let framing = HTTPMultipartByteRanges(ranges: [r(0, 10), r(50, 5)], contentLength: 100, boundary: "B")
        #expect(String(decoding: framing.partHeader(0), as: UTF8.self) == "\r\n--B\r\nContent-Range: bytes 0-9/100\r\n\r\n")
        #expect(String(decoding: framing.partHeader(1), as: UTF8.self) == "\r\n--B\r\nContent-Range: bytes 50-54/100\r\n\r\n")
        #expect(String(decoding: framing.closingBoundary, as: UTF8.self) == "\r\n--B--\r\n")
        let expected = framing.partHeader(0).count + 10 + framing.partHeader(1).count + 5 + framing.closingBoundary.count
        #expect(framing.bodyLength == UInt64(expected))
        #expect(framing.contentType == "multipart/byteranges; boundary=B")
    }

    @Test func chunkFramingIsHexadecimal() {
        #expect(HTTPChunkedFraming.sizeLine(255) == Data("ff\r\n".utf8))
        #expect(HTTPChunkedFraming.sizeLine(524288) == Data("80000\r\n".utf8))
        #expect(HTTPChunkedFraming.footer == Data("\r\n0\r\n\r\n".utf8))
    }

    @Test func requestBodiesFollowTheMethod() {
        #expect(HTTPRequestRules.decision(method: "POST", contentLength: "12", isSupported: true) == .readBody(12))
        #expect(HTTPRequestRules.decision(method: "POST", contentLength: nil, isSupported: true) == .badRequest)
        #expect(HTTPRequestRules.decision(method: "PUT", contentLength: "abc", isSupported: false) == .badRequest)
        #expect(HTTPRequestRules.decision(method: "PUT", contentLength: "3", isSupported: false) == .methodNotAllowed)
        #expect(HTTPRequestRules.decision(method: "GET", contentLength: nil, isSupported: true) == .noBody)
        #expect(HTTPRequestRules.decision(method: "GET", contentLength: "0", isSupported: true) == .noBody)
        #expect(HTTPRequestRules.decision(method: "GET", contentLength: "1", isSupported: true) == .badRequest)
        #expect(HTTPRequestRules.decision(method: "DELETE", contentLength: nil, isSupported: false) == .methodNotAllowed)
    }

    @Test func uploadsAreHandedOverInTwoMebibytePieces() {
        let mib = 1024 * 1024
        #expect(HTTPRequestRules.bodyPieceLengths(total: 0).isEmpty)
        #expect(HTTPRequestRules.bodyPieceLengths(total: 100) == [100])
        #expect(HTTPRequestRules.bodyPieceLengths(total: UInt64(2 * mib)) == [2 * mib])
        #expect(HTTPRequestRules.bodyPieceLengths(total: UInt64(2 * mib + 1)) == [2 * mib, 1])
        #expect(HTTPRequestRules.bodyPieceLengths(total: UInt64(5 * mib)) == [2 * mib, 2 * mib, mib])
    }

    @Test func theDateHeaderIsInEnglishAndGMT() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(HTTPDateHeader.string(for: date) == "Thu, 01 Jan 1970 00:00:00 GMT")
    }

    @Test func theDeadlinesAndLimitsAreThePortals() {
        #expect(HTTPServerLimits.portalRequestBodyPiece == 2_097_152)
        #expect(HTTPServerLimits.portalHeaderWriteDeadline == 240)
        #expect(HTTPServerLimits.responseReadAhead == 524_288)
        #expect(HTTPServerLimits.headerLineLength == 8190 && HTTPServerLimits.headerLines == 100)
    }

    private func scan(_ text: String, _ scanner: inout HTTPRequestHeadScanner) -> HTTPRequestHeadScanner.Verdict {
        Array(text.utf8).withUnsafeBytes { scanner.scan($0) }
    }

    @Test func headersAreHeldToTheirLimitsAndBodiesPassedOver() {
        var scanner = HTTPRequestHeadScanner()
        #expect(scan("GET / HTTP/1.1\r\nHost: x\r\n\r\n", &scanner) == .withinLimits)
        // A body announced by its length is not taken for header lines.
        let body = String(repeating: "x\n", count: 300)
        #expect(scan("POST /a HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body, &scanner) == .withinLimits)
        #expect(scan("GET / HTTP/1.1\r\n" + String(repeating: "X: 1\r\n", count: 99) + "\r\n", &scanner) == .withinLimits)
        #expect(scan("GET / HTTP/1.1\r\n" + String(repeating: "X: 1\r\n", count: 100), &scanner) == .tooManyLines)

        var long = HTTPRequestHeadScanner()
        #expect(scan("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 8185) + "\r\n", &long) == .withinLimits)
        var longer = HTTPRequestHeadScanner()
        #expect(scan("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 8186) + "\r\n", &longer) == .lineTooLong)
        // An endless line is caught before its end.
        var endless = HTTPRequestHeadScanner()
        #expect(scan(String(repeating: "a", count: 9000), &endless) == .lineTooLong)

        // Split anywhere, the bytes give the same verdicts.
        var split = HTTPRequestHeadScanner()
        for character in "POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcGET / HTTP/1.1\r\n\r\n" {
            #expect(scan(String(character), &split) == .withinLimits)
        }
        var chunked = HTTPRequestHeadScanner()
        #expect(scan("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "z", count: 20000), &chunked) == .withinLimits)
    }
}
