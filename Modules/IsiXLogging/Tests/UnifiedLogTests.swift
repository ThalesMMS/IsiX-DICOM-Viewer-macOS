//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreFoundation
import Foundation
import Testing
@testable import IsiXLogging

/// The two steps that let the unified log show a Swift literal format: the
/// string handed to NSLogv exposes the literal's own bytes, and NSLogv is
/// found. What the log then shows, with standard error discarded, is
/// tests/test-swift-nslog-unified-log.py.
struct UnifiedLogTests {

    @Test func aLiteralFormatExposesItsOwnBytes() throws {
        let format: StaticString = "Scissor Start %d"
        let string = try #require(LiteralLogFormat.string(over: format))
        let pointer = try #require(CFStringGetCStringPtr(string, CFStringBuiltInEncodings.ASCII.rawValue))
        #expect(UnsafeRawPointer(pointer) == UnsafeRawPointer(format.utf8Start))
        #expect(string as String == "Scissor Start %d")
    }

    @Test func aFormatThatIsNotASCIIGoesTheOldWay() {
        #expect(LiteralLogFormat.string(over: "Unicode test: é %d") == nil)
    }

    @Test func foundationsNSLogvIsFound() {
        #expect(LiteralLogFormat.nslogv != nil)
    }
}
