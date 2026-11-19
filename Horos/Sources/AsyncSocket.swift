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

//
//  AsyncSocket.m
//  
//  This class is in the public domain.
//  Originally created by Dustin Voss on Wed Jan 29 2003.
//  Updated and maintained by Deusty Designs and the Mac development community.
//
//  http://code.google.com/p/cocoaasyncsocket/
//

import Foundation
import NIOCore

/// The implementation of AsyncSocket, declared in AsyncSocket.h: the socket of
/// the Horos and OsiriX SDK's HTTP server. The class is Objective-C for the
/// runtime, so that a plugin built for either SDK finds it by name.
///
/// The application's HTTP server is SwiftNIO's. A socket the server makes for
/// one of its connections wraps that connection's channel: it answers the
/// addresses of its two ends, whether it is connected, and disconnects. The
/// connection's exchange does the reading and the writing, so the read and
/// write requests, the streams, TLS and the run loop scheduling do nothing
/// and say so once in the log. A socket made any other way is never
/// connected, and accepting or connecting answers NO with an error.
@objc @implementation extension AsyncSocket {
    // The instance variables of the SDK, with its types: a plugin built for
    // it binds each name when it loads and reads and writes them directly,
    // with no message.

    /// The native sockets, the transport over them, the CFSockets, the
    /// streams, their run loop sources and the context they were made with.
    /// A socket here is a SwiftNIO channel and has none of them: zero and nil.
    final var theNativeSocket4: CFSocketNativeHandle = 0, theNativeSocket6: CFSocketNativeHandle = 0
    final var theNativeSocketIsOurs: Bool = false, theNativeTransport: Bool = false, theNativeTransportOpen: Bool = false, theNativeWriteBlocked: Bool = false
    final var theNativeOpenGeneration: UInt = 0
    final var theNativeTLSContext: UnsafeMutableRawPointer?
    final var theNativeTransportError: NSError?
    final var theSocket4: CFSocket?, theSocket6: CFSocket?
    final var theReadStream: CFReadStream?
    final var theWriteStream: CFWriteStream?
    final var theSource4: CFRunLoopSource?, theSource6: CFRunLoopSource?
    /// The run loop as the SDK kept it, not retained: a copy of threadRunLoop,
    /// written with it. Nothing here reads it.
    unowned(unsafe) final var theRunLoop: CFRunLoop?
    final var theContext = CFSocketContext()
    final var theRunLoopModes: NSArray?
    /// The queues of the reads and of the writes asked for, the one under
    /// way, its timer and what was read ahead. The connection's exchange
    /// reads and writes: nil. The SDK did not retain its timers.
    unowned(unsafe) final var theConnectTimer: Timer?
    final var theReadQueue: NSMutableArray?
    final var theCurrentRead: AnyObject?
    unowned(unsafe) final var theReadTimer: Timer?
    final var partialReadBuffer: NSMutableData?
    final var theWriteQueue: NSMutableArray?
    final var theCurrentWrite: AnyObject?
    unowned(unsafe) final var theWriteTimer: Timer?
    /// The delegate as the SDK kept it, not retained: a copy of
    /// delegateReference, written with it. Nothing here reads it.
    unowned(unsafe) final var theDelegate: AnyObject?
    final var theFlags: UInt16 = 0
    final var theUserData: Int = 0

    /// Unretained in the SDK; weak here, so that it never dangles.
    final weak var delegateReference: AnyObject?
    /// The channel of the connection this socket stands for.
    final var channel: Channel?
    /// The exchange of that connection, which closes it once its writes have left.
    final weak var engine: HTTPConnectionEngine?
    /// The run loop of the thread the connection's code runs on.
    final var threadRunLoop: CFRunLoop?
    /// That run loop as its server chose it, when the server chooses.
    final var runLoop: RunLoop?

    public override init() {
        super.init()
    }

    public init!(delegate: Any!) {
        delegateReference = delegate as AnyObject?
        theDelegate = delegate as AnyObject?
        super.init()
    }

    public init!(delegate: Any!, userData: Int) {
        delegateReference = delegate as AnyObject?
        theDelegate = delegate as AnyObject?
        theUserData = userData
        super.init()
    }

    public override var description: String {
        let address = Unmanaged.passUnretained(self).toOpaque()
        guard let channel, channel.isActive else { return "<AsyncSocket \(address): not connected>" }
        return "<AsyncSocket \(address) local \(localHost() ?? "nowhere"):\(localPort()) remote \(connectedHost() ?? "nowhere"):\(connectedPort())>"
    }

    func delegate() -> Any! {
        delegateReference
    }

    /// Nothing is ever pending for the delegate: the exchange reads and writes.
    func canSafelySetDelegate() -> Bool {
        true
    }

    func setDelegate(_ delegate: Any!) {
        delegateReference = delegate as AnyObject?
        theDelegate = delegate as AnyObject?
    }

    func userData() -> Int {
        theUserData
    }

    func setUserData(_ userData: Int) {
        theUserData = userData
    }

    // MARK: What the channel has no counterpart for

    func getCFSocket() -> Unmanaged<CFSocket>! {
        Self.inert("-getCFSocket", "a connection is a SwiftNIO channel and has no CFSocket")
        return nil
    }

    func getCFReadStream() -> Unmanaged<CFReadStream>! {
        Self.inert("-getCFReadStream", "a connection is a SwiftNIO channel and has no CFReadStream")
        return nil
    }

    func getCFWriteStream() -> Unmanaged<CFWriteStream>! {
        Self.inert("-getCFWriteStream", "a connection is a SwiftNIO channel and has no CFWriteStream")
        return nil
    }

    // MARK: Accepting and connecting

    func accept(onPort port: UInt16) throws {
        throw Self.unavailable("-acceptOnPort:error:")
    }

    func accept(onInterface interface: String!, port: UInt16) throws {
        throw Self.unavailable("-acceptOnInterface:port:error:")
    }

    func connect(toHost hostname: String!, onPort port: UInt16) throws {
        throw Self.unavailable("-connectToHost:onPort:error:")
    }

    func connect(toHost hostname: String!, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        throw Self.unavailable("-connectToHost:onPort:withTimeout:error:")
    }

    func connect(toAddress remoteAddr: Data!) throws {
        throw Self.unavailable("-connectToAddress:error:")
    }

    func connect(toAddress remoteAddr: Data!, withTimeout timeout: TimeInterval) throws {
        throw Self.unavailable("-connectToAddress:withTimeout:error:")
    }

    func connect(toAddress remoteAddr: Data!, viaInterfaceAddress interfaceAddr: Data!, withTimeout timeout: TimeInterval) throws {
        throw Self.unavailable("-connectToAddress:viaInterfaceAddress:withTimeout:error:")
    }

    // MARK: Disconnecting

    /// Closes the connection now.
    func disconnect() {
        channel?.close(promise: nil)
    }

    /// Nothing is ever being read for the delegate: the same as -disconnect.
    func disconnectAfterReading() {
        channel?.close(promise: nil)
    }

    /// Closes the connection once what the exchange has written has left.
    func disconnectAfterWriting() {
        if let engine {
            engine.closeConnection()
        } else {
            channel?.close(promise: nil)
        }
    }

    func disconnectAfterReadingAndWriting() {
        disconnectAfterWriting()
    }

    // MARK: The two ends

    func isConnected() -> Bool {
        channel?.isActive ?? false
    }

    func connectedHost() -> String! {
        channel?.remoteAddress?.ipAddress
    }

    func connectedPort() -> UInt16 {
        UInt16(truncatingIfNeeded: channel?.remoteAddress?.port ?? 0)
    }

    func localHost() -> String! {
        channel?.localAddress?.ipAddress
    }

    func localPort() -> UInt16 {
        UInt16(truncatingIfNeeded: channel?.localAddress?.port ?? 0)
    }

    /// The peer's address as a sockaddr.
    func connectedAddress() -> Data! {
        Self.socketAddressData(channel?.remoteAddress)
    }

    func localAddress() -> Data! {
        Self.socketAddressData(channel?.localAddress)
    }

    func isIPv4() -> Bool {
        if case .v4 = channel?.localAddress { return true }
        return false
    }

    func isIPv6() -> Bool {
        if case .v6 = channel?.localAddress { return true }
        return false
    }

    // MARK: Reading and writing

    func readData(withTimeout timeout: TimeInterval, tag: Int) {
        Self.inertRead("-readDataWithTimeout:tag:")
    }

    func readData(withTimeout timeout: TimeInterval, buffer: NSMutableData!, bufferOffset offset: UInt, tag: Int) {
        Self.inertRead("-readDataWithTimeout:buffer:bufferOffset:tag:")
    }

    func readData(withTimeout timeout: TimeInterval, buffer: NSMutableData!, bufferOffset offset: UInt, maxLength length: UInt, tag: Int) {
        Self.inertRead("-readDataWithTimeout:buffer:bufferOffset:maxLength:tag:")
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        Self.inertRead("-readDataToLength:withTimeout:tag:")
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, buffer: NSMutableData!, bufferOffset offset: UInt, tag: Int) {
        Self.inertRead("-readDataToLength:withTimeout:buffer:bufferOffset:tag:")
    }

    @objc(readDataToData:withTimeout:tag:)
    func readData(to data: Data!, withTimeout timeout: TimeInterval, tag: Int) {
        Self.inertRead("-readDataToData:withTimeout:tag:")
    }

    @objc(readDataToData:withTimeout:buffer:bufferOffset:tag:)
    func readData(to data: Data!, withTimeout timeout: TimeInterval, buffer: NSMutableData!, bufferOffset offset: UInt, tag: Int) {
        Self.inertRead("-readDataToData:withTimeout:buffer:bufferOffset:tag:")
    }

    @objc(readDataToData:withTimeout:maxLength:tag:)
    func readData(to data: Data!, withTimeout timeout: TimeInterval, maxLength length: UInt, tag: Int) {
        Self.inertRead("-readDataToData:withTimeout:maxLength:tag:")
    }

    @objc(readDataToData:withTimeout:buffer:bufferOffset:maxLength:tag:)
    func readData(to data: Data!, withTimeout timeout: TimeInterval, buffer: NSMutableData!, bufferOffset offset: UInt, maxLength length: UInt, tag: Int) {
        Self.inertRead("-readDataToData:withTimeout:buffer:bufferOffset:maxLength:tag:")
    }

    @objc(writeData:withTimeout:tag:)
    func write(_ data: Data!, withTimeout timeout: TimeInterval, tag: Int) {
        Self.inert("-writeData:withTimeout:tag:", "the connection's HTTP exchange writes its answers")
    }

    /// No read is ever under way: NaN, as the SDK answered then, and the
    /// three values are left as they are.
    func progress(ofReadReturningTag tag: UnsafeMutablePointer<Int>!, bytesDone done: UnsafeMutablePointer<UInt>!, total: UnsafeMutablePointer<UInt>!) -> Float {
        .nan
    }

    func progress(ofWriteReturningTag tag: UnsafeMutablePointer<Int>!, bytesDone done: UnsafeMutablePointer<UInt>!, total: UnsafeMutablePointer<UInt>!) -> Float {
        .nan
    }

    func startTLS(_ tlsSettings: [AnyHashable: Any]!) {
        Self.inert("-startTLS:", "TLS belongs to the listener, which presents the web server's identity")
    }

    func enablePreBuffering() {
    }

    // MARK: Run loops

    @objc(moveToRunLoop:)
    func move(to runLoop: RunLoop!) -> Bool {
        Self.inert("-moveToRunLoop:", "the server chooses the thread of a connection when it accepts it")
        return false
    }

    /// The run loop of the connection's thread; NULL for a socket that is not connected.
    func runLoopRef() -> Unmanaged<CFRunLoop>! {
        threadRunLoop.map { Unmanaged.passUnretained($0) }
    }

    func setRunLoopModes(_ runLoopModes: [Any]!) -> Bool {
        Self.inert("-setRunLoopModes:", "a connection's code runs in the default mode of its thread's run loop")
        return false
    }

    func addRunLoopMode(_ runLoopMode: String!) -> Bool {
        Self.inert("-addRunLoopMode:", "a connection's code runs in the default mode of its thread's run loop")
        return false
    }

    func removeRunLoopMode(_ runLoopMode: String!) -> Bool {
        Self.inert("-removeRunLoopMode:", "a connection's code runs in the default mode of its thread's run loop")
        return false
    }

    func runLoopModes() -> [Any]! {
        [RunLoop.Mode.default.rawValue]
    }

    /// Nothing is read ahead for the delegate.
    func unreadData() -> Data! {
        nil
    }

    // MARK: Line separators

    @objc(CRLFData)
    class func crlfData() -> Data! {
        Data([0x0D, 0x0A])
    }

    @objc(CRData)
    class func crData() -> Data! {
        Data([0x0D])
    }

    @objc(LFData)
    class func lfData() -> Data! {
        Data([0x0A])
    }

    @objc(ZeroData)
    class func zeroData() -> Data! {
        Data([0x00])
    }
}

extension AsyncSocket {
    /// The socket of a connection the server accepted.
    static func wrapping(_ channel: Channel) -> AsyncSocket {
        let socket: AsyncSocket = AsyncSocket(delegate: nil, userData: 0)
        socket.channel = channel
        return socket
    }

    fileprivate static func inert(_ selector: String, _ reason: String) {
        FormerSDKFacade.inert("AsyncSocket", selector, because: reason)
    }

    fileprivate static func inertRead(_ selector: String) {
        inert(selector, "the connection's HTTP exchange reads its requests")
    }

    /// Why a socket of this class neither listens nor connects.
    fileprivate static func unavailable(_ selector: String) -> NSError {
        inert(selector, "the application's HTTP server listens through SwiftNIO; a socket only stands for one of its connections")
        return NSError(domain: AsyncSocketErrorDomain, code: Int(AsyncSocketCFSocketError.rawValue), userInfo: [
            NSLocalizedDescriptionKey: "AsyncSocket neither listens nor connects in this application: the HTTP server makes the sockets of its own connections.",
        ])
    }

    /// The bytes of the sockaddr of `address`.
    fileprivate static func socketAddressData(_ address: SocketAddress?) -> Data? {
        switch address {
        case .v4(let v4):
            return withUnsafeBytes(of: v4.address) { Data($0) }
        case .v6(let v6):
            return withUnsafeBytes(of: v6.address) { Data($0) }
        default:
            return nil
        }
    }
}
