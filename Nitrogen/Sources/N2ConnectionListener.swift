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

import Cocoa
import Darwin

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
fileprivate func n2ConnectionListenerDLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #else
    if N2Debug.isActive() { withVaList(arguments) { NSLogv(format, $0) } }
    #endif
}

/// The CFSocket accept callback. `info` is the listener, not retained (the
/// socket context has no retain callback), as before.
fileprivate func n2ConnectionListenerAccept(_ socket: CFSocket?, _ type: CFSocketCallBackType, _ address: CFData?,
                                            _ data: UnsafeRawPointer?, _ info: UnsafeMutableRawPointer?) {
    guard let info = info else { return }
    let listener = Unmanaged<N2ConnectionListener>.fromOpaque(info).takeUnretainedValue()
    if type != .acceptCallBack {
        return
    }

    // for an AcceptCallBack, the data parameter is a pointer to a CFSocketNativeHandle
    let nativeSocketHandle = data!.load(as: CFSocketNativeHandle.self)

    var name = [UInt8](repeating: 0, count: Int(SOCK_MAXADDRLEN))
    var namelen = socklen_t(name.count)
    var peer: Data? = nil
    let got = name.withUnsafeMutableBytes { bytes in
        getpeername(nativeSocketHandle, bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self), &namelen)
    }
    if got == 0 {
        peer = Data(name[0..<Int(namelen)])
    }

//    DLog(@"Accepting connection from %@", peer);

    var readStream: Unmanaged<CFReadStream>? = nil
    var writeStream: Unmanaged<CFWriteStream>? = nil
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle, &readStream, &writeStream)
    // Balances the create, as the CFRelease calls did.
    let read = readStream?.takeRetainedValue()
    let write = writeStream?.takeRetainedValue()
    if let read = read, let write = write {
        CFReadStreamSetProperty(read, CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        CFWriteStreamSetProperty(write, CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        listener.handleNewConnection(fromAddress: peer, inputStream: read as InputStream, outputStream: write as OutputStream)
    } else {
        close(nativeSocketHandle)
    }
}

/// Listens on a TCP port (IPv4 and IPv6) or a local socket path, and opens a
/// connection of the given N2Connection class for each client.
///
/// Implemented in Swift since #710: the Objective-C name, the selectors and
/// <Horos/N2ConnectionListener.h> are those of the former class. N2Connection
/// stays in Objective-C.
@objc(N2ConnectionListener)
public final class N2ConnectionListener: NSObject {
    /// errno of the last failed bind, or 0 after a successful init.
    private static var sLastBindErrno: Int32 = 0

    private static func recordBindFailure() {
        sLastBindErrno = errno
        if sLastBindErrno == 0 {
            sLastBindErrno = EADDRINUSE
        }
    }

    private let connectionClass: AnyClass
    private var ipv4socket: CFSocket?
    private var ipv6socket: CFSocket?
    private let clients = NSMutableArray()

    /// Atomic in the former header; a Bool is read and written as one byte.
    @objc public var threadPerConnection: Bool = false

    // errno of the last failed bind, or 0 after a successful init. The instance
    // is gone when init returns nil, so callers have to ask the class.
    @objc public static func lastBindErrno() -> Int32 {
        return sLastBindErrno
    }

    @objc(initWithPort:connectionClass:)
    public convenience init?(port: Int, connectionClass classs: AnyClass) {
        self.init(port: port, loopbackOnly: false, connectionClass: classs)
    }

    // Binds 127.0.0.1 and ::1 instead of INADDR_ANY, so the port is reachable only
    // from this machine. A listener publishing anything worth a credential should
    // be explicit about which of the two it wants.
    @objc(initWithPort:loopbackOnly:connectionClass:)
    public init?(port: Int, loopbackOnly: Bool, connectionClass classs: AnyClass) {
        connectionClass = classs
        super.init()
        N2ConnectionListener.sLastBindErrno = 0

        NotificationCenter.default.addObserver(self, selector: #selector(connectionStatusDidChange(_:)),
                                               name: .N2ConnectionStatusDidChange, object: nil)

        var socketCtxt = CFSocketContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                         retain: nil, release: nil, copyDescription: nil)
        ipv4socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP,
                                    CFSocketCallBackType.acceptCallBack.rawValue, n2ConnectionListenerAccept, &socketCtxt)
        ipv6socket = CFSocketCreate(kCFAllocatorDefault, PF_INET6, SOCK_STREAM, IPPROTO_TCP,
                                    CFSocketCallBackType.acceptCallBack.rawValue, n2ConnectionListenerAccept, &socketCtxt)
        guard let ipv4socket = ipv4socket, let ipv6socket = ipv6socket else {
            NSException(name: .genericException, reason: "Could not create listening sockets.", userInfo: nil).raise()
            return nil
        }
        var yes: Int32 = 1
        setsockopt(CFSocketGetNative(ipv4socket), SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(CFSocketGetNative(ipv6socket), SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var port = port

        // set up the IPv4 endpoint; if port is 0, this will cause the kernel to choose a port for us
        var addr4 = sockaddr_in()
        addr4.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr4.sin_family = sa_family_t(AF_INET)
        addr4.sin_port = in_port_t(truncatingIfNeeded: port).bigEndian
        // INADDR_LOOPBACK (127.0.0.1) or INADDR_ANY (0.0.0.0), in network order
        addr4.sin_addr.s_addr = (loopbackOnly ? UInt32(0x7f000001) : UInt32(0)).bigEndian
        let address4 = Data(bytes: &addr4, count: MemoryLayout<sockaddr_in>.size)

        if CFSocketSetAddress(ipv4socket, address4 as CFData) != .success {
            // if (error) *error = [[NSError alloc] initWithDomain:TCPServerErrorDomain code:kTCPServerCouldNotBindToIPv4Address userInfo:nil];
            N2ConnectionListener.recordBindFailure()
            self.ipv4socket = nil
            self.ipv6socket = nil
            return nil
        }

        if port == 0 {
            // now that the binding was successful, we get the port number
            // -- we will need it for the v6 endpoint and for the NSNetService
            port = Int(self.port())
            NSLog("Warning: listening on port %d", Int32(truncatingIfNeeded: port))
        }

        // set up the IPv6 endpoint
        var addr6 = sockaddr_in6()
        addr6.sin6_len = __uint8_t(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = in_port_t(truncatingIfNeeded: port).bigEndian
        addr6.sin6_addr = loopbackOnly ? in6addr_loopback : in6addr_any
        let address6 = Data(bytes: &addr6, count: MemoryLayout<sockaddr_in6>.size)

        if CFSocketSetAddress(ipv6socket, address6 as CFData) != .success {
            // if (error) *error = [[NSError alloc] initWithDomain:TCPServerErrorDomain code:kTCPServerCouldNotBindToIPv6Address userInfo:nil];
            N2ConnectionListener.recordBindFailure()
            self.ipv4socket = nil
            self.ipv6socket = nil
            return nil
        }

        // set up the run loop sources for the sockets
        let cfrl = CFRunLoopGetCurrent()
        let source4 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, ipv4socket, 0)
        CFRunLoopAddSource(cfrl, source4, .commonModes)

        let source6 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, ipv6socket, 0)
        CFRunLoopAddSource(cfrl, source6, .commonModes)

        N2ConnectionListener.sLastBindErrno = 0
    }

    @objc(initWithPath:connectionClass:)
    public init?(path: String, connectionClass classs: AnyClass) {
        connectionClass = classs
        super.init()
        N2ConnectionListener.sLastBindErrno = 0

        NotificationCenter.default.addObserver(self, selector: #selector(connectionStatusDidChange(_:)),
                                               name: .N2ConnectionStatusDidChange, object: nil)

        var socketCtxt = CFSocketContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                         retain: nil, release: nil, copyDescription: nil)
        ipv4socket = CFSocketCreate(kCFAllocatorDefault, PF_LOCAL, SOCK_STREAM, IPPROTO_IP,
                                    CFSocketCallBackType.acceptCallBack.rawValue, n2ConnectionListenerAccept, &socketCtxt)
        guard let ipv4socket = ipv4socket else {
            NSException(name: .genericException, reason: "Could not create listening socket.", userInfo: nil).raise()
            return nil
        }

        var yes: Int32 = 1
        setsockopt(CFSocketGetNative(ipv4socket), SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // set up the IPv4 endpoint; if port is 0, this will cause the kernel to choose a port for us
        var local = sockaddr_un()
        local.sun_family = sa_family_t(AF_LOCAL)
        withUnsafeMutableBytes(of: &local.sun_path) { sunPath in
            let utf8 = Array(path.utf8.prefix(103))
            sunPath.copyBytes(from: utf8) // strncpy(local.sun_path, [path UTF8String], 103)
            sunPath[103] = 0
            unlink(sunPath.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let address = Data(bytes: &local, count: MemoryLayout<sockaddr_un>.size)

        if CFSocketSetAddress(ipv4socket, address as CFData) != .success {
            // if (error) *error = [[NSError alloc] initWithDomain:TCPServerErrorDomain code:kTCPServerCouldNotBindToIPv4Address userInfo:nil];
            N2ConnectionListener.recordBindFailure()
            self.ipv4socket = nil
            self.ipv6socket = nil
            return nil
        }

        // set up the run loop sources for the sockets
        let cfrl = CFRunLoopGetCurrent()
        let source4 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, ipv4socket, 0)
        CFRunLoopAddSource(cfrl, source4, .commonModes)

        // As before, a path listener has no IPv6 socket, and the former code
        // still asked CFSocketCreateRunLoopSource for one: it stops here, as it
        // did in Objective-C. Kept unchanged by the migration (#710).
        let source6 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, ipv6socket!, 0)
        CFRunLoopAddSource(cfrl, source6, .commonModes)

        N2ConnectionListener.sLastBindErrno = 0
    }

    deinit {
        n2ConnectionListenerDLog("[N2ConnectionListener dealloc]")
        NotificationCenter.default.removeObserver(self)

        if let ipv4socket = ipv4socket {
            CFSocketInvalidate(ipv4socket)
        }

        if let ipv6socket = ipv6socket {
            CFSocketInvalidate(ipv6socket)
        }
    }

    /// Called by the accept callback, formerly by message.
    @objc(handleNewConnectionFromAddress:inputStream:outputStream:)
    func handleNewConnection(fromAddress addr: Data?, inputStream istr: InputStream, outputStream ostr: OutputStream) {
        var address: String? = nil
        if let addr = addr {
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { bytes in
                _ = addr.copyBytes(to: bytes.bindMemory(to: UInt8.self))
            }
            switch Int32(storage.ss_family) {
            case AF_INET:
                var tmp = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sain in
                        var s_addr = sain.pointee.sin_addr.s_addr
                        _ = inet_ntop(AF_INET, &s_addr, &tmp, socklen_t(tmp.count))
                    }
                }
                address = String(cString: tmp)
            case AF_INET6:
                var tmp = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sain6 in
                        var sin6_addr = sain6.pointee.sin6_addr
                        _ = inet_ntop(AF_INET6, &sin6_addr, &tmp, socklen_t(tmp.count))
                    }
                }
                address = String(cString: tmp)
            default:
                break
            }
        }

        n2ConnectionListenerDLog("Handling new connection from %@", (address as NSString?) ?? ("(null)" as NSString))

        if threadPerConnection {
            // +arrayWithObjects: stopped at a nil address, and the thread then
            // failed on -objectAtIndex:2: that is kept.
            let args = NSMutableArray(objects: istr, ostr)
            if let address = address { args.add(address) }
            performSelector(inBackground: #selector(_threadHandleNewConnection(_:)), with: NSArray(array: args))
        } else {
            let connection = N2ConnectionListener.makeConnection(connectionClass, address: address, is: istr, os: ostr)

            objc_sync_enter(clients)
            clients.add(connection)
            objc_sync_exit(clients)

            NotificationCenter.default.post(name: .N2ConnectionListenerOpenedConnection,
                                            object: self,
                                            userInfo: [N2ConnectionListenerOpenedConnection: connection])
        }
    }

    /// [[_class alloc] initWithAddress:address port:0 is:istr os:ostr]: the
    /// class is given by the caller (N2Connection or a subclass).
    private static func makeConnection(_ connectionClass: AnyClass, address: String?, is istr: InputStream, os ostr: OutputStream) -> N2Connection {
        return (connectionClass as! N2Connection.Type).init(address: address, port: 0, is: istr, os: ostr)
    }

    /// Runs on its own thread (performSelectorInBackground:).
    @objc(_threadHandleNewConnection:)
    func _threadHandleNewConnection(_ args: NSArray) {
        autoreleasepool {
            // Holds the connection until the thread is done with it, as the
            // @finally release did, also when an exception ends the loop.
            var c: N2Connection? = nil
            do {
                try HorosObjCException.perform {
                    let istr = args.object(at: 0) as! InputStream
                    let ostr = args.object(at: 1) as! OutputStream
                    let address = args.object(at: 2) as? String

                    c = N2ConnectionListener.makeConnection(self.connectionClass, address: address, is: istr, os: ostr)

                    objc_sync_enter(self.clients)
                    self.clients.add(c!)
                    objc_sync_exit(self.clients)

                    NotificationCenter.default.post(name: .N2ConnectionListenerOpenedConnection,
                                                    object: self,
                                                    userInfo: [N2ConnectionListenerOpenedConnection: c!])

                    while c!.status != Int(N2ConnectionStatusClosed.rawValue) {
                        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
                    }
                }
            } catch {
                // N2LogExceptionWithStackTrace(e)
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, true, "-[N2ConnectionListener _threadHandleNewConnection:]")
                }
            }
        }
    }

    /// Observer of N2ConnectionStatusDidChangeNotification.
    @objc(connectionStatusDidChange:)
    func connectionStatusDidChange(_ notification: Notification) {
        let connection = notification.object as? N2Connection
        switch connection?.status ?? 0 {
        case Int(N2ConnectionStatusClosed.rawValue):
            connection?.close()
            if let connection = connection {
                objc_sync_enter(clients)
                clients.remove(connection)
                objc_sync_exit(clients)
            }
        default:
            break
        }
    }

    @objc public func port() -> in_port_t {
        guard let ipv4socket = ipv4socket, let addr = CFSocketCopyAddress(ipv4socket) as Data? else { return 0 }
        // The former code copied the whole address into a sockaddr_in; the
        // port is read from the same bytes.
        var addr4 = sockaddr_in()
        withUnsafeMutableBytes(of: &addr4) { bytes in
            _ = addr.copyBytes(to: bytes.bindMemory(to: UInt8.self))
        }
        return in_port_t(bigEndian: addr4.sin_port)
    }
}
