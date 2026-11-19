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

/// The implementation of N2Connection, declared in N2Connection.h: the
/// connection of the plugin SDK of Horos and OsiriX, which N2XMLRPCConnection
/// descends from.
///
/// The class opened a pair of streams to an address, or took the pair a
/// listener had accepted, and moved bytes between them and two buffers. That
/// transport left the application: its listeners are SwiftNIO's, and they hand
/// a connection the bytes received and send what it writes. What is generic
/// stays here (the status and its notification, the options, the buffers, the
/// messages a subclass overrides), and a connection that is asked to open
/// streams closes with an error instead, which the log is told once.
@objc @implementation extension N2Connection {
    // The instance variables of the SDK, with its names and types: a plugin
    // built for it binds each name when it loads, and its subclass reads and
    // writes them directly, with no message. A buffer a plugin set to nil is
    // an empty one, as a message to nil answered.

    /// The host: a string, or an NSHost.
    final var _address: AnyObject?
    final var _port: Int = 0
    /// The streams, and what their events counted. There are none: nil and 0.
    final var _inputStream: InputStream?, _outputStream: OutputStream?
    final var _inputBuffer: NSMutableData? = NSMutableData(), _outputBuffer: NSMutableData? = NSMutableData()
    final var _handleOpenCompleted: UInt = 0, _maximumReadSizePerEvent: UInt = 0, _handleHasSpaceAvailable: UInt = 0, _outputBufferIndex: UInt = 0
    /// An N2ConnectionStatus. A plugin's direct write posts no notification.
    final var _status: Int = Int(N2ConnectionStatusClosed.rawValue)
    final var _tlsFlag: Bool = false
    final var _closeOnRemoteClose: Bool = false, _closeWhenDoneSending: Bool = false, _closeOnNextSpaceAvailable: Bool = false, _handlingData: Bool = false
    final var _error: NSError?
    /// The time of the last event of the streams; its name here is another
    /// because the read-only property of that name answers it.
    final var horos_lastEventTimeInterval: TimeInterval = 0
    /// Declared only by the header of an older SDK: what the last events of
    /// the streams said (bytes to read, room to write, the peer closing) and
    /// the timer that kept the connection's run loop turning while they were
    /// open. There are no streams: false and nil.
    final var _hasBytesAvailable: Bool = false, _hasSpaceAvailable: Bool = false, _handleConnectionClose: Bool = false
    final var _lifecycle: Timer?

    var lastEventTimeInterval: TimeInterval {
        horos_lastEventTimeInterval
    }

    var maximumReadSizePerEvent: UInt {
        get { _maximumReadSizePerEvent }
        set { _maximumReadSizePerEvent = newValue }
    }

    var closeOnRemoteClose: Bool {
        get { _closeOnRemoteClose }
        set { _closeOnRemoteClose = newValue }
    }

    var closeWhenDoneSending: Bool {
        get { _closeWhenDoneSending }
        set { _closeWhenDoneSending = newValue }
    }

    var closeOnNextSpaceAvailable: Bool {
        get { _closeOnNextSpaceAvailable }
        set { _closeOnNextSpaceAvailable = newValue }
    }

    private static let statusDidChange = Notification.Name("N2ConnectionStatusDidChangeNotification")

    private static func noTransport(_ selector: String) {
        FormerSDKFacade.inert("N2Connection", selector,
                              because: "the stream transport of the Nitrogen connections left the application; a connection that would open streams closes with an error")
    }

    // MARK: Synchronous requests

    @objc(sendSynchronousRequest:toAddress:port:)
    class func sendSynchronousRequest(_ request: Data!, toAddress address: Any!, port: Int) -> Data! {
        sendSynchronousRequest(request, toAddress: address, port: port, tls: false)
    }

    @objc(sendSynchronousRequest:toAddress:port:tls:)
    class func sendSynchronousRequest(_ request: Data!, toAddress address: Any!, port: Int, tls tlsFlag: Bool) -> Data! {
        sendSynchronousRequest(request, toAddress: address, port: port, tls: tlsFlag, dataHandlerTarget: nil, selector: nil, context: nil)
    }

    @objc(sendSynchronousRequest:toAddress:port:dataHandlerTarget:selector:context:)
    class func sendSynchronousRequest(_ request: Data!, toAddress address: Any!, port: Int, dataHandlerTarget target: Any!,
                                      selector: Selector!, context: UnsafeMutableRawPointer!) -> Data! {
        sendSynchronousRequest(request, toAddress: address, port: port, tls: false, dataHandlerTarget: target, selector: selector, context: context)
    }

    /// The request was sent over a connection of its own and the answer read
    /// until the peer closed. Nothing is sent now: the answer is nil, and the
    /// data handler is not called.
    @objc(sendSynchronousRequest:toAddress:port:tls:dataHandlerTarget:selector:context:)
    class func sendSynchronousRequest(_ request: Data!, toAddress address: Any!, port: Int, tls tlsFlag: Bool,
                                      dataHandlerTarget target: Any!, selector: Selector!, context: UnsafeMutableRawPointer!) -> Data! {
        noTransport("+sendSynchronousRequest:toAddress:port:tls:dataHandlerTarget:selector:context:")
        return nil
    }

    // MARK: Lifetime

    /// A closed connection with no address: what a subclass that carries the
    /// bytes itself starts from.
    override init() {
        super.init()
    }

    @objc(initWithAddress:port:)
    convenience init!(address: Any!, port: Int) {
        self.init(address: address, port: port, tls: false, is: nil, os: nil)
    }

    @objc(initWithAddress:port:is:os:)
    convenience init!(address: Any!, port: Int, is: InputStream!, os: OutputStream!) {
        self.init(address: address, port: port, tls: false, is: `is`, os: os)
    }

    @objc(initWithAddress:port:tls:)
    convenience init!(address: Any!, port: Int, tls tlsFlag: Bool) {
        self.init(address: address, port: port, tls: tlsFlag, is: nil, os: nil)
    }

    /// With streams, the connection took them and opened them; without, it
    /// connected to the address. Either way it now goes through -open, which a
    /// subclass may override, and ends closed.
    @objc(initWithAddress:port:tls:is:os:)
    init!(address: Any!, port: Int, tls tlsFlag: Bool, is: InputStream!, os: OutputStream!) {
        _address = address as AnyObject?
        _port = port
        _tlsFlag = tlsFlag
        super.init()

        if `is` != nil && os != nil {
            _status = Int(N2ConnectionStatusConnecting.rawValue)
            open()
        } else {
            reconnect()
        }
    }

    /// Why the connection closed, when it was not asked to.
    var error: (any Error)! {
        _error
    }

    var address: String! {
        if let host = _address as? Host {
            return host.address
        }
        return _address as? String
    }

    @objc(reconnectToAddress:port:)
    func reconnect(toAddress address: Any!, port: Int) {
        _address = address as AnyObject?
        _port = port
        reconnect()
    }

    func reconnect() {
        close()

        _inputBuffer?.length = 0
        _outputBuffer?.length = 0
        _outputBufferIndex = 0

        status = Int(N2ConnectionStatusConnecting.rawValue)

        open()
    }

    func startTLS() {
        _tlsFlag = true
        Self.noTransport("-startTLS")
    }

    /// Opened the streams. There are none: a connection that was connecting
    /// closes, with the reason in -error. A closed one, which is what a
    /// subclass with a transport of its own is, is left alone.
    func open() {
        guard _status != Int(N2ConnectionStatusClosed.rawValue) else { return }
        Self.noTransport("-open")
        _error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: [
            NSLocalizedDescriptionKey: "N2Connection has no stream transport in this application: the connection to \(address ?? "(null)"):\(_port) was not opened"])
        close()
    }

    func isSecure() -> Bool {
        _tlsFlag
    }

    var status: Int {
        get { _status }
        set {
            if newValue == _status {
                return
            }
            _status = newValue
            NotificationCenter.default.post(name: Self.statusDidChange, object: self)
        }
    }

    func close() {
        if _status == Int(N2ConnectionStatusClosed.rawValue) {
            return
        }
        status = Int(N2ConnectionStatusClosed.rawValue)

        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    // MARK: Bytes

    /// Everything received so far, for a subclass to read what it can of it.
    @objc(handleData:)
    func handle(_ data: NSMutableData!) {
    }

    /// Nothing sends what is waiting.
    func trySendingDataNow() {
    }

    /// What was written has left; for a subclass.
    func connectionFinishedSendingData() {
    }

    /// Keeps `data` to be sent, while the connection is not closed. A closed
    /// connection has nowhere to send it and drops it: a subclass that carries
    /// the bytes overrides this.
    @objc(writeData:)
    func write(_ data: Data!) {
        guard _status != Int(N2ConnectionStatusClosed.rawValue), let data else { return }
        if Int(_outputBufferIndex) == _outputBuffer?.length ?? 0 { // all data was sent, reset the send buffer
            _outputBuffer?.length = 0
            _outputBufferIndex = 0
        }
        _outputBuffer?.append(data)
    }

    func writeBufferSize() -> Int {
        (_outputBuffer?.length ?? 0) - Int(_outputBufferIndex)
    }

    func availableSize() -> Int {
        _inputBuffer?.length ?? 0
    }

    /// The first `size` bytes received, or all of them for 0, which leave the buffer.
    @objc(readData:)
    func readData(_ size: Int) -> Data! {
        let range = takenRange(size)
        let data = _inputBuffer?.subdata(with: range) ?? Data()
        _inputBuffer?.replaceBytes(in: range, withBytes: nil, length: 0)
        return data
    }

    @objc(readData:toBuffer:)
    func readData(_ size: Int, toBuffer buffer: UnsafeMutableRawPointer!) -> Int {
        let range = takenRange(size)
        if let buffer {
            _inputBuffer?.getBytes(buffer, range: range)
        }
        _inputBuffer?.replaceBytes(in: range, withBytes: nil, length: 0)
        return range.length
    }

    private final func takenRange(_ size: Int) -> NSRange {
        let available = _inputBuffer?.length ?? 0
        return NSRange(location: 0, length: size > 0 ? min(size, available) : available)
    }

    func readBuffer() -> Data! {
        _inputBuffer.map { $0 as Data } ?? Data()
    }

    // MARK: NSStreamDelegate

    /// The streams' events drove the connection. None is scheduled now; a
    /// subclass that sends this to super has the time of the event noted.
    @objc(stream:handleEvent:)
    func stream(_ stream: Stream, handle event: Stream.Event) {
        horos_lastEventTimeInterval = Date.timeIntervalSinceReferenceDate
    }
}
