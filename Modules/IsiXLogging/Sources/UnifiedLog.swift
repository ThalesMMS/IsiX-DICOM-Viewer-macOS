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
import Darwin
import Foundation

/// `NSLogv` for Swift with a literal format, written where and as the
/// Objective-C `NSLog` writes. The application and every internal module that
/// logs declare their own `NSLog(_ format: StaticString, ...)` over it, which
/// shadows Foundation's inside that module, and a `String` one marked
/// unavailable, so that a format built at run time does not compile.
///
/// Foundation's Swift overlay implements `NSLog(_:_:)` on its own: its line
/// reaches the unified log, if at all, as one private string sent by
/// Foundation, which reads `<private>` as a whole, and the application is
/// launched with its standard error going nowhere. `NSLogv` is still
/// Foundation's C function, which writes to both as the Objective-C `NSLog`
/// does.
///
/// `NSLogv` hands the unified log the format and the arguments apart only
/// when the format's characters are a C string inside a loaded image, as an
/// Objective-C `@"..."` literal's are. The log then shows the format's text and
/// the numbers, and `<private>` for each string or object argument that is not
/// itself a literal. Any other format is logged as the formatted line in one
/// private string, which reads `<private>` as a whole. A Swift literal reaches
/// `NSLogv` bridged from `String`: one longer than 15 UTF-8 bytes still points
/// into the executable, while a shorter one is a small string, copied out of
/// it, so "Scissor Start" read `<private>` as a whole.
///
/// So the format is a `StaticString`, handed to `NSLogv` as a `CFString` made
/// over the literal's own bytes without copying them
/// (`CFStringCreateWithCStringNoCopy`). Arguments keep the log's default
/// privacy, as from Objective-C. Two kinds of format stay private: one that is
/// not ASCII, which Objective-C also stores without a C string; and a very
/// short one that CoreFoundation keeps inside the string reference itself (a
/// tagged pointer) instead of pointing at the bytes - every format of up to 7
/// bytes, and some of 8 to 11 bytes made only of common letters, such as
/// "localhost".
public func unifiedLogv(_ format: StaticString, _ arguments: [CVarArg]) {
    withVaList(arguments) { list in
        if let literal = LiteralLogFormat.string(over: format), let log = LiteralLogFormat.nslogv {
            // va_list is one pointer on both Darwin architectures.
            log(literal, unsafeBitCast(list, to: UnsafeMutableRawPointer.self))
        } else {
            NSLogv(format.description, list)
        }
    }
}

enum LiteralLogFormat {
    typealias NSLogvFunction = @convention(c) (CFString, UnsafeMutableRawPointer) -> Void

    /// Foundation's `NSLogv` (`void NSLogv(NSString *, va_list)`), called with
    /// the `CFString` itself: Swift imports it with a `String` format, and
    /// bridging a short string back would copy it out of the executable again.
    static let nslogv: NSLogvFunction? = {
        guard MemoryLayout<CVaListPointer>.size == MemoryLayout<UnsafeMutableRawPointer>.size,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSLogv") else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: NSLogvFunction.self)
    }()

    /// A string over the literal's bytes, which stay in the executable for the
    /// life of the process; nil for a format that is not ASCII.
    static func string(over format: StaticString) -> CFString? {
        guard format.hasPointerRepresentation, format.isASCII else { return nil }
        return CFStringCreateWithCStringNoCopy(
            nil, UnsafeRawPointer(format.utf8Start).assumingMemoryBound(to: CChar.self),
            CFStringBuiltInEncodings.ASCII.rawValue, kCFAllocatorNull)
    }
}
