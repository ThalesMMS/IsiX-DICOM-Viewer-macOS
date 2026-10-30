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

import AppKit
import IsiXHTTPServer

/// XML-RPC for RIS integration: the methods a RIS, a script, a horos:// link
/// or AppleScript calls by name.
///
/// The interface owns the listener and answers its connections; each
/// connection runs on a thread of its own (XMLRPCInterfaceConnection.swift).
/// The methods, by responsibility:
/// - opening studies and series: XMLRPCInterface+Display.swift, and showing
///   them on the main thread: XMLRPCInterface+Opening.swift;
/// - retrieving from a node or a URL: XMLRPCInterface+Retrieve.swift;
/// - the browser and the viewers: XMLRPCInterface+Windows.swift.
/// The table of published names and the encoding of the answers are
/// `XMLRPCMethodTable` and `XMLRPCMethodResult` (IsiXHTTPServer); how a
/// request's parameters are read is `RISRequestRules` (IsiXDICOMNetwork).
///
/// The methods are called on the connection threads, or on the main thread by
/// AppleScript, and are nonisolated: what has to happen on the main thread is
/// sent there, as it always was.
@objc(XMLRPCInterface)
public final class XMLRPCInterface: NSObject, N2XMLRPCConnectionDelegate {
    private var listener: XMLRPCListener?
    private let https: Bool

    public override init() {
        let defaults = UserDefaults.standard
        let port = defaults.integer(forKey: "httpXMLRPCServerPort")

        // This interface publishes KillOsiriX, Retrieve, DownloadURL and
        // dbwindowfind, and dbwindowfind returns the database: patient names
        // and identifiers included. Horos answered every peer and asked for no
        // credential, so a preference turned on for a local script published
        // all of that to the network. Calls made on this computer are still
        // answered as Horos answers them, including those a RIS sends to the
        // machine's own network address, so the socket listens on every
        // interface and each request is judged by its peer address, against
        // the settings of the Listener pane as they are when it arrives.
        https = defaults.bool(forKey: XMLRPCServerAccess.httpsKey)
        super.init()

        // HTTPS presents the web portal's identity, made the first time either
        // needs it: one self-signed certificate for the two servers of this Mac.
        if https && !XMLRPCListener.httpsIdentityAvailable() {
            // The interface stays, without a listener, rather than serving
            // plain HTTP.
            NSLog("--- XML-RPC interface not activated on port %d: HTTPS is on and no certificate could be read or created in the keychain", Int32(truncatingIfNeeded: port))
            return
        }

        // Each connection runs on a thread of its own and answers through
        // this interface. The listener does not retain the interface, which
        // owns it.
        listener = XMLRPCListener(port: port, https: https) { [weak self] transport in
            guard let self else { return nil }
            let connection = XMLRPCInterfaceConnection(transport: transport)
            connection.dontSpecifyStringType = true
            connection.delegate = self
            return connection
        }

        if listener != nil {
            let policy = XMLRPCAccessPolicy.policy(from: defaults)
            let scopes = ["this Mac only", "this Mac and the local network", "this Mac and any address"]
            NSLog("--- XML-RPC interface activated on port: %d (%@), answering %@%@%@", Int32(truncatingIfNeeded: port),
                  (https ? "HTTPS" : "HTTP") as NSString,
                  scopes[policy.scope.rawValue] as NSString,
                  (policy.scope == .thisMac ? "" : (policy.requirePassword ? ", with a password" : ", WITHOUT a password")) as NSString,
                  (policy.allowedAddresses.isEmpty ? "" : ", and the listed addresses without one") as NSString)
        } else {
            AppController.shared()?.reportListenBindFailure(forService: "XML-RPC", port: port,
                                                            errnoCode: XMLRPCListener.lastBindErrno())
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        listener?.stop()
    }

    // MARK: N2XMLRPCConnectionDelegate

    /// The selector of a published method. Names are matched without regard to
    /// case, as the first interface matched them; one that is not published is
    /// not dispatched.
    @objc(selectorStringForXMLRPCRequestMethodName:)
    public func selectorString(forXMLRPCRequestMethodName name: String) -> String? {
        XMLRPCMethodTable.selector(forMethodName: name)
    }

    // MARK: Utilities of the methods

    /// The database the browser shows.
    var database: DicomDatabase? {
        BrowserController.currentBrowser()?.database
    }

    /// What a method answers about a study, series or image: its attributes
    /// that are strings, numbers and dates.
    @objc(dictionaryForObject:)
    public class func dictionaryForObject(_ object: NSManagedObject) -> NSDictionary {
        XMLRPCOwnedThreadRead.dictionary(for: object) as NSDictionary
    }

    /// The study of a study, series or image.
    func study(for object: NSManagedObject?) -> DicomStudy? {
        if let study = object as? DicomStudy { return study }
        if object is DicomSeries { return object?.value(forKey: "study") as? DicomStudy }
        if object is DicomImage { return object?.value(forKeyPath: "series.study") as? DicomStudy }
        return nil
    }

    /// The failure of a request the method cannot read, with its response
    /// document as the description.
    @objc(errorWithCode:)
    public class func error(withCode code: Int) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: XMLRPCMethodResult.errorDocument(code: code)])
    }

    /// Fails the call with `code` (400: the request cannot be read).
    static func fail(_ code: Int, _ error: NSErrorPointer) -> NSDictionary? {
        error?.pointee = Self.error(withCode: code)
        return nil
    }

    /// The answer `{error: code}`.
    static func answer(_ code: Int) -> NSDictionary {
        NSDictionary(object: XMLRPCMethodResult.errorMember(code), forKey: "error" as NSString)
    }

    /// The answer `{error: code, key: object}`.
    static func answer(_ code: Int, _ object: Any, forKey key: String) -> NSDictionary {
        NSDictionary(objects: [XMLRPCMethodResult.errorMember(code), object], forKeys: ["error" as NSString, key as NSString])
    }

    /// `[NSDictionary dictionaryWithObjectsAndKeys: …, nil]`: the list ends at
    /// its first nil object.
    static func objectsAndKeys(_ pairs: [(Any?, String)]) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        for (object, key) in pairs {
            guard let object else { break }
            dictionary.setObject(object, forKey: key as NSString)
        }
        return dictionary.copy() as! NSDictionary
    }

    /// -boolValue of a number or a string; NO for nil.
    static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }

    /// -integerValue of a number or a string; 0 for nil.
    static func integerValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? NSString { return string.integerValue }
        return 0
    }

    /// -intValue of a number or a string; 0 for nil.
    static func intValue(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    /// N2LogException(e) (`stack` false) or N2LogExceptionWithStackTrace(e) in
    /// the method `function`.
    static func log(_ exception: NSException, stack: Bool, _ function: String) {
        _N2LogExceptionImpl(exception, stack, function)
    }

    // MARK: Called in process

    /// The deprecated entry point of plugins that answered the former web
    /// server's XML-RPC requests themselves: the answer goes into
    /// `httpServerMessage` under `ASResponse` and `NSXMLDocumentResponse`.
    @available(*, deprecated)
    @objc(processXMLRPCMessage:httpServerMessage:HTTPServerRequest:version:paramDict:encoding:)
    public func processXMLRPCMessage(_ selName: String?, httpServerMessage: NSMutableDictionary?, httpServerRequest mess: AnyObject?,
                                     version vers: String?, paramDict: NSDictionary?, encoding: String?) {
        let connection = XMLRPCInterfaceConnection()
        connection.delegate = self

        var error: NSError?
        var response: Any?
        // An exception in the method, or a call without parameters (which
        // raised when the parameters were put in an array), is answered with
        // the error -1.
        var raised = true
        if let paramDict {
            raised = HorosObjCException.caught {
                response = connection.methodCall(selName, params: [paramDict], error: &error)
            } != nil
        }
        if raised && error == nil {
            error = NSError(domain: NSCocoaErrorDomain, code: -1, userInfo: nil)
        }
        if let error {
            response = NSDictionary(object: String(error.code), forKey: "error" as NSString)
        }

        if let response, let httpServerMessage {
            httpServerMessage.setValue(response, forKey: "ASResponse")
            httpServerMessage.setValue(try? XMLDocument(xmlString: N2XMLRPC.response(withValue: response) as String, options: []),
                                       forKey: "NSXMLDocumentResponse")
        }
    }

    /// A call made in this process: by AppleScript and by horos:// links.
    @objc(methodCall:parameters:error:)
    public func methodCall(_ methodName: String?, parameters: [AnyHashable: Any]?) throws -> Any {
        let connection = XMLRPCInterfaceConnection()
        connection.delegate = self
        // The AppleScript bridge passes no parameters when the script supplies
        // none.
        let parameters = parameters ?? [:]
        var error: NSError?
        let result = connection.methodCall(methodName, params: [parameters], error: &error)
        if let error { throw error }
        // A method that answers nothing (KillOsiriX) fails the call with the
        // error Swift made of the Objective-C method's nil answer for these
        // Swift callers.
        guard let result else { throw NSError(domain: "Foundation._GenericObjCError", code: 0) }
        return result
    }
}
