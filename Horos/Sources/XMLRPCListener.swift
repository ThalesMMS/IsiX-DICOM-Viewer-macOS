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
import IsiXKeychain
import NIOCore

/// What the XML-RPC interface's connection (XMLRPCInterfaceConnection.swift)
/// does with its transport: it reads the request from the bytes received so far, answers through `XMLRPCTransport`, and closes itself
/// after its answer or its 10-second deadline.
@objc(IsiXXMLRPCServerConnection)
protocol XMLRPCServerConnection: NSObjectProtocol {
    /// Starts the connection's deadline, on its thread.
    func open()
    /// Every byte received so far, each time more arrive.
    @objc(handleData:) func handle(_ data: NSMutableData)
    func close()
    /// What was written has left.
    func connectionFinishedSendingData()
}

/// The network side of one XML-RPC connection, for its Objective-C connection.
@objc(IsiXXMLRPCTransport)
final class XMLRPCTransport: NSObject, @unchecked Sendable {
    /// The peer's IP address, which the access rules judge.
    @objc let peerAddress: String
    private let channel: Channel
    private let worker: HTTPServerWorker
    /// Set on the worker once the connection is made; read there only.
    fileprivate var connection: XMLRPCServerConnection?

    fileprivate init(channel: Channel, worker: HTTPServerWorker) {
        self.channel = channel
        self.worker = worker
        self.peerAddress = channel.remoteAddress?.ipAddress ?? ""
        super.init()
    }

    /// Sends `data`; once it has left, the connection hears of it on its thread.
    @objc(writeData:)
    func writeData(_ data: Data) {
        let channel = self.channel
        let worker = self.worker
        let transport = UncheckedSendableBox(self)
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(buffer).whenSuccess {
                worker.perform { transport.value.connection?.connectionFinishedSendingData() }
            }
        }
    }

    /// Closes the connection once what was written has left.
    @objc func close() {
        let channel = self.channel
        channel.eventLoop.execute {
            channel.flush()
            channel.close(promise: nil)
        }
    }
}

/// The XML-RPC interface's listener, over SwiftNIO, in HTTP or HTTPS with the
/// web server's Keychain identity. Each connection runs on a thread of its own,
/// as before: the methods it calls wait for the main thread, and one slow call
/// must not hold the others.
@objc(IsiXXMLRPCListener)
final class XMLRPCListener: NSObject, @unchecked Sendable {
    private static let errnoLock = NSLock()
    nonisolated(unsafe) private static var lastErrno: Int32 = 0

    /// The errno of the last listener that could not open its port.
    @objc static func lastBindErrno() -> Int32 {
        errnoLock.withLock { lastErrno }
    }

    /// The identity HTTPS presents, made the first time it is needed; nil
    /// when none could be read or made.
    @objc static func httpsIdentityAvailable() -> Bool {
        WebServerIdentity.identityAndChain() != nil
    }

    private var listener: HTTPServerListener?
    /// The port listened on: the one asked for, or the one given for 0.
    @objc private(set) var port: Int = 0

    /// Listens on `port` on every interface; nil when the port cannot be
    /// opened (see +lastBindErrno) or HTTPS has no identity.
    @objc init?(port: Int, https: Bool, makeConnection: @escaping (XMLRPCTransport) -> XMLRPCServerConnection?) {
        super.init()
        var tls: HTTPServerTLSIdentity?
        if https {
            guard let identity = WebServerIdentity.identityAndChain() else { return nil }
            tls = HTTPServerTLSIdentity(identity: identity.identity, chain: identity.chain)
        }
        let factory = UncheckedSendableBox(makeConnection)
        let listener = HTTPServerListener(port: port, tls: tls) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(XMLRPCChannelHandler(makeConnection: factory.value))
            }
        }
        do {
            self.port = try listener.start()
        } catch {
            let code = (error as? HTTPServerListener.BindFailure)?.errnoCode ?? 0
            Self.errnoLock.withLock { Self.lastErrno = code }
            return nil
        }
        self.listener = listener
    }

    /// Stops accepting connections.
    @objc func stop() {
        listener?.stop()
        listener = nil
    }

    deinit {
        listener?.stop()
    }
}

/// One XML-RPC connection on its event loop: the bytes go to the connection's
/// own thread as they arrive, with all those before them.
private final class XMLRPCChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let makeConnection: (XMLRPCTransport) -> XMLRPCServerConnection?
    private var worker: HTTPServerWorker?
    private var transport: XMLRPCTransport?
    private let received = UncheckedSendableBox(NSMutableData())

    init(makeConnection: @escaping (XMLRPCTransport) -> XMLRPCServerConnection?) {
        self.makeConnection = makeConnection
    }

    func channelActive(context: ChannelHandlerContext) {
        let worker = HTTPServerWorker.detached(name: "XML-RPC connection")
        let transport = XMLRPCTransport(channel: context.channel, worker: worker)
        self.worker = worker
        self.transport = transport
        let factory = UncheckedSendableBox(makeConnection)
        let box = UncheckedSendableBox(transport)
        let channel = context.channel
        worker.perform {
            guard let connection = factory.value(box.value) else {
                channel.close(promise: nil)
                return
            }
            box.value.connection = connection
            connection.open()
        }
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let worker, let transport, let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        let received = self.received
        let box = UncheckedSendableBox(transport)
        worker.perform {
            received.value.append(bytes, length: bytes.count)
            box.value.connection?.handle(received.value)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let worker, let transport {
            let box = UncheckedSendableBox(transport)
            worker.perform {
                box.value.connection?.close()
                box.value.connection = nil
            }
            worker.finish()
        }
        worker = nil
        transport = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
