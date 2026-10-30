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
import Network
import Security

/// One SMTP conversation on one port, over Network.framework.
///
/// Without TLS the connection is plain TCP. With TLS it starts in plain text
/// too, through SMTPPlainTextFramer: the greeting, EHLO and STARTTLS are read
/// and written by that framer, and when the session starts TLS the framer
/// puts TLS above itself (nw_framer_prepend_application_protocol) and steps
/// aside. Network.framework has no other way to start TLS on an open
/// connection. A server that waits for the handshake before greeting (port
/// 465) gets it after a second of silence.
///
/// Everything here runs on `queue`, the connection's queue; the framer hands
/// its bytes over to it, and is written to through its own async.
final class SMTPConnection: @unchecked Sendable {
    enum Outcome: Sendable {
        /// The server took the message.
        case delivered
        /// The conversation stopped on an error.
        case failed(SMTPError)
        /// The connection ended, or never opened, without an SMTP error; a
        /// stream error has been logged.
        case closed
    }

    /// Certificates trusted besides the system's, for a local test server's
    /// self-signed one. Set by the focused test only, before any message is
    /// sent; the app leaves it empty, and the system's evaluation applies alone.
    nonisolated(unsafe) static var testAnchorCertificates: [SecCertificate] = []

    /// How long the TCP connection may take to open.
    static let openTimeout: TimeInterval = 10
    /// How long the server may stay silent once it is open before TLS is
    /// started (or, without TLS, the conversation fails).
    static let greetingTimeout: TimeInterval = 1

    private let queue = DispatchQueue(label: "IsiX.SMTPConnection")
    private let host: String
    private let port: Int
    private var session: SMTPSession
    private var connection: NWConnection?
    private var completion: (@Sendable (Outcome) -> Void)?

    /// The framer while it carries the plain text, until TLS starts or the
    /// session goes on without it.
    private var framer: SMTPFramerHandle?
    /// The connection is ready for send and receive.
    private var isReady = false
    /// Lines written before the connection is ready, as after STARTTLS.
    private var pendingOutput = Data()
    private var lines = SMTPLineBuffer()
    private var isOpen = false
    private var heardFromServer = false
    private var isFinished = false

    init(host: String, port: Int, session: SMTPSession) {
        self.host = host
        self.port = port
        self.session = session
    }

    /// Opens the connection; `completion` is called once, on the connection's queue.
    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async { self.open(completion) }
    }

    private func open(_ completion: @escaping @Sendable (Outcome) -> Void) {
        self.completion = completion
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else {
            NSLog("Stream error: %@", "invalid port \(self.port)")
            finish(.closed)
            return
        }
        let parameters = NWParameters.tcp
        if session.tlsMode != .none {
            let options = NWProtocolFramer.Options(definition: SMTPPlainTextFramer.definition)
            options[SMTPPlainTextFramer.ownerKey] = SMTPFramerOwner(self)
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in stateChanged(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + SMTPConnection.openTimeout) { [self] in
            if !isOpen { finish(.closed) }
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            if !isOpen { opened() }
            receive()
            flush()
        case let .waiting(error), let .failed(error):
            NSLog("Stream error: %@", SMTPConnection.describe(error))
            finish(.closed)
        case .cancelled:
            finish(.closed)
        default:
            break
        }
    }

    /// TCP is open: the plain-text framer started, or the plain connection is ready.
    fileprivate func opened(framer: SMTPFramerHandle? = nil) {
        guard !isFinished else { return }
        isOpen = true
        if let framer { self.framer = framer }
        queue.asyncAfter(deadline: .now() + SMTPConnection.greetingTimeout) { [self] in
            guard !isFinished, !heardFromServer else { return }
            do throws(SMTPError) {
                perform(try session.serverStayedSilent())
            } catch {
                finish(.failed(error))
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { received(data) }
            if isFinished { return }
            if let error {
                NSLog("Stream error: %@", SMTPConnection.describe(error))
                finish(.closed)
            } else if isComplete {
                finish(.closed)
            } else {
                receive()
            }
        }
    }

    /// Bytes from the server, through the framer or the connection.
    fileprivate func received(_ data: Data) {
        guard !isFinished else { return }
        heardFromServer = true
        for line in lines.append(data) {
            do throws(SMTPError) {
                perform(try session.receive(line))
            } catch {
                finish(.failed(error))
            }
            if isFinished { return }
        }
    }

    private func perform(_ actions: [SMTPSession.Action]) {
        for action in actions {
            switch action {
            case let .send(line):
                write(Data((line + "\r\n").utf8))
            case .startTLS:
                handOver(addingTLS: true)
            case .continueWithoutTLS:
                handOver(addingTLS: false)
            case .close:
                finish(.closed)
            }
        }
    }

    /// The framer steps aside: what follows goes through the connection,
    /// over TLS or still in plain text.
    private func handOver(addingTLS: Bool) {
        guard let framer else { return }
        self.framer = nil
        let tls = addingTLS ? tlsOptions() : nil
        framer.instance.async {
            if let tls {
                _ = try? framer.instance.prependApplicationProtocol(options: tls)
            }
            framer.instance.passThroughInput()
            framer.instance.passThroughOutput()
            framer.instance.markReady()
        }
    }

    private func write(_ data: Data) {
        if let framer {
            framer.instance.async { framer.instance.writeOutput(data: data) }
        } else {
            pendingOutput.append(data)
            flush()
        }
    }

    private func flush() {
        guard isReady, !pendingOutput.isEmpty, let connection else { return }
        let data = pendingOutput
        pendingOutput = Data()
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let anchors = SMTPConnection.testAnchorCertificates
        if !anchors.isEmpty {
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        }
        return options
    }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        framer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let completion = self.completion
        self.completion = nil
        if case .closed = outcome, session.succeeded {
            completion?(.delivered)
        } else {
            completion?(outcome)
        }
    }

    /// The error's text as the streams' NSError gave it.
    static func describe(_ error: NWError) -> String {
        switch error {
        case let .posix(code):
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue)).localizedDescription
        case let .tls(status):
            return NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
        default:
            return error.localizedDescription
        }
    }
}

/// The framer instance, which Network.framework lets other threads use only
/// through its own async.
struct SMTPFramerHandle: @unchecked Sendable {
    let instance: NWProtocolFramer.Instance
}

/// How the framer finds its connection: through its options, weakly.
final class SMTPFramerOwner: @unchecked Sendable {
    weak var connection: SMTPConnection?

    init(_ connection: SMTPConnection) {
        self.connection = connection
    }
}

/// The plain-text part of a connection that may start TLS. It reads and
/// writes bytes for SMTPConnection until it is told to step aside; it never
/// marks itself ready before, so nothing goes through the connection above it.
final class SMTPPlainTextFramer: NWProtocolFramerImplementation {
    static let label = "IsiXSMTP"
    static let definition = NWProtocolFramer.Definition(implementation: SMTPPlainTextFramer.self)
    static let ownerKey = "owner"

    private let owner: SMTPFramerOwner?

    required init(framer: NWProtocolFramer.Instance) {
        owner = framer.options[SMTPPlainTextFramer.ownerKey] as? SMTPFramerOwner
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        let handle = SMTPFramerHandle(instance: framer)
        let owner = owner
        owner?.connection?.queueAsync { owner?.connection?.opened(framer: handle) }
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var chunk: Data?
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65536) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                chunk = Data(buffer)
                return buffer.count
            }
            guard let chunk else { return 0 }
            let owner = owner
            owner?.connection?.queueAsync { owner?.connection?.received(chunk) }
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

    func cleanup(framer: NWProtocolFramer.Instance) {}
}

extension SMTPConnection {
    /// Runs `work` on the connection's queue.
    fileprivate func queueAsync(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
