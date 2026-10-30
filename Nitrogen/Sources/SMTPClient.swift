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
import IsiXMail

// SMTPClient keeps the Objective-C name, selectors and <Horos/SMTPClient.h> of
// the former class. The conversation (commands, replies, errors) is
// IsiXMail's SMTPSession; the connection, over Network.framework, is
// SMTPConnection.

/// The keys of +send:'s dictionary.
let SMTPServerAddressKey = "SMTPServerAddress"
let SMTPServerPortsKey = "SMTPServerPorts"
let SMTPServerTLSModeKey = "SMTPServerTLSMode"
let SMTPFromKey = "SMTPFrom"
let SMTPServerAuthFlagKey = "SMTPServerAuthFlag"
let SMTPServerAuthUsernameKey = "SMTPServerAuthUsername"
let SMTPServerAuthPasswordKey = "SMTPServerAuthPassword"
let SMTPToKey = "SMTPTo"
let SMTPHeadersKey = "SMTPHeaders"
let SMTPSubjectKey = "SMTPSubject"
let SMTPMessageKey = "SMTPMessage"

extension SMTPError {
    /// Raises the NSException the former class raised for it, to the caller
    /// of the method that checked the arguments.
    func raise() -> Never {
        NSException(name: isInvalidArgument ? .invalidArgumentException : .genericException, reason: reason, userInfo: nil).raise()
        fatalError(reason)
    }
}

/// The object, if it is of the class.
private func smtpObject(_ params: NSDictionary?, _ key: String, _ cls: AnyClass) -> Any? {
    guard let obj = params?.object(forKey: key) else { return nil }
    return (obj as AnyObject).isKind(of: cls) ? obj : nil
}

@objc(SMTPClient)
public final class SMTPClient: NSObject {
    @objc public private(set) var address: String
    @objc public private(set) var ports: [Any]
    @objc public private(set) var tlsMode: Int
    @objc public private(set) var username: String?
    @objc public private(set) var password: String?

    @objc(send:)
    public static func send(_ params: NSDictionary?) {
        let auth = (smtpObject(params, SMTPServerAuthFlagKey, NSNumber.self) as? NSNumber)?.boolValue ?? false
        SMTPClient(serverAddress: smtpObject(params, SMTPServerAddressKey, NSString.self) as? String,
                   ports: smtpObject(params, SMTPServerPortsKey, NSArray.self) as? [Any],
                   tlsMode: (smtpObject(params, SMTPServerTLSModeKey, NSNumber.self) as? NSNumber)?.intValue ?? 0,
                   username: auth ? smtpObject(params, SMTPServerAuthUsernameKey, NSString.self) as? String : nil,
                   password: auth ? smtpObject(params, SMTPServerAuthPasswordKey, NSString.self) as? String : nil)
            .sendMessage(smtpObject(params, SMTPMessageKey, NSString.self) as? String,
                         withSubject: smtpObject(params, SMTPSubjectKey, NSString.self) as? String,
                         from: smtpObject(params, SMTPFromKey, NSString.self) as? String,
                         to: smtpObject(params, SMTPToKey, NSString.self) as? String,
                         headers: smtpObject(params, SMTPHeadersKey, NSDictionary.self) as? NSDictionary)
    }

    @objc(clientWithServerAddress:ports:tlsMode:username:password:)
    public static func client(withServerAddress address: String?, ports: [Any]?, tlsMode: Int, username authUsername: String?, password authPassword: String?) -> SMTPClient {
        SMTPClient(serverAddress: address, ports: ports, tlsMode: tlsMode, username: authUsername, password: authPassword)
    }

    @objc(initWithServerAddress:ports:tlsMode:username:password:)
    public init(serverAddress address: String?, ports: [Any]?, tlsMode: Int, username authUsername: String?, password authPassword: String?) {
        guard let address, !address.isEmpty else { SMTPError.invalidServerAddress.raise() }
        self.address = address
        if let ports, !ports.isEmpty {
            self.ports = ports
        } else {
            self.ports = [NSNumber(value: 25), NSNumber(value: 465), NSNumber(value: 587)]
        }
        self.tlsMode = tlsMode
        self.username = authUsername
        self.password = authPassword
        super.init()
    }

    @objc(splitAddress:intoEmail:description:)
    public static func splitAddress(_ address: String?, intoEmail email: AutoreleasingUnsafeMutablePointer<NSString?>?, description desc: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        do {
            let split = try SMTPAddress.split(address ?? "")
            email?.pointee = split.email as NSString
            desc?.pointee = split.name as NSString?
        } catch {
            error.raise()
        }
    }

    @objc(sendMessage:withSubject:from:to:)
    public func sendMessage(_ message: String?, withSubject subject: String?, from: String?, to toAddresses: String?) {
        sendMessage(message, withSubject: subject, from: from, to: toAddresses, headers: nil)
    }

    /// Checks the addresses here, raising as the former class did, and sends
    /// in the background: each port in turn until one takes the message.
    @objc(sendMessage:withSubject:from:to:headers:)
    public func sendMessage(_ message: String?, withSubject subject: String?, from: String?, to toAddresses: String?, headers: NSDictionary?) {
        do throws(SMTPError) {
            guard let from, !from.isEmpty else { throw .emptySender }
            guard let toAddresses, !toAddresses.isEmpty else { throw .emptyDestination }
            let mail = SMTPMessage(sender: try SMTPAddress.split(from), recipients: try SMTPAddress.recipients(toAddresses),
                                   subject: subject, body: message, headers: SMTPClient.headerFields(headers))
            var credentials: SMTPSession.Credentials?
            if let username, let password {
                credentials = SMTPSession.Credentials(username: username, password: password)
            }
            let session = SMTPSession(tlsMode: SMTPTLSMode(clientValue: tlsMode), credentials: credentials,
                                      hostname: SMTPClient.hostname(), message: mail)
            SMTPDelivery(host: address, ports: ports.map(SMTPClient.portNumber), session: session).start()
        } catch {
            error.raise()
        }
    }

    /// The caller's headers, in the dictionary's own order, their values as
    /// %@ printed them.
    private static func headerFields(_ headers: NSDictionary?) -> [SMTPHeaderField] {
        guard let headers else { return [] }
        return headers.map { key, value in
            guard let name = key as? String else { return .invalidName(className: NSStringFromClass(type(of: key as AnyObject))) }
            return .field(name: name, value: String(describing: value as AnyObject))
        }
    }

    /// -integerValue of a port, which NSNumber and NSString answer, or the
    /// message Objective-C gave any other object.
    private static func portNumber(_ port: Any) -> Result<Int, SMTPError> {
        if let number = port as? NSNumber { return .success(number.intValue) }
        if let string = port as? NSString { return .success(string.integerValue) }
        return .failure(.unrecognizedSelector(receiverClass: NSStringFromClass(type(of: port as AnyObject)), selector: "integerValue"))
    }

    /// The name of this machine, with ".local" when it has no domain.
    static func hostname() -> String {
        var hostname = [CChar](repeating: 0, count: 128)
        gethostname(&hostname, 127)
        hostname[127] = 0
        var string = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if !string.contains(".") { string += ".local" }
        return string
    }
}

/// One message on its way: the ports are tried in order, each on a
/// connection of its own, until one takes it. A failed conversation is logged
/// and the next port tried; the last failure is logged again at the end when
/// no port took the message.
final class SMTPDelivery: Sendable {
    private let host: String
    private let ports: [Result<Int, SMTPError>]
    private let session: SMTPSession

    init(host: String, ports: [Result<Int, SMTPError>], session: SMTPSession) {
        self.host = host
        self.ports = ports
        self.session = session
    }

    func start() {
        attempt(0, lastFailure: nil)
    }

    private func attempt(_ index: Int, lastFailure: SMTPError?) {
        guard index < ports.count else {
            if let lastFailure {
                NSLog("******* SMTPClient exception: %@", lastFailure.reason)
            }
            return
        }
        switch ports[index] {
        case let .failure(error):
            NSLog("SMTP Exception: %@", error.reason)
            attempt(index + 1, lastFailure: error)
        case let .success(port):
            SMTPConnection(host: host, port: port, session: session).start { outcome in
                switch outcome {
                case .delivered:
                    break
                case let .failed(error):
                    NSLog("SMTP Exception: %@", error.reason)
                    self.attempt(index + 1, lastFailure: error)
                case .closed:
                    self.attempt(index + 1, lastFailure: lastFailure)
                }
            }
        }
    }
}
