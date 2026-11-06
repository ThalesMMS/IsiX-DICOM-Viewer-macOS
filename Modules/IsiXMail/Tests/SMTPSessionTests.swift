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
@testable import IsiXMail

/// The SMTP conversation without a connection: the commands it answers each
/// reply with, the reply lines it reads and the errors it stops on. The same
/// conversation over Network.framework, against a local test server with and
/// without TLS, is tests/test-smtp-network-framework.py.
struct SMTPSessionTests {

    private let message = SMTPMessage(sender: SMTPAddress(email: "sender@example.test", name: "Sender"),
                                      recipients: [SMTPAddress(email: "a@example.test"), SMTPAddress(email: "b@example.test", name: "Bé")],
                                      subject: "Subject", body: "<p>Body</p>")

    private func session(_ mode: SMTPTLSMode = .none, credentials: SMTPSession.Credentials? = nil) -> SMTPSession {
        SMTPSession(tlsMode: mode, credentials: credentials, hostname: "client.local", message: message)
    }

    /// The commands a run of replies gets, flattened.
    private func run(_ session: inout SMTPSession, _ replies: [String]) throws -> [SMTPSession.Action] {
        var actions: [SMTPSession.Action] = []
        for reply in replies {
            actions += try session.receive(reply)
        }
        return actions
    }

    private func sent(_ actions: [SMTPSession.Action]) -> [String] {
        actions.compactMap { if case let .send(line) = $0 { line } else { nil } }
    }

    @Test func plainSessionWithoutCredentialsSaysHELO() throws {
        var s = session()
        let actions = try run(&s, ["220 server ready", "250 hello", "250 sender ok", "250 a ok", "250 b ok", "354 go on", "250 queued", "221 bye"])
        let lines = sent(actions)
        #expect(Array(lines.prefix(5)) == ["HELO client.local", "MAIL FROM: <sender@example.test>", "RCPT TO: <a@example.test>", "RCPT TO: <b@example.test>", "DATA"])
        #expect(lines.contains("From: =?UTF-8?B?\(Data("Sender".utf8).base64EncodedString())?= <sender@example.test>"))
        #expect(lines.contains("To: a@example.test, =?UTF-8?B?\(Data("Bé".utf8).base64EncodedString())?= <b@example.test>"))
        #expect(lines.contains(Data("<p>Body</p>".utf8).base64EncodedString()))
        #expect(lines.suffix(2) == [".", "QUIT"])
        #expect(actions.last == .close)
        #expect(s.succeeded)
    }

    @Test func startTLSIsUsedWhenOffered() throws {
        var s = session(.required)
        #expect(try s.receive("220 ready") == [.send("EHLO client.local")])
        #expect(try s.receive("250-server") == [])
        #expect(try s.receive("250-STARTTLS") == [])
        #expect(try s.receive("250 8BITMIME") == [.send("STARTTLS")])
        #expect(try s.receive("220 go ahead") == [.startTLS, .send("EHLO client.local")])
        #expect(s.isTLS)
        #expect(try s.receive("250 server") == [.send("MAIL FROM: <sender@example.test>")])
    }

    @Test func withoutSTARTTLSIfPossibleGoesOnInPlainTextAndRequiredFails() throws {
        var possible = session(.ifPossible)
        #expect(try run(&possible, ["220 ready", "250 server"]) == [.send("EHLO client.local"), .continueWithoutTLS, .send("MAIL FROM: <sender@example.test>")])
        var required = session(.required)
        _ = try required.receive("220 ready")
        #expect(throws: SMTPError.startTLSUnsupported) { try required.receive("250 server") }
        #expect(SMTPError.startTLSUnsupported.reason == "Server doesn't support STARTTLS")
    }

    @Test func aSilentServerGetsTLSOnlyWhenAllowed() throws {
        var tls = session(.ifPossible)
        #expect(try tls.serverStayedSilent() == [.startTLS])
        // Greeted over TLS from the first byte: no STARTTLS, and HELO without credentials.
        #expect(try tls.receive("220 ready") == [.send("HELO client.local")])
        var plain = session()
        #expect(throws: SMTPError.stalledWithoutTLS) { try plain.serverStayedSilent() }
        #expect(SMTPError.stalledWithoutTLS.reason == "Connection stalled, probably wants TLS handshake, user said no TLS")
    }

    @Test func authenticationPrefersCRAMMD5ThenPLAINThenLOGIN() throws {
        let credentials = SMTPSession.Credentials(username: "tim", password: "tanstaaftanstaaf")
        var cram = session(credentials: credentials)
        #expect(try run(&cram, ["220 ready", "250-server", "250-AUTH LOGIN PLAIN CRAM-MD5", "250 ok"]).last == .send("AUTH CRAM-MD5"))
        // RFC 2195's example, digest in lower-case hexadecimal as the RFC writes it.
        let challenge = Data("<1896.697170952@postoffice.reston.mci.net>".utf8).base64EncodedString()
        let answer = try cram.receive("334 " + challenge)
        #expect(answer == [.send(Data("tim b913a602c7eda7a495b4e6e7334d3890".utf8).base64EncodedString())])
        #expect(try cram.receive("235 ok") == [.send("MAIL FROM: <sender@example.test>")])

        var plain = session(credentials: credentials)
        #expect(try run(&plain, ["220 ready", "250 AUTH PLAIN LOGIN"]).last == .send("AUTH PLAIN " + Data("tim\0tim\0tanstaaftanstaaf".utf8).base64EncodedString()))

        var login = session(credentials: credentials)
        _ = try run(&login, ["220 ready", "250 AUTH LOGIN"])
        #expect(try login.receive("334 " + Data("Username:".utf8).base64EncodedString()) == [.send(Data("tim".utf8).base64EncodedString())])
        #expect(try login.receive("334 " + Data("Password:".utf8).base64EncodedString()) == [.send(Data("tanstaaftanstaaf".utf8).base64EncodedString())])
        #expect(try login.receive("235 ok") == [.send("MAIL FROM: <sender@example.test>")])

        var none = session(credentials: credentials)
        _ = try none.receive("220 ready")
        #expect(throws: SMTPError.noSupportedAuthentication) { try none.receive("250 AUTH GSSAPI") }
    }

    @Test func longSecretsAreHashedFirst() {
        // HMAC hashes a key longer than its 64-byte block, as the client did.
        let secret = String(repeating: "x", count: 100)
        #expect(SMTPSession.cramMD5(challenge: "c", secret: secret) == "8fad3cf01c631bc1b4acf3035df4a5a1")
        #expect(SMTPSession.cramMD5(challenge: "", secret: "") == "74e6f7298a9c2d168935f58c001bad88")
    }

    @Test func theBodyIsBase64InLinesOf76Characters() throws {
        let body = String(repeating: "<p>Mensagem sintética, sem destinatário real.</p>", count: 40)
        var s = session()
        let lines = sent(try run(&s, ["220 server ready", "250 hello", "250 sender ok", "250 a ok", "250 b ok", "354 go on"]))
            .dropFirst(5)
        // The default message has a short body: one line, as before.
        #expect(lines.contains(Data("<p>Body</p>".utf8).base64EncodedString()))

        let message = SMTPMessage(sender: SMTPAddress(email: "s@example.test"),
                                  recipients: [SMTPAddress(email: "r@example.test")], subject: "s", body: body)
        let data = try message.dataLines()
        let blank = try #require(data.firstIndex(of: ""))
        let encoded = Array(data[(blank + 1)..<(data.count - 1)])
        #expect(data.last == ".")
        #expect(encoded.count == (Data(body.utf8).base64EncodedString().count + 75) / 76)
        #expect(encoded.dropLast().allSatisfy { $0.count == 76 })
        #expect(encoded.last!.count <= 76)
        #expect(Data(base64Encoded: encoded.joined()) == Data(body.utf8))
        // The header lines stay as they were.
        #expect(data.contains("Subject: =?UTF-8?B?\(Data("s".utf8).base64EncodedString())?="))

        let empty = SMTPMessage(sender: SMTPAddress(email: "s@example.test"),
                                recipients: [SMTPAddress(email: "r@example.test")], subject: nil, body: "")
        #expect(try empty.dataLines().suffix(3) == ["", "", "."])
    }

    @Test func errorsKeepTheirMessages() throws {
        var s = session(credentials: SMTPSession.Credentials(username: "tim", password: "wrong"))
        _ = try run(&s, ["220 ready", "250 AUTH PLAIN"])
        #expect(throws: SMTPError.serverError(code: 535, message: "5.7.8 Authentication failed")) { try s.receive("535 5.7.8 Authentication failed") }
        #expect(SMTPError.serverError(code: 535, message: "5.7.8 Authentication failed").reason == "Error 535: 5.7.8 Authentication failed")
        #expect(SMTPError.serverError(code: 554, message: nil).reason == "Error 554: (null)")

        var unexpected = session()
        #expect(throws: SMTPError.unexpectedReply(status: .initial, code: 250)) { try unexpected.receive("250 hello") }
        #expect(SMTPError.unexpectedReply(status: .mail, code: 354).reason == "Don't know how to act with status 5, code 354")
        #expect(throws: SMTPError.unparsableLine) { try unexpected.receive("hello") }
        #expect(throws: SMTPError.unparsableLine) { try unexpected.receive(nil) }
        #expect(SMTPError.noSupportedAuthentication.reason == "The server doesn't allow any authentication techniques supported by this client.")
        #expect(SMTPError.unrecognizedSelector(receiverClass: "__NSCFNumber", selector: "lowercaseString").reason == "-[__NSCFNumber lowercaseString]: unrecognized selector")
        #expect(SMTPError.emptySender.isInvalidArgument && !SMTPError.unparsableLine.isInvalidArgument)
    }

    @Test func headersAreAddedButCannotReplaceTheClientsOwn() throws {
        var m = message
        m.headers = [.field(name: "X-Portal", value: "1"), .field(name: "Subject", value: "other")]
        let lines = try m.dataLines()
        #expect(lines.contains("X-Portal: 1"))
        #expect(!lines.contains("Subject: other"))
        m.headers = [.invalidName(className: "__NSCFNumber")]
        #expect(throws: SMTPError.unrecognizedSelector(receiverClass: "__NSCFNumber", selector: "lowercaseString")) { try m.dataLines() }
        m.headers = []
        m.subject = nil
        m.body = nil
        let bare = try m.dataLines()
        #expect(bare.contains("Subject: =?UTF-8?B?(null)?="))
        #expect(bare.suffix(2) == ["", "."])
    }

    @Test func addressesSplitAsBefore() throws {
        #expect(try SMTPAddress.split("Name <a@b.c>") == SMTPAddress(email: "a@b.c", name: "Name"))
        #expect(try SMTPAddress.split("<a@b.c>") == SMTPAddress(email: "a@b.c", name: ""))
        #expect(try SMTPAddress.split("a@b.c") == SMTPAddress(email: "a@b.c"))
        #expect(throws: SMTPError.invalidAddress) { try SMTPAddress.split("Name <a@b.c") }
        #expect(throws: SMTPError.invalidAddress) { try SMTPAddress.split("a@b.c>") }
        #expect(throws: SMTPError.invalidAddress) { try SMTPAddress.split(">a@b.c<") }
        #expect(try SMTPAddress.recipients("a@b.c, , <>, B <d@e.f>") == [SMTPAddress(email: "a@b.c"), SMTPAddress(email: "d@e.f", name: "B")])
        #expect(throws: SMTPError.emptyDestination) { try SMTPAddress.recipients(" , <>") }
    }

    @Test func replyLinesAndTheLineBuffer() throws {
        #expect(try SMTPReplyLine.parse("250-AUTH PLAIN") == SMTPReplyLine(code: 250, separator: "-", text: "AUTH PLAIN"))
        #expect(try SMTPReplyLine.parse("250 ok") == SMTPReplyLine(code: 250, separator: " ", text: "ok"))
        #expect(try SMTPReplyLine.parse("220") == SMTPReplyLine(code: 220, separator: nil, text: nil))
        var buffer = SMTPLineBuffer()
        #expect(buffer.append(Array("220 a\r\n\r\n250".utf8)) == ["220 a"])
        #expect(buffer.append(Array(" b\r\n".utf8)) == ["250 b"])
        #expect(buffer.append([0xFF, 13, 10]) == [nil])
        #expect(buffer.append([0x32, 0, 13, 10]) == [])
    }

    @Test func clientModeValuesMapAsTheClientComparedThem() {
        #expect(SMTPTLSMode(clientValue: 0) == .none)
        #expect(SMTPTLSMode(clientValue: 1) == .ifPossible)
        #expect(SMTPTLSMode(clientValue: 2) == .required)
        #expect(SMTPTLSMode(clientValue: 7) == .ifPossible)
    }
}
