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
import IsiXDICOMNetwork
import IsiXPreferences

// BY DEFAULT OSIRIX USES 8780 PORT

/// Shares DB with Bonjour
///
/// Confined to the main actor, where everything reaches it: the preferences it
/// follows, the listener's reports and the advertisement it publishes. What is
/// announced, and the protocol the shared database speaks, are the rules of
/// IsiXDICOMNetwork; the connections run on the listener's workers and receive
/// what they need from here (`SharedDatabaseServing`).
@MainActor
@objc(BonjourPublisher)
public final class BonjourPublisher: NSObject, @preconcurrency NetServiceDelegate, @preconcurrency HorosDatabaseServerDelegate {
    private let processGraph: ProcessGraph
    private let sender: SharedDatabaseDICOMSender

    private var _listener: HorosDatabaseServer? // the Network.framework listener

    private var _bonjour: NetService?
    private var _advertisement: BonjourAdvertisement?

    @available(*, deprecated, message: "use -[[AppController sharedAppController] bonjourPublisher]")
    @objc(currentPublisher)
    public nonisolated class func currentPublisher() -> BonjourPublisher? {
        return ProcessGraph.process.bonjourPublisher
    }

    /// The publisher of the process, which the application controller makes at launch.
    public override convenience init() {
        self.init(processGraph: ProcessGraph.process)
    }

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
        sender = SharedDatabaseDICOMSender(processGraph: processGraph)
        super.init()
        let controller = NSUserDefaultsController.shared
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingIsActiveDefaultsKey, options: .initial, context: nil)
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingNameDefaultsKey, options: .initial, context: nil)
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingIsPasswordProtectedDefaultsKey, options: .initial, context: nil)
        controller.addObserver(self, forValuesKey: OsirixBonjourSharingPasswordDefaultsKey, options: .initial, context: nil)
    }

    isolated deinit {
        let controller = NSUserDefaultsController.shared
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingIsActiveDefaultsKey)
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingNameDefaultsKey)
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingIsPasswordProtectedDefaultsKey)
        controller.removeObserver(self, forValuesKey: OsirixBonjourSharingPasswordDefaultsKey)

        _listener?.delegate = nil
        _listener?.stop()
        _listener = nil
        _advertisement?.stop()
        _advertisement = nil
        _bonjour = nil
    }

    // The shared user defaults controller reports a preference on the thread
    // that wrote it: the change is handled on the main actor.
    public nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if object is NSUserDefaultsController {
            let keyPath = keyPath.map { ($0 as NSString).substring(from: 7) }
            if Self.isEqual(keyPath, OsirixBonjourSharingIsActiveDefaultsKey) {
                onMainActor { self.toggleSharing(UserDefaults.bonjourSharingIsActive()) }
                return
            } else if Self.isEqual(keyPath, OsirixBonjourSharingNameDefaultsKey) {
                // The advertisement carries the name: a new one replaces it (-updateBonjour).
                onMainActor { self.updateBonjour() }
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
    private nonisolated static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }

    @available(*, deprecated, message: "use -[[[AppController sharedAppController] bonjourPublisher] port]")
    @objc(OsiriXDBCurrentPort)
    public nonisolated func osiriXDBCurrentPort() -> Int32 {
        return onMainActorSync { Int32(truncatingIfNeeded: self._listener?.port ?? 0) }
    }

    @objc(toggleSharing:)
    public func toggleSharing(_ activate: Bool) {
        if activate && ProtectedMode.isActive {
            ProtectedMode.skip("Bonjour database sharing")
            return
        }
        // NSNetService and the direct-transfer service, reached by selector, are Objective-C.
        HorosObjCException.logged("-[BonjourPublisher toggleSharing:]", stack: true) {
            if activate && self._listener == nil {
                // The listener reports ready or failed on the main queue; the advertisement is published
                // only once it is ready (-databaseServerDidStart:), never for a port nothing listens on.
                let serving = SharedDatabaseServing(processGraph: self.processGraph, sender: self.sender)
                let listener = HorosDatabaseServer(port: SharedDatabaseAnnouncement.port) { peer in
                    O2DatabaseConnection.serve(peer, serving: serving)
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
    }

    public func databaseServerDidStart(_ server: HorosDatabaseServer) {
        if server !== _listener { return } // a stopped server's late callback
        NSLog("Horos database shared on port %ld", server.port)
        updateBonjour()
    }

    public func databaseServer(_ server: HorosDatabaseServer, didFailWithPOSIXError posixError: Int32, description: String) {
        if server !== _listener { return }
        NSLog("Warning: unable to share the Horos database on port 8780: %@", description)
        // The server stopped itself. Without a listener the advertisement goes: the
        // user is told why, and turning sharing off and on again tries the port once more.
        processGraph.appController?.reportListenBindFailure(forService: ListenBindFailure.databaseSharingService,
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
        let name = UserDefaults.bonjourSharingName()
        if SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: _bonjour?.port, advertisedName: _bonjour?.name,
                                                   listenerPort: listenerPort, name: name) {
            _bonjour?.delegate = nil
            _bonjour?.stop()
            _bonjour = nil
            _advertisement?.stop()
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
            // The advertisement is DNSServiceRegister: it refuses a port no
            // listener is on, takes the name the daemon gives it on a collision, and
            // retries only a transient daemon failure. The deprecated -netService
            // accessor keeps returning an NSNetService for its remaining callers.
            _advertisement = BonjourAdvertisement(name: name ?? "", type: SharedDatabaseAnnouncement.serviceType, port: listener.port)
            _bonjour = NetService(domain: "", type: SharedDatabaseAnnouncement.serviceType, name: name ?? "",
                                  port: Int32(truncatingIfNeeded: listener.port))
            _bonjour?.delegate = self
        }

        let preferences = processGraph.preferences
        var announcement = SharedDatabaseAnnouncement(aeTitle: preferences[NetworkPreferences.aeTitle],
                                                      dicomPort: preferences[NetworkPreferences.aePort],
                                                      uid: AppController.uid())

        let directPolicy: AnyClass? = NSClassFromString("HorosDirectTransferPolicy")
        let directService: AnyClass? = NSClassFromString("HorosDirectTransferService")
        if let directService, directService.responds(to: NSSelectorFromString("sharedService")) {
            _ = (directService as AnyObject).perform(NSSelectorFromString("sharedService"))?
                .takeUnretainedValue().perform(NSSelectorFromString("startIfSharingActive"))
        }
        if let directPolicy, directPolicy.responds(to: NSSelectorFromString("bonjourTXTFields")) {
            let capability = (directPolicy as AnyObject).perform(NSSelectorFromString("bonjourTXTFields"))?
                .takeUnretainedValue() as? [String: Any]
            announcement.directTransferVersion = capability?["HorosDirectTransferVersion"] as? String
            announcement.directTransferPort = capability?["HorosDirectTransferPort"] as? String
        }

        let record = announcement.txtRecord
        if _bonjour?.setTXTRecord(Self.dataFromTXTRecordDictionary(record)) != true {
            NSLog("Warning: Horos Bonjour net service setTXTRecordData FAILED")
        }

        _advertisement?.publish(txtRecord: record)
    }

    /// +[NSNetService dataFromTXTRecordDictionary:], given the values as they are
    /// (strings): the Swift overlay takes only Data values.
    private static func dataFromTXTRecordDictionary(_ record: [String: String]) -> Data? {
        return (NetService.self as AnyObject).perform(NSSelectorFromString("dataFromTXTRecordDictionary:"), with: record)?
            .takeUnretainedValue() as? Data
    }

    /** The native DNS-SD advertisement this publisher uses; nil while sharing is off. */
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

    /// The TXT record of a shared database Bonjour found, as the Sources list
    /// keeps it (SharedDatabaseServiceRecord). A text key without a value is
    /// empty text; one that is not UTF-8 raises, as it always did.
    @objc(dictionaryFromXTRecordData:)
    public nonisolated class func dictionaryFromXTRecordData(_ data: Data?) -> NSDictionary {
        let d = NSMutableDictionary()
        // The Objective-C method, not the Swift overlay: a key without a value
        // comes as NSNull, which the overlay's [String: Data] cannot hold, and
        // nil raises as it did.
        guard let dict = (NetService.self as AnyObject).perform(NSSelectorFromString("dictionaryFromTXTRecordData:"), with: data)?
                .takeUnretainedValue() as? [String: Any] else { return d }

        let entries = dict.mapValues { ($0 as? Data).map(SharedDatabaseServiceRecord.Value.data) ?? .none }
        do {
            for (key, value) in try SharedDatabaseServiceRecord.decode(entries) {
                switch value {
                case .text(let text): d[key] = text
                case .data(let bytes): d[key] = bytes
                case .none: d[key] = NSNull()
                }
            }
        } catch {
            switch error {
            case .notUTF8(let key):
                NSException(name: .invalidArgumentException,
                            reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(key))", userInfo: nil).raise()
            }
        }

        return d
    }

    /// Sends now, after the sends the clients already ordered, and returns once
    /// it is done.
    @objc(sendDICOMFilesToOsiriXNode:)
    public nonisolated func sendDICOMFiles(toOsiriXNode todo: NSDictionary) {
        sender.sendAndWait(calledAET: todo.object(forKey: "AETitle") as? String,
                           hostname: todo.object(forKey: "Address") as? String,
                           port: (todo.object(forKey: "Port") as? NSString)?.intValue ?? 0,
                           files: todo.object(forKey: "Files") as? [Any],
                           transferSyntax: (todo.object(forKey: "TransferSyntax") as? NSString)?.intValue ?? 0)
    }
}

/// What a connection of the shared database receives from the publisher that
/// serves it, instead of reaching for the application's singletons.
struct SharedDatabaseServing: Sendable {
    let processGraph: ProcessGraph
    let sender: SharedDatabaseDICOMSender

    /// The database this app shares, and the only one a request reaches: the
    /// default database, whichever local database the browser shows.
    ///
    /// A peer reads this database and no other: the index it copies (`DATAB`),
    /// its size (`DBSIZ`) and date (`VERSI`), the files it names (`DICOM`,
    /// `DCMSE`, `MFILE`) and the objects it changes (`SETVA`, `ADDAL`, `REMAL`).
    /// The files it sends (`SENDD`, `SENDG`) are therefore written into this
    /// database's folder and indexed in it, where the peer finds them. Writing
    /// them into the folder of the database the browser shows, while the index
    /// is this one, left them in one database and their index in another.
    /// It needs no main actor: the browser is not asked.
    var sharedDatabase: DicomDatabase? {
        processGraph.defaultDatabase
    }
}

/// The DICOM sends that clients of the shared database order (`DCMSE`), one at
/// a time, as the publisher's lock made them.
///
/// The actor runs on a serial queue of its own: a send lasts as long as its
/// transfer, and it does not hold a thread of the shared pool meanwhile. The
/// Objective-C entry, which always returned once its send was done, waits on
/// the same queue.
actor SharedDatabaseDICOMSender {
    private nonisolated let queue = DispatchSerialQueue(label: "org.horosproject.shared-database.dicom-send", qos: .utility)
    private nonisolated let processGraph: ProcessGraph

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    /// Queues the send a client ordered and returns at once.
    nonisolated func enqueue(_ order: SharedDatabaseSendOrder) {
        Task { await self.send(order) }
    }

    private func send(_ order: SharedDatabaseSendOrder) {
        Self.run(calledAET: order.aeTitle, hostname: order.address, port: order.portNumber, files: order.files,
                 transferSyntax: order.transferSyntaxNumber, processGraph: processGraph)
    }

    /// Sends after the sends already queued, and returns once it is done.
    nonisolated func sendAndWait(calledAET: String?, hostname: String?, port: Int32, files: [Any]?, transferSyntax: Int32) {
        let processGraph = processGraph
        queue.sync {
            Self.run(calledAET: calledAET, hostname: hostname, port: port, files: files,
                     transferSyntax: transferSyntax, processGraph: processGraph)
        }
    }

    private nonisolated static func run(calledAET: String?, hostname: String?, port: Int32, files: [Any]?,
                                        transferSyntax: Int32, processGraph: ProcessGraph) {
        autoreleasepool {
            guard let database = processGraph.defaultDatabase else {
                // +[NSDictionary dictionaryWithObject:forKey:] refused the nil database.
                _N2LogExceptionImpl(NSException(name: .invalidArgumentException,
                                                reason: "*** +[NSDictionary dictionaryWithObject:forKey:]: object cannot be nil", userInfo: nil),
                                    true, "-[BonjourPublisher sendDICOMFilesToOsiriXNode:]")
                return
            }
            let storeSCU = DCMTKStoreSCU(callingAET: processGraph.preferences[NetworkPreferences.aeTitle],
                                         calledAET: calledAET,
                                         hostname: hostname,
                                         port: port,
                                         filesToSend: files,
                                         transferSyntax: transferSyntax,
                                         compression: 1.0,
                                         extraParameters: ["DicomDatabase": database]) // nil == TLS not supported !

            do {
                try storeSCU.sendFiles()
            } catch {
                let failure = error as? StoreSendFailure
                NSLog("Bonjour DICOM Send FAILED")
                NSLog("%@", (failure?.name ?? "") as NSString)
                NSLog("%@", (failure?.reason ?? error.localizedDescription) as NSString)
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
// O2InvalidRequest and let any other exception reach -run.
// @unchecked Sendable, which Error requires: NSException is not declared
// Sendable. The interrupt is thrown and caught on the one worker thread that
// runs the request, and the exception it carries is never changed after it
// was raised.
private enum O2Interrupt: Error, @unchecked Sendable {
    // A request that breaks the protocol: the connection is closed, nothing
    // further of it is read or executed.
    case invalidRequest(String) // O2InvalidRequest
    case exception(NSException)
}

// One request of one client. It runs synchronously on a worker of HorosDatabaseServer: it reads from its
// HorosDatabasePeer until the request is complete, answers, and ends the stream. What the bytes say -
// the command, its parameters, every length, count and string, and the shape of each answer - is read
// and written by IsiXDICOMNetwork (SharedDatabaseRequestParser, SharedDatabaseReply); this class does
// what a request asks of the database and of the files.
@objc(O2DatabaseConnection)
public final class O2DatabaseConnection: NSObject {
    private var _parser = SharedDatabaseRequestParser()
    private var _done = false // the request is complete and answered
    private var _closed = false // the request was refused or broke the protocol: nothing more is read or sent
    private let _readBuffer = NSMutableData()
    private var _readOffset = 0 // bytes of _readBuffer the parser consumed, removed once per pass
    private let _peer: HorosDatabasePeer
    private let _serving: SharedDatabaseServing
    private var _requestPaths: SharedDatabaseRequestPaths? // the folders this request's paths resolve against
    private var _linkedPaths: NSMutableSet? // its absolute paths outside them
    private var _servedPaths: [String] = [] // the files a DICOM or DCMSE request names, resolved as they come
    private var _savedFiles: [String] = [] // the files of an upload, written as they come
    private var _sharedDatabase: DicomDatabase? // the shared database, read once per request
    private var _sharedDatabaseKnown = false
    private var _requestDatabase: DicomDatabase? // its index, a private-queue context of this connection

    /// A connection served with the process's own dependencies, for a caller
    /// that is not the publisher. Its DICOM sends are queued on a queue of its own.
    @objc(servePeer:)
    public class func serve(_ peer: HorosDatabasePeer) {
        let processGraph = ProcessGraph.process
        serve(peer, serving: SharedDatabaseServing(processGraph: processGraph,
                                                   sender: SharedDatabaseDICOMSender(processGraph: processGraph)))
    }

    static func serve(_ peer: HorosDatabasePeer, serving: SharedDatabaseServing) {
        let connection = O2DatabaseConnection(peer: peer, serving: serving)
        connection.run()
    }

    private init(peer: HorosDatabasePeer, serving: SharedDatabaseServing) {
        _peer = peer
        _serving = serving
        super.init()
    }

    private func _rejectRequest(_ reason: String) -> O2Interrupt {
        return .invalidRequest(reason)
    }

    /// Whether the server asks for a password, and which, as the preferences hold them now.
    private static func access() -> SharedDatabaseAccess {
        SharedDatabaseAccess(isPasswordProtected: UserDefaults.bonjourSharingIsPasswordProtected(),
                             password: UserDefaults.bonjourSharingPassword())
    }

    // Everything still unconsumed in the receive buffer for the current request.
    // Reads arrive in blocks, and a block bounds nothing about the request.
    private func _closeIfBufferExceedsLimit() {
        let limit = _parser.maximumBufferedBytes
        if availableSize > limit {
            NSLog("Shared database: request from %@ closed: more than %ld bytes buffered", address, limit)
            close()
        }
    }

    // The request, on this worker, from its first byte to the end of its answer. Every wait for the
    // network ends: the peer times out after its idle limit of monotonic time, fails with the
    // connection, or is cancelled when sharing stops. Nothing thrown here reaches the Swift worker.
    private func run() {
        defer { _peer.cancel() }
        do {
            while !_done && !_closed {
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
                        if !_parser.isAwaitingCommand || availableSize != 0 {
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

    // Refuses the request: nothing more of it is read or answered, and the stream is not ended
    // cleanly, so the client sees the connection close without a response.
    private func close() {
        _closed = true
        _peer.cancel()
    }

    // Reads what has arrived, as far as it goes: each uploaded file is written and each requested
    // path resolved as soon as it is complete, and a complete request is executed and answered.
    private func handleData() throws {
        do {
            while !_done && !_closed {
                let unread = UnsafeRawBufferPointer(start: _readBuffer.bytes + _readOffset, count: availableSize)
                let (event, consumed) = _parser.next(unread, access: Self.access)
                _readOffset += consumed
                switch event {
                case .needsMoreData:
                    _closeIfBufferExceedsLimit()
                    return
                case .refused:
                    close()
                    return
                case .rejected(let reason):
                    throw _rejectRequest(reason)
                case .uploadedFile(let range):
                    try _saveUploadedFile(UnsafeRawBufferPointer(rebasing: unread[range]))
                case .requestedPaths(let paths):
                    for path in paths {
                        _servedPaths.append(try _servedPathForRequestedPath(path))
                    }
                case .complete(let request):
                    // The handlers that read or change the index run inside its
                    // context's queue, the objects of the request never leave it.
                    if _parser.command?.usesIndex == true {
                        try _onRequestDatabaseQueue { try _execute(request) }
                    } else {
                        try _execute(request)
                    }
                    _done = true
                }
            }
        } catch O2Interrupt.invalidRequest(let reason) {
            NSLog("Shared database: request from %@ closed: %@", address, reason)
            close()
        }
        // A complete request is answered by now: -run ends the stream.
    }

    private func _execute(_ request: SharedDatabaseRequest) throws {
        switch request {
        case .authorizationVersion:
            writeData(SharedDatabaseReply.authorizationVersion)
        case .database:
            try DATAB()
        case .databaseSize:
            try DBSIZ()
        case .destinationInfo:
            try GETDI()
        case .modificationTime:
            try VERSI()
        case .databaseVersion:
            writeData(SharedDatabaseReply.databaseVersion(_serving.processGraph.preferences[DatabasePreferences.databaseVersion]))
        case .isPasswordProtected:
            // is this database protected by a password
            writeData(SharedDatabaseReply.answer(UserDefaults.bonjourSharingIsPasswordProtected()))
        case .password(let offered):
            writeData(SharedDatabaseReply.answer(Self.access().accepts(offered)))
        case .upload(let generatedByViewer, _):
            try SEND(generatedByViewer: generatedByViewer)
        case .message:
            break // is this used ? nah
        case .album(let adding, let parameters):
            try ALBUM(adding: adding, parameters: parameters)
        case .setAttribute(let objectID, let value, let key):
            try SETVA(objectID: objectID, value: value, key: key)
        case .fileDate(let path):
            try MFILE(path)
        case .dicomSend(let order):
            try DCMSE(order)
        case .fetch(let destinations):
            try DICOM(destinations: destinations)
        }
    }

    // The database of this request (SharedDatabaseServing.sharedDatabase), read once: the files of
    // an upload are written into its folder and indexed in its index, the paths a request names
    // resolve against its folders, and every answer describes it. Nothing reads another.
    private func _database() throws -> DicomDatabase? {
        if !_sharedDatabaseKnown {
            let serving = _serving
            _sharedDatabase = try HorosObjCException.throwing(O2Interrupt.exception) { serving.sharedDatabase }
            _sharedDatabaseKnown = true
        }
        return _sharedDatabase
    }

    private func _requestIndexDatabase() throws -> DicomDatabase {
        if let database = _requestDatabase {
            return database
        }
        let shared = try _database()
        guard let database = try HorosObjCException.throwing(O2Interrupt.exception, { shared?.privateQueueIndependentDatabase() }) as? DicomDatabase else {
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

    /// -[NSMutableArray addObject:] raised on nil.
    private static func nilObject() -> O2Interrupt {
        return .exception(NSException(name: .invalidArgumentException,
                                      reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil))
    }

    // Written from the receive buffer, where the parser found the file, without a copy, into the
    // folder of the database whose index SEND adds it to.
    private func _saveUploadedFile(_ bytes: UnsafeRawBufferPointer) throws {
        let database = try _database()
        let dstPath = try HorosObjCException.throwing(O2Interrupt.exception) { database?.uniquePathForNewDataFile(withExtension: "dcm") }

        let data = bytes.isEmpty ? NSData()
            : NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), length: bytes.count, freeWhenDone: false)
        // -writeToFile:atomically: answers its failure; the file is listed all the same, as it was.
        _ = dstPath.map { data.write(toFile: $0, atomically: true) }

        guard let dstPath else { throw Self.nilObject() }
        _savedFiles.append(dstPath)
    }

    // Asks the browser, on the main actor, to show what a request changed.
    private func _refreshBrowser() {
        let processGraph = _serving.processGraph
        Task { @MainActor in processGraph.currentBrowser?.refreshDatabase(nil) }
    }

    // The file a request names. A relative path is an image of
    // DATABASE.noindex by its name, or an older client's ROI; an absolute path is
    // used as it is. A path of another shape, or with a `.` or `..` component, closes
    // the request. An absolute path outside the database's folders is kept for
    // -_requireLinkedPaths, which decides once every path of the request is known.
    private func _servedPathForRequestedPath(_ requested: String) throws -> String {
        if _requestPaths == nil {
            // Once per request: a DCMSE names a path per image.
            let database = try _database()
            _requestPaths = try HorosObjCException.throwing(O2Interrupt.exception) {
                SharedDatabaseRequestPaths(databaseDirectory: ((database?.sqlFilePath ?? "") as NSString).deletingLastPathComponent as NSString,
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
        let database = try _database()
        var raised: NSException?
        let known = SharedDatabaseLinkedPaths.shared.containsAll(linkedPaths, indexFile: (database?.sqlFilePath ?? "") as NSString) { paths in
            // Only the paths, as dictionaries: no image is materialized.
            var found: [Any] = []
            // An exception of the lookup ends the request, as it did, once the
            // shared cache is left consistent.
            raised = HorosObjCException.caught {
                // Only values come back: a private-queue context, fetched on its queue.
                let index = database?.privateQueueIndependentDatabase() as? DicomDatabase
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Image")
                request.predicate = NSPredicate(format: "pathString IN %@", paths)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["pathString"]
                // -executeFetchRequest:error:, as before (NSManagedObjectContext.fetch
                // sends -executeRequest:error:).
                let rows = (try? index?.managedObjectContext.__execute(request)) as? [[String: Any]]
                found = rows?.compactMap { $0["pathString"] } ?? []
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
        let idatabase = try _requestIndexDatabase()

        // The locker keeps the persistentStoreCoordinator locked until the answer is written.
        var locker: N2Locker?
        try HorosObjCException.throwing(O2Interrupt.exception) {
            locker = N2Locker.lock(idatabase.managedObjectContext.persistentStoreCoordinator) // this object unlocks the persistentStoreCoordinator when released
            idatabase.save()
        }

        var representationToSend: NSMutableData?
        HorosObjCException.logged("-[O2DatabaseConnection DATAB]", stack: true) {
            // we send the database SQL file
            let databasePath = idatabase.sqlFilePath

            representationToSend = databasePath.flatMap { NSMutableData(contentsOfFile: $0) }
        }

        if let representationToSend {
            writeData(representationToSend as Data)
        }

        NSLog("Bonjour connection received from %@", address)

        withExtendedLifetime(locker) {}
    }

    private func DBSIZ() throws {
        let idatabase = try _requestIndexDatabase()

        var fileSize: UInt64 = 0

        var locker: N2Locker? = try HorosObjCException.throwing(O2Interrupt.exception) { N2Locker.lock(idatabase.managedObjectContext.persistentStoreCoordinator) }
        HorosObjCException.logged("-[O2DatabaseConnection DBSIZ]", stack: true) {
            idatabase.save()

            let databasePath = idatabase.sqlFilePath ?? ""

            let fattrs = try? FileManager.default.attributesOfItem(atPath: databasePath)

            fileSize = (fattrs?[FileAttributeKey.size] as? NSNumber)?.uint64Value ?? 0
        }
        try HorosObjCException.throwing(O2Interrupt.exception) {
            withExtendedLifetime(locker) {}
            locker = nil // unlocks the persistentStoreCoordinator
        }

        // Four bytes, read unsigned by the client: an index of 4 GiB or more is
        // answered with the value that says so, never with its size wrapped.
        if SharedDatabaseReply.indexSizeValue(fileSize) == SharedDatabaseReply.indexTooLargeForReply {
            NSLog("Shared database: the index (%llu bytes) is too large to be shared with %@", fileSize, address)
        }
        writeData(SharedDatabaseReply.indexSize(fileSize))
    }

    private func GETDI() throws {
        let preferences = _serving.processGraph.preferences
        let syntax = DCMTKStoreSCU.sendSyntax(forListenerSyntax: Int32(truncatingIfNeeded: preferences[NetworkPreferences.preferredSyntaxForIncoming]))
        let entries = SharedDatabaseReply.destinationInfo(aeTitle: preferences[NetworkPreferences.aeTitle],
                                                          port: preferences[NetworkPreferences.aePort],
                                                          transferSyntax: syntax)
        let dictionary = NSDictionary(objects: entries.map(\.value), forKeys: entries.map { $0.key as NSString })

        // NSArchiver data, which released clients decode with NSUnarchiver. This
        // client reads it with SharedDatabaseDestinationInfo, which accepts a
        // dictionary of strings and nothing else.
        writeData(try HistoricalArchive.archivedData(withRootObject: dictionary))
    }

    private func VERSI() throws {
        let idatabase = try _requestIndexDatabase()

        let val = idatabase.timeOfLastModification

        writeData(SharedDatabaseReply.modificationTime(val))
    }

    private func SEND(generatedByViewer: Bool) throws {
        let idatabase = try _requestIndexDatabase()

        let savedFiles = _savedFiles
        var added: [Any]?
        let objects = try HorosObjCException.throwing(O2Interrupt.exception) { () -> [Any]? in
            added = DatabaseIngest.process.index(savedFiles, preset: generatedByViewer ? .sharedDatabaseGenerated : .sharedDatabaseReceived, in: idatabase)
            return idatabase.objects(withIDs: added) as [Any]?
        } ?? []
        // A client writes the annotations SR of a study it shows and sends it here: it takes the place of the
        // study's earlier ones, as one written here does, since the client cannot remove them from this index.
        if generatedByViewer {
            AnnotationsSRPruning.removeEarlier(than: added, in: idatabase)
        }

        var pathNumbers: [Int32] = []
        for image in objects {
            let number = try HorosObjCException.throwing(O2Interrupt.exception) { unsafeBitCast(image as AnyObject, to: O2SharedDatabaseImage.self).pathNumber }
            pathNumbers.append(number?.int32Value ?? 0)
        }

        writeData(SharedDatabaseReply.upload(pathNumbers: pathNumbers))
    }

    /// The album parameters of ADDAL and REMAL: a property list whose albumStudies
    /// and albumUID are read as -objectForKey: read them.
    private func _albumParameters(_ object: String) throws -> (studies: Any?, albumUID: Any?) {
        guard let d = try? PropertyListSerialization.propertyList(from: Data(object.utf8), options: [], format: nil) else {
            throw O2Interrupt.exception(NSException(name: .genericException, reason: "can't parse parameters", userInfo: nil))
        }
        guard let parameters = d as? [String: Any] else {
            // -objectForKey: sent to a property list that is not a dictionary.
            throw O2Interrupt.exception(NSException(name: .invalidArgumentException,
                                                    reason: "-[\(type(of: d as AnyObject)) objectForKey:]: unrecognized selector sent to instance",
                                                    userInfo: nil))
        }
        return (parameters["albumStudies"], parameters["albumUID"])
    }

    private func ALBUM(adding: Bool, parameters object: String) throws {
        let (studies, albumUID) = try _albumParameters(object)

        let idatabase = try _requestIndexDatabase()

        HorosObjCException.logged(adding ? "-[O2DatabaseConnection ADDAL]" : "-[O2DatabaseConnection REMAL]", stack: true) {
            let album = idatabase.object(withID: albumUID) as AnyObject? // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: albumUID]]];
            let albumStudies = (album as? NSObject)?.mutableSetValue(forKey: "studies")

            if let studies {
                guard let uris = studies as? [Any] else {
                    // Fast enumeration of a value that is not a collection.
                    NSException(name: .invalidArgumentException,
                                reason: "-[\(type(of: studies as AnyObject)) countByEnumeratingWithState:objects:count:]: unrecognized selector sent to instance",
                                userInfo: nil).raise()
                    return
                }
                for uri in uris {
                    let study = idatabase.object(withID: uri) as AnyObject? // (DicomStudy*) [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: uri]]];
                    if let albumStudies {
                        guard let study else {
                            NSException(name: .invalidArgumentException,
                                        reason: "*** -[__NSSetM \(adding ? "addObject" : "removeObject"):]: object cannot be nil", userInfo: nil).raise()
                            return
                        }
                        if adding {
                            albumStudies.add(study)
                        } else {
                            albumStudies.remove(study)
                        }
                    }
                    if let study {
                        unsafeBitCast(study, to: O2SharedDatabaseStudy.self).archiveAnnotationsAsDICOMSR()
                    }
                }
            }

            _ = idatabase.save(nil)

            self._refreshBrowser()
        }
    }

    private func SETVA(objectID objectId: String, value: String?, key: String) throws {
        var value = value // nil is a value here: it clears reportURL

        // Only the keys the client sets, each with its type: any other key
        // path closes the request before the database is touched.
        let kind = SharedDatabaseRequests.settableKind(forKey: key)
        if kind == .refused {
            throw _rejectRequest("key \(key) cannot be set remotely")
        }

        let idatabase = try _requestIndexDatabase()

        // The request -_rejectRequest: raised inside the @try, which let it through.
        var rejection: String?
        HorosObjCException.logged("-[O2DatabaseConnection SETVA]", stack: true) {
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

        _refreshBrowser()
    }

    private func MFILE(_ requested: String) throws {
        var path = requested

        if (path as NSString).length > 0 {
            if (path as NSString).character(at: 0) != UInt16(UInt8(ascii: "/")) {
                let database = try _database()
                path = ((database?.baseDirPath as NSString?)?.appendingPathComponent(path)) ?? ""
            }
        }
        path = try _servedPathForRequestedPath(path)
        try _requireLinkedPaths()

        let fattrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = fattrs?[FileAttributeKey.modificationDate] as? NSObject
        let content = SharedDatabaseReply.fileDate(date?.description)

        writeData(content)
    }

    private func DCMSE(_ order: SharedDatabaseSendOrder) throws {
        try _requireLinkedPaths()

        var order = order.resolvingLoopback(peerAddress: address)
        order.files = _servedPaths

        _serving.sender.enqueue(order)
    }

    private func DICOM(destinations: [String]) throws {
        // Nothing is written before every path is known to be served.
        try _requireLinkedPaths()

        writeData(SharedDatabaseReply.fetchCount(_servedPaths.count))
        for (path, destination) in zip(_servedPaths, destinations) {
            let content = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            writeData(SharedDatabaseReply.fetchedFileLength(content?.count ?? 0))
            writeData(content)

            let frame = SharedDatabaseReply.destinationPath(destination)
            writeData(frame.length)
            writeData(frame.path)
        }
    }
}
