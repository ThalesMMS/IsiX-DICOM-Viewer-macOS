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
import IsiXMail
import IsiXPreferences
import Synchronization

extension PortalMailServer {
    /// The server the Web Sharing pane's sheet stored in `preferences`; not
    /// set when it stored none.
    init(preferences: any PreferenceStore) {
        self.init(host: preferences[WebPortalPreferences.mailServerHost] ?? "",
                  port: preferences[WebPortalPreferences.mailServerPort],
                  tlsMode: SMTPTLSMode(clientValue: preferences[WebPortalPreferences.mailServerTLSMode]),
                  username: preferences[WebPortalPreferences.mailServerUsername] ?? "")
    }

    /// Stores the server, or removes every key of it when it is not set, so
    /// that no port, mode or user name of a former server stays behind.
    func store(in preferences: any PreferenceStore) {
        guard isSet else {
            preferences.remove(WebPortalPreferences.mailServerHost)
            preferences.remove(WebPortalPreferences.mailServerPort)
            preferences.remove(WebPortalPreferences.mailServerTLSMode)
            preferences.remove(WebPortalPreferences.mailServerUsername)
            return
        }
        preferences.set(host, for: WebPortalPreferences.mailServerHost)
        preferences.set(port, for: WebPortalPreferences.mailServerPort)
        preferences.set(tlsMode.rawValue, for: WebPortalPreferences.mailServerTLSMode)
        preferences.set(username, for: WebPortalPreferences.mailServerUsername)
    }
}

/// Sends the emails of the web portal: a forgotten password, the notice of new
/// studies, the notice of a study shared with a user, a temporary account.
///
/// With a server set, an email goes to it by SMTP, in every build. Without
/// one, the direct build hands it to the Mail application, which sends it from
/// one of its accounts; a sandboxed sender may make a message in Mail but not
/// tell it to send, so the App Store build has no such route and says that no
/// server is set.
///
/// How each email ended is given to `record`, and to whoever asked: nothing
/// is dropped on the way. The server, its password and the Mail application
/// are given to the delivery, which reads no preference and no Keychain item
/// by itself.
final class WebPortalMailDelivery: Sendable {
    /// Hands a message to the Mail application; false when Mail did not take
    /// it. Called on the main thread, where Mail's client reads the HTML.
    typealias MailApplication = @MainActor @Sendable (PortalMail) -> Bool
    typealias Completion = @Sendable (PortalMailReport) -> Void

    /// Whether this build may send through the Mail application.
    #if MACAPPSTORE
    static let sendsThroughMailApplication = false
    #else
    static let sendsThroughMailApplication = true
    #endif

    private let server: @Sendable () -> PortalMailServer
    private let password: @Sendable (_ account: String) -> String?
    private let mailApplication: MailApplication?
    private let hostname: @Sendable () -> String
    private let record: Completion
    /// Where the password is read and a connection started: reading the
    /// Keychain can take seconds, which the caller's thread does not wait.
    private let queue = DispatchQueue(label: "IsiX.WebPortalMailDelivery")

    /// `server` and `password` are asked again for every email, so a change
    /// in the pane applies to the next one. `mailApplication` is dropped in a
    /// build that may not send through Mail, whoever gives it.
    init(server: @escaping @Sendable () -> PortalMailServer,
         password: @escaping @Sendable (_ account: String) -> String?,
         mailApplication: MailApplication?,
         hostname: @escaping @Sendable () -> String = { SMTPClient.hostname() },
         record: @escaping Completion) {
        self.server = server
        self.password = password
        self.mailApplication = WebPortalMailDelivery.sendsThroughMailApplication ? mailApplication : nil
        self.hostname = hostname
        self.record = record
    }

    /// The route the next email takes.
    var route: PortalMailRoute {
        PortalMailRoute.choose(server: server(), mailApplicationAvailable: mailApplication != nil)
    }

    private func session(sending mail: PortalMail, through server: PortalMailServer) -> Result<SMTPSession, PortalMailFailure> {
        server.session(sending: mail, password: server.authenticates ? password(server.passwordAccount) : nil,
                       hostname: hostname())
    }

    /// Why `mail` cannot leave, when that is known before any connection: no
    /// route, an address SMTP refuses, a server that authenticates without a
    /// password in the Keychain. Nil when the email would be attempted.
    /// Reads the Keychain: not for the main thread.
    func obstacle(to mail: PortalMail) -> PortalMailFailure? {
        switch route {
        case .none:
            return .noServer
        case .mailApplication:
            return nil
        case let .server(server):
            if case let .failure(failure) = session(sending: mail, through: server) { return failure }
            return nil
        }
    }

    /// True when `mail` is known not to leave, which is then recorded as a
    /// failed email: a caller that answers a person before the delivery ends
    /// asks this first, and does not promise an email.
    func refuses(_ mail: PortalMail) -> Bool {
        guard let failure = obstacle(to: mail) else { return false }
        record(PortalMailReport(date: Date(), recipients: mail.recipients, route: route, failure: failure))
        return true
    }

    /// Sends `mail` by the route of the moment. Returns at once; the report
    /// goes to `record` and then to `completion`, on the main thread for the
    /// Mail application and on a queue of the delivery otherwise.
    func send(_ mail: PortalMail, completion: Completion? = nil) {
        let route = self.route
        let finish: @Sendable (PortalMailFailure?) -> Void = { [record] failure in
            let report = PortalMailReport(date: Date(), recipients: mail.recipients, route: route, failure: failure)
            record(report)
            completion?(report)
        }
        switch route {
        case .none:
            finish(.noServer)
        case .mailApplication:
            guard let mailApplication else { return finish(.noServer) }
            DispatchQueue.main.async {
                let taken = MainActor.assumeIsolated { mailApplication(mail) }
                finish(taken ? nil : .mailApplication)
            }
        case let .server(server):
            queue.async { [self] in
                switch session(sending: mail, through: server) {
                case let .failure(failure):
                    finish(failure)
                case let .success(session):
                    SMTPDelivery(host: server.host, ports: server.ports.map { .success($0) }, session: session).start { result in
                        switch result {
                        case .delivered:
                            finish(nil)
                        case let .failed(error, streamError):
                            finish(error.map { .smtp($0) } ?? .connection(streamError))
                        }
                    }
                }
            }
        }
    }
}

/// The last email of the portal and how it ended, kept while the application
/// runs: what the Web Sharing pane shows under the mail server.
final class WebPortalMailStatus: Sendable {
    typealias Observer = @Sendable (PortalMailReport) -> Void

    static let process = WebPortalMailStatus()

    private struct State {
        var last: PortalMailReport?
        var observers: [Int: Observer] = [:]
        var nextToken = 0
    }

    private let state = Mutex(State())

    var last: PortalMailReport? {
        state.withLock { $0.last }
    }

    /// Keeps `report` as the last one and tells the observers, on the thread
    /// of the caller.
    func record(_ report: PortalMailReport) {
        let observers = state.withLock { state in
            state.last = report
            return Array(state.observers.values)
        }
        for observer in observers { observer(report) }
    }

    /// Calls `observer` for every report from now on, until the token it
    /// returns is given to `stopObserving`.
    func observe(_ observer: @escaping Observer) -> Int {
        state.withLock { state in
            state.nextToken += 1
            state.observers[state.nextToken] = observer
            return state.nextToken
        }
    }

    func stopObserving(_ token: Int) {
        state.withLock { _ = $0.observers.removeValue(forKey: token) }
    }
}
