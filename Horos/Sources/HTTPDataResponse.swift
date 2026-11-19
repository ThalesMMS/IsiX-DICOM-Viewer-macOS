/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The implementation of HTTPDataResponse, declared in HTTPResponse.h: the
/// response of the Horos and OsiriX SDK's HTTP server whose body is data in
/// memory. The class is Objective-C for the runtime, so that a plugin built
/// for either SDK finds it by name and its Objective-C subclass keeps every
/// method. The web portal's response (WebPortalResponse) is a subclass: its
/// body is this data.
@objc @implementation extension HTTPDataResponse {
    // The two instance variables of the SDK, offset and data, with its types:
    // a plugin built for it binds their names when it loads, and its subclass
    // reads and writes them directly. Their names here are others because
    // the class and its subclasses answer -offset and -data.

    /// The offset as the SDK kept it, an unsigned int: a copy of readOffset,
    /// written where the SDK wrote it and stopped at its greatest value.
    /// Nothing here reads it, so that a body of 4 GiB or more is still read
    /// to its end, and what a plugin writes there directly moves no read.
    final var horos_offset: UInt32 = 0
    /// The body; nil is an empty one.
    final var horos_data: NSData?
    /// Where the next read starts.
    final var readOffset: UInt64 = 0

    /// The body as Swift data.
    final var dataStorage: Data? {
        get { horos_data as Data? }
        set { horos_data = newValue as NSData? }
    }

    public override init() {
        super.init()
    }

    public init!(data: Data!) {
        horos_data = data as NSData?
        super.init()
    }

    var contentLength: UInt64 {
        UInt64(horos_data?.length ?? 0)
    }

    var offset: UInt64 {
        get { readOffset }
        set {
            readOffset = newValue
            horos_offset = UInt32(clamping: newValue)
        }
    }

    /// Up to `length` bytes from the offset, which moves past them; an offset
    /// past the end reads nothing.
    func readData(ofLength length: UInt32) -> Data! {
        let body = dataStorage ?? Data()
        let start = Int(min(readOffset, UInt64(body.count)))
        let count = min(Int(length), body.count - start)
        readOffset = UInt64(start + count)
        horos_offset = UInt32(clamping: readOffset)
        return body.subdata(in: body.startIndex + start ..< body.startIndex + start + count)
    }

    var isDone: Bool {
        readOffset == contentLength
    }
}

// What the connection's exchange reads a response through. Each member asks
// the object by its Objective-C selector, so that a plugin's subclass that
// overrides one, or adds one of the optional ones, is the one that answers.
extension HTTPDataResponse: HTTPServerResponse, HTTPServerDeferredResponse {
    func readData(ofLength length: Int) -> Data? {
        readData(ofLength: UInt32(clamping: length))
    }

    var isChunked: Bool { FormerHTTPResponseOptions.isChunked(self) }

    var responseHeaderFields: [(String, String)] { FormerHTTPResponseOptions.headerFields(of: self) }

    func connectionDidClose() { FormerHTTPResponseOptions.connectionDidClose(self) }

    var waitsForData: Bool { FormerHTTPResponseOptions.isAsynchronous(self) }
}

/// The optional part of the SDK's HTTPResponse protocol, asked of a response
/// by name, as the SDK's connection asked it: the header fields it adds,
/// whether its body is chunked or comes later, and the notice that the
/// connection is done with it.
enum FormerHTTPResponseOptions {
    private static let httpHeaders = NSSelectorFromString("httpHeaders")
    private static let isChunkedSelector = NSSelectorFromString("isChunked")
    private static let isAsynchronousSelector = NSSelectorFromString("isAsynchronous")
    private static let connectionDidCloseSelector = NSSelectorFromString("connectionDidClose")

    /// -httpHeaders, in the order the dictionary enumerates them.
    static func headerFields(of response: any NSObjectProtocol) -> [(String, String)] {
        guard response.responds(to: httpHeaders),
              let headers = response.perform(httpHeaders)?.takeUnretainedValue() as? NSDictionary else { return [] }
        var fields: [(String, String)] = []
        for case let (name as String, value as String) in headers {
            fields.append((name, value))
        }
        return fields
    }

    static func isChunked(_ response: any NSObjectProtocol) -> Bool {
        answersYes(response, isChunkedSelector)
    }

    static func isAsynchronous(_ response: any NSObjectProtocol) -> Bool {
        answersYes(response, isAsynchronousSelector)
    }

    static func connectionDidClose(_ response: any NSObjectProtocol) {
        guard response.responds(to: connectionDidCloseSelector) else { return }
        typealias Notice = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(implementation(of: connectionDidCloseSelector, in: response), to: Notice.self)(response, connectionDidCloseSelector)
    }

    private static func answersYes(_ response: any NSObjectProtocol, _ selector: Selector) -> Bool {
        guard response.responds(to: selector) else { return false }
        typealias Question = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(implementation(of: selector, in: response), to: Question.self)(response, selector).boolValue
    }

    /// The method of a selector the object has said it responds to.
    private static func implementation(of selector: Selector, in response: any NSObjectProtocol) -> IMP? {
        class_getMethodImplementation(object_getClass(response), selector)
    }
}

/// A response of a plugin's own class, which follows the SDK's HTTPResponse
/// protocol and descends from neither of the SDK's two response classes, as
/// the exchange reads it.
final class FormerHTTPResponseAdapter: HTTPServerResponse, HTTPServerDeferredResponse {
    private let response: any NSObjectProtocol & HTTPResponse

    init(_ response: any NSObjectProtocol & HTTPResponse) {
        self.response = response
    }

    var contentLength: UInt64 { response.contentLength }

    var offset: UInt64 {
        get { response.offset }
        set { response.offset = newValue }
    }

    func readData(ofLength length: Int) -> Data? {
        response.readData(ofLength: UInt32(clamping: length))
    }

    var isDone: Bool { response.isDone }

    var isChunked: Bool { FormerHTTPResponseOptions.isChunked(response) }

    var responseHeaderFields: [(String, String)] { FormerHTTPResponseOptions.headerFields(of: response) }

    func connectionDidClose() { FormerHTTPResponseOptions.connectionDidClose(response) }

    var waitsForData: Bool { FormerHTTPResponseOptions.isAsynchronous(response) }
}
