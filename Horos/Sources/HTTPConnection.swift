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
import IsiXHTTPServer

/// The implementation of HTTPConnection, declared in HTTPConnection.h: a
/// connection of the Horos and OsiriX SDK's HTTP server. The class is
/// Objective-C for the runtime, so that a plugin built for either SDK finds it
/// by name and its Objective-C subclass keeps every method and its own
/// overrides; the web portal's connection (WebPortalConnection) is a subclass.
///
/// The HTTP exchange of the connection is the HTTPConnectionEngine its server
/// gives it, over SwiftNIO. The engine asks the connection what the SDK's
/// connection asked itself, by the same selectors and on the connection's own
/// thread (the conformance below), and the methods here that answer a request
/// do it through the engine. By itself the class serves GET and HEAD of the
/// regular files under its server's document root, without a password.
@objc @implementation extension HTTPConnection {
    // The instance variables of the SDK, with its types: a plugin built for
    // it binds each name when it loads, and its subclass reads and writes
    // them directly, with no message. Those whose name here is not the SDK's
    // have it because the web portal's connection answers a message of that
    // name.

    /// The socket the server made for the connection, which wraps its channel.
    final var asyncSocket: AsyncSocket?
    /// The server as the SDK kept it, not retained: a copy of owningServer,
    /// written with it. Nothing here reads it.
    unowned(unsafe) final var horos_server: HTTPServer?
    /// What the SDK's connection kept of the request it was reading and of
    /// the answer it was sending. The exchange is the engine's: nil and 0.
    final var horos_request: CFHTTPMessage?
    final var numHeaderLines: Int32 = 0
    final var nonce: NSString?
    final var lastNC: Int = 0
    final var httpResponse: NSObject?
    final var ranges: NSMutableArray?, ranges_headers: NSMutableArray?
    final var ranges_boundry: NSString?
    final var rangeIndex: Int32 = 0
    final var requestContentLength: UInt64 = 0, requestContentLengthReceived: UInt64 = 0
    final var responseDataSizes: NSMutableArray?

    /// The socket, under the name the web portal reads it by.
    final var socket: AsyncSocket? { asyncSocket }
    /// Unretained in the SDK; weak here, so that it never dangles.
    final weak var owningServer: HTTPServer?
    /// The exchange this connection answers; set by the server.
    final weak var engine: HTTPConnectionEngine?

    public override init() {
        super.init()
    }

    @objc(initWithAsyncSocket:forServer:)
    public init!(asyncSocket newSocket: AsyncSocket!, for myServer: HTTPServer!) {
        asyncSocket = newSocket
        owningServer = myServer
        horos_server = myServer
        super.init()
        newSocket?.setDelegate(self)
    }

    // MARK: What is served

    func supportsMethod(_ method: String!, atPath path: String!) -> Bool {
        method == "GET" || method == "HEAD"
    }

    /// The rule the request reader follows. It decides before the connection's
    /// thread is asked, so an override changes nothing.
    func expectsRequestBody(fromMethod method: String!, atPath relativePath: String!) -> Bool {
        method.map { HTTPRequestRules.expectsBody(method: $0) } ?? false
    }

    /// TLS belongs to the listener; the connection is not asked.
    func isSecureServer() -> Bool {
        false
    }

    func sslIdentityAndCertificates() -> [Any]! {
        nil
    }

    func isPasswordProtected(_ path: String!) -> Bool {
        false
    }

    func useDigestAccessAuthentication() -> Bool {
        true
    }

    func realm() -> String! {
        "Enter your username and password."
    }

    func password(forUser username: String!) -> String! {
        nil
    }

    /// The class has no password check of its own: a protected path is not
    /// served unless a subclass says who is authenticated.
    func isAuthenticated() -> Bool {
        FormerSDKFacade.inert("HTTPConnection", "-isAuthenticated",
                              because: "the password check of the former HTTP server is not in the application; a subclass that protects a path overrides this method")
        return false
    }

    /// The regular file inside the server's document root that `path` names,
    /// its links resolved; a path that ends in a slash names its index.html.
    /// Nil without a document root, for a path that leaves the root, and for
    /// anything that is not a regular file.
    func filePath(forURI path: String!) -> String! {
        guard let root = owningServer?.documentRoot(), root.isFileURL,
              let encoded = path?.components(separatedBy: "?").first,
              var requested = HorosWebRequestPath(encoded) else { return nil }
        if requested.hasSuffix("/") {
            requested += "index.html"
        }
        return HorosWebFilePath(root.path, requested)
    }

    @objc(httpResponseForMethod:URI:)
    func httpResponse(forMethod method: String!, uri path: String!) -> (any NSObjectProtocol & HTTPResponse)! {
        guard let filePath = filePath(forURI: path) else { return nil }
        return HTTPFileResponse(filePath: filePath)
    }

    // MARK: Uploads

    func prepareForBody(withSize contentLength: UInt64) {
    }

    func processDataChunk(_ postDataChunk: Data!) {
    }

    // MARK: Answers

    /// The request is complete: the usual answer, which asks the methods above.
    func replyToHTTPRequest() {
        engine?.replyWithResponse()
    }

    func handleVersionNotSupported(_ version: String!) {
        engine?.answerVersionNotSupported(version ?? "(null)")
    }

    func handleAuthenticationFailed() {
        engine?.sendErrorResponse(status: 401, headers: [("Content-Length", "0")], body: nil, closeAfter: false)
    }

    func handleResourceNotFound() {
        NSLog("HTTP Server: Error 404 - Not Found")
        engine?.sendErrorResponse(status: 404, headers: [("Content-Length", "0")], body: nil, closeAfter: false)
    }

    func handleInvalidRequest(_ data: Data!) {
        engine?.answerInvalidRequest()
    }

    func handleUnknownMethod(_ method: String!) {
        engine?.answerUnknownMethod(method ?? "(null)")
    }

    /// The bytes of a response's head, with the date, Accept-Ranges and the
    /// fields of the response being sent.
    func preprocessResponse(_ response: CFHTTPMessage!) -> Data! {
        guard let response else { return nil }
        return engine?.serializedHead(of: response) ?? HTTPConnectionEngine.serializedHead(of: response, responseFields: [])
    }

    func preprocessErrorResponse(_ response: CFHTTPMessage!) -> Data! {
        guard let response else { return nil }
        return engine?.serializedHead(of: response) ?? HTTPConnectionEngine.serializedHead(of: response, responseFields: [])
    }

    func responseHasAvailableData() {
        engine?.responseHasAvailableData()
    }

    // MARK: The end

    /// The connection is closed. The servers observe the notification and let
    /// the connection go.
    func die() {
        NotificationCenter.default.post(name: HTTPConnection.didDieNotification, object: self)
    }
}

extension HTTPConnection {
    /// HTTPConnectionDidDieNotification, which the header defines as a literal.
    static let didDieNotification = Notification.Name("HTTPConnectionDidDie")
}

// What the engine asks of a connection. The methods the header declares
// answer it by their selectors, so that a subclass's override, a plugin's
// Objective-C one included, is the one that answers.
extension HTTPConnection: HTTPConnectionEngineDelegate {
    /// The response of -httpResponseForMethod:URI:, as the engine reads one.
    func httpServerResponse(forMethod method: String, uri path: String) -> HTTPServerResponse? {
        guard let response = httpResponse(forMethod: method, uri: path) else { return nil }
        return (response as? HTTPServerResponse) ?? FormerHTTPResponseAdapter(response)
    }

    func connectionDidDie() {
        die()
    }
}
