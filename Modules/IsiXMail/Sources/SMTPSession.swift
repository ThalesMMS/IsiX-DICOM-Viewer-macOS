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

import CryptoKit
import Foundation

/// How a session may use TLS. The raw values are those of
/// SMTPClientTLSMode, which the Mail accounts' settings are mapped to.
public enum SMTPTLSMode: Int, Sendable {
    /// Never: a server that waits for a TLS handshake before greeting fails.
    case none = 0
    /// STARTTLS when the server offers it, plain text otherwise; TLS from the
    /// first byte when the server does not greet within a second.
    case ifPossible = 1
    /// As ifPossible, but a server that greets without offering STARTTLS is
    /// an error.
    case required = 2

    /// An unknown value, as the client compared it: any mode but 0 uses TLS,
    /// and only 2 requires it.
    public init(clientValue: Int) {
        self = SMTPTLSMode(rawValue: clientValue) ?? (clientValue == 0 ? .none : .ifPossible)
    }
}

/// A header field the caller adds to a message.
public enum SMTPHeaderField: Equatable, Sendable {
    case field(name: String, value: String)
    /// A key that is not a string: the session fails when it writes the
    /// headers, with the message Objective-C gave for -lowercaseString.
    case invalidName(className: String)
}

/// One message to send: who sends it to whom, and what.
public struct SMTPMessage: Equatable, Sendable {
    public var sender: SMTPAddress
    public var recipients: [SMTPAddress]
    public var subject: String?
    /// HTML, sent base64-encoded as text/html in UTF-8.
    public var body: String?
    public var headers: [SMTPHeaderField]

    public init(sender: SMTPAddress, recipients: [SMTPAddress], subject: String?, body: String?, headers: [SMTPHeaderField] = []) {
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.headers = headers
    }

    /// The fields the client writes itself, which a caller's header cannot replace.
    static let reservedHeaders: Set<String> = ["from", "to", "subject", "mime-version", "content-type", "content-transfer-encoding"]

    /// The lines of the DATA section, up to the "." that ends it.
    func dataLines() throws(SMTPError) -> [String] {
        var lines: [String] = []
        if let name = sender.name {
            lines.append("From: =?UTF-8?B?\(base64(name))?= <\(sender.email)>")
        } else {
            lines.append("From: \(sender.email)")
        }
        let to = recipients.map { recipient in
            recipient.name.map { "=?UTF-8?B?\(base64($0))?= <\(recipient.email)>" } ?? recipient.email
        }
        lines.append("To: " + to.joined(separator: ", "))
        lines.append("Subject: =?UTF-8?B?\(subject.map(base64) ?? "(null)")?=")
        lines.append("Mime-Version: 1.0")
        lines.append("Content-Type: text/html; charset=\"UTF-8\"")
        lines.append("Content-Transfer-Encoding: base64")
        for header in headers {
            switch header {
            case let .field(name, value):
                if !SMTPMessage.reservedHeaders.contains(name.lowercased()) {
                    lines.append("\(name): \(value)")
                }
            case let .invalidName(className):
                throw .unrecognizedSelector(receiverClass: className, selector: "lowercaseString")
            }
        }
        lines.append("")
        // No body sent no line at all, not even an empty one.
        if let body {
            lines.append(contentsOf: base64Lines(body))
        }
        lines.append(".")
        return lines
    }
}

/// Base64 of a string's UTF-8, on one line: an encoded word of a header, or an
/// AUTH argument.
func base64(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
}

/// Base64 of a body's UTF-8 in lines of at most 76 characters, as RFC 2045
/// writes it. A body on one line passed the 998 characters RFC 5322 allows a
/// line once it was longer than about 740 bytes, and some servers refuse or cut
/// such a line. An empty body is one empty line.
func base64Lines(_ string: String) -> [String] {
    Data(string.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        .components(separatedBy: "\r\n")
}

/// The SMTP conversation of one connection, without the connection: it reads
/// the server's reply lines and answers with what to send, when to start TLS
/// and when to close. The connection, over Network.framework, is the app's.
public struct SMTPSession: Sendable {
    /// Where the conversation is. The raw values appear in the
    /// "Don't know how to act with status" message.
    public enum Status: Int, Sendable {
        case initial = 0
        case helo = 1
        case ehlo = 2
        case startTLS = 3
        case auth = 4
        case mail = 5
        case rcpt = 6
        case data = 7
        case quit = 8
    }

    enum AuthMechanism: Sendable {
        case plain, login, cramMD5
    }

    public enum Action: Equatable, Sendable {
        /// A command line, without its CRLF.
        case send(String)
        /// Start TLS on the connection now; what follows goes over TLS.
        case startTLS
        /// The server offers no STARTTLS and TLS is only wanted if possible:
        /// the rest goes on in plain text.
        case continueWithoutTLS
        /// The conversation is over: close the connection.
        case close
    }

    public struct Credentials: Equatable, Sendable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public let tlsMode: SMTPTLSMode
    public let credentials: Credentials?
    /// The name this machine gives in HELO and EHLO.
    public let hostname: String
    public let message: SMTPMessage

    public private(set) var status = Status.initial
    private var mechanism: AuthMechanism?
    /// The mechanisms the server's EHLO listed on its AUTH line.
    public private(set) var authMechanisms: [String]?
    public private(set) var canStartTLS = false
    public private(set) var isTLS = false
    /// The server accepted the message.
    public private(set) var succeeded = false
    private var pendingRecipients = 0

    public init(tlsMode: SMTPTLSMode, credentials: Credentials?, hostname: String, message: SMTPMessage) {
        self.tlsMode = tlsMode
        self.credentials = credentials
        self.hostname = hostname
        self.message = message
    }

    private mutating func moveTo(_ status: Status) {
        self.status = status
        mechanism = nil
    }

    /// The server has said nothing for a second since the connection opened:
    /// it waits for a TLS handshake (as on port 465), which is started if
    /// TLS is allowed.
    public mutating func serverStayedSilent() throws(SMTPError) -> [Action] {
        guard tlsMode != .none else { throw .stalledWithoutTLS }
        isTLS = true
        return [.startTLS]
    }

    /// What to do on a line the server sent.
    public mutating func receive(_ line: String?) throws(SMTPError) -> [Action] {
        let reply = try SMTPReplyLine.parse(line)
        return try handle(reply)
    }

    private mutating func ehlo() -> [Action] {
        moveTo(.ehlo)
        return [.send("EHLO " + hostname)]
    }

    private mutating func mail() -> [Action] {
        moveTo(.mail)
        return [.send("MAIL FROM: <\(message.sender.email)>")]
    }

    private mutating func authenticate() throws(SMTPError) -> [Action] {
        guard let credentials else { return mail() }
        let modes = authMechanisms ?? []
        moveTo(.auth)
        if modes.contains("CRAM-MD5") {
            mechanism = .cramMD5
            return [.send("AUTH CRAM-MD5")]
        } else if modes.contains("PLAIN") {
            mechanism = .plain
            let username = credentials.username
            return [.send("AUTH PLAIN " + base64("\(username)\0\(username)\0\(credentials.password)"))]
        } else if modes.contains("LOGIN") {
            mechanism = .login
            return [.send("AUTH LOGIN")]
        }
        throw .noSupportedAuthentication
    }

    private mutating func handle(_ reply: SMTPReplyLine) throws(SMTPError) -> [Action] {
        let code = reply.code
        if code >= 500 {
            throw .serverError(code: code, message: reply.text)
        }

        switch (status, code) {
        case (.initial, 220):
            if (!isTLS && tlsMode != .none) || credentials != nil {
                return ehlo()
            }
            moveTo(.helo)
            return [.send("HELO " + hostname)]

        case (.helo, 250), (.ehlo, 250):
            if status == .ehlo, let text = reply.text {
                let name: Substring
                let value: Substring?
                if let space = text.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    name = text[..<space]
                    value = text[text.index(after: space)...]
                } else {
                    name = Substring(text)
                    value = nil
                }
                if name == "AUTH" {
                    authMechanisms = value.map { String($0).components(separatedBy: .whitespaces) }
                }
                if name == "STARTTLS" {
                    canStartTLS = true
                }
            }
            // The last EHLO line can name a capability too: read every line
            // before acting.
            if reply.continues {
                return []
            }
            if !isTLS && tlsMode != .none {
                if canStartTLS {
                    moveTo(.startTLS)
                    return [.send("STARTTLS")]
                }
                if tlsMode == .required {
                    throw .startTLSUnsupported
                }
                return [.continueWithoutTLS] + (try authenticate())
            }
            return try authenticate()

        case (.startTLS, 220):
            isTLS = true
            return [.startTLS] + ehlo()

        case (.auth, 235) where mechanism != nil:
            return mail()

        case (.auth, 334) where mechanism == .login:
            switch SMTPSession.decodedChallenge(reply.text) {
            case "Username:":
                return [.send(base64(credentials?.username ?? ""))]
            case "Password:":
                return [.send(base64(credentials?.password ?? ""))]
            default:
                // Any other challenge went on to the message, as the C switch
                // fell through to 235.
                return mail()
            }

        case (.auth, 334) where mechanism == .cramMD5:
            let challenge = SMTPSession.decodedChallenge(reply.text)
            let username = credentials?.username ?? ""
            let digest = SMTPSession.cramMD5(challenge: challenge, secret: credentials?.password ?? "")
            return [.send(base64("\(username) \(digest)"))]

        case (.mail, 250):
            var actions: [Action] = []
            for recipient in message.recipients {
                var address = recipient.email
                if address.rangeOfCharacter(from: CharacterSet(charactersIn: "<>")) == nil {
                    address = "<\(address)>"
                }
                actions.append(.send("RCPT TO: " + address))
                pendingRecipients += 1
            }
            moveTo(.rcpt)
            return actions

        case (.rcpt, 250):
            pendingRecipients -= 1
            if pendingRecipients == 0 {
                moveTo(.data)
                return [.send("DATA")]
            }
            return []

        case (.data, 354):
            return try message.dataLines().map { .send($0) }

        case (.data, 250):
            succeeded = true
            moveTo(.quit)
            return [.send("QUIT")]

        case (.quit, 221):
            return [.close]

        default:
            throw .unexpectedReply(status: status, code: code)
        }
    }

    /// The text of a base64 challenge; empty when it is not base64.
    static func decodedChallenge(_ text: String?) -> String {
        guard let text, let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The CRAM-MD5 answer to a challenge: HMAC-MD5 keyed by the password, in
    /// the lower-case hexadecimal of RFC 2195, which a strict server compares
    /// as a string. MD5 is what the mechanism requires on the wire.
    static func cramMD5(challenge: String, secret: String) -> String {
        let code = HMAC<Insecure.MD5>.authenticationCode(for: Data(challenge.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
