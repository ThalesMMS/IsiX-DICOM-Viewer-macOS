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

import CFNetwork
import Foundation

/// An XML-RPC request as received so far on one connection.
///
/// The XML-RPC interface parses everything a connection has received each time
/// more arrives, and acts once the header is complete: it judges the request
/// there (credentials, peer), then waits for the body that Content-Length
/// announces, if any. A request without Content-Length is taken as it is when
/// its header completes.
public struct XMLRPCHTTPRequest {
    /// The HTTP version answers use when the request names none.
    public static let defaultVersion = kCFHTTPVersion1_1 as String

    /// The parsed request, for the parts not exposed here.
    public let message: CFHTTPMessage

    /// The request parsed from `received`, or nil while its header is not
    /// complete.
    public init?(received: Data) {
        let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
        received.withUnsafeBytes { bytes in
            if let base = bytes.bindMemory(to: UInt8.self).baseAddress {
                _ = CFHTTPMessageAppendBytes(message, base, bytes.count)
            }
        }
        guard CFHTTPMessageIsHeaderComplete(message) else {
            return nil
        }
        self.message = message
    }

    /// The request's HTTP version, or HTTP/1.1 when its request line has none.
    public var version: String {
        // CFNetwork answers NULL for a request line it could not read, though
        // Swift imports the result as never nil.
        let copied = unsafeBitCast(CFHTTPMessageCopyVersion(message), to: Optional<Unmanaged<CFString>>.self)
        return (copied?.takeRetainedValue() as String?) ?? Self.defaultVersion
    }

    /// A header field, as the request wrote it.
    public func field(_ name: String) -> String? {
        CFHTTPMessageCopyHeaderFieldValue(message, name as CFString)?.takeRetainedValue() as String?
    }

    /// The Content-Length field, unparsed.
    public var contentLengthField: String? {
        field("Content-Length")
    }

    /// The bytes after the header, or nil when none have arrived.
    public var body: Data? {
        CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data?
    }

    /// Whether the body announced is all there. Content-Length is read as
    /// -[NSString intValue] reads it, and compared with the body's length as
    /// the Objective-C compared an unsigned length with an int: a negative
    /// value is never reached, and the request waits for its deadline.
    public var isComplete: Bool {
        guard let field = contentLengthField else { return true }
        let announced = UInt(bitPattern: Int((field as NSString).intValue))
        return UInt(body?.count ?? 0) >= announced
    }

    /// The body, cut at Content-Length when it is longer; a negative
    /// Content-Length cuts nothing. Nil when no body arrived.
    public var content: Data? {
        guard let body else { return nil }
        guard let field = contentLengthField else { return body }
        let announced = Int((field as NSString).intValue)
        guard UInt(bitPattern: announced) < UInt(body.count) else { return body }
        return body.prefix(announced)
    }
}

/// The responses of the XML-RPC interface, as HTTP messages.
public enum XMLRPCHTTPResponse {
    /// A `methodResponse` document, fault or not, in the body of a 200, which
    /// is where the XML-RPC specification puts both, with its type and length.
    public static func document(_ document: String, version: String) -> CFHTTPMessage {
        let body = Data(document.utf8)
        let response = message(status: 200, version: version)
        CFHTTPMessageSetHeaderFieldValue(response, "Content-Type" as CFString, "text/xml; charset=utf-8" as CFString)
        CFHTTPMessageSetHeaderFieldValue(response, "Content-Length" as CFString, length(of: body) as CFString)
        CFHTTPMessageSetBody(response, body as CFData)
        return response
    }

    /// The answer of a method that ran: a 200 with the response document and
    /// its length, without a Content-Type, as the interface always sent it.
    public static func methodResponse(_ body: Data, version: String) -> CFHTTPMessage {
        let response = message(status: 200, version: version)
        CFHTTPMessageSetHeaderFieldValue(response, "Content-Length" as CFString, length(of: body) as CFString)
        CFHTTPMessageSetBody(response, body as CFData)
        return response
    }

    /// A bare status line with the header fields a client needs to act on it,
    /// and an empty body: the 401 that carries the authentication challenge,
    /// a 403, or the empty 200 of an order answered before it runs.
    public static func status(_ status: Int, headers: [String: String], version: String) -> CFHTTPMessage {
        let response = message(status: status, version: version)
        for (field, value) in headers {
            CFHTTPMessageSetHeaderFieldValue(response, field as CFString, value as CFString)
        }
        CFHTTPMessageSetHeaderFieldValue(response, "Content-Length" as CFString, "0" as CFString)
        return response
    }

    /// The bytes that go on the wire.
    public static func serialized(_ response: CFHTTPMessage) -> Data {
        (CFHTTPMessageCopySerializedMessage(response)?.takeRetainedValue() as Data?) ?? Data()
    }

    private static func message(status: Int, version: String) -> CFHTTPMessage {
        CFHTTPMessageCreateResponse(kCFAllocatorDefault, status, nil, version as CFString).takeRetainedValue()
    }

    /// The length as `%d` of `(int) length` wrote it.
    private static func length(of body: Data) -> String {
        String(Int32(truncatingIfNeeded: body.count))
    }
}

/// The method call of a request document, read as the interface reads it.
public enum XMLRPCMethodCall {
    /// The document's one `methodCall` element.
    public static func element(in document: XMLDocument) throws -> XMLNode {
        let methodCalls = (try? document.nodes(forXPath: "methodCall")) ?? []
        guard methodCalls.count == 1 else {
            throw XMLRPCCodingError.generic("request contains \(Int32(truncatingIfNeeded: methodCalls.count)) method calls")
        }
        return methodCalls[0]
    }

    /// The name of the method called.
    public static func methodName(of methodCall: XMLNode) throws -> String {
        let methodNames = (try? methodCall.nodes(forXPath: "methodName")) ?? []
        guard methodNames.count == 1 else {
            throw XMLRPCCodingError.generic("method call contains \(Int32(truncatingIfNeeded: methodNames.count)) method names")
        }
        return methodNames[0].stringValue ?? ""
    }

    /// The parameters, decoded; a `<nil/>` parameter makes the call
    /// unreadable, as it could not go into the array of parameters.
    public static func parameters(of methodCall: XMLNode) throws -> [NSObject] {
        let values = (try? methodCall.nodes(forXPath: "params/param/value")) ?? []
        return try values.map { value in
            guard let parameter = try XMLRPCValueCoder.parse(value) else {
                throw XMLRPCCodingError.invalidArgument("*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
            }
            return parameter
        }
    }
}

/// Which method of the interface's delegate answers a call, and with what.
public enum XMLRPCDispatch {
    /// The selector for `methodName`: the one the delegate publishes for it,
    /// or else `name:error:` when the delegate responds to it, or else
    /// `name:`. Only a published selector may be called without the
    /// delegate's further say.
    public static func selector(forMethodName name: String?, published: String?,
                                respondsTo: (String) -> Bool) -> (selector: String, isPublished: Bool) {
        if let published {
            return (published, true)
        }
        let withError = "\(name ?? "(null)"):error:"
        return (respondsTo(withError) ? withError : "\(name ?? "(null)"):", false)
    }

    /// Whether the selector's last argument is the NSError of the call.
    public static func takesError(_ selector: String) -> Bool {
        selector.hasSuffix(":error:")
    }

    /// How many parameters a method takes: its arguments, without the
    /// receiver, the selector and the error.
    public static func acceptedParameterCount(argumentCount: Int, selector: String) -> Int {
        max(0, argumentCount - 2 - (takesError(selector) ? 1 : 0))
    }

    /// The parameters a method is called with: one empty struct for a call
    /// that has none.
    public static func parameters(_ parameters: [Any]?) -> [Any] {
        guard let parameters, !parameters.isEmpty else { return [NSDictionary()] }
        return parameters
    }
}
