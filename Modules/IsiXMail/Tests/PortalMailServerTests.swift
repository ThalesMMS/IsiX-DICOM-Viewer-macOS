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

/// The portal's mail server as a value: what counts as a server, the ports it
/// is tried on, where its password is kept, which route an email takes and
/// what stops one before anything is sent.
@Suite struct PortalMailServerTests {
    private let mail = PortalMail(body: "<p>Body</p>", subject: "Subject", sender: "Portal <portal@example.test>",
                                  recipients: "a@example.test, B <b@example.test>")

    @Test func aServerIsSetByItsHostAndTriesItsPortOrTheThreeDefaults() {
        let none = PortalMailServer(host: "  ")
        #expect(!none.isSet)
        #expect(none.host == "")
        let server = PortalMailServer(host: " smtp.example.test ", port: 587, tlsMode: .required, username: " tim ")
        #expect(server.isSet && server.authenticates)
        #expect(server.host == "smtp.example.test" && server.username == "tim")
        #expect(server.ports == [587])
        #expect(server.address == "smtp.example.test:587")
        let anyPort = PortalMailServer(host: "smtp.example.test")
        #expect(anyPort.ports == [25, 465, 587])
        #expect(anyPort.address == "smtp.example.test")
        #expect(!anyPort.authenticates)
        // A port no connection can use is no port.
        #expect(PortalMailServer(host: "h", port: 70000).port == 0)
        #expect(PortalMailServer(host: "h", port: -1).port == 0)
    }

    @Test func thePasswordIsKeptForTheUserAtTheServer() {
        let server = PortalMailServer(host: "SMTP.Example.test", port: 587, username: "tim")
        #expect(server.passwordAccount == "tim@smtp.example.test")
        // Another server, or another user, is another item: neither is offered this one's password.
        #expect(PortalMailServer(host: "other.example.test", username: "tim").passwordAccount != server.passwordAccount)
        #expect(PortalMailServer(host: "smtp.example.test", username: "ana").passwordAccount != server.passwordAccount)
        // The port and the TLS mode are not part of who the password is for.
        #expect(PortalMailServer(host: "smtp.example.test", port: 465, tlsMode: .none, username: "tim").passwordAccount
                == server.passwordAccount)
    }

    @Test func aServerThatIsSetIsAlwaysTheRoute() {
        let server = PortalMailServer(host: "smtp.example.test")
        #expect(PortalMailRoute.choose(server: server, mailApplicationAvailable: true) == .server(server))
        #expect(PortalMailRoute.choose(server: server, mailApplicationAvailable: false) == .server(server))
        let none = PortalMailServer(host: "")
        #expect(PortalMailRoute.choose(server: none, mailApplicationAvailable: true) == .mailApplication)
        #expect(PortalMailRoute.choose(server: none, mailApplicationAvailable: false) == .none)
    }

    @Test func theEmailIsReadFromThePortalsHeaders() {
        let read = PortalMail(body: "<p>Body</p>", headers: ["To": "a@example.test", "Sender": "portal@example.test",
                                                             "Subject": "Subject", "Other": 3])
        #expect(read == PortalMail(body: "<p>Body</p>", subject: "Subject", sender: "portal@example.test", recipients: "a@example.test"))
        // What is absent, or is not text, is empty.
        #expect(PortalMail(body: nil, headers: ["To": 7]) == PortalMail(body: "", subject: "", sender: "", recipients: ""))
        #expect(PortalMail(body: nil, headers: nil).recipients == "")
    }

    @Test func aSessionCarriesTheMessageTheModeAndTheCredentials() throws {
        let server = PortalMailServer(host: "smtp.example.test", port: 587, tlsMode: .ifPossible, username: "tim")
        let session = try server.session(sending: mail, password: "secret", hostname: "client.local").get()
        #expect(session.tlsMode == .ifPossible)
        #expect(session.credentials == SMTPSession.Credentials(username: "tim", password: "secret"))
        #expect(session.hostname == "client.local")
        #expect(session.message.sender == SMTPAddress(email: "portal@example.test", name: "Portal"))
        #expect(session.message.recipients.map(\.email) == ["a@example.test", "b@example.test"])
        #expect(session.message.subject == "Subject" && session.message.body == "<p>Body</p>")

        // No user name: no credentials, whatever password is offered.
        let open = PortalMailServer(host: "smtp.example.test", tlsMode: .none)
        let plain = try open.session(sending: mail, password: "ignored", hostname: "client.local").get()
        #expect(plain.credentials == nil && plain.tlsMode == .none)
    }

    @Test func whatStopsAnEmailBeforeItIsSent() {
        let server = PortalMailServer(host: "smtp.example.test", username: "tim")
        func failure(_ mail: PortalMail, password: String? = "secret") -> PortalMailFailure? {
            if case let .failure(failure) = server.session(sending: mail, password: password, hostname: "client.local") { return failure }
            return nil
        }
        // A server that authenticates and no password to give it.
        #expect(failure(mail, password: nil) == .noPassword)
        #expect(failure(mail, password: "") == .noPassword)
        // SMTP needs a sender: the portal's address, empty until it is entered.
        var noSender = mail
        noSender.sender = " "
        #expect(failure(noSender) == .smtp(.emptySender))
        var noRecipient = mail
        noRecipient.recipients = ""
        #expect(failure(noRecipient) == .smtp(.emptyDestination))
        noRecipient.recipients = ", ,"
        #expect(failure(noRecipient) == .smtp(.emptyDestination))
        var unbalanced = mail
        unbalanced.recipients = "Name <a@example.test"
        #expect(failure(unbalanced) == .smtp(.invalidAddress))
        #expect(failure(mail) == nil)
    }

    @Test func theLogLineSaysWhoAndHowItEnded() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let server = PortalMailServer(host: "smtp.example.test", port: 587)
        #expect(PortalMailReport(date: date, recipients: "a@example.test", route: .server(server), failure: nil).logMessage
                == "email to a@example.test sent through smtp.example.test:587")
        #expect(PortalMailReport(date: date, recipients: "a@example.test", route: .mailApplication, failure: nil).logMessage
                == "email to a@example.test handed to the Mail application")
        #expect(PortalMailReport(date: date, recipients: "a@example.test", route: .none, failure: .noServer).logMessage
                == "email to a@example.test not sent: no mail server is set")
        #expect(PortalMailReport(date: date, recipients: "a@example.test", route: .server(server),
                                 failure: .smtp(.serverError(code: 535, message: "5.7.8 refused"))).logMessage
                == "email to a@example.test not sent: Error 535: 5.7.8 refused")
        #expect(PortalMailFailure.connection("Connection refused").logText == "Connection refused")
        #expect(PortalMailFailure.connection(nil).logText == "the connection to the mail server could not be opened")
        #expect(PortalMailFailure.noPassword.logText == "the password of the mail server is not in the Keychain")
        #expect(PortalMailFailure.mailApplication.logText == "the Mail application did not take the message")
    }
}
