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
import NIOCore

/// The implementation of HTTPServer, declared in HTTPServer.h: the HTTP server
/// of the Horos and OsiriX SDK. The class is Objective-C for the runtime, so
/// that a plugin built for either SDK finds it by name and its Objective-C
/// subclass keeps every method and its own overrides; the web portal's server
/// (WebPortalServer) is a subclass.
///
/// It listens through SwiftNIO (HTTPServerListener), in HTTP or, with an
/// identity, in HTTPS. For each connection accepted it makes a socket that
/// wraps the channel, a connection of its connection class and the engine
/// that runs the HTTP exchange on the thread chosen for the connection, and
/// it publishes itself with Bonjour when it has a type.
@objc @implementation extension HTTPServer {
    // The instance variables of the SDK, with its types: a plugin built for
    // it binds each name when it loads, and its subclass reads and writes
    // them directly, with no message. Those whose name here is not the SDK's
    // have it because the class answers a message of that name.

    /// The SDK's listening socket. The listener is SwiftNIO's: nil.
    final var asyncSocket: AsyncSocket?
    /// The delegate as the SDK kept it, not retained: a copy of
    /// delegateReference, written with it. Nothing here reads it.
    unowned(unsafe) final var horos_delegate: AnyObject?
    final var horos_documentRoot: NSURL?
    final var horos_connectionClass: AnyClass? = HTTPConnection.self
    final var netService: NetService?
    final var horos_domain: NSString? = "local."
    final var horos_type: NSString?
    final var horos_name: NSString? = ""
    final var horos_port: UInt16 = 0
    final var horos_txtRecordDictionary: NSDictionary?
    /// The connections open, each an HTTPConnection, until they close; read
    /// and changed under connectionsLock.
    final var connections: NSMutableArray? = NSMutableArray()

    /// Unretained in the SDK; weak here, so that it never dangles.
    final weak var delegateReference: AnyObject?

    /// The identity HTTPS presents; nil serves plain HTTP. TLS is the
    /// listener's: a connection's -isSecureServer is not asked.
    final var tlsIdentity: HTTPServerTLSIdentity?
    /// Whether the server ends what it started, as the SDK's did: -stop closes
    /// the connections still open, and a server released while it listens
    /// stops. The web portal's server says no: its connections outlive a stop
    /// and its listener outlives the server, as they have since the portal
    /// listens through SwiftNIO.
    final var endsWhatItStarted = true

    final var listener: HTTPServerListener?
    final let connectionsLock = NSLock()
    /// The engines of the connections open, which a connection does not keep.
    final var engines: [ObjectIdentifier: HTTPConnectionEngine] = [:]

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(connectionDidDie(_:)),
                                               name: HTTPConnection.didDieNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if endsWhatItStarted {
            _ = stop()
        }
    }

    // MARK: Configuration

    func delegate() -> Any! {
        delegateReference
    }

    func setDelegate(_ newDelegate: Any!) {
        delegateReference = newDelegate as AnyObject?
        horos_delegate = newDelegate as AnyObject?
    }

    /// The folder whose files a plain HTTPConnection serves.
    func documentRoot() -> URL! {
        horos_documentRoot as URL?
    }

    func setDocumentRoot(_ value: URL!) {
        horos_documentRoot = value as NSURL?
    }

    /// The class of the connections made; HTTPConnection unless set, and
    /// when set to a class that does not descend from it.
    func connectionClass() -> AnyClass! {
        horos_connectionClass
    }

    func setConnectionClass(_ value: AnyClass!) {
        horos_connectionClass = value
    }

    func domain() -> String! {
        horos_domain as String?
    }

    func setDomain(_ value: String!) {
        horos_domain = value as NSString?
    }

    /// The Bonjour type; the server is published only when it has one.
    func type() -> String! {
        horos_type as String?
    }

    func setType(_ value: String!) {
        horos_type = value as NSString?
    }

    func name() -> String! {
        horos_name as String?
    }

    /// The name Bonjour published the service under; nil while it is not published.
    func publishedName() -> String! {
        netService?.name
    }

    func setName(_ value: String!) {
        horos_name = value as NSString?
    }

    /// The port to listen on; once started, the port listened on.
    func port() -> UInt16 {
        horos_port
    }

    func setPort(_ value: UInt16) {
        horos_port = value
    }

    @objc(TXTRecordDictionary)
    func txtRecordDictionary() -> [AnyHashable: Any]! {
        horos_txtRecordDictionary as? [AnyHashable: Any]
    }

    /// Also changes the record of a service already published.
    @objc(setTXTRecordDictionary:)
    func setTXTRecord(_ dict: [AnyHashable: Any]!) {
        horos_txtRecordDictionary = dict as NSDictionary?
        if let netService, let dict {
            netService.setTXTRecord(Self.txtRecordData(dict))
        }
    }

    // MARK: Control

    /// Opens the port and publishes the service. Throws
    /// HTTPServerListener.BindFailure when the port cannot be opened.
    @objc(start:)
    func start() throws {
        let server = HTTPServerReference(self)
        let listener = HTTPServerListener(port: Int(horos_port), tls: tlsIdentity) { channel in
            channel.eventLoop.makeCompletedFuture {
                let handler = HTTPConnectionChannelHandler { channel, handler in
                    server.server?.makeConnection(channel: channel, handler: handler)
                }
                try channel.pipeline.syncOperations.addHandlers(HTTPConnectionChannelHandler.decoders() + [handler])
            }
        }
        setPort(UInt16(truncatingIfNeeded: try listener.start()))
        self.listener = listener
        NSLog("Started HTTP server on port %hu", port())
        if let type = type() {
            let service = NetService(domain: domain() ?? "local.", type: type, name: name() ?? "", port: Int32(port()))
            service.delegate = self
            service.publish()
            // The record goes after the publication: before it, it was not safe.
            if let txtRecord = txtRecordDictionary() {
                service.setTXTRecord(Self.txtRecordData(txtRecord))
            }
            netService = service
        }
    }

    @discardableResult
    func stop() -> Bool {
        netService?.stop()
        netService = nil
        listener?.stop()
        listener = nil
        if endsWhatItStarted {
            let open = connectionsLock.withLock { Array(engines.values) }
            for engine in open {
                engine.closeConnection()
            }
        }
        return true
    }

    // MARK: Connections

    func numberOfHTTPConnections() -> UInt32 {
        UInt32(truncatingIfNeeded: connectionsLock.withLock { connections?.count ?? 0 })
    }

    /// A connection closed (HTTPConnectionDidDieNotification, which every
    /// server observes): if it is one of this server's, the server lets it go.
    /// Called on the connection's thread.
    func connectionDidDie(_ notification: Notification!) {
        guard let connection = notification?.object as? HTTPConnection else { return }
        forget(connection)
    }

    // MARK: Bonjour

    @objc(netServiceDidPublish:)
    public func netServiceDidPublish(_ sender: NetService) {
        NSLog("Bonjour Service Published: domain(%@) type(%@) name(%@)", sender.domain, sender.type, sender.name)
    }

    @objc(netService:didNotPublish:)
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("Failed to Publish Service: domain(%@) type(%@) name(%@)", sender.domain, sender.type, sender.name)
        NSLog("Error Dict: %@", "\(errorDict as AnyObject)")
    }
}

extension HTTPServer {
    /// Whether `connection` is one of this server's and still open.
    func holds(_ connection: HTTPConnection) -> Bool {
        connectionsLock.withLock { engines[ObjectIdentifier(connection)] != nil }
    }

    fileprivate func forget(_ connection: HTTPConnection) {
        // The engine is let go once the lock is released.
        _ = connectionsLock.withLock {
            connections?.removeObject(identicalTo: connection)
            return engines.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    /// A new connection, on its channel's event loop: its socket, the thread
    /// it runs on, the connection object and the engine of its exchange. Nil
    /// refuses the connection.
    fileprivate func makeConnection(channel: Channel, handler: HTTPConnectionChannelHandler) -> HTTPConnectionEngine? {
        let socket = AsyncSocket.wrapping(channel)
        let worker: HTTPServerWorker
        if responds(to: HTTPServerSelectors.wantsRunLoop) {
            // The server chooses the run loop, as the delegate of the SDK's
            // listening socket did; without one the connection is refused.
            typealias Choice = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<RunLoop>?
            let choose = unsafeBitCast(method(for: HTTPServerSelectors.wantsRunLoop), to: Choice.self)
            guard let runLoop = choose(self, HTTPServerSelectors.wantsRunLoop, nil, socket)?.takeUnretainedValue() else { return nil }
            socket.runLoop = runLoop
            worker = HTTPServerWorker(runLoop: runLoop.getCFRunLoop())
        } else {
            worker = HTTPServerSelectors.sharedWorker
        }
        socket.threadRunLoop = worker.runLoop
        socket.theRunLoop = worker.runLoop
        let connectionType = (connectionClass() as? HTTPConnection.Type) ?? HTTPConnection.self
        guard let connection = connectionType.init(asyncSocket: socket, for: self) else { return nil }
        let engine = HTTPConnectionEngine(channel: channel, handler: handler, worker: worker, delegate: connection) { [weak self, weak connection] _ in
            // The connection has told the servers already, unless a subclass
            // ended -die without its superclass's.
            if let connection { self?.forget(connection) }
        }
        connection.engine = engine
        socket.engine = engine
        connectionsLock.withLock {
            connections?.add(connection)
            engines[ObjectIdentifier(connection)] = engine
        }
        return engine
    }

    /// The TXT record of a dictionary whose values are strings or data.
    fileprivate static func txtRecordData(_ dictionary: [AnyHashable: Any]) -> Data {
        var record: [String: Data] = [:]
        for case let (key as String, value) in dictionary {
            if let text = value as? String {
                record[key] = Data(text.utf8)
            } else if let data = value as? Data {
                record[key] = data
            }
        }
        return NetService.data(fromTXTRecord: record)
    }
}

/// A server, for the listener's threads: they only ask it for a connection.
private final class HTTPServerReference: @unchecked Sendable {
    weak var server: HTTPServer?
    init(_ server: HTTPServer) { self.server = server }
}

private enum HTTPServerSelectors {
    /// The AsyncSocket delegate method by which a server chooses the run loop
    /// of each new connection.
    static let wantsRunLoop = NSSelectorFromString("onSocket:wantsRunLoopForNewSocket:")

    /// The thread of the connections of the servers that choose none: one for
    /// the life of the application, as a server's connections all ran on its
    /// own run loop.
    static let sharedWorker = HTTPServerWorker.detached(name: "HTTP server connections")
}
