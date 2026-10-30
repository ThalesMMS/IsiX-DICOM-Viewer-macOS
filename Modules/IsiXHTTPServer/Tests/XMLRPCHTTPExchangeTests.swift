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

/// The HTTP side of an XML-RPC exchange: when a request is complete, what
/// its body is, how a call is read and dispatched, and what the answers look
/// like on the wire. The connection that uses them is checked against the
/// former Objective-C one by tests/test-xmlrpc-connection-equivalence.py.
struct XMLRPCHTTPExchangeTests {

    private func request(_ text: String) -> XMLRPCHTTPRequest? {
        XMLRPCHTTPRequest(received: Data(text.utf8))
    }

    @Test func aRequestWaitsForItsHeader() {
        #expect(request("") == nil)
        #expect(request("POST / HTTP/1.1\r\nContent-Length: 4\r\n") == nil)
        #expect(request("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\n") != nil)
    }

    @Test func theBodyIsCompleteAtContentLength() throws {
        let partial = try #require(request("POST / HTTP/1.0\r\nContent-Length: 4\r\n\r\nab"))
        #expect(!partial.isComplete)
        #expect(partial.version == "HTTP/1.0")
        let whole = try #require(request("POST / HTTP/1.1\r\ncontent-length: 4\r\n\r\nabcdef"))
        #expect(whole.isComplete)
        #expect(whole.content == Data("abcd".utf8))
        #expect(whole.contentLengthField == "4")
    }

    @Test func contentLengthIsReadAsTheFormerConnectionReadIt() throws {
        // Without Content-Length the request is taken as it is.
        let bare = try #require(request("POST / HTTP/1.1\r\n\r\nabc"))
        #expect(bare.isComplete)
        #expect(bare.content == Data("abc".utf8))
        // A header without a body has none.
        let empty = try #require(request("POST / HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(empty.isComplete)
        #expect(empty.content == nil)
        // -intValue: leading digits, and a negative length is never reached.
        let trailing = try #require(request("POST / HTTP/1.1\r\nContent-Length: 3xyz\r\n\r\nabcd"))
        #expect(trailing.isComplete)
        #expect(trailing.content == Data("abc".utf8))
        let negative = try #require(request("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\nabcd"))
        #expect(!negative.isComplete)
        #expect(negative.content == Data("abcd".utf8))
        let zero = try #require(request("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nabcd"))
        #expect(zero.isComplete)
        #expect(zero.content == Data())
    }

    @Test func aRequestLineWithoutVersionIsAnsweredInHTTP11() throws {
        let garbage = try #require(request("garbage\r\n\r\n"))
        #expect(garbage.version == "HTTP/1.1")
    }

    @Test func answersAreSerialized() {
        let document = String(decoding: XMLRPCHTTPResponse.serialized(XMLRPCHTTPResponse.document("<x/>é", version: "HTTP/1.0")), as: UTF8.self)
        #expect(document.hasPrefix("HTTP/1.0 200 OK\r\n"))
        #expect(document.contains("Content-Type: text/xml; charset=utf-8\r\n"))
        #expect(document.contains("Content-Length: 6\r\n"))
        #expect(document.hasSuffix("\r\n\r\n<x/>é"))

        let method = String(decoding: XMLRPCHTTPResponse.serialized(XMLRPCHTTPResponse.methodResponse(Data("ab".utf8), version: "HTTP/1.1")), as: UTF8.self)
        #expect(method.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(!method.contains("Content-Type"))
        #expect(method.hasSuffix("Content-Length: 2\r\n\r\nab"))

        let challenge = String(decoding: XMLRPCHTTPResponse.serialized(
            XMLRPCHTTPResponse.status(401, headers: ["WWW-Authenticate": "Basic realm=\"x\""], version: "HTTP/1.1")), as: UTF8.self)
        #expect(challenge.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        // CFNetwork writes field names in its own case; clients read them in any.
        #expect(challenge.lowercased().contains("www-authenticate: basic realm=\"x\"\r\n"))
        #expect(challenge.hasSuffix("Content-Length: 0\r\n\r\n"))
    }

    @Test func theMethodCallIsRead() throws {
        let document = try XMLDocument(xmlString: "<methodCall><methodName>Echo</methodName><params>"
                                       + "<param><value><struct></struct></value></param><param><value>x</value></param>"
                                       + "</params></methodCall>", options: [])
        let call = try XMLRPCMethodCall.element(in: document)
        #expect(try XMLRPCMethodCall.methodName(of: call) == "Echo")
        let parameters = try XMLRPCMethodCall.parameters(of: call)
        #expect(parameters.count == 2)
        #expect(parameters[1] as? String == "x")
    }

    @Test func anUnreadableCallSaysWhy() throws {
        let none = try XMLDocument(xmlString: "<methodResponse/>", options: [])
        #expect(throws: XMLRPCCodingError(name: "NSGenericException", reason: "request contains 0 method calls")) {
            try XMLRPCMethodCall.element(in: none)
        }
        let unnamed = try XMLDocument(xmlString: "<methodCall><methodName>a</methodName><methodName>b</methodName></methodCall>", options: [])
        #expect(throws: XMLRPCCodingError(name: "NSGenericException", reason: "method call contains 2 method names")) {
            try XMLRPCMethodCall.methodName(of: XMLRPCMethodCall.element(in: unnamed))
        }
        let nilParameter = try XMLDocument(xmlString: "<methodCall><methodName>a</methodName><params>"
                                           + "<param><value><nil/></value></param></params></methodCall>", options: [])
        #expect(throws: XMLRPCCodingError(name: "NSInvalidArgumentException",
                                          reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")) {
            try XMLRPCMethodCall.parameters(of: XMLRPCMethodCall.element(in: nilParameter))
        }
    }

    @Test func onlyAPublishedSelectorIsCalledWithoutTheDelegatesSay() {
        let published = XMLRPCDispatch.selector(forMethodName: "displaystudy", published: "DisplayStudy:error:",
                                                respondsTo: { _ in false })
        #expect(published.selector == "DisplayStudy:error:" && published.isPublished)
        let withError = XMLRPCDispatch.selector(forMethodName: "isEqualTo", published: nil,
                                                respondsTo: { $0 == "isEqualTo:error:" })
        #expect(withError.selector == "isEqualTo:error:" && !withError.isPublished)
        let plain = XMLRPCDispatch.selector(forMethodName: "isEqualTo", published: nil, respondsTo: { _ in false })
        #expect(plain.selector == "isEqualTo:" && !plain.isPublished)
    }

    @Test func theParametersFitTheSelector() {
        #expect(XMLRPCDispatch.acceptedParameterCount(argumentCount: 4, selector: "DisplayStudy:error:") == 1)
        #expect(XMLRPCDispatch.acceptedParameterCount(argumentCount: 3, selector: "isEqualTo:") == 1)
        #expect(XMLRPCDispatch.acceptedParameterCount(argumentCount: 2, selector: "a:error:") == 0)
        #expect(XMLRPCDispatch.parameters(nil).count == 1)
        #expect(XMLRPCDispatch.parameters([]).first is NSDictionary)
        #expect(XMLRPCDispatch.parameters(["a", "b"]).count == 2)
    }
}
