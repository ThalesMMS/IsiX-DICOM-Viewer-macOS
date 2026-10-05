//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import os

/// Why the XML-RPC listener turned a request away before reading it.
@objc(HorosRISRefusal)
public enum RISRefusal: Int {
    /// The listener wants a password and the request carried none.
    case noCredential
    /// The request carried a password that does not match.
    case wrongCredential
    /// The listener answers this machine only.
    case loopbackOnly
}

/// Tells the user why a request from a RIS, made through a `horos://` link or
/// an XML-RPC call, did nothing.
///
/// The methods answer the caller with an error code, but a link has no caller
/// to read it, and an XML-RPC client seldom shows it: the user saw the viewer
/// come to the front and nothing else. Each failure is logged and shown in an
/// alert that names what was asked for and why it failed. Failures that come
/// while an alert is up are gathered into the next one rather than stacked.
@objc(HorosRISRequestAlert)
public final class RISRequestAlert: NSObject {
    // MARK: Messages

    /// A node named in the request is not in Locations.
    @objc(serverNotFoundMessage:)
    public static func serverNotFound(_ name: String) -> String {
        return String(format: NSLocalizedString("No node named \"%@\" is in Locations. A RIS request designates a node by its description or, for a DICOM node, by its AE title; a DICOMweb node needs Q&R turned on.", comment: "RIS request: node not found"), name)
    }

    /// The node answered, with no study.
    @objc(nothingFoundMessageOnServer:filters:)
    public static func nothingFound(server: String, filters: String) -> String {
        return String(format: NSLocalizedString("The node \"%@\" found no study matching %@.", comment: "RIS request: empty answer"), server, filters)
    }

    /// The node could not be asked.
    @objc(queryFailedMessageOnServer:filters:)
    public static func queryFailed(server: String, filters: String) -> String {
        return String(format: NSLocalizedString("The node \"%@\" could not be queried for %@. The console log gives the reason.", comment: "RIS request: query failed"), server, filters)
    }

    /// The study is not in the database, and PACS On-Demand did not bring it.
    ///
    /// `onDemandNodes` is `nil` when PACS On-Demand is not on for these
    /// requests, and empty when it is on with no node chosen.
    @objc(notInDatabaseMessageForFilters:onDemandNodes:)
    public static func notInDatabase(filters: String, onDemandNodes: [String]?) -> String {
        guard let nodes = onDemandNodes else {
            return String(format: NSLocalizedString("No study matching %@ is in the database.", comment: "RIS request: not in the database"), filters)
        }
        if nodes.isEmpty {
            return String(format: NSLocalizedString("No study matching %@ is in the database, and no PACS On-Demand node is chosen in the preferences.", comment: "RIS request: no on-demand node"), filters)
        }
        return String(format: NSLocalizedString("No study matching %@ is in the database or on the PACS On-Demand nodes (%@).", comment: "RIS request: not found on demand"), filters, nodes.joined(separator: ", "))
    }

    /// Added to the alert that offers to turn the URL support on.
    @objc(notCarriedOutMessage:)
    public static func notCarriedOut(_ request: String) -> String {
        return String(format: NSLocalizedString("The request %@ was not carried out.", comment: "RIS request: XML-RPC off"), request)
    }

    static func refusedMessage(peer: String, reason: RISRefusal) -> String {
        switch reason {
        case .noCredential:
            return String(format: NSLocalizedString("An XML-RPC request from %@ was refused because it carried no password.", comment: "RIS request: no password"), peer)
        case .wrongCredential:
            return String(format: NSLocalizedString("An XML-RPC request from %@ was refused because its password is wrong.", comment: "RIS request: wrong password"), peer)
        case .loopbackOnly:
            return String(format: NSLocalizedString("An XML-RPC request from %@ was refused: XML-RPC answers this computer only. Other computers are let in with Network Access… in the Listener settings.", comment: "RIS request: loopback only"), peer)
        }
    }

    /// The alert text: the reason, then the code the caller was answered.
    static func text(_ message: String, code: Int) -> String {
        return message + "\n\n" + String(format: NSLocalizedString("Error code: %@", comment: "RIS request: error code"), String(code))
    }

    /// How the filters of a request read in a message: `PatientID = 123`.
    @objc(describeFilters:)
    public static func describe(filters: [String: Any]) -> String {
        let terms = filters.keys.sorted().map { "\($0) = \(String(describing: filters[$0]! as AnyObject))" }
        return terms.isEmpty ? "-" : terms.joined(separator: ", ")
    }

    /// How a link reads in a message: its method, then its other parameters.
    public static func describe(method: String?, parameters: [String: String]) -> String {
        var filters = parameters
        filters["methodName"] = nil
        return (method ?? "image") + (filters.isEmpty ? "" : " (" + describe(filters: filters) + ")")
    }

    // MARK: Reporting

    /// Logs a failed request and shows it. Callable from any thread.
    @objc(reportMessage:code:)
    public static func report(_ message: String, code: Int) {
        NSLog("RIS request failed (%d): %@", code, message)
        show(text(message, code: code))
    }

    /// Which refusals are shown. A value, so the policy is checked with the
    /// times given rather than with the clock.
    struct RefusalLedger {
        /// How long a client challenged for a password has to come back with
        /// it. HTTP clients often ask without a credential first and send it
        /// after the `401`; that exchange is not a failure.
        static let challengeGrace: TimeInterval = 3
        /// One refusal alert per peer in this time, so a host that keeps
        /// calling with a wrong password cannot bury the screen in alerts.
        static let interval: TimeInterval = 60

        /// Peers refused for lack of a password, and when, while the grace runs.
        private var pending: [String: Date] = [:]
        /// When each peer was last shown a refusal.
        private var shown: [String: Date] = [:]

        /// Notes a challenge; `isDue(peer:challengedAt:at:)` says later whether
        /// it went unanswered.
        mutating func challenged(peer: String, at time: Date) { pending[peer] = time }

        /// The peer came back with a good password.
        mutating func accepted(peer: String) { pending[peer] = nil }

        /// Asked once the grace is over: whether the challenge of `time` is
        /// still unanswered, and is to be shown now.
        mutating func isDue(peer: String, challengedAt time: Date, at now: Date) -> Bool {
            guard pending[peer] == time else { return false }
            pending[peer] = nil
            return shouldShow(peer: peer, at: now)
        }

        /// Whether a refusal of this peer is shown now, given the last one.
        mutating func shouldShow(peer: String, at now: Date) -> Bool {
            if let last = shown[peer], now.timeIntervalSince(last) < Self.interval { return false }
            shown[peer] = now
            return true
        }
    }

    private static let refusals = OSAllocatedUnfairLock(initialState: RefusalLedger())

    /// Notes a refused request. A refusal for lack of a password is shown
    /// only when the same peer is not let in within the grace: until then it
    /// may be the challenge of an ordinary authentication.
    @objc(noteRefusalFromPeer:reason:)
    public static func noteRefusal(peer: String?, reason: RISRefusal) {
        let peer = peer ?? "?"
        let now = Date()
        guard reason == .noCredential else {
            if refusals.withLock({ $0.shouldShow(peer: peer, at: now) }) {
                report(refusedMessage(peer: peer, reason: reason), code: 401)
            }
            return
        }
        refusals.withLock { $0.challenged(peer: peer, at: now) }
        DispatchQueue.global().asyncAfter(deadline: .now() + RefusalLedger.challengeGrace) {
            if refusals.withLock({ $0.isDue(peer: peer, challengedAt: now, at: Date()) }) {
                report(refusedMessage(peer: peer, reason: .noCredential), code: 401)
            }
        }
    }

    /// Notes a request that was let in: a challenge sent to this peer just
    /// before was answered.
    @objc(noteAcceptedFromPeer:)
    public static func noteAccepted(peer: String?) {
        guard let peer = peer else { return }
        refusals.withLock { $0.accepted(peer: peer) }
    }

    // MARK: Presentation

    @MainActor private static var presenting = false
    @MainActor private static var waiting: [String] = []

    /// The text of the alert on screen, for checks run against the app.
    @MainActor @objc public private(set) static var shownText: String?

    private static func show(_ text: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { present(text) }
        }
    }

    @MainActor private static func present(_ text: String) {
        if presenting {
            if !waiting.contains(text) && waiting.count < 10 { waiting.append(text) }
            return
        }
        presenting = true
        defer { presenting = false; shownText = nil }
        var next: String? = text
        while let text = next {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("RIS Request Failed", comment: "RIS request alert title")
            alert.informativeText = text
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            shownText = text
            NSApp.activate()
            alert.runModal()
            next = waiting.isEmpty ? nil : waiting.joined(separator: "\n\n")
            waiting.removeAll()
        }
    }
}
