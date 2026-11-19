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

/// The SMTP server the web portal sends its emails through, as the Web Server
/// pane stores it. The password is not part of it: it is kept in the Keychain,
/// under `passwordAccount`.
public struct PortalMailServer: Equatable, Sendable {
    /// The ports tried in turn when none is set, as the client always tried them.
    public static let defaultPorts = [25, 465, 587]

    /// Empty when no server is set.
    public var host: String
    /// 0 when none is set: `defaultPorts` are then tried in turn.
    public var port: Int
    public var tlsMode: SMTPTLSMode
    /// Empty for a server that takes messages without authentication.
    public var username: String

    /// The host and the user name without the blanks around them; a port
    /// outside 1...65535 is no port.
    public init(host: String, port: Int = 0, tlsMode: SMTPTLSMode = .required, username: String = "") {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = (1...65535).contains(port) ? port : 0
        self.tlsMode = tlsMode
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A server is set when it has a host.
    public var isSet: Bool { !host.isEmpty }

    /// The server asks for a user name and a password.
    public var authenticates: Bool { !username.isEmpty }

    /// The ports a delivery tries, in order.
    public var ports: [Int] { port == 0 ? PortalMailServer.defaultPorts : [port] }

    /// The account of the Keychain item that holds the password: the user at
    /// this server, so that a password kept for one server is never offered
    /// to another, nor as another user.
    public var passwordAccount: String { "\(username)@\(host.lowercased())" }

    /// The server as one text, for the pane and the log: the host, and the
    /// port when one is set.
    public var address: String { port == 0 ? host : "\(host):\(port)" }
}

/// How an email of the portal leaves this computer.
public enum PortalMailRoute: Equatable, Sendable {
    /// Through the SMTP server set for the portal.
    case server(PortalMailServer)
    /// Through the Mail application, which sends it from one of its accounts.
    case mailApplication
    /// No way: no server is set and the Mail application is not a route.
    case none

    /// A server that is set is always the route. Without one, the Mail
    /// application is, where the build may tell it to send.
    public static func choose(server: PortalMailServer, mailApplicationAvailable: Bool) -> PortalMailRoute {
        if server.isSet { return .server(server) }
        return mailApplicationAvailable ? .mailApplication : .none
    }
}

/// One email of the portal: who sends it to whom, and what. The addresses are
/// as the portal's headers carry them, "Name <address>" or a bare address, the
/// recipients separated by commas.
public struct PortalMail: Equatable, Sendable {
    /// HTML.
    public var body: String
    public var subject: String
    public var sender: String
    public var recipients: String

    public init(body: String, subject: String, sender: String, recipients: String) {
        self.body = body
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
    }

    /// The email of the portal's own message: its template, already filled,
    /// and its headers (To, Sender, Subject). A header that is absent, or is
    /// not text, is empty.
    public init(body: String?, headers: [String: Any]?) {
        self.init(body: body ?? "", subject: headers?["Subject"] as? String ?? "",
                  sender: headers?["Sender"] as? String ?? "", recipients: headers?["To"] as? String ?? "")
    }
}

/// Why an email of the portal was not sent.
public enum PortalMailFailure: Error, Equatable, Sendable {
    /// No server is set, and this build has no other route.
    case noServer
    /// The server asks for a password and the Keychain has none for it.
    case noPassword
    /// The addresses were refused before anything was sent, or the server
    /// refused the conversation.
    case smtp(SMTPError)
    /// No port of the server took the connection, or it closed before the
    /// message was accepted; with the text of the connection's error when
    /// there was one.
    case connection(String?)
    /// The Mail application did not take the message.
    case mailApplication

    /// The failure in the words of the log, which is not translated.
    public var logText: String {
        switch self {
        case .noServer: return "no mail server is set"
        case .noPassword: return "the password of the mail server is not in the Keychain"
        case let .smtp(error): return error.reason
        case let .connection(text): return text ?? "the connection to the mail server could not be opened"
        case .mailApplication: return "the Mail application did not take the message"
        }
    }
}

/// How one email of the portal ended.
public struct PortalMailReport: Equatable, Sendable {
    public var date: Date
    public var recipients: String
    /// The route it took, or would have taken.
    public var route: PortalMailRoute
    /// Nil when the message was accepted: by the server, or by the Mail
    /// application, which sends it later on its own.
    public var failure: PortalMailFailure?

    public init(date: Date, recipients: String, route: PortalMailRoute, failure: PortalMailFailure?) {
        self.date = date
        self.recipients = recipients
        self.route = route
        self.failure = failure
    }

    /// The line of the portal's log.
    public var logMessage: String {
        if let failure {
            return "email to \(recipients) not sent: \(failure.logText)"
        }
        switch route {
        case let .server(server): return "email to \(recipients) sent through \(server.address)"
        case .mailApplication, .none: return "email to \(recipients) handed to the Mail application"
        }
    }
}

extension PortalMailServer {
    /// The SMTP conversation that sends `mail` through this server, or why it
    /// cannot be started: an address the client refuses, or a server that
    /// authenticates without a password to give it. `hostname` is the name
    /// this computer gives in HELO and EHLO.
    public func session(sending mail: PortalMail, password: String?, hostname: String) -> Result<SMTPSession, PortalMailFailure> {
        let message: SMTPMessage
        do throws(SMTPError) {
            guard !mail.sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptySender }
            guard !mail.recipients.isEmpty else { throw .emptyDestination }
            message = SMTPMessage(sender: try SMTPAddress.split(mail.sender), recipients: try SMTPAddress.recipients(mail.recipients),
                                  subject: mail.subject, body: mail.body)
        } catch {
            return .failure(.smtp(error))
        }
        var credentials: SMTPSession.Credentials?
        if authenticates {
            guard let password, !password.isEmpty else { return .failure(.noPassword) }
            credentials = SMTPSession.Credentials(username: username, password: password)
        }
        return .success(SMTPSession(tlsMode: tlsMode, credentials: credentials, hostname: hostname, message: message))
    }
}
