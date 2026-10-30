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
import IsiXHTTPServer

/// A connection of the XML-RPC interface, on its own thread. The SwiftNIO
/// listener (XMLRPCListener.swift) hands it the bytes received and sends what
/// it writes; made without a transport, it runs the calls made in process.
final class XMLRPCInterfaceConnection: N2XMLRPCConnection, XMLRPCServerConnection {
    private let transport: XMLRPCTransport?
    /// Set on the connection thread before the call runs on a thread of its
    /// own, and read there when the call has answered.
    private var discardsResponse = false

    /// Made by the listener for a connection it accepted: the transport
    /// carries the bytes, TLS included, and names the peer.
    init(transport: XMLRPCTransport) {
        self.transport = transport
        super.init()
    }

    /// A connection for a call made in this process.
    override init() {
        transport = nil
        super.init()
    }

    /// The peer's address, which the access rules judge.
    override var address: String? {
        transport?.peerAddress ?? super.address
    }

    // -writeData:
    override func write(_ data: Data) {
        if let transport {
            transport.writeData(data)
        } else {
            super.write(data)
        }
    }

    override func close() {
        super.close()
        transport?.close()
    }

    // "Do not send a response to XML-RPC orders": the caller gets an empty 200
    // as soon as the order is read, and the order runs on a thread of its own,
    // so a RIS that waits for nothing is not held while a study opens.
    override func handleXmlrpcMethodCall(_ args: [Any]) {
        guard UserDefaults.standard.bool(forKey: XMLRPCServerAccess.doNotRespondKey) else {
            super.handleXmlrpcMethodCall(args)
            return
        }
        writeStatus(200, headers: nil, version: (args[1] as? String) ?? XMLRPCHTTPRequest.defaultVersion)
        discardsResponse = true
        Thread.detachNewThreadSelector(#selector(handleXmlrpcMethodCallWithoutResponse(_:)), toTarget: self, with: args)
    }

    @objc(handleXmlrpcMethodCallWithoutResponse:)
    func handleXmlrpcMethodCallWithoutResponse(_ args: NSArray) {
        autoreleasepool {
            super.handleXmlrpcMethodCall(args as! [Any])
        }
    }

    /// The response of an order whose caller was already answered is dropped.
    override func writeResponse(_ response: CFHTTPMessage) {
        if discardsResponse {
            return
        }
        super.writeResponse(response)
    }

    // Runs on the connection thread, with the request headers complete and the
    // body not yet read, so a refused request never reaches the XML parser or a
    // method.
    override func shouldHandleRequest(_ request: CFHTTPMessage, version: String) -> Bool {
        let authorization = CFHTTPMessageCopyHeaderFieldValue(request, "Authorization" as CFString)?.takeRetainedValue() as String?
        let policy = XMLRPCAccessPolicy.policy(from: UserDefaults.standard)
        let peer = (address ?? "(null)") as NSString
        let credentialSent = (authorization as NSString?)?.length ?? 0 > 0

        switch policy.decision(peerAddress: address, authorization: authorization) {
        case .allow:
            RISRequestAlert.noteAccepted(peer: address)
            return true

        case .challenge:
            NSLog("--- XML-RPC request from %@ refused: %@", peer, (credentialSent ? "wrong credential" : "no credential") as NSString)
            RISRequestAlert.noteRefusal(peer: address, reason: credentialSent ? .wrongCredential : .noCredential)
            writeStatus(401, headers: ["WWW-Authenticate": XMLRPCServerAccess.challengeHeaderValue], version: version)
            return false

        case .refuse:
            NSLog("--- XML-RPC request from %@ refused: the interface answers this computer only", peer)
            RISRequestAlert.noteRefusal(peer: address, reason: .loopbackOnly)
            writeStatus(403, headers: nil, version: version)
            return false

        case .refuseOutsideLocalNetwork:
            NSLog("--- XML-RPC request from %@ refused: the interface answers other computers from the local network only", peer)
            RISRequestAlert.noteRefusal(peer: address, reason: .outsideLocalNetwork)
            writeStatus(403, headers: nil, version: version)
            return false

        case .refuseNoPasswordSet:
            NSLog("--- XML-RPC request from %@ refused: other computers have to send a password, and none is set", peer)
            RISRequestAlert.noteRefusal(peer: address, reason: .noPasswordSet)
            writeStatus(403, headers: nil, version: version)
            return false
        }
    }

    /// Lets a plugin answer first: the call is posted as
    /// OsirixXMLRPCMessageNotification, with the parameters, the method name,
    /// the request document and the peer; a plugin that answers sets
    /// `Response` (Cocoa values) or, as older plugins did,
    /// `NSXMLDocumentResponse`, or `Processed`. Otherwise the interface
    /// answers.
    override func methodCall(_ methodName: String?, params: [Any]?, error: NSErrorPointer) -> Any? {
        // A method a plugin of the plugin API registered: its names never
        // shadow the interface's own.
        if let methodName, let outcome = IsiXPluginHost.answerXMLRPC(methodName, parameters: params ?? []) {
            switch outcome {
            case .answer(let value):
                return IsiXXMLRPCCoding.object(of: value)
            case .fault(let reason):
                let fault = XMLRPCRequestContract.fault(forFailedMethodName: methodName, reason: reason)
                error?.pointee = NSError(domain: NSCocoaErrorDomain, code: fault.code, userInfo: [NSLocalizedDescriptionKey: fault.document])
                return nil
            }
        }
        let document = requestDocument ?? (try? XMLDocument(
            xmlString: N2XMLRPC.request(withMethodName: methodName as NSString?, arguments: params) as String, options: []))

        let notificationObject: NSMutableDictionary
        if let first = (params as NSArray?)?.firstObject as? NSDictionary {
            notificationObject = first.mutableCopy() as! NSMutableDictionary
        } else {
            notificationObject = NSMutableDictionary()
        }
        // The entries end at the first that has no value, as the list of
        // +dictionaryWithObjectsAndKeys: ended at its first nil.
        let entries: [(String, Any?)] = [("MethodName", methodName), ("methodName", methodName),
                                         ("NSXMLDocument", document), ("peerAddress", address)]
        for (key, value) in entries {
            guard let value else { break }
            notificationObject.setObject(value, forKey: key as NSString)
        }
        NotificationCenter.default.post(name: .OsirixXMLRPCMessage, object: notificationObject)

        let processed = notificationObject.object(forKey: "Processed")
        if Self.boolValue(processed) || notificationObject.object(forKey: "Response") != nil
            || notificationObject.object(forKey: "NSXMLDocumentResponse") != nil {
            // Most probably a plugin. New plugins answer Cocoa values under
            // Response.
            if let response = notificationObject.object(forKey: "Response") {
                return response
            }
            // Older plugins answered a document under NSXMLDocumentResponse.
            let answered = notificationObject.object(forKey: "NSXMLDocumentResponse") as? XMLNode
            guard let answered else { return N2XMLRPC.parseElement(nil) }
            var value: XMLNode?
            // A document without a value raises, as -objectAtIndex: did, and
            // the caller answers the fault.
            if let raised = HorosObjCException.caught({
                let values = (try? answered.objects(forXQuery: "/methodResponse/params/param/value")) as NSArray?
                value = values?.object(at: 0) as? XMLNode
            }) {
                raised.raise()
            }
            return N2XMLRPC.parseElement(value)
        }

        return super.methodCall(methodName, params: params, error: error)
    }

    /// -boolValue of a number or a string; NO for nil.
    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }
}
