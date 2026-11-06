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
import Network
import NIOCore
import NIOTransportServices
import Security

/// The identity an HTTPS listener presents, with the chain its peers are shown.
struct HTTPServerTLSIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let chain: [SecCertificate]

    /// The TLS options of a listener that presents this identity. Network.framework
    /// signs with the Keychain's own key, which may not be exportable. The
    /// identity's certificate goes first by itself; the rest of the chain
    /// (its issuers) follows it.
    func listenerOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)
        let issuers = chain.filter { certificate in leaf.map { !CFEqual($0, certificate) } ?? true }
        let secIdentity: sec_identity_t?
        if issuers.isEmpty {
            secIdentity = sec_identity_create(identity)
        } else {
            secIdentity = sec_identity_create_with_certificates(identity, issuers as CFArray)
        }
        if let secIdentity {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        }
        return options
    }
}

/// A TCP listener of the app's HTTP servers (the web portal and XML-RPC),
/// over SwiftNIO and Network.framework: on every interface, IPv4 and IPv6,
/// in plain HTTP or in TLS with a Keychain identity. Each accepted connection
/// gets the pipeline `childInitializer` makes.
final class HTTPServerListener: @unchecked Sendable {
    /// A listener that could not open its port.
    struct BindFailure: Error, CustomStringConvertible {
        /// The POSIX error, 0 when the failure was not one.
        let errnoCode: Int32
        let underlying: Error
        var description: String { String(describing: underlying) }
    }

    private let port: Int
    private let tls: HTTPServerTLSIdentity?
    private let childInitializer: @Sendable (Channel) -> EventLoopFuture<Void>
    private let lock = NSLock()
    private var channel: Channel?

    init(port: Int, tls: HTTPServerTLSIdentity?, childInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) {
        self.port = port
        self.tls = tls
        self.childInitializer = childInitializer
    }

    /// The event loops of every listener and connection of the app.
    static let group = NIOTSEventLoopGroup(loopCount: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount)))

    /// Opens the port and starts accepting; answers the port opened, which is
    /// the one asked for unless that was 0. Waits for the port to open.
    @discardableResult
    func start() throws -> Int {
        var bootstrap = NIOTSListenerBootstrap(group: Self.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer(childInitializer)
        if let tls {
            bootstrap = bootstrap.tlsOptions(tls.listenerOptions())
        }
        do {
            let channel = try bootstrap.bind(host: "::", port: port).wait()
            lock.withLock { self.channel = channel }
            return channel.localAddress?.port ?? port
        } catch {
            throw BindFailure(errnoCode: Self.errnoCode(of: error), underlying: error)
        }
    }

    /// Stops accepting connections; those already open go on.
    func stop() {
        let channel = lock.withLock { () -> Channel? in
            defer { self.channel = nil }
            return self.channel
        }
        channel?.close(promise: nil)
    }

    static func errnoCode(of error: Error) -> Int32 {
        if let error = error as? NWError, case .posix(let code) = error {
            return code.rawValue
        }
        if let error = error as? IOError {
            return error.errnoCode
        }
        return 0
    }
}

/// The thread a connection's application code runs on: a thread with a run
/// loop, which takes blocks from other threads in its default mode.
final class HTTPServerWorker: @unchecked Sendable {
    let runLoop: CFRunLoop

    init(runLoop: CFRunLoop) {
        self.runLoop = runLoop
    }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// A thread of its own, with a run loop that runs until `finish()`.
    static func detached(name: String) -> HTTPServerWorker {
        let ready = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var runLoop: CFRunLoop? }
        let box = Box()
        let thread = Thread {
            Thread.current.name = name
            box.runLoop = CFRunLoopGetCurrent()
            // A source that never fires keeps the run loop waiting for blocks.
            var context = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        ready.wait()
        return HTTPServerWorker(runLoop: box.runLoop!)
    }

    /// Ends a detached worker's run loop, after the blocks already given to it.
    func finish() {
        let runLoop = self.runLoop
        perform { CFRunLoopStop(runLoop) }
    }
}
