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
import CoreData

// BY DEFAULT OSIRIX USES 8780 PORT

/// Shares DB with Bonjour
@objc(BonjourPublisher)
public final class BonjourPublisher: NSObject, NetServiceDelegate, HorosDatabaseServerDelegate {
    private var _listener: HorosDatabaseServer? // the Network.framework listener (#615)

    private var _bonjour: NetService?
    private var _advertisement: BonjourAdvertisement?

    private var dicomSendLock: NSLock?

    //@property(retain) NSString* serviceName;
    //@property(retain, readonly) NSNetService* netService;

    @available(*, deprecated, message: "use -[[AppController sharedAppController] bonjourPublisher]")
    @objc(currentPublisher)
    public class func currentPublisher() -> BonjourPublisher? {
        return AppController.shared()?.bonjourPublisher
    }

    public override init() {
        super.init()
        let controller = NSUserDefaultsController.shared
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingIsActiveDefaultsKey, options: .initial, context: nil)
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingNameDefaultsKey, options: .initial, context: nil)
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingIsPasswordProtectedDefaultsKey, options: .initial, context: nil)
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingPasswordDefaultsKey, options: .initial, context: nil)
    }

    deinit {
        let controller = NSUserDefaultsController.shared
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingIsActiveDefaultsKey)
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingNameDefaultsKey)
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingIsPasswordProtectedDefaultsKey)
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingPasswordDefaultsKey)

        dicomSendLock = nil
        //	self.serviceName = NULL;

        _listener?.delegate = nil
        _listener?.stop()
        _listener = nil
        // The advertisement is the main queue's (BonjourDiscovery.swift).
        if let advertisement = _advertisement { onMainActor { advertisement.stop() } }
        _advertisement = nil
        _bonjour = nil
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        var keyPath = keyPath
        if (object as AnyObject?) === NSUserDefaultsController.shared {
            keyPath = keyPath.map { ($0 as NSString).substring(from: 7) }
            if Self.isEqual(keyPath, OsirixBonjourSharingIsActiveDefaultsKey) {
                toggleSharing(UserDefaults.bonjourSharingIsActive())
                return
            } else if Self.isEqual(keyPath, OsirixBonjourSharingNameDefaultsKey) {
                // The advertisement carries the name: a new one replaces it (-updateBonjour).
                updateBonjour()
                return
            } else if Self.isEqual(keyPath, OsirixBonjourSharingIsPasswordProtectedDefaultsKey) {
                return
            } else if Self.isEqual(keyPath, OsirixBonjourSharingPasswordDefaultsKey) {
                return
            }
        }

        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    /// -[NSString isEqualToString:]: a literal comparison, and NO for nil.
    private static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }

    @available(*, deprecated, message: "use -[[[AppController sharedAppController] bonjourPublisher] port]")
    @objc(OsiriXDBCurrentPort)
    public func osiriXDBCurrentPort() -> Int32 {
        return Int32(truncatingIfNeeded: _listener?.port ?? 0)
    }

    @objc(toggleSharing:)
    public func toggleSharing(_ activate: Bool) {
        if activate && ProtectedMode.isActive {
            ProtectedMode.skip("Bonjour database sharing")
            return
        }
        do {
            try HorosObjCException.perform {
                if activate && self._listener == nil {
                    // The listener reports ready or failed on the main queue; the advertisement is published
                    // only once it is ready (-databaseServerDidStart:), never for a port nothing listens on.
                    let listener = HorosDatabaseServer(port: 8780) { peer in
                        O2DatabaseConnection.serve(peer)
                    }
                    self._listener = listener
                    listener.delegate = self
                    listener.start()
                }

                if !activate, let listener = self._listener {
                    listener.delegate = nil
                    listener.stop()
                    self._listener = nil
                }

                self.updateBonjour()
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[BonjourPublisher toggleSharing:]")
            }
        }
    }

    public func databaseServerDidStart(_ server: HorosDatabaseServer) {
        if server !== _listener { return } // a stopped server's late callback
        NSLog("Horos database shared on port %ld", server.port)
        updateBonjour()
    }

    public func databaseServer(_ server: HorosDatabaseServer, didFailWithPOSIXError posixError: Int32, description: String) {
        if server !== _listener { return }
        NSLog("Warning: unable to share the Horos database on port 8780: %@", description)
        // The server stopped itself. Without a listener the advertisement goes (#389, #392): the
        // user is told why, and turning sharing off and on again tries the port once more.
        AppController.shared()?.reportListenBindFailure(forService: ListenBindFailure.databaseSharingService,
                                                                    port: 8780,
                                                                    errnoCode: posixError)
        _listener?.delegate = nil
        _listener = nil
        updateBonjour()
    }

    public func databaseServer(_ server: HorosDatabaseServer, isWaitingWithPOSIXError posixError: Int32, description: String) {
        if server !== _listener { return }
        NSLog("Horos database sharing is waiting for the network: %@", description)
        updateBonjour() // port 0: the advertisement is withdrawn until the listener is ready again
    }

    @objc public func updateBonjour() {
        // A service created while sharing is disabled retains port zero forever.
        // Drop inactive/stale advertisements and create one only for a listener that is ready,
        // under the name the preferences hold now.
        let listenerPort = _listener?.port ?? 0
        if listenerPort == 0 || (_bonjour != nil && (_bonjour!.port != listenerPort || !Self.isEqual(_bonjour!.name, UserDefaults.bonjourSharingName()))) {
            _bonjour?.delegate = nil
            _bonjour?.stop()
            _bonjour = nil
            if let advertisement = _advertisement { onMainActorSync { advertisement.stop() } }
            _advertisement = nil
        }
        if listenerPort == 0 {
            if let directService: AnyClass = NSClassFromString("HorosDirectTransferService"),
               directService.responds(to: NSSelectorFromString("sharedService")) {
                _ = (directService as AnyObject).perform(NSSelectorFromString("sharedService"))?
                    .takeUnretainedValue().perform(NSSelectorFromString("stop"))
            }
            return
        }
        if _bonjour == nil, let listener = _listener {
            // The advertisement is DNSServiceRegister (#606): it refuses a port no
            // listener is on, takes the name the daemon gives it on a collision, and
            // retries only a transient daemon failure. The deprecated -netService
            // accessor keeps returning an NSNetService for its remaining callers.
            let port = listener.port
            // Made and published on the main queue, where it is scheduled.
            _advertisement = onMainActorSync {
                BonjourAdvertisement(name: UserDefaults.bonjourSharingName() ?? "", type: "_osirixdb._tcp.", port: port)
            }
            _bonjour = NetService(domain: "", type: "_osirixdb._tcp.", name: UserDefaults.bonjourSharingName() ?? "", port: Int32(truncatingIfNeeded: listener.port))
            _bonjour?.delegate = self
        }

        let txtrec = NSMutableDictionary()
        txtrec.setObject(UserDefaults.standard.string(forKey: "AETITLE") ?? "OSIRIX", forKey: "AETitle" as NSString)
        txtrec.setObject(UserDefaults.standard.string(forKey: "AEPORT") ?? "11112", forKey: "port" as NSString)
        if let uid = AppController.uid() {
            txtrec.setObject(uid, forKey: "UID" as NSString)
        }

        let directPolicy: AnyClass? = NSClassFromString("HorosDirectTransferPolicy")
        let directService: AnyClass? = NSClassFromString("HorosDirectTransferService")
        if let directService, directService.responds(to: NSSelectorFromString("sharedService")) {
            _ = (directService as AnyObject).perform(NSSelectorFromString("sharedService"))?
                .takeUnretainedValue().perform(NSSelectorFromString("startIfSharingActive"))
        }
        if let directPolicy, directPolicy.responds(to: NSSelectorFromString("bonjourTXTFields")) {
            let capability = (directPolicy as AnyObject).perform(NSSelectorFromString("bonjourTXTFields"))?.takeUnretainedValue() as? NSDictionary
            if let version = capability?.object(forKey: "HorosDirectTransferVersion") as? NSString, version.length > 0 {
                txtrec.setObject(version, forKey: "HorosDirectTransferVersion" as NSString)
            }
            if let directPort = capability?.object(forKey: "HorosDirectTransferPort") as? NSString, directPort.length > 0 {
                txtrec.setObject(directPort, forKey: "HorosDirectTransferPort" as NSString)
            }
        }

        if _bonjour?.setTXTRecord(Self.dataFromTXTRecordDictionary(txtrec)) != true {
            NSLog("Warning: Horos Bonjour net service setTXTRecordData FAILED")
        }

        let advertisement = _advertisement
        if listenerPort != 0 {
            let record = txtrec as! [String: String]
            onMainActorSync { advertisement?.publish(txtRecord: record) }
        } else {
            onMainActorSync { advertisement?.stop() }
        }
    }

    /// +[NSNetService dataFromTXTRecordDictionary:], given the values as they are
    /// (strings): the Swift overlay takes only Data values.
    private static func dataFromTXTRecordDictionary(_ txtrec: NSDictionary) -> Data? {
        return (NetService.self as AnyObject).perform(NSSelectorFromString("dataFromTXTRecordDictionary:"), with: txtrec)?
            .takeUnretainedValue() as? Data
    }

    /** The native DNS-SD advertisement this publisher uses (#606); nil while sharing is off. */
    @objc public var advertisement: BonjourAdvertisement? {
        return _advertisement
    }

    @available(*, deprecated)
    @objc public func netService() -> NetService? {
        return _bonjour
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        if sender !== _bonjour { return } // a delayed callback from an earlier service
        NSLog("Warning: Horos Bonjour net service did not publish, %@", errorDict as NSDictionary)
        _bonjour?.delegate = nil
        _bonjour?.stop()
        _bonjour = nil
    }

    public func netServiceDidStop(_ sender: NetService) {
        NSLog("Horos Bonjour net service did stop")
    }

    //- (void)connectionOpened:(NSNotification*)notification {
    //	N2Connection* connection = [[notification userInfo] objectForKey:N2ConnectionListenerOpenedConnection];
    //	[connection setDelegate:self];
    //}

    @objc(dictionaryFromXTRecordData:)
    public class func dictionaryFromXTRecordData(_ data: Data?) -> NSDictionary {
        let d = NSMutableDictionary()
        // The Objective-C method, not the Swift overlay: a key without a value
        // comes as NSNull, which the overlay's [String: Data] cannot hold, and
        // nil raises as it did.
        guard let dict = (NetService.self as AnyObject).perform(NSSelectorFromString("dictionaryFromTXTRecordData:"), with: data)?
                .takeUnretainedValue() as? NSDictionary else { return d }

        for (key, data) in dict {
            let key = key as! NSString
            if key.isEqual(to: "AETitle") || key.isEqual(to: "port") || key.isEqual(to: "UID") {
                d.setObject(Self.utf8String(data, key: key), forKey: key)
            } else {
                d.setObject(data, forKey: key)
            }
        }

        return d
    }

    /// [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], for a value
    /// -setObject:forKey: then stores: what raised before raises the same way.
    private static func utf8String(_ data: Any, key: NSString) -> NSString {
        guard let data = data as? Data else {
            NSException(name: .invalidArgumentException,
                        reason: "-[\(type(of: data as AnyObject)) bytes]: unrecognized selector sent to instance", userInfo: nil).raise()
            return ""
        }
        guard let string = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else {
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(key))", userInfo: nil).raise()
            return ""
        }
        return string
    }

    @objc(sendDICOMFilesToOsiriXNode:)
    public func sendDICOMFiles(toOsiriXNode todo: NSDictionary) {
        autoreleasepool {
            if dicomSendLock == nil {
                dicomSendLock = NSLock()
            }
            let lock = dicomSendLock!

            lock.lock()
            defer { lock.unlock() }
            do {
                try HorosObjCException.perform {
                    guard let database = DicomDatabase.default() else {
                        NSException(name: .invalidArgumentException,
                                    reason: "*** +[NSDictionary dictionaryWithObject:forKey:]: object cannot be nil", userInfo: nil).raise()
                        return
                    }
                    let storeSCU = DCMTKStoreSCU(callingAET: UserDefaults.standard.string(forKey: "AETITLE"),
                                                 calledAET: todo.object(forKey: "AETitle") as? String,
                                                 hostname: todo.object(forKey: "Address") as? String,
                                                 port: (todo.object(forKey: "Port") as? NSString)?.intValue ?? 0,
                                                 filesToSend: todo.value(forKey: "Files") as? [Any],
                                                 transferSyntax: (todo.object(forKey: "TransferSyntax") as? NSString)?.intValue ?? 0,
                                                 compression: 1.0,
                                                 extraParameters: ["DicomDatabase": database]) // nil == TLS not supported !

                    do {
                        try HorosObjCException.perform {
                            storeSCU?.run(nil)
                        }
                    } catch {
                        let ne = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                        NSLog("Bonjour DICOM Send FAILED")
                        NSLog("%@", (ne?.name.rawValue ?? "") as NSString)
                        NSLog("%@", (ne?.reason as NSString?) ?? "(null)")
                    }
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, true, "-[BonjourPublisher sendDICOMFilesToOsiriXNode:]")
                }
            }
        }
    }
}

// What the objects of the index answer that the server asks of them: sent as
// Objective-C sent them, by message, without a class check.
@objc private protocol O2SharedDatabaseImage {
    var pathNumber: NSNumber? { get }
}

@objc private protocol O2SharedDatabaseStudy {
    func archiveAnnotationsAsDICOMSR()
}

// How a request of O2DatabaseConnection ends early. The Objective-C class raised
// O2NotEnoughData and O2InvalidRequest and let any other exception reach -run.
// @unchecked Sendable, which Error requires: NSException is not declared
// Sendable. The interrupt is thrown and caught on the one worker thread that
// runs the request, and the exception it carries is never changed after it
// was raised.
private enum O2Interrupt: Error, @unchecked Sendable {
    case notEnoughData // O2NotEnoughData
    // A request that breaks the protocol (#614): the connection is closed, nothing
    // further of it is read or executed.
    case invalidRequest(String) // O2InvalidRequest
    case exception(NSException)
}

// One request of one client (#615). It used to be an N2Connection, whose run loop called
// -handleData: as bytes arrived and sent what was written in the background. It now runs
// synchronously on a worker of HorosDatabaseServer: it reads from its HorosDatabasePeer
// until the request is complete, answers, and ends the stream. The request handlers below
// are unchanged; the methods they called on N2Connection are provided here over the peer.
@objc(O2DatabaseConnection)
public final class O2DatabaseConnection: NSObject {
    private enum Mode: Int {
        case NONE = 0, DONE,
             DATAB,
             DBSIZ,
             GETDI,
             VERSI,
             DBVER,
             ISPWD,
             PASWD,
             SENDD,
             SENDG,
             NEWMS,
             ADDAL,
             REMAL,
             SETVA,
             MFILE,
             DCMSE,
             DICOM
    }

    private var _mode = Mode.NONE
    private var _hdi = 0
    private var _authorized = false
    private var _closed = false // the request was refused or broke the protocol: nothing more is read or sent
    private let _stack = NSMutableArray()
    private let _readBuffer = NSMutableData()
    private var _readOffset = 0 // bytes of _readBuffer the handlers consumed, removed once per pass
    private let _peer: HorosDatabasePeer
    private var _requestPaths: SharedDatabaseRequestPaths? // the folders this request's paths resolve against (#637)
    private var _linkedPaths: NSMutableSet? // its absolute paths outside them
    private var _requestDatabase: DicomDatabase? // the index, a private-queue context of this connection (#966)

    @objc(servePeer:)
    public class func serve(_ peer: HorosDatabasePeer) {
        let connection = O2DatabaseConnection(peer: peer)
        connection.run()
    }

    private init(peer: HorosDatabasePeer) {
        _peer = peer
        super.init()
    }

    private func _rejectRequest(_ reason: String) -> O2Interrupt {
        return .invalidRequest(reason)
    }

    // Everything still unconsumed in the receive buffer for the current request.
    // Reads arrive in blocks, and a block bounds nothing about the request. This is
    // asked for every block of an upload, so the limits are read once.
    private static let O2MaximumFileLength = SharedDatabaseWire.maximumFileLength
    private static let O2BufferLimitAwaitingCommand = SharedDatabaseWire.maximumBufferedBytesAwaitingCommand
    private static let O2BufferLimitUpload = SharedDatabaseWire.maximumBufferedBytesForUpload
    private static let O2BufferLimitOther = SharedDatabaseWire.maximumBufferedBytesForOtherRequests

    private func _maximumBufferedBytes() -> Int {
        switch _mode {
        case .NONE: return Self.O2BufferLimitAwaitingCommand
        case .SENDD, .SENDG: return Self.O2BufferLimitUpload
        default: return Self.O2BufferLimitOther
        }
    }

    private func _closeIfBufferExceedsLimit() {
        if availableSize > _maximumBufferedBytes() {
            NSLog("Shared database: request from %@ closed: more than %ld bytes buffered", address, _maximumBufferedBytes())
            close()
        }
    }

    // The request, on this worker, from its first byte to the end of its answer. Every wait for the
    // network ends: the peer times out after its idle limit of monotonic time, fails with the
    // connection, or is cancelled when sharing stops. Nothing thrown here reaches the Swift worker.
    private func run() {
        defer { _peer.cancel() }
        do {
            while _mode != .DONE && !_closed {
                let ended = try autoreleasepool { () throws -> Bool in
                    let before = _readBuffer.length
                    do {
                        try _peer.appendReceivedData(to: _readBuffer)
                    } catch {
                        NSLog("Shared database: request from %@ ended: %@", address, error.localizedDescription)
                        return true
                    }
                    if _readBuffer.length == before {
                        // A client that goes away in the middle of a request never completes it.
                        if _mode != .NONE || availableSize != 0 {
                            NSLog("Shared database: %@ disconnected before completing its request", address)
                        }
                        return true
                    }
                    try handleData()
                    // Consumed bytes go once per pass: removing them read by read moved the
                    // rest of the request every time, which for 2000 paths cost more than
                    // parsing them.
                    if _readOffset != 0 {
                        _readBuffer.replaceBytes(in: NSRange(location: 0, length: _readOffset), withBytes: nil, length: 0)
                        _readOffset = 0
                    }
                    return false
                }
                if ended { return }
            }
            if _closed {
                return
            }
            do {
                try _peer.finish()
            } catch {
                NSLog("Shared database: answer to %@ not completed: %@", address, error.localizedDescription)
            }
        } catch O2Interrupt.exception(let exception) {
            _N2LogExceptionImpl(exception, true, "-[O2DatabaseConnection run]")
        } catch {
            NSLog("Shared database: request from %@ ended: %@", address, "\(error)")
        }
    }

    // What the handlers used of N2Connection, over the peer.
    private var address: String { return _peer.address }
    private var availableSize: Int { return _readBuffer.length - _readOffset }

    // The unread part of the request, as a view valid until the buffer changes.
    private var readBuffer: Data {
        return Data(bytesNoCopy: _readBuffer.mutableBytes + _readOffset, count: _readBuffer.length - _readOffset, deallocator: .none)
    }

    /// -[NSData subdataWithRange:] and -getBytes:range: raised on a range past the end.
    private func _checkRange(_ size: Int) throws {
        if size < 0 || _readOffset + size > _readBuffer.length {
            throw O2Interrupt.exception(NSException(name: .rangeException,
                                                    reason: "*** -[NSConcreteMutableData subdataWithRange:]: range {\(_readOffset), \(UInt(bitPattern: size))} exceeds data length \(_readBuffer.length)",
                                                    userInfo: nil))
        }
    }

    @discardableResult
    private func readData(_ size: Int) throws -> Data {
        try _checkRange(size)
        let data = _readBuffer.subdata(with: NSRange(location: _readOffset, length: size))
        _readOffset += size
        return data
    }

    @discardableResult
    private func readData(_ size: Int, toBuffer buffer: UnsafeMutableRawPointer) throws -> Int {
        try _checkRange(size)
        _readBuffer.getBytes(buffer, range: NSRange(location: _readOffset, length: size))
        _readOffset += size
        return size
    }

    // The unread bytes and a step past them, for the length and string readers: a view object
    // or a copy per string cost more than parsing it.
    private func _unreadBytes() -> UnsafePointer<UInt8> {
        return _readBuffer.bytes.assumingMemoryBound(to: UInt8.self) + _readOffset
    }

    private func _skipBytes(_ size: Int) { _readOffset += size }

    // Sends before returning, in blocks the peer waits for: a slow reader holds the request back
    // instead of an ever larger buffer. A failed send ends the request.
    private func writeData(_ data: Data?) {
        guard !_closed, let data, data.count > 0 else {
            return
        }
        do {
            try _peer.writeData(data)
        } catch {
            NSLog("Shared database: sending to %@ failed: %@", address, error.localizedDescription)
            close()
        }
    }

    private var writeBufferSize: Int { return 0 } // written synchronously: nothing is ever left queued

    // Refuses the request: nothing more of it is read or answered, and the stream is not ended
    // cleanly, so the client sees the connection close without a response.
    private func close() {
        _closed = true
        _peer.cancel()
    }

    private func handleData() throws {
        _hdi = 0

        do {
            // The request is complete and its answer may still be on its way out:
            // anything more the client sends is not part of it, and kept it would
            // grow the buffer for as long as the answer takes.
            if _mode == .DONE {
                if availableSize != 0 {
                    try readData(availableSize)
                }
                return
            }

            if _mode == .NONE {
                if availableSize < 6 {
                    return
                }
                let protected = UserDefaults.bonjourSharingIsPasswordProtected()
                if memcmp(_unreadBytes(), "AUTHR", 6) == 0 {
                    let length = SharedDatabaseAuthorization.authorizedPrefixLength(readBuffer, password: UserDefaults.bonjourSharingPassword(), required: protected)
                    if length == 0 { return }
                    if length < 0 { close(); return }
                    try readData(length)
                    _authorized = true
                }
                var command = [CChar](repeating: 0, count: 6)
                try command.withUnsafeMutableBytes { _ = try readData(6, toBuffer: $0.baseAddress!) }
                if command[5] != 0 { close(); return }
                guard let name = NSString(utf8String: command) else { close(); return }
                if protected && !_authorized && !SharedDatabaseAuthorization.isPublicCommand(name as String) {
                    close()
                    return
                }
                if strcmp(command, "AUTHV") == 0 {
                    var version = UInt32(1).bigEndian
                    writeData(Data(bytes: &version, count: 4))
                    _mode = .DONE
                    return
                }

                if strcmp(command, "DATAB") == 0 {
                    _mode = .DATAB
                } else if strcmp(command, "DBSIZ") == 0 {
                    _mode = .DBSIZ
                } else if strcmp(command, "GETDI") == 0 {
                    _mode = .GETDI
                } else if strcmp(command, "VERSI") == 0 {
                    _mode = .VERSI
                } else if strcmp(command, "DBVER") == 0 {
                    _mode = .DBVER
                } else if strcmp(command, "ISPWD") == 0 {
                    _mode = .ISPWD
                } else if strcmp(command, "PASWD") == 0 {
                    _mode = .PASWD
                } else if strcmp(command, "SENDD") == 0 {
                    _mode = .SENDD
                } else if strcmp(command, "SENDG") == 0 {
                    _mode = .SENDG
                } else if strcmp(command, "NEWMS") == 0 {
                    _mode = .NEWMS
                } else if strcmp(command, "ADDAL") == 0 {
                    _mode = .ADDAL
                } else if strcmp(command, "REMAL") == 0 {
                    _mode = .REMAL
                } else if strcmp(command, "SETVA") == 0 {
                    _mode = .SETVA
                } else if strcmp(command, "MFILE") == 0 {
                    _mode = .MFILE
                } else if strcmp(command, "DCMSE") == 0 {
                    _mode = .DCMSE
                } else if strcmp(command, "DICOM") == 0 {
                    _mode = .DICOM
                }

                if _mode == .NONE {
                    close()
                }
            }

            // The handlers that read or change the index run inside its
            // context's queue, the objects of the request never leave it (#966).
            switch _mode {
            case .DATAB, .DBSIZ, .VERSI, .SENDD, .SENDG, .ADDAL, .REMAL, .SETVA:
                return try _onRequestDatabaseQueue { try _handleIndexRequest() }
            default:
                return try _handleOtherRequest()
            }
        } catch O2Interrupt.notEnoughData {
            _closeIfBufferExceedsLimit()
            return
        } catch O2Interrupt.invalidRequest(let reason) {
            NSLog("Shared database: request from %@ closed: %@", address, reason)
            close()
            return
        }
        // A complete request (DONE) is answered by now: -run ends the stream.
    }

    private func _requestIndexDatabase() throws -> DicomDatabase {
        if let database = _requestDatabase {
            return database
        }
        guard let database = try objc({ DicomDatabase.default()?.privateQueueIndependentDatabase() }) as? DicomDatabase else {
            throw Self.nilObject()
        }
        _requestDatabase = database
        return database
    }

    private func _onRequestDatabaseQueue(_ body: () throws -> Void) throws {
        let database = try _requestIndexDatabase()
        var failure: Error?
        // An exception still goes on to -run, raised again outside the queue.
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            do { try body() } catch { failure = error }
        }
        if let failure {
            throw failure
        }
    }

    private func _handleIndexRequest() throws {
        switch _mode {
        case .DATAB:
            return try DATAB()
        case .DBSIZ:
            return try DBSIZ()
        case .VERSI:
            return try VERSI()
        case .SENDD, .SENDG:
            return try SEND()
        case .ADDAL:
            return try ADDAL()
        case .REMAL:
            return try REMAL()
        case .SETVA:
            return try SETVA()
        default:
            break
        }
    }

    private func _handleOtherRequest() throws {
            switch _mode {
            case .DATAB:
                return try DATAB()
            case .DBSIZ:
                return try DBSIZ()
            case .GETDI:
                return try GETDI()
            case .VERSI:
                return try VERSI()
            case .DBVER:
                return DBVER()
            case .ISPWD:
                return ISPWD()
            case .PASWD:
                return try PASWD()
            case .SENDD:
                return try SEND()
            case .SENDG:
                return try SEND()
            case .NEWMS:
                return try NEWMS()
            case .ADDAL:
                return try ADDAL()
            case .REMAL:
                return try REMAL()
            case .SETVA:
                return try SETVA()
            case .MFILE:
                return try MFILE()
            case .DCMSE:
                return try DCMSE()
            case .DICOM:
                return try DICOM()
            case .NONE, .DONE:
                break
            }
    }

    /// Runs Objective-C code that may raise: an exception reaches -run, as it did.
    private func objc<T>(_ body: () -> T) throws -> T {
        var result: T?
        do {
            try HorosObjCException.perform {
                result = body()
            }
        } catch {
            throw O2Interrupt.exception(Self.exception(error))
        }
        return result!
    }

    /// Runs what an Objective-C @try caught and logged.
    private func logged(_ function: String, _ body: () -> Void) {
        do {
            try HorosObjCException.perform(body)
        } catch {
            _N2LogExceptionImpl(Self.exception(error), true, function)
        }
    }

    private static func exception(_ error: Error) -> NSException {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            ?? NSException(name: .genericException, reason: (error as NSError).localizedDescription, userInfo: nil)
    }

    /// -[NSMutableArray addObject:] raised on nil.
    private static func nilObject() -> O2Interrupt {
        return .exception(NSException(name: .invalidArgumentException,
                                      reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil))
    }

    private func _stackObject(_ o: Any) {
        _stack.add(o)
        _hdi += 1
    }

    private func _stackedObject() -> Any? {
        if _stack.count <= _hdi {
            return nil
        }
        let object = _stack.object(at: _hdi)
        _hdi += 1
        return object
    }

    private func _unstack() {
        _hdi -= 1
        _stack.removeObject(at: _hdi)
    }

    private func _requireDataSize(_ size: Int) throws {
        if size < 0 {
            throw _rejectRequest("negative data size")
        }
        if availableSize < size {
            throw O2Interrupt.notEnoughData
        }
    }

    // A 32-bit length or count, validated before anything is consumed: a negative
    // value, or one above what the command can really carry, rejects the request.
    private func _readLengthUpTo(_ maximum: Int, what: String) throws -> Int {
        try _requireDataSize(4)

        let raw = UnsafeRawPointer(_unreadBytes()).loadUnaligned(as: UInt32.self)
        let value = SharedDatabaseWire.validated(raw, maximum: maximum)
        if value < 0 {
            throw _rejectRequest("invalid \(what) (\(Int32(bitPattern: UInt32(bigEndian: raw))))")
        }
        _skipBytes(4)

        return value
    }

    private func _stackReadLengthUpTo(_ maximum: Int, what: String) throws -> Int {
        if _stack.count > _hdi {
            return (_stackedObject() as? NSNumber)?.intValue ?? 0
        }

        let value = try _readLengthUpTo(maximum, what: what)

        _stackObject(NSNumber(value: value))

        return value
    }

    private func _stackReadCount() throws -> Int {
        return try _stackReadLengthUpTo(SharedDatabaseWire.maximumCount, what: "count")
    }

    // Zero length is how the client sends nil, so nil and @"" stay distinct. The
    // length prefix is left in the buffer until the whole string has arrived: a
    // fragment boundary anywhere inside it resumes from the same place.
    private func _readString() throws -> String? {
        try _requireDataSize(4)

        let raw = UnsafeRawPointer(_unreadBytes()).loadUnaligned(as: UInt32.self)
        let length = SharedDatabaseWire.validated(raw, maximum: SharedDatabaseWire.maximumStringLength)
        if length < 0 {
            throw _rejectRequest("invalid string length (\(Int32(bitPattern: UInt32(bigEndian: raw))))")
        }

        try _requireDataSize(length + 4)

        var status = SharedDatabaseWire.StringStatus.value
        let value = SharedDatabaseWire.decode(_unreadBytes() + 4, length: length, status: &status)
        if status == .unterminated {
            throw _rejectRequest("string without its terminator")
        }
        if status == .embeddedNull {
            throw _rejectRequest("string with an embedded terminator")
        }
        if status == .invalidUTF8 {
            throw _rejectRequest("string that is not UTF-8")
        }

        _skipBytes(length + 4)

        return value as String?
    }

    // The resume stack cannot hold nil: a null string is stacked as NSNull and
    // handed back as nil.
    private func _stackReadString() throws -> String? {
        if _stack.count > _hdi {
            let value = _stackedObject()
            return (value as AnyObject?) === NSNull() ? nil : value as? String
        }
        let value = try _readString()

        _stackObject(value ?? NSNull())

        return value
    }

    // For parameters a command cannot do without.
    private func _stackReadRequiredString(_ what: String) throws -> String {
        guard let value = try _stackReadString() else {
            throw _rejectRequest("missing \(what)")
        }
        return value
    }

    private func _stackIndependentDatabase() throws -> DicomDatabase {
        if _stack.count > _hdi {
            return _stackedObject() as! DicomDatabase
        }
        let database = try _requestIndexDatabase()

        _stackObject(database)

        return database
    }

    // The file a request names (#637). A relative path is an image of
    // DATABASE.noindex by its name, or an older client's ROI; an absolute path is
    // used as it is. A path of another shape, or with a `.` or `..` component, closes
    // the request. An absolute path outside the database's folders is kept for
    // -_requireLinkedPaths, which decides once every path of the request is known.
    private func _servedPathForRequestedPath(_ requested: String) throws -> String {
        if _requestPaths == nil {
            // Once per request: a DCMSE names a path per image.
            _requestPaths = try objc {
                let database = DicomDatabase.default()
                return SharedDatabaseRequestPaths(databaseDirectory: ((database?.sqlFilePath ?? "") as NSString).deletingLastPathComponent as NSString,
                                                  dataDirectory: database?.dataDirPath() as NSString?,
                                                  folderSize: Int(BrowserController.defaultFolderSizeForDB()))
            }
        }
        var resolved: NSString?
        let kind = _requestPaths!.kind(ofRequestedPath: requested as NSString, resolvedPath: &resolved)
        guard kind != .refused, let resolved else {
            throw _rejectRequest("path \(requested) does not name a file of the database")
        }
        if kind == .linked {
            if _linkedPaths == nil {
                _linkedPaths = NSMutableSet()
            }
            _linkedPaths!.add(resolved)
        }
        return resolved as String
    }

    // Absolute paths outside the database's folders are read only for the images
    // the index links in place, by exactly that path (HorosSharedDatabaseLinkedPaths
    // keeps the ones it has confirmed); one unknown path closes the whole request,
    // before any of it is answered.
    private func _requireLinkedPaths() throws {
        guard let linkedPaths = _linkedPaths, linkedPaths.count > 0 else {
            return
        }
        let database = try objc { DicomDatabase.default() }
        var raised: NSException?
        let known = SharedDatabaseLinkedPaths.shared.containsAll(linkedPaths, indexFile: (database?.sqlFilePath ?? "") as NSString) { paths in
            // Only the paths, as dictionaries: no image is materialized.
            var found: [Any] = []
            do {
                try HorosObjCException.perform {
                    // Only values come back: a private-queue context, fetched on its queue (#966).
                    let index = database?.privateQueueIndependentDatabase() as? DicomDatabase
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Image")
                    request.predicate = NSPredicate(format: "pathString IN %@", paths)
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["pathString"]
                    // -executeFetchRequest:error:, as before (NSManagedObjectContext.fetch
                    // sends -executeRequest:error:).
                    let rows = (try? index?.managedObjectContext.__execute(request)) as NSArray?
                    found = rows?.value(forKey: "pathString") as? [Any] ?? []
                }
            } catch {
                // An exception of the lookup ends the request, as it did, once the
                // shared cache is left consistent.
                raised = Self.exception(error)
            }
            return found
        }
        if let raised {
            throw O2Interrupt.exception(raised)
        }
        if !known {
            throw _rejectRequest(String(format: "a path outside the database that no image links to, among %@", linkedPaths))
        }
    }

    private func DATAB() throws {
        let idatabase = try _stackIndependentDatabase()

        var representationToSend: NSMutableData?

        // The locker was autoreleased: it unlocked the persistentStoreCoordinator once the
        // answer was written, when the pass's autorelease pool drained. It lives as long here.
        var locker: N2Locker?
        let lock = _stackedObject()
        if lock == nil {
            try objc {
                locker = N2Locker.lock(idatabase.managedObjectContext.persistentStoreCoordinator) // this object unlocks the persistentStoreCoordinator when released
                _stackObject(locker!)
                idatabase.save()
            }
        }

        var done = false

        logged("-[O2DatabaseConnection DATAB]") {
            // we send the database SQL file
            let databasePath = idatabase.sqlFilePath

            representationToSend = databasePath.flatMap { NSMutableData(contentsOfFile: $0) }
            done = true
        }
        if done {
            _unstack() // -> release N2Locker, unlocks the persistentStoreCoordinator (this line may not be called, so the persistentStoreCoordinator will be unlocked when this connection object is released -- when the stack is released)
        }

        if let representationToSend {
            writeData(representationToSend as Data)
        }

        NSLog("Bonjour connection received from %@", address)

        _mode = .DONE
        withExtendedLifetime(locker) {}
    }

    private func DBSIZ() throws {
        let idatabase = try _stackIndependentDatabase()

        var fileSize: UInt64 = 0

        try objc { _ = idatabase.managedObjectContext.persistentStoreCoordinator?.perform(#selector(NSLocking.lock)) }
        logged("-[O2DatabaseConnection DBSIZ]") {
            idatabase.save()

            let databasePath = idatabase.sqlFilePath ?? ""

            let fattrs = (try? FileManager.default.attributesOfItem(atPath: databasePath)) as NSDictionary?

            fileSize = (fattrs?.object(forKey: FileAttributeKey.size) as? NSNumber)?.uint64Value ?? 0
        }
        try objc { _ = idatabase.managedObjectContext.persistentStoreCoordinator?.perform(#selector(NSLocking.unlock)) }

        // Four bytes, read unsigned by the client: an index of 4 GiB or more is
        // answered with the value that says so, never with its size wrapped (#637).
        var size = SharedDatabaseRequests.reply(forIndexSize: fileSize)
        if size == SharedDatabaseRequests.indexTooLargeForReply {
            NSLog("Shared database: the index (%llu bytes) is too large to be shared with %@", fileSize, address)
        }
        size = size.bigEndian
        writeData(Data(bytes: &size, count: MemoryLayout<UInt32>.size))

        _mode = .DONE
    }

    private func GETDI() throws {
        let defaults = UserDefaults.standard
        let syntax = try objc { DCMTKStoreSCU.sendSyntax(forListenerSyntax: Int32(truncatingIfNeeded: defaults.integer(forKey: "preferredSyntaxForIncoming"))) }
        // +dictionaryWithObjectsAndKeys: stops at the first nil object.
        var objects: [Any] = []
        var keys: [NSString] = []
        for (object, key) in [(defaults.string(forKey: "AETITLE"), "AETitle"),
                              (defaults.string(forKey: "AEPORT"), "Port"),
                              (String(format: "%d", syntax), "TransferSyntax")] as [(String?, String)] {
            guard let object else { break }
            objects.append(object)
            keys.append(key as NSString)
        }
        let dictionary = NSDictionary(objects: objects, forKeys: keys)

        // NSArchiver data, which released clients decode with NSUnarchiver. This
        // client reads it with SharedDatabaseDestinationInfo, which accepts a
        // dictionary of strings and nothing else (#817).
        writeData(try HistoricalArchive.archivedData(withRootObject: dictionary))

        _mode = .DONE
    }

    private func VERSI() throws {
        let idatabase = try _stackIndependentDatabase()

        let val = try objc { idatabase.timeOfLastModification }

        var swappedValue = val.bitPattern.bigEndian

        if MemoryLayout.size(ofValue: swappedValue) != 8 { NSLog("********** warning sizeof( swappedValue) != 8") }

        writeData(Data(bytes: &swappedValue, count: MemoryLayout<TimeInterval>.size))

        _mode = .DONE
    }

    private func DBVER() {
        let versString = UserDefaults.standard.string(forKey: "DATABASEVERSION")

        writeData((versString as NSString?)?.data(using: String.Encoding.ascii.rawValue))

        _mode = .DONE
    }

    private func ISPWD() {
        // is this database protected by a password
        _ = UserDefaults.bonjourSharingPassword()

        var val: UInt32 = 0
        if UserDefaults.bonjourSharingIsPasswordProtected() {
            val = UInt32(1).bigEndian
        }

        writeData(Data(bytes: &val, count: MemoryLayout<Int32>.size))

        _mode = .DONE
    }

    private func PASWD() throws {
        try _requireDataSize(4)
        let length = UInt32(bigEndian: UnsafeRawPointer(_unreadBytes()).loadUnaligned(as: UInt32.self))
        if length == 0 || length > 4097 { close(); return }
        try _requireDataSize(Int(Int32(bitPattern: length)) + 4)
        try readData(4)
        let bytes = try readData(Int(length))
        if bytes[bytes.startIndex + Int(length) - 1] != 0 { close(); return }
        let incomingPswd = bytes.withUnsafeBytes {
            NSString(bytes: $0.baseAddress!, length: Int(length) - 1, encoding: String.Encoding.utf8.rawValue)
        }

        // We read the string
        var val: UInt32 = 0

        let password = UserDefaults.bonjourSharingPassword() as NSString?
        if !UserDefaults.bonjourSharingIsPasswordProtected() || ((password?.length ?? 0) > 0 && incomingPswd?.isEqual(to: password! as String) == true) {
            val = UInt32(1).bigEndian
        }

        writeData(Data(bytes: &val, count: MemoryLayout<Int32>.size))

        _mode = .DONE
    }

    private func SEND() throws {
        let fileNo = try _stackReadCount()

        var savedFiles = _stackedObject() as? NSMutableArray
        if savedFiles == nil {
            savedFiles = NSMutableArray()
            _stackObject(savedFiles!)
        }

        while savedFiles!.count < fileNo {
            let fileSize = try _stackReadLengthUpTo(Self.O2MaximumFileLength, what: "file length")
            // A file arrives in thousands of blocks, and waiting for the rest is the
            // usual state here: raising O2NotEnoughData for every block cost more
            // than receiving the upload. The resume stack is left exactly as the
            // exception would leave it.
            if availableSize < fileSize {
                _closeIfBufferExceedsLimit()
                return
            }

            let dstPath = try objc { BrowserController.currentBrowser()?.database?.uniquePathForNewDataFile(withExtension: "dcm") }

            let data = try readData(fileSize)
            try objc { _ = dstPath.map { (data as NSData).write(toFile: $0, atomically: true) } }

            guard let dstPath else { throw Self.nilObject() }
            savedFiles!.add(dstPath)

            _unstack()
        }

        let idatabase = try _stackIndependentDatabase()

        let generatedByOsiriX = _mode == .SENDG
        let objects = try objc { () -> [Any]? in
            let added = idatabase.addFiles(atPaths: savedFiles as? [Any], postNotifications: true, dicomOnly: false, rereadExistingItems: true, generatedByOsiriX: generatedByOsiriX)
            return idatabase.objects(withIDs: added) as [Any]?
        } ?? []

        let representationToSend = NSMutableData()
        var temp = UInt32(truncatingIfNeeded: objects.count).bigEndian
        representationToSend.append(&temp, length: 4)
        for image in objects {
            let number = try objc { unsafeBitCast(image as AnyObject, to: O2SharedDatabaseImage.self).pathNumber }
            var temp = UInt32(bitPattern: number?.int32Value ?? 0).bigEndian
            representationToSend.append(&temp, length: 4)
        }

        writeData(representationToSend as Data)

        _mode = .DONE
    }

    private func NEWMS() throws { // is this used ? nah
        let size = try _stackReadLengthUpTo(SharedDatabaseWire.maximumStringLength, what: "message length")

        try _requireDataSize(size)
        if size != 0 { try readData(size) } // readData:0 would take the whole buffer
        //    NSData* da = [self readData:size];

        //    NSDictionary* d = [NSPropertyListSerialization propertyListFromData:da mutabilityOption: NSPropertyListImmutable format: nil errorDescription: nil];
        //
        //    if (d)
        //    {
        //        NSString *message = [d objectForKey:@"message"];
        //    }

        _mode = .DONE
    }

    /// The album parameters of ADDAL and REMAL: a property list whose albumStudies
    /// and albumUID are read as -objectForKey: read them.
    private func _albumParameters(_ object: String) throws -> (studies: AnyObject?, albumUID: AnyObject?) {
        let d = try? PropertyListSerialization.propertyList(from: Data(object.utf8), options: [], format: nil)

        guard let d = d.map({ $0 as AnyObject }) else {
            throw O2Interrupt.exception(NSException(name: .genericException, reason: "can't parse parameters", userInfo: nil))
        }

        return try objc {
            (d.perform(#selector(NSDictionary.object(forKey:)), with: "albumStudies")?.takeUnretainedValue(),
             d.perform(#selector(NSDictionary.object(forKey:)), with: "albumUID")?.takeUnretainedValue())
        }
    }

    private func ADDAL() throws {
        let object = try _stackReadRequiredString("album parameters")

        let (studies, albumUID) = try _albumParameters(object)

        let idatabase = try _stackIndependentDatabase()

        logged("-[O2DatabaseConnection ADDAL]") {
            let album = idatabase.object(withID: albumUID) as AnyObject? // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: albumUID]]];
            let albumStudies = (album as? NSObject)?.mutableSetValue(forKey: "studies")

            if let studies {
                for uri in unsafeDowncast(studies, to: NSArray.self) {
                    let study = idatabase.object(withID: uri) as AnyObject? // (DicomStudy*) [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: uri]]];
                    _ = albumStudies?.perform(#selector(NSMutableSet.add(_:)), with: study)
                    if let study {
                        unsafeBitCast(study, to: O2SharedDatabaseStudy.self).archiveAnnotationsAsDICOMSR()
                    }
                }
            }

            _ = idatabase.save(nil)

            BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("refreshDatabase:"), with: self, waitUntilDone: false)
        }

        _mode = .DONE
    }

    private func REMAL() throws {
        let object = try _stackReadRequiredString("album parameters")

        let (studies, albumUID) = try _albumParameters(object)

        let idatabase = try _stackIndependentDatabase()

        logged("-[O2DatabaseConnection REMAL]") {
            let album = idatabase.object(withID: albumUID) as AnyObject? // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: albumUID]]];
            let albumStudies = (album as? NSObject)?.mutableSetValue(forKey: "studies")

            if let studies {
                for uri in unsafeDowncast(studies, to: NSArray.self) {
                    let study = idatabase.object(withID: uri) as AnyObject? // (DicomStudy*) [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: uri]]];
                    _ = albumStudies?.perform(#selector(NSMutableSet.remove(_:)), with: study)
                    if let study {
                        unsafeBitCast(study, to: O2SharedDatabaseStudy.self).archiveAnnotationsAsDICOMSR()
                    }
                }
            }

            _ = idatabase.save(nil)

            BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("refreshDatabase:"), with: self, waitUntilDone: false)
        }

        _mode = .DONE
    }

    private func SETVA() throws {
        let objectId = try _stackReadRequiredString("object identifier")
        var value = try _stackReadString() // nil is a value here: it clears reportURL
        let key = try _stackReadRequiredString("key")

        // Only the keys the client sets, each with its type (#637): any other key
        // path closes the request before the database is touched.
        let kind = SharedDatabaseRequests.settableKind(forKey: key)
        if kind == .refused {
            throw _rejectRequest("key \(key) cannot be set remotely")
        }

        let idatabase = try _stackIndependentDatabase()

        // The request -_rejectRequest: raised inside the @try, which let it through.
        var rejection: String?
        logged("-[O2DatabaseConnection SETVA]") {
            let item = idatabase.object(withID: objectId) as? NSObject // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: object]]];

            if let item {
                if kind == .number {
                    item.setValue(NSNumber(value: (value as NSString?)?.intValue ?? 0), forKeyPath: key)
                } else if kind == .text {
                    item.setValue(value, forKeyPath: key)
                } else { // reportURL
                    let reports = idatabase.reportsDirPath() ?? ""
                    if value == nil {
                        // The report file goes only if it is one of the database's reports.
                        let current = item.value(forKey: "reportURL") as? String
                        if SharedDatabaseRequests.isPath(current, insideReportsDirectory: reports) {
                            try? FileManager.default.removeItem(atPath: current!)
                        } else if current != nil {
                            NSLog("Shared database: %@ cleared a report outside the reports folder; the file is kept", self.address)
                        }
                    } else {
                        value = SharedDatabaseRequests.reportPath(forName: value!, reportsDirectory: reports)
                        if value == nil {
                            rejection = "report name that does not stay in the reports folder"
                            return
                        }
                    }

                    item.setValue(value, forKey: "reportURL")
                }
            }

            _ = idatabase.save(nil)
        }
        if let rejection {
            throw _rejectRequest(rejection)
        }

        try objc { BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("refreshDatabase:"), with: self, waitUntilDone: false) }

        _mode = .DONE
    }

    private func MFILE() throws {
        var path = try _stackReadRequiredString("path")

        if (path as NSString).length > 0 {
            if (path as NSString).character(at: 0) != UInt16(UInt8(ascii: "/")) {
                path = try objc { ((DicomDatabase.default()?.baseDirPath as NSString?)?.appendingPathComponent(path)) ?? "" }
            }
        }
        path = try _servedPathForRequestedPath(path)
        try _requireLinkedPaths()

        let content = try objc { () -> Data? in
            let fattrs = (try? FileManager.default.attributesOfItem(atPath: path)) as NSDictionary?

            let date = fattrs?.object(forKey: FileAttributeKey.modificationDate) as? NSObject
            return (date?.description as NSString?)?.data(using: String.Encoding.unicode.rawValue)
        }

        writeData(content)

        _mode = .DONE
    }

    private func DCMSE() throws {
        let AETitle = try _stackReadRequiredString("AE title")
        var Address = try _stackReadRequiredString("address")
        let Port = try _stackReadRequiredString("port")
        let TransferSyntax = try _stackReadRequiredString("transfer syntax")

        let noOfFiles = try _stackReadCount()

        var localPaths = _stackedObject() as? NSMutableArray
        if localPaths == nil {
            localPaths = NSMutableArray()
            _stackObject(localPaths!)
        }

        while localPaths!.count < noOfFiles {
            let path = try _servedPathForRequestedPath(try _stackReadRequiredString("path"))

            localPaths!.add(path)

            _unstack() // the string
        }
        try _requireLinkedPaths()

        if (Address as NSString).isEqual(to: "127.0.0.1") {
            Address = address
        }

        let todo = NSDictionary(objects: [Address, TransferSyntax, Port, AETitle, localPaths!],
                                forKeys: ["Address", "TransferSyntax", "Port", "AETitle", "Files"] as [NSString])

        guard let publisher = try objc({ AppController.shared()?.bonjourPublisher }) else {
            throw O2Interrupt.exception(NSException(name: .invalidArgumentException,
                                                    reason: "*** +[NSThread detachNewThreadSelector:toTarget:withObject:]: target is nil", userInfo: nil))
        }
        try objc { Thread.detachNewThreadSelector(NSSelectorFromString("sendDICOMFilesToOsiriXNode:"), toTarget: publisher, with: todo) }

        _mode = .DONE
    }

    private func DICOM() throws {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let noOfFiles = try _stackReadCount()

        var localPaths = _stackedObject() as? NSMutableArray
        if localPaths == nil {
            localPaths = NSMutableArray()
            _stackObject(localPaths!)
        }
        var dstPaths = _stackedObject() as? NSMutableArray
        if dstPaths == nil {
            dstPaths = NSMutableArray()
            _stackObject(dstPaths!)
        }

        while localPaths!.count < noOfFiles {
            let path = try _servedPathForRequestedPath(try _stackReadRequiredString("path"))

            localPaths!.add(path)

            _unstack() // the string
        }

        while dstPaths!.count < noOfFiles {
            let path = try _stackReadRequiredString("destination path")

            dstPaths!.add(path)

            _unstack() // the string
        }

        // Nothing is written before every path is known to be served.
        try _requireLinkedPaths()

        var temp = UInt32(truncatingIfNeeded: noOfFiles).bigEndian
        writeData(Data(bytes: &temp, count: 4))
        for i in 0..<noOfFiles {
            let path = localPaths!.object(at: i) as! String

            let content = try objc { try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) }
            var size = UInt32(truncatingIfNeeded: content?.count ?? 0).bigEndian
            writeData(Data(bytes: &size, count: 4))
            writeData(content as Data?)

            let string = (dstPaths!.object(at: i) as! String).utf8CString
            var stringSize = UInt32(truncatingIfNeeded: string.count).bigEndian // +1 to include the last 0 !
            writeData(Data(bytes: &stringSize, count: 4))
            writeData(string.withUnsafeBufferPointer { Data(buffer: $0) })
        }

        _mode = .DONE
    }
}
