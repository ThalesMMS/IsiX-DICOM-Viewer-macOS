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
import Synchronization
import IsiXDatabase
import IsiXPreferences

/// How many requests that are not urgent may be connected to one remote database at once.
private let MAX_SIMULTANEOUS_NONURGENT_CONNECTIONS = 4

/// What ends a request of the shared-database client. The Swift side throws
/// it; the Objective-C entry points raise it as the exception the former
/// client raised: `failed` with that exception's name and reason, `raised` as
/// the exception Objective-C code raised under a guard.
/// @unchecked Sendable, which Error requires: NSException is not declared
/// Sendable, and the failure is thrown and caught on the thread of its request.
private enum SharedDatabaseClientFailure: Error, @unchecked Sendable {
    case failed(NSExceptionName, String)
    case raised(NSException)

    /// What -addObject: of a mutable array raised on nil.
    static let nilObject = failed(.invalidArgumentException, "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
    static let notConnected = failed(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: ""))
    static let invalidResponse = failed(.internalInconsistencyException, NSLocalizedString("Invalid response data from remote host.", comment: ""))

    /// The exception an Objective-C caller receives for `error`.
    static func exception(for error: Error) -> NSException {
        switch error as? SharedDatabaseClientFailure {
        case .failed(let name, let reason)?:
            return NSException(name: name, reason: reason, userInfo: nil)
        case .raised(let exception)?:
            return exception
        case nil:
            return NSException(name: .genericException, reason: error.localizedDescription, userInfo: nil)
        }
    }
}

/// An Objective-C entry point of the client: what `body` throws is raised for
/// the caller, as the former client raised it.
private func raisingForObjectiveC<T>(_ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        SharedDatabaseClientFailure.exception(for: error).raise()
        preconditionFailure(error.localizedDescription)
    }
}

/// -[NSMutableArray addObject:], which refused nil where Swift would add NSNull.
private func remoteDicomDatabaseAdd(_ array: NSMutableArray, _ object: Any?) throws {
    guard let object else { throw SharedDatabaseClientFailure.nilObject }
    array.add(object)
}

// A retry owns a fresh protocol state and discards only its unfinished file.
private func horosCleanupRemoteDownload(_ context: NSMutableDictionary) {
    let values = context.object(forKey: "state") as? NSMutableArray
    if let values, values.count > 5 { (values.object(at: 5) as? Stream)?.close() }
    if let values, values.count > 4, let path = values.object(at: 4) as? String {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func horosResetRemoteDownload(_ context: NSMutableDictionary) {
    horosCleanupRemoteDownload(context)
    context.setObject(NSMutableArray(object: N2MutableUInteger.mutableUInteger(with: 0)), forKey: "state" as NSString)
    context.setObject(NSMutableSet(array: (context.object(forKey: "expected") as? [Any]) ?? []), forKey: "remaining" as NSString)
}

// One request on one NWConnection, on the calling thread's terms. The
// six-byte command, the integer order, the archives and the end-of-response by
// close are the protocol's, unchanged; the thread and run loop per request are
// gone, and a partial response is an error rather than a short success.
private func horosSendDatabaseRequest(_ request: NSData, _ address: String?, _ port: Int,
                                      _ handler: ((NSData?) -> Int)?) throws -> NSData {
    let thread = Thread.current
    var receiving: DatabaseTransport.Receiver? = nil
    if let handler {
        receiving = { data, handlerError in
            // The handler is a method of any object, by its selector: an
            // Objective-C exception it raises must not cross into Swift.
            var consumed = 0
            if let exception = HorosObjCException.caught({ consumed = handler(data as NSData?) }) {
                handlerError.pointee = NSError(domain: "HorosDatabaseResponse", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: exception.reason ?? exception.name.rawValue])
                return -1
            }
            return consumed
        }
    }
    do {
        return try DatabaseTransport.sendRequest(request as Data, toHost: address ?? "", port: port,
                                                 receiving: receiving, cancelled: { thread.isCancelled }) as NSData
    } catch {
        // The transport always describes its failure; "The shared-database
        // request failed." was the Objective-C fallback for an error without one.
        throw SharedDatabaseClientFailure.failed(.objectInaccessibleException, (error as NSError).localizedDescription)
    }
}

/// Removes a directory when it is released. A RemoteDicomDatabase holds one from
/// its -dealloc: Swift releases the ivars after the superclasses' -dealloc, which
/// is where the former -dealloc removed its base directory.
private final class RemoteDicomDatabaseDirectoryRemoval {
    private let path: String

    init(path: String) {
        self.path = path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// What the server did not receive of the files a shared database added. They
/// stay where the sending found them, in the temporary folder of the database
/// or where the person had them, and each update of the index sends them again,
/// as they were added. The person is told of the first failure, and of the next
/// only once everything has arrived in between.
private final class RemoteDicomDatabaseWaitingUploads: Sendable {
    struct Batch: Sendable {
        let paths: [String]
        let generatedByOsiriX: Bool
    }

    private let state = Mutex<(batches: [Batch], told: Bool)>(([], false))

    /// Keeps `batch` for the next attempt: whether the person is to be told now.
    func keep(_ batch: Batch) -> Bool {
        state.withLock { state in
            defer { state.told = true }
            state.batches.append(batch)
            return !state.told
        }
    }

    /// The batches that wait, which no longer do: an attempt keeps again what
    /// fails, and two attempts never send the same file.
    func takeAll() -> [Batch] {
        state.withLock { state in
            defer { state.batches = [] }
            return state.batches
        }
    }

    /// An upload arrived whole: with nothing waiting, the next failure is told.
    func arrived() {
        state.withLock { state in
            if state.batches.isEmpty { state.told = false }
        }
    }
}

/// An index an update replaced: its file, and the coordinator that opened it,
/// which lives as long as a context uses it.
private struct RemoteDicomDatabaseReplacedIndex {
    weak var coordinator: NSPersistentStoreCoordinator?
    let url: URL
}

/// A key image marked on an image the database had just added, which the
/// server learns of once an update brings the image: its SOP instance, as the
/// index keeps it, and its frame.
private struct RemoteDicomDatabaseWaitingKeyImage {
    let sopInstanceUID: Data
    let frameID: NSNumber?
}

@objc(RemoteDicomDatabase)
public final class RemoteDicomDatabase: DicomDatabase {
    // The former ivars. Their zero values are those of an independent database,
    // which -[N2ManagedDatabase independentDatabase] creates with the inherited
    // initializer, as before. The properties are dynamic: Objective-C, key-value
    // coding and observing reach them by message, as they did.
    private var _baseBaseDirPath: String? = nil
    private var _sqlFileName: String? = nil
    private var _address: String? = nil
    private var _port: Int = 0
    private var _host: Host? = nil
    private var _updateLock: NSRecursiveLock? = nil
    private var _updateTimer: Timer? = nil
    private var _timestamp: TimeInterval = 0
    private var _connectionsSemaphoreId: DispatchSemaphore? = nil
    private var _password: String? = nil
    private var _requiresAuthenticatedRequests = false
    private var _authenticationKnown = false
    /// Set by deinit for a main database: removes its base directory after the superclasses' -dealloc.
    private var _baseBaseDirRemoval: RemoteDicomDatabaseDirectoryRemoval? = nil
    /// The main database's: the files its uploads could not send yet.
    private let waitingUploads = RemoteDicomDatabaseWaitingUploads()
    /// The indexes updates replaced, until nothing uses them. On the main thread.
    private var _replacedIndexes: [RemoteDicomDatabaseReplacedIndex] = []
    /// The main database's: key images the server does not have yet. On the main thread.
    private var _waitingKeyImages: [RemoteDicomDatabaseWaitingKeyImage] = []

    @objc public private(set) dynamic var address: String? {
        get { return _address }
        set { _address = newValue }
    }

    @objc public private(set) dynamic var port: Int {
        get { return _port }
        set { _port = newValue }
    }

    @objc public private(set) dynamic var host: Host? {
        get { return _host }
        set { _host = newValue }
    }

    /// Private, as before; set by key-value coding by the probes.
    @objc dynamic var password: String? {
        get { return _password }
        set { _password = newValue }
    }

    @objc dynamic var authenticationKnown: Bool {
        get { return _authenticationKnown }
        set { _authenticationKnown = newValue }
    }

    @objc dynamic var requiresAuthenticatedRequests: Bool {
        get { return _requiresAuthenticatedRequests }
        set { _requiresAuthenticatedRequests = newValue }
    }

    @objc(NSManagedObjectContextClass)
    public override func nsManagedObjectContextClass() -> AnyClass! {
        return RemoteDicomDatabaseManagedObjectContext.self
    }

    @objc(databaseForLocation:port:name:update:)
    public class func database(forLocation location: String!, port: UInt, name: String!, update flagUpdate: Bool) -> RemoteDicomDatabase! {
        var host: Host? = nil
        var outputPort: Int = 0
        _ = RemoteDatabaseNodeIdentifier.location(location, port: port, to: &host, port: &outputPort)

        return raisingForObjectiveC {
            if (host?.addresses.count ?? 0) == 0 && (host?.names.count ?? 0) == 0 {
                throw SharedDatabaseClientFailure.failed(.genericException, NSLocalizedString("This remote database is unaccessible because its address could not be resolved.", comment: ""))
            }

            let dbs = DicomDatabase.allDatabases() ?? []
            for case let db as RemoteDicomDatabase in dbs {
                if db.port == outputPort, let dbAddress = db.host?.address, let hostAddress = host?.address,
                   (dbAddress as NSString).isEqual(to: hostAddress) {
                    if flagUpdate {
                        try db.updateIndex()
                    }
                    return db
                }
            }

            NSLog("-- Remote database created")

            // With the port the lookup above compared, the one the location
            // resolves to: the port given is 0 when the default one is meant, and
            // a database created with it was never found again. A database whose
            // first update fails is released, as -initWithHost:port:update: did.
            let db = RemoteDicomDatabase(host: host, port: outputPort, update: false)
            if flagUpdate {
                try db?.updateIndex()
            }
            if name != nil {
                db?.name = name
            }

            return db
        }
    }

    // MARK: Instance

    public override func dataNodeIdentifier() -> DataNodeIdentifier! {
        return RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: self.address, port: UInt(bitPattern: self.port), description: self.description, dictionary: nil) as? DataNodeIdentifier
    }

    public dynamic override var name: String! {
        get {
            let displayedHost: String = self.host?.name ?? self.address ?? "(null)"
            return String(format: NSLocalizedString("%@ database at %@", comment: ""), self.assignedName ?? "IsiX DICOM Viewer", displayedHost)
        }
        set {
            super.name = newValue
        }
    }

    @objc(initWithLocation:port:)
    public convenience init!(location: String!, port: UInt) {
        var host: Host? = nil
        var outputPort: Int = 0
        _ = RemoteDatabaseNodeIdentifier.location(location, port: port, to: &host, port: &outputPort)

        self.init(host: host, port: outputPort, update: true)
    }

    @objc(initWithHost:port:update:)
    public convenience init!(host: Host!, port: Int, update flagUpdate: Bool) {
        let path = FileManager.default.tmpDirectoryPathInTmp()

        self.init(path: path)
        _baseBaseDirPath = path
        _updateLock = NSRecursiveLock()
        _connectionsSemaphoreId = DispatchSemaphore(value: MAX_SIMULTANEOUS_NONURGENT_CONNECTIONS)

        self.host = host
        self.address = host?.address
        self.port = port

        if flagUpdate {
            do {
                try self.updateIndex()
            } catch {
                // [self autorelease]; self = nil; @throw;
                _ = Unmanaged.passUnretained(self).autorelease()
                SharedDatabaseClientFailure.exception(for: error).raise()
            }
        }
    }

    deinit {
        // Out of the registry, and its lock left, before waiting for an update:
        // the update may need the main thread, which may be asking the registry.
        DicomDatabaseRegistry.leave(self)

        // The update timer goes on the main thread, whose run loop it was added
        // to, without waiting for it: a timer is invalidated on the thread it
        // was scheduled on, and the last release may come from any thread. The
        // timer holds the database weakly, so a firing before the invalidation
        // finds no database and does nothing.
        if let timer = _updateTimer {
            _updateTimer = nil
            if Thread.isMainThread {
                timer.invalidate()
            } else {
                timer.performSelector(onMainThread: #selector(Timer.invalidate), with: nil, waitUntilDone: false)
            }
        }

        let temp = _updateLock
        temp?.lock() // if currently importing, wait until finished
        _updateLock = nil
        temp?.unlock()

        // The semaphore is released with its property.

        _password = nil
        _address = nil
        _host = nil
        _sqlFileName = nil

        if self.isMainDatabase(), let baseBaseDirPath = _baseBaseDirPath {
            _baseBaseDirRemoval = RemoteDicomDatabaseDirectoryRemoval(path: baseBaseDirPath)
        }
    }

    public override func isLocal() -> Bool {
        return false
    }

    public override func saveModel() -> Bool {
        return false
    }

    @objc func _updateTimerCallback() {
        _ = self.initiateUpdate()
        self.requestPassForFilesThatWait()
        self.sendWhatWaits()
    }

    /// The action of the update timer. Its user info holds the database
    /// weakly, so a firing once the database's deallocation has begun finds
    /// none and does nothing.
    @objc(_updateTimerCallbackClass:)
    class func _updateTimerCallbackClass(_ timer: Timer) {
        let database = timer.userInfo as? NSHashTable<RemoteDicomDatabase>
        database?.anyObject?._updateTimerCallback()
    }

    public override var sqlFilePath: String! {
        if let sqlFileName = _sqlFileName {
            return (self.baseDirPath as NSString?)?.appendingPathComponent(sqlFileName)
        } else {
            return super.sqlFilePath
        }
    }

    @objc(localPathForImage:)
    public func localPath(for image: DicomImage?) -> String? {
        // %@ of a nil object is "(null)".
        func described(_ value: Any?) -> CVarArg {
            return (value as? NSObject) ?? ("(null)" as NSString)
        }

        var name: String
        if (image?.numberOfFrames?.intValue ?? 0) > 1 {
            name = String(format: "%@-%@.%@", described(image?.value(forKeyPath: "series.study.patientUID")), described(image?.value(forKey: "sopInstanceUID")), described(image?.value(forKey: "extension")))
        } else {
            name = String(format: "%@-%@-%d.%@", described(image?.value(forKeyPath: "series.study.patientUID")), described(image?.value(forKey: "sopInstanceUID")), (image?.value(forKey: "instanceNumber") as? NSNumber)?.int32Value ?? 0, described(image?.value(forKey: "extension")))
        }

        return (self.tempDirPath() as NSString?)?.appendingPathComponent(DicomFile.nSreplaceBadCharacter(name))
    }

    /// The variant every way into the index ends in: -addFilesAtPaths: calls it,
    /// and the variants with fewer arguments come to it, so overriding one of
    /// those too would send each file twice. The index here is a copy of the
    /// server's, replaced at each update: what is added goes to the server, or
    /// it is gone at the next update and nobody else ever had it.
    public override func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {

        let objectIDs = super.addFilesDescribed(inDictionaries: dicomFilesArray, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles, returnArray: true)

        let r = (self.objects(withIDs: objectIDs) as NSArray?) ?? NSArray()

        let filesToSend = NSMutableArray(capacity: r.count)
        let filesToSendObjectIDs = NSMutableArray(capacity: r.count)
        var pathsToSend = Set<String>()
        for i in 0..<r.count {
            let image = r.object(at: i) as! DicomImage
            let found = image.completePath()

            // The frames of a multi-frame object are images of one file, which goes
            // once. The next frame finds it where the first moved it, or, with a path
            // remembered from before the move, where it was: both are known, so it
            // never removes at the destination what the first moved there.
            if let found, pathsToSend.contains(found) {
                continue
            }
            var path = found
            if let found { pathsToSend.insert(found) }

            if let imagePath = path, (imagePath as NSString).hasPrefix(self.dataDirPath()) { // is in DATABASE dir, remote databases work in TEMP dir only
                let tpath = self.localPath(for: image)
                if let tpath {
                    try? FileManager.default.removeItem(atPath: tpath)
                    try? FileManager.default.moveItem(atPath: imagePath, toPath: tpath)
                }
                path = tpath
            }
            if let path, path != found, !pathsToSend.insert(path).inserted {
                continue
            }

            raisingForObjectiveC { try remoteDicomDatabaseAdd(filesToSend, path) }
            filesToSendObjectIDs.add(image.objectID)
        }

        if filesToSend.count > 0 {
            self.send(Array(filesToSend), images: Array(filesToSendObjectIDs), generatedByOsiriX: generatedByOsiriX)
        }
        return returnArray ? objectIDs : nil
    }

    /// Sends `paths` from a thread of its own, and updates the images of
    /// `objectIDs`, when there is one per file, with the names the server gave.
    private func send(_ paths: [Any], images objectIDs: [Any], generatedByOsiriX: Bool) {
        // Only the main database knows the server: an independent one, which
        // is what imports and works off the main thread, has no address.
        let server = self.isMainDatabase() ? self : (self.mainDatabase as? RemoteDicomDatabase) ?? self
        (RemoteDicomDatabase.self as AnyObject).performSelector(inBackground: #selector(RemoteDicomDatabase._uploadFilesAtPathsGeneratedByOsiriX(_:)),
                                                                with: NSArray(objects: paths, objectIDs, NSNumber(value: generatedByOsiriX), server))
    }

    @objc(_uploadFilesAtPathsGeneratedByOsiriX:)
    class func _uploadFilesAtPathsGeneratedByOsiriX(_ io: NSArray) {
        autoreleasepool {
            let paths = ((io.object(at: 0) as? [Any]) ?? []).compactMap { $0 as? String }
            let objIDs = (io.object(at: 1) as? [Any]) ?? []
            let byOsiriX = (io.object(at: 2) as? NSNumber)?.boolValue ?? false
            guard let remoteDB = io.object(at: 3) as? RemoteDicomDatabase else { return }
            var arrived = 0
            var failure: Error?
            // Core Data, which raises, reads the images.
            HorosObjCException.logged("+[RemoteDicomDatabase _uploadFilesAtPathsGeneratedByOsiriX:]", stack: true) {
                // A private-queue context: the images are read and sent from
                // inside its queue.
                let iContext = remoteDB.privateQueueIndependentContext()

                let thread = Thread.current
                thread.name = NSLocalizedString("Remote DICOM add...", comment: "name of thread that sends dicom files to the remote database after local addFiles")
                thread.status = NSLocalizedString("Sending data...", comment: "")
                ThreadsManager.default().addThreadAndStart(thread)

                N2ManagedObjectContextPerformAndWait(iContext) {
                    var images: [Any] = []
                    // Identifiers of an index an update has replaced since the addition
                    // are not looked up in the new one, which Core Data refuses by raising.
                    let sameIndex = (objIDs.first as? NSManagedObjectID)?.persistentStore?.persistentStoreCoordinator === iContext?.persistentStoreCoordinator
                    for oid in objIDs where sameIndex {
                        // An object that cannot be read is left out; the others go.
                        HorosObjCException.caught {
                            if let iContext, let oid = oid as? NSManagedObjectID {
                                images.append(iContext.object(with: oid))
                            }
                        }
                    }

                    // An update of the index since the addition leaves the identifiers
                    // without their images; the files go all the same.
                    do {
                        try remoteDB.uploadFiles(atPaths: paths, imageObjects: images.count == paths.count ? images : nil, generatedByOsiriX: byOsiriX, arrived: &arrived)
                    } catch {
                        failure = error
                    }
                }
            }
            if let failure {
                _N2LogExceptionImpl(SharedDatabaseClientFailure.exception(for: failure), true, "+[RemoteDicomDatabase _uploadFilesAtPathsGeneratedByOsiriX:]")
            }
            remoteDB.recordUpload(of: paths, arrived: arrived, generatedByOsiriX: byOsiriX)
        }
    }

    /// After an upload of `paths`, of which the first `arrived` reached the
    /// server: the others wait for the next update, which sends them again, and
    /// the person learns that they have not arrived yet.
    private func recordUpload(of paths: [String], arrived: Int, generatedByOsiriX: Bool) {
        guard arrived < paths.count else {
            waitingUploads.arrived()
            return
        }
        let tell = waitingUploads.keep(.init(paths: Array(paths[arrived...]), generatedByOsiriX: generatedByOsiriX))
        let thread = Thread.current
        let failed = NSLocalizedString("Sending failed. Will re-try later...", comment: "")
        thread.status = failed
        // Quitting cancels the sending, and nothing tries again after it.
        guard tell, !thread.isCancelled else { return }
        let title = self.name ?? ""
        onMainRunLoop {
            _ = HorosAlertPanel.run(title: title, message: failed, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// The update timer's turn to send again what the server has not received:
    /// each batch as it was added, without the files that are gone since.
    private func sendWhatWaits() {
        for batch in waitingUploads.takeAll() {
            let paths = batch.paths.filter { FileManager.default.fileExists(atPath: $0) }
            if paths.count < batch.paths.count {
                NSLog("---- shared database: %lu file(s) waiting to be sent are no longer there", UInt(batch.paths.count - paths.count))
            }
            if !paths.isEmpty {
                self.send(paths, images: [], generatedByOsiriX: batch.generatedByOsiriX)
            }
        }
    }

    // MARK: Communication

    @objc(synchronousRequest:urgent:dataHandlerTarget:selector:context:)
    func synchronousRequest(_ request: NSData?, urgent: Bool, dataHandlerTarget target: AnyObject?, selector sel: Selector?, context: UnsafeMutableRawPointer?) -> NSData? {
        return raisingForObjectiveC { try self.sendRequest(request, urgent: urgent, dataHandlerTarget: target, selector: sel, context: context) }
    }

    /// The request of -synchronousRequest:urgent:dataHandlerTarget:selector:context:,
    /// which throws what the Objective-C method raises. A request that fails
    /// on every attempt is logged and answers nil.
    private func sendRequest(_ request: NSData?, urgent: Bool, dataHandlerTarget target: AnyObject? = nil, selector sel: Selector? = nil, context: UnsafeMutableRawPointer? = nil) throws -> NSData? {
        var request: NSData = request ?? NSData()
        if request.length >= 6 {
            let command = NSString(bytes: request.bytes, length: 5, encoding: String.Encoding.ascii.rawValue)
            if !SharedDatabaseAuthorization.isPublicCommand((command as String?) ?? "") {
                // Upload-only destinations are created with update:NO and have not
                // downloaded an index, so authentication cannot depend on fetchIndex.
                if !self.authenticationKnown, !(try self.authenticate()) { return nil }
                if self.requiresAuthenticatedRequests {
                    guard let authenticated = SharedDatabaseAuthorization.authenticatedRequest(request as Data, password: self.password ?? "") else {
                        throw SharedDatabaseClientFailure.failed(.invalidArgumentException, NSLocalizedString("Authentication is required for this shared database operation.", comment: ""))
                    }
                    request = authenticated as NSData
                }
            }
        }
        // The number of simultaneous connections to one remote database is still
        // bounded, but waiting for a slot now observes cancellation.
        var acquired = false
        if !urgent, let semaphore = _connectionsSemaphoreId {
            while !acquired {
                if Thread.current.isCancelled {
                    throw SharedDatabaseClientFailure.failed(.genericException, NSLocalizedString("The shared-database request was cancelled.", comment: ""))
                }
                acquired = semaphore.wait(timeout: .now() + .milliseconds(100)) == .success
            }
        }
        defer {
            if acquired {
                _connectionsSemaphoreId?.signal()
            }
        }

        var handler: ((NSData?) -> Int)? = nil
        if let target, let sel {
            let unretainedTarget = Unmanaged.passUnretained(target)
            handler = { data in
                typealias Implementation = @convention(c) (AnyObject, Selector, AnyObject?, NSData?, UnsafeMutableRawPointer?) -> Int
                let object = unretainedTarget.takeUnretainedValue()
                let implementation = unsafeBitCast(class_getMethodImplementation(object_getClass(object), sel), to: Implementation.self)
                return implementation(object, sel, nil, data, context)
            }
        }

        // The old client replayed every failed request up to five times. A read
        // may be sent again once its partial local state is discarded; a command
        // that changes the remote database or uploads files may not, because a
        // repeat can duplicate what it did.
        let attempts = SharedDatabaseCommand.isRetryable(request as Data) ? 3 : 1
        var lastFailure: Error? = nil
        for attempt in 0..<attempts {
            if Thread.current.isCancelled { break }
            do {
                if attempt > 0 {
                    // Never append a second response to a partial first one.
                    if sel == NSSelectorFromString("_connection:handleData_fetchDatabaseIndex:context:") {
                        // The index file starts over, and nothing of it counts as
                        // received. The context is the one downloadDatabaseIndex()
                        // made, which holds the file's stream and path.
                        let indexContext = Unmanaged<NSMutableArray>.fromOpaque(context!).takeUnretainedValue()
                        guard indexContext.count > 4, let path = indexContext.object(at: 4) as? String,
                              let received = indexContext.object(at: 3) as? N2MutableUInteger,
                              let stream = OutputStream(toFileAtPath: path, append: false) else {
                            throw SharedDatabaseClientFailure.failed(.invalidArgumentException, "*** -[__NSArrayM replaceObjectAtIndex:withObject:]: object cannot be nil")
                        }
                        (indexContext.object(at: 2) as? Stream)?.close()
                        stream.open()
                        indexContext.replaceObject(at: 2, with: stream)
                        received.unsignedIntegerValue = 0
                    }
                    if sel == NSSelectorFromString("_connection:handleData_fetchDataForImage:context:") {
                        horosResetRemoteDownload(Unmanaged<NSMutableDictionary>.fromOpaque(context!).takeUnretainedValue())
                    }
                    Thread.sleep(forTimeInterval: 0.1 * Double(attempt) * Double(attempt))
                }
                return try horosSendDatabaseRequest(request, self.address, self.port, handler)
            } catch {
                lastFailure = error
                _N2LogExceptionImpl(SharedDatabaseClientFailure.exception(for: error), true, "-[RemoteDicomDatabase synchronousRequest:urgent:dataHandlerTarget:selector:context:]")
            }
        }
        if let lastFailure {
            let guidance = SharedDatabaseCommand.actionRequired(for: request as Data)
            if let guidance, !guidance.isEmpty {
                let exception = SharedDatabaseClientFailure.exception(for: lastFailure)
                NSLog("---- shared database: %@ %@", exception.reason ?? exception.name.rawValue, guidance)
            }
        }
        return nil
    }

    @objc(synchronousRequest:urgent:)
    func synchronousRequest(_ request: NSData?, urgent now: Bool) -> NSData? {
        return self.synchronousRequest(request, urgent: now, dataHandlerTarget: nil, selector: nil, context: nil)
    }

    @objc(_data:appendInt:)
    class func _data(_ data: NSMutableData, appendInt i: UInt32) {
        var big = i.bigEndian
        data.append(&big, length: 4)
    }

    @objc(_data:appendStringUTF8:)
    class func _data(_ data: NSMutableData, appendStringUTF8 str: Any?) {
        // [str UTF8String]: a value that is not a string is refused, as the runtime refused it.
        var string: NSString? = nil
        if let str {
            guard let s = str as? NSString else {
                (str as AnyObject).doesNotRecognizeSelector(NSSelectorFromString("UTF8String"))
                preconditionFailure()
            }
            string = s
        }
        withExtendedLifetime(string) {
            let cstr = string?.utf8String
            let cstrlen: UInt32 = cstr != nil ? UInt32(strlen(cstr!) + 1) : 0
            RemoteDicomDatabase._data(data, appendInt: cstrlen)
            if let cstr { data.append(cstr, length: Int(cstrlen)) }
        }
    }

    @objc func fetchDatabaseVersion() -> String? {
        return raisingForObjectiveC { try self.requestDatabaseVersion() }
    }

    private func requestDatabaseVersion() throws -> String? {
        let request = NSMutableData(bytes: "DBVER", length: 6)
        guard let response = try self.sendRequest(request, urgent: true), response.length > 0 else { throw SharedDatabaseClientFailure.notConnected }
        return NSString(data: response as Data, encoding: String.Encoding.utf8.rawValue) as String?
    }

    @objc func fetchIsPasswordProtected() -> Bool {
        return raisingForObjectiveC { try self.requestIsPasswordProtected() }
    }

    private func requestIsPasswordProtected() throws -> Bool {
        let request = NSMutableData(bytes: "ISPWD", length: 6)
        let big: Int32 = try self.requestInteger(request)
        self.requiresAuthenticatedRequests = Int32(bigEndian: big) != 0
        if !self.requiresAuthenticatedRequests { self.password = nil }
        return self.requiresAuthenticatedRequests
    }

    /// The answer to `request` that is one integer of the size of `T`, as the
    /// server wrote its bytes.
    private func requestInteger<T: FixedWidthInteger>(_ request: NSData) throws -> T {
        guard let response = try self.sendRequest(request, urgent: true), response.length > 0 else { throw SharedDatabaseClientFailure.notConnected }
        if response.length != MemoryLayout<T>.size { throw SharedDatabaseClientFailure.invalidResponse }
        var value: T = 0
        response.getBytes(&value, length: MemoryLayout<T>.size)
        return value
    }

    @objc func supportsAuthenticatedRequests() -> Bool {
        return raisingForObjectiveC { try self.requestSupportsAuthentication() }
    }

    private func requestSupportsAuthentication() throws -> Bool {
        let response = try self.sendRequest(NSData(bytes: "AUTHV", length: 6), urgent: true)
        if response?.length != 4 { return false }
        var version: UInt32 = 0
        response!.getBytes(&version, length: 4)
        return UInt32(bigEndian: version) == 1
    }

    @objc(fetchIsRightPassword:)
    func fetchIsRightPassword(_ pwd: String?) -> Bool {
        return raisingForObjectiveC { try self.requestIsRightPassword(pwd) }
    }

    private func requestIsRightPassword(_ pwd: String?) throws -> Bool {
        let request = NSMutableData(bytes: "PASWD", length: 6)
        RemoteDicomDatabase._data(request, appendStringUTF8: pwd)
        let big: Int32 = try self.requestInteger(request)
        return Int32(bigEndian: big) != 0
    }

    @objc func fetchDatabaseIndexSize() -> UInt32 {
        return raisingForObjectiveC { try self.requestDatabaseIndexSize() }
    }

    private func requestDatabaseIndexSize() throws -> UInt32 {
        let request = NSMutableData(bytes: "DBSIZ", length: 6)
        let big: UInt32 = try self.requestInteger(request)
        let size = UInt32(bigEndian: big)
        // A server that cannot describe its index in four bytes says so.
        if size == SharedDatabaseRequests.indexTooLargeForReply {
            throw SharedDatabaseClientFailure.failed(.objectInaccessibleException, NSLocalizedString("The remote database index is 4 GB or larger and cannot be transferred by database sharing.", comment: ""))
        }
        return size
    }

    @objc func requestDatabasePasswordOnMainThread() {
        precondition(Thread.isMainThread, "The remote database password dialog requires the main thread.")
        self.password = MainActor.assumeIsolated { BrowserDatabaseSource.process.processGraph.currentBrowser?.askPassword() }
    }

    @objc func prepareAuthentication() -> Bool {
        return raisingForObjectiveC { try self.authenticate() }
    }

    /// -prepareAuthentication: whether the requests can go, asking the person
    /// for the password a protected server wants; false when they cancel.
    private func authenticate() throws -> Bool {
        self.authenticationKnown = false
        let isPasswordProtected = try self.requestIsPasswordProtected()

        if isPasswordProtected {
            if !(try self.requestSupportsAuthentication()) {
                throw SharedDatabaseClientFailure.failed(.destinationInvalidException, NSLocalizedString("The protected database server must be updated to support authenticated requests. Unauthenticated fallback is disabled.", comment: ""))
            }
            if self.password == nil {
                if Thread.isMainThread { self.requestDatabasePasswordOnMainThread() }
                else { self.performSelector(onMainThread: #selector(RemoteDicomDatabase.requestDatabasePasswordOnMainThread), with: nil, waitUntilDone: true) }
                if self.password == nil { return false } // the user cancelled the prompt
            }

            let isRightPassword = try self.requestIsRightPassword(self.password)
            if !isRightPassword {
                self.password = nil
                throw SharedDatabaseClientFailure.failed(.invalidArgumentException, NSLocalizedString("Wrong password for remote database.", comment: ""))
            }
        }

        self.authenticationKnown = true
        return true
    }

    @objc func fetchDatabaseIndex() -> String? {
        return raisingForObjectiveC { try self.downloadDatabaseIndex() }
    }

    /// -fetchDatabaseIndex: the path of the server's index, downloaded into the
    /// database's folder, or nil when the person cancelled the password.
    private func downloadDatabaseIndex() throws -> String? {
        let thread = Thread.current
        thread.status = NSLocalizedString("Negotiating...", comment: "")

        let version = try self.requestDatabaseVersion()

        if version != CurrentDatabaseVersion {
            throw SharedDatabaseClientFailure.failed(.destinationInvalidException, String(format: NSLocalizedString("Invalid remote database model %@. When sharing databases, make sure both ends are running the same software versions.", comment: ""), version ?? "(null)"))
        }

        if !(try self.authenticate()) { return nil }

        let databaseIndexSize = UInt(try self.requestDatabaseIndexSize())

        if databaseIndexSize == 0 {
            throw SharedDatabaseClientFailure.failed(.objectInaccessibleException, NSLocalizedString("The remote database index is empty.", comment: ""))
        }

        thread.enterOperation()
        thread.status = NSLocalizedString("Transferring database index...", comment: "")
        let path: String? = FileManager.default.tmpFilePath(inDir: self.baseDirPath)
        let fileStream = path.flatMap { OutputStream(toFileAtPath: $0, append: false) }
        var complete = false
        defer {
            fileStream?.close()
            if !complete, let path { try? FileManager.default.removeItem(atPath: path) }
            thread.exitOperation()
        }
        guard let path, let fileStream else {
            throw SharedDatabaseClientFailure.failed(.objectInaccessibleException, NSLocalizedString("The remote database index could not be written to a temporary file.", comment: ""))
        }
        fileStream.open()
        // What the handler reads: the thread, the expected size, the file's
        // stream, the bytes received and the file's path.
        let context = NSMutableArray(array: [thread, NSNumber(value: databaseIndexSize), fileStream, N2MutableUInteger.mutableUInteger(with: 0), path])
        // A retry replaces the stream: the one in the context is the last.
        defer { (context.object(at: 2) as? Stream)?.close() }
        let request = NSData(bytes: "DATAB", length: 6)
        _ = try self.sendRequest(request, urgent: true, dataHandlerTarget: self, selector: NSSelectorFromString("_connection:handleData_fetchDatabaseIndex:context:"), context: Unmanaged.passUnretained(context).toOpaque())
        if thread.isCancelled { return nil }
        let received = (context.object(at: 3) as! N2MutableUInteger).unsignedIntegerValue
        if received != databaseIndexSize {
            throw SharedDatabaseClientFailure.failed(.objectInaccessibleException, String(format: NSLocalizedString("Incomplete remote database index: received %lu of %lu bytes.", comment: ""), received, databaseIndexSize))
        }
        complete = true
        thread.status = NSLocalizedString("Done.", comment: "")
        return path
    }

    @objc(_connection:handleData_fetchDatabaseIndex:context:)
    func _connection(_ connection: AnyObject?, handleData_fetchDatabaseIndex data: NSData?, context: NSArray) -> Int {
        // Writes what arrived of the index to its file; raises what the stream
        // could not write.
        return raisingForObjectiveC { () throws -> Int in
            let thread = context.object(at: 0) as! Thread
            let databaseIndexSize = Int(bitPattern: (context.object(at: 1) as! NSNumber).uintValue)
            let fileStream = context.object(at: 2) as! OutputStream
            let obtainedSize = context.object(at: 3) as! N2MutableUInteger

            var size = data?.length ?? 0, start = 0
            while size > 0 {
                let w = fileStream.write(data!.bytes.assumingMemoryBound(to: UInt8.self) + start, maxLength: size)
                if w > 0 {
                    size -= w
                    start += w
                    obtainedSize.unsignedIntegerValue = obtainedSize.unsignedIntegerValue + UInt(w)
                } else { throw SharedDatabaseClientFailure.failed(.genericException, fileStream.streamError?.localizedDescription ?? "(null)") }
            }

            thread.progress = 1.0 * Double(obtainedSize.unsignedIntegerValue) / Double(databaseIndexSize)
            thread.progressDetails = String(format: NSLocalizedString("Received %lu of %lu bytes", comment: ""), obtainedSize.unsignedIntegerValue, UInt(bitPattern: databaseIndexSize))

            return data?.length ?? 0
        }
    }

    @objc func fetchDatabaseTimestamp() -> TimeInterval {
        return raisingForObjectiveC { try self.requestDatabaseTimestamp() }
    }

    private func requestDatabaseTimestamp() throws -> TimeInterval {
        let request = NSMutableData(bytes: "VERSI", length: 6)
        let swapped: UInt64 = try self.requestInteger(request)
        return Double(bitPattern: UInt64(bigEndian: swapped))
    }

    @objc(fetchDicomDestinationInfoForAddress:port:)
    public class func fetchDicomDestinationInfo(forAddress address: String?, port: Int) -> NSDictionary? {
        return raisingForObjectiveC { () throws -> NSDictionary? in
            var port = port
            if port == 0 { port = 8780 }
            let request = NSMutableData(bytes: "GETDI", length: 6)
            // Over the shared-database transport (NWConnection), with its 45-second
            // idle limit; a failure raises with its description, as the stream
            // connection that sent it before did.
            let thread = Thread.current
            let response: Data
            do {
                response = try DatabaseTransport.sendRequest(request as Data, toHost: address ?? "", port: port,
                                                             receiving: nil, cancelled: { thread.isCancelled })
            } catch {
                throw SharedDatabaseClientFailure.failed(.genericException, (error as NSError).localizedDescription)
            }
            if response.isEmpty {
                throw SharedDatabaseClientFailure.notConnected
            }
            // The peer's NSArchiver data, read as a dictionary of strings without
            // instantiating any class it names; NSUnarchiver let the peer choose.
            guard let info = SharedDatabaseDestinationInfo.dictionary(fromReply: response) else {
                throw SharedDatabaseClientFailure.invalidResponse
            }
            return info
        }
    }

    @objc public func fetchDicomDestinationInfo() -> NSDictionary? {
        return RemoteDicomDatabase.fetchDicomDestinationInfo(forAddress: self.address, port: self.port)
    }

    @objc(updateOnMainThread:)
    func updateOnMainThread(_ path: String?) {
        _updateLock?.lock()
        defer { _updateLock?.unlock() }

        // An update that started before viewers of this database opened
        // leaves them the index they read (SharedIndexReplacement).
        // -updateOnMainThread: runs where its name says.
        let database = ObjectIdentifier(self)
        let openViewers = MainActor.assumeIsolated { Self.openViewers(of: database) }
        guard SharedIndexReplacement.replacesIndex(openViewersOfDatabase: openViewers) else {
            if let path, path != self.storedSqlFilePath {
                try? FileManager.default.removeItem(atPath: path)
            }
            NSLog("-- Remote database update dropped: %ld viewer(s) show the current index", openViewers)
            return
        }

        // Core Data opens the index and its contexts, which raises.
        HorosObjCException.logged("-[RemoteDicomDatabase updateOnMainThread:]", stack: true) {
            let context = self.context(atPath: path)
            // Synchronize with both contexts before publishing the replacement.
            // The coordinators remain owned by their contexts; no stores are
            // mutated here. Keep the UI and its notifications on the main
            // thread rather than entering a coordinator's private queue.
            N2ManagedObjectContextPerformAndWait(self.managedObjectContext) {}
            N2ManagedObjectContextPerformAndWait(context) {}

            self._sqlFileName = (path as NSString?)?.lastPathComponent
            // The path of N2ManagedDatabase, without -setSqlFilePath:.
            self.storedSqlFilePath = path

            let previousContext = self.managedObjectContext
            if let previousContext { _ = Unmanaged.passRetained(previousContext).autorelease() }

            MainActor.assumeIsolated { BrowserDatabaseSource.process.processGraph.currentBrowser?.willChangeContext() }

            self.managedObjectContext = context

            self.markWaitingKeyImages(in: context)

            NotificationCenter.default.post(name: .OsirixAddToDB, object: self)
            NotificationCenter.default.post(name: ._O2AddToDBAnyway, object: self)
            NotificationCenter.default.post(name: .OsirixDicomDatabaseDidChangeContext, object: self)

            self.retireIndex(of: previousContext)

            if self._updateTimer == nil {
                // Weakly: the timer neither keeps the database alive nor calls
                // it once its deallocation has begun.
                let weakDatabase = NSHashTable<RemoteDicomDatabase>.weakObjects()
                weakDatabase.add(self)
                let timer = Timer(timeInterval: TimeInterval(PreferencesSource.process.preferences[DatabasePreferences.databaseRefreshInterval]), target: RemoteDicomDatabase.self as AnyObject, selector: #selector(RemoteDicomDatabase._updateTimerCallbackClass(_:)), userInfo: weakDatabase, repeats: true)
                self._updateTimer = timer
                RunLoop.main.add(timer, forMode: .modalPanel)
                RunLoop.main.add(timer, forMode: .default)
            }
        }
    }

    /// The index `previousContext` read goes once no context uses its
    /// coordinator, at a later update: an upload or a pass may still write in it
    /// from a context of its own. Removed when the database let go of the
    /// context, it was gone under them: Core Data could not open it again
    /// ("Error opening store") and their save failed. The indexes replaced
    /// before, which nothing uses any more, go now.
    private func retireIndex(of previousContext: NSManagedObjectContext?) {
        self._replacedIndexes.removeAll { index in
            guard index.coordinator == nil else { return false }
            try? FileManager.default.removeItem(at: index.url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: index.url.path + "-shm"))
            return true
        }
        if let coordinator = previousContext?.persistentStoreCoordinator, let url = coordinator.persistentStores.first?.url {
            self._replacedIndexes.append(RemoteDicomDatabaseReplacedIndex(coordinator: coordinator, url: url))
        }
    }

    @objc func update() {
        raisingForObjectiveC { try self.updateIndex() }
    }

    /// -update: downloads the server's index and its date, and has the main
    /// thread open it; throws what the Objective-C method raises.
    private func updateIndex() throws {
        let thread = Thread.current

        NSLog("-- Remote database update")

        thread.enterOperation()
        _updateLock?.lock()
        defer {
            _updateLock?.unlock()
            thread.exitOperation()
        }
        thread.status = NSLocalizedString("Downloading index...", comment: "")
        guard let path = try self.downloadDatabaseIndex() else {
            throw SharedDatabaseClientFailure.failed(.genericException, "Cancelled.")
        }

        self._timestamp = try self.requestDatabaseTimestamp()

        self.performSelector(onMainThread: #selector(RemoteDicomDatabase.updateOnMainThread(_:)), with: path, waitUntilDone: false)
    }

    @objc(updateThread:)
    func updateThread(_ obj: Any?) {
        autoreleasepool {
            let thread = Thread.current
            thread.name = NSLocalizedString("Updating remote database...", comment: "")
            ThreadsManager.default().addThreadAndStart(thread)
            do {
                try self.updateIndex()
            } catch {
                _N2LogExceptionImpl(SharedDatabaseClientFailure.exception(for: error), true, "-[RemoteDicomDatabase updateThread:]")
            }
        }
    }

    /// The 2D viewers showing the index of `database`; those of another
    /// database, a local one beside it, do not hold its updates back.
    @MainActor
    private static func openViewers(of database: ObjectIdentifier) -> Int {
        (ViewerController.getDisplayed2DViewers() ?? NSMutableArray())
            .filter { ($0 as? ViewerController)?.database.map(ObjectIdentifier.init) == database }.count
    }

    @objc public func initiateUpdate() -> Thread? {

        let me = ObjectIdentifier(self)
        if !SharedIndexReplacement.replacesIndex(openViewersOfDatabase: onMainActorSync({ Self.openViewers(of: me) })) {
            return nil
        }

        guard let updateLock = _updateLock, updateLock.try() else {
            return nil
        }
        defer { updateLock.unlock() }
        // The update lists itself in Activity once it runs. The
        // database serializes its updates under its update lock.
        let database = UncheckedSendableBox(self)
        return ActivityThread.startUnlisted(name: NSLocalizedString("Updating remote database...", comment: "")) { _ in
            database.value.updateThread(nil)
        }
    }

    @objc func needsUpdate() -> Bool {
        let timestamp = self.fetchDatabaseTimestamp()
        return timestamp != _timestamp
    }

    @objc(fetchFileModificationDate:)
    func fetchFileModificationDate(_ path: String?) -> String? { // ------------------------------------ this seems to be unused
        return raisingForObjectiveC {
            let request = NSMutableData(bytes: "MFILE", length: 6)
            let pathData = (path as NSString?)?.data(using: String.Encoding.unicode.rawValue)
            RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: pathData?.count ?? 0))
            if let pathData { request.append(pathData) }
            guard let response = try self.sendRequest(request, urgent: true), response.length > 0 else { throw SharedDatabaseClientFailure.notConnected }
            return NSString(data: response as Data, encoding: String.Encoding.unicode.rawValue) as String?
        }
    }

    /// The shared database of another computer `object` is a row of, which
    /// the browser may not show: a viewer of a shared study stays open beside
    /// a browser showing a local database, and a change the server is not told
    /// of is undone at the next update of the index. The main database for a
    /// context of an independent one, since the request leaves from the main
    /// database, which knows the server; nil for a row of a database of this
    /// computer and for an object of no database.
    static func database(of object: NSManagedObject?) -> RemoteDicomDatabase? {
        guard let database = (object?.managedObjectContext as? N2ManagedObjectContext)?.database as? RemoteDicomDatabase else { return nil }
        return database.isMainDatabase() ? database : database.mainDatabase as? RemoteDicomDatabase
    }

    @objc(object:setValue:forKey:)
    public func object(_ object: NSManagedObject?, setValue value: Any?, forKey key: String?) {
        raisingForObjectiveC { try self.setRemoteValue(value, forKey: key, of: object) }
    }

    /// -object:setValue:forKey: on the server, and the date of its index after it.
    private func setRemoteValue(_ value: Any?, forKey key: String?, of object: NSManagedObject?) throws {
        let request = NSMutableData(bytes: "SETVA", length: 6)
        RemoteDicomDatabase._data(request, appendStringUTF8: object?.objectID.uriRepresentation().absoluteString)
        RemoteDicomDatabase._data(request, appendStringUTF8: (value as? NSNumber)?.stringValue ?? value)
        RemoteDicomDatabase._data(request, appendStringUTF8: key)
        _ = try self.sendRequest(request, urgent: true)
        _timestamp = try self.requestDatabaseTimestamp()
    }

    /// Marks on the server, as key images, `images` this database has just
    /// added, which are marked here already. They are records of the local copy
    /// of the index, which the server does not know: `object(_:setValue:forKey:)`
    /// names an object by its identifier in the index, and theirs would name no
    /// image of the server's, or another one it numbered the same. The marks
    /// wait for the update whose index has the images, after their upload. On
    /// the main thread.
    @objc(markAddedImagesAsKeyImages:)
    public func markAddedImagesAsKeyImages(_ images: [DicomImage]) {
        // The update that brings the images is the main database's.
        let server = self.isMainDatabase() ? self : (self.mainDatabase as? RemoteDicomDatabase) ?? self
        for image in images {
            guard let sopInstanceUID = image.compressedSopInstanceUID else { continue }
            server._waitingKeyImages.append(RemoteDicomDatabaseWaitingKeyImage(sopInstanceUID: sopInstanceUID, frameID: image.frameID))
        }
    }

    /// After an update: the waiting key images the new index has are marked in
    /// it, as the server will hold them, and on the server, now that it can name
    /// them. The others, and those the server did not take, wait for a next
    /// update. The local mark is the stored value alone: the mark made when the
    /// image was added already did what marking does besides. On the main
    /// thread, before the browser is told of the new index.
    private func markWaitingKeyImages(in context: NSManagedObjectContext?) {
        guard !_waitingKeyImages.isEmpty, let context else { return }
        let waiting = _waitingKeyImages
        _waitingKeyImages = []
        let yes = NSNumber(value: true)
        for mark in waiting {
            var images: [DicomImage] = []
            N2ManagedObjectContextPerformAndWait(context) {
                let request = NSFetchRequest<DicomImage>(entityName: DicomDatabaseImageEntityName)
                request.predicate = NSPredicate(format: "compressedSopInstanceUID == %@", mark.sopInstanceUID as NSData)
                images = ((try? context.fetch(request)) ?? []).filter { $0.frameID == mark.frameID }
                for image in images {
                    image.storedIsKeyImage = yes
                }
            }
            if images.isEmpty {
                _waitingKeyImages.append(mark)
                continue
            }
            do {
                // A request without an answer throws when the date is asked.
                for image in images {
                    try self.setRemoteValue(yes, forKey: "isKeyImage", of: image)
                }
            } catch {
                _waitingKeyImages.append(mark)
                _N2LogExceptionImpl(SharedDatabaseClientFailure.exception(for: error), false, "-[RemoteDicomDatabase markWaitingKeyImages]")
            }
        }
    }

    private enum RemoteDicomDatabaseStudiesAlbumAction { case add, remove }

    private func _studies(_ dicomStudies: [Any]?, album dicomAlbum: DicomAlbum?, action: RemoteDicomDatabaseStudiesAlbumAction) throws {
        let command: String
        switch action {
        case .add: command = "ADDAL"
        case .remove: command = "REMAL"
        }

        let studiesIds = NSMutableArray()
        for dicomStudy in dicomStudies ?? [] {
            studiesIds.add((dicomStudy as! NSManagedObject).objectID.uriRepresentation().absoluteString)
        }
        let albumId = dicomAlbum?.objectID.uriRepresentation().absoluteString

        // +dictionaryWithObjectsAndKeys: ends at the first nil object.
        let params = NSMutableDictionary()
        params.setObject(studiesIds, forKey: "albumStudies" as NSString)
        if let albumId { params.setObject(albumId, forKey: "albumUID" as NSString) }

        let request = NSMutableData(bytes: command, length: 6)
        RemoteDicomDatabase._data(request, appendStringUTF8: NSDictionary(dictionary: params).description)

        _ = try self.sendRequest(request, urgent: true)

        _timestamp = try self.requestDatabaseTimestamp()
    }

    public override func addStudies(_ dicomStudies: [Any]!, to dicomAlbum: DicomAlbum!) {
        super.addStudies(dicomStudies, to: dicomAlbum)
        raisingForObjectiveC { try self._studies(dicomStudies, album: dicomAlbum, action: .add) }
    }

    @objc(removeStudies:fromAlbum:)
    public func removeStudies(_ dicomStudies: [Any]?, fromAlbum dicomAlbum: DicomAlbum?) {
        raisingForObjectiveC { try self._studies(dicomStudies, album: dicomAlbum, action: .remove) }
    }

    @objc(uploadFilesAtPaths:imageObjects:)
    public func uploadFiles(atPaths paths: [Any]?, imageObjects images: [Any]?) {
        return self.uploadFiles(atPaths: paths, imageObjects: images, generatedByOsiriX: false)
    }

    @objc(data:readInteger:)
    class func data(_ data: NSMutableData, readInteger valp: UnsafeMutablePointer<UInt32>) -> Bool {
        if data.length < 4 {
            return false
        }
        var big: UInt32 = 0
        data.getBytes(&big, range: NSRange(location: 0, length: 4))
        data.replaceBytes(in: NSRange(location: 0, length: 4), withBytes: nil, length: 0)
        valp.pointee = UInt32(bigEndian: big)
        return true
    }

    @objc(uploadFilesAtPaths:imageObjects:generatedByOsiriX:)
    public func uploadFiles(atPaths paths: [Any]?, imageObjects images: [Any]?, generatedByOsiriX: Bool) {
        var arrived = 0
        raisingForObjectiveC { try self.uploadFiles(atPaths: paths, imageObjects: images, generatedByOsiriX: generatedByOsiriX, arrived: &arrived) }
    }

    /// The upload, which counts in `arrived` the files of the requests the
    /// server answered, the first of `paths`. A request that gets no answer ends
    /// it: the files after it are sent by a next attempt, in their order, and
    /// those before it are not sent twice.
    private func uploadFiles(atPaths paths: [Any]?, imageObjects images: [Any]?, generatedByOsiriX: Bool, arrived: inout Int) throws {
        let paths: NSArray = (paths as NSArray?) ?? NSArray()
        let images = images as NSArray?
        let thread = Thread.current
        thread.enterOperation()
        defer { thread.exitOperation() }
        for path in paths {
            if !FileManager.default.fileExists(atPath: (path as? String) ?? "") {
                throw SharedDatabaseClientFailure.failed(.invalidArgumentException, "File not available.")
            }
        }
        var failure: Error? = nil
        // The images take the names the server gave by KVC, and their context
        // saves: Core Data raises.
        let raised = HorosObjCException.caught {
            do {
                let request = NSMutableData(bytes: generatedByOsiriX ? "SENDG" : "SENDD", length: 6)
                RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: paths.count))
                let filesInRequest = NSMutableArray()
                let dbObjsInRequest: NSMutableArray? = images != nil ? NSMutableArray() : nil

                for i in 0..<paths.count {
                    let path = paths.object(at: i)
                    thread.progress = 1.0 * Double(i - filesInRequest.count / 2) / Double(paths.count)

                    filesInRequest.add(path)
                    if let dbObjsInRequest { try remoteDicomDatabaseAdd(dbObjsInRequest, images!.object(at: i)) }

                    let fileData = NSData(contentsOfFile: (path as? String) ?? "")
                    RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: fileData?.length ?? 0))
                    if let fileData { request.append(fileData as Data) }

                    if request.length > 32 * 1024 * 1024 || ((path as AnyObject) === (paths.lastObject as AnyObject?) && filesInRequest.count > 0) { // we split the send in smaller chunks to avoid allocation problems
                        let count = NSMutableData()
                        RemoteDicomDatabase._data(count, appendInt: UInt32(truncatingIfNeeded: filesInRequest.count))
                        request.replaceBytes(in: NSRange(location: 6, length: count.length), withBytes: count.bytes, length: count.length)

                        // The request logs a failure and answers nil.
                        guard let response = try self.sendRequest(request, urgent: true)?.mutableCopy() as? NSMutableData else {
                            break
                        }
                        arrived += filesInRequest.count
                        if let dbObjsInRequest, dbObjsInRequest.count > 0, response.length > 0 {
                            var n: UInt32 = 0
                            if RemoteDicomDatabase.data(response, readInteger: &n) {
                                if Int(n) == dbObjsInRequest.count {
                                    for j in 0..<Int(n) {
                                        var number: UInt32 = 0
                                        if RemoteDicomDatabase.data(response, readInteger: &number) {
                                            let image = dbObjsInRequest.object(at: j) as! NSObject
                                            image.setValue(String(format: "%d.dcm", Int32(bitPattern: number)), forKey: "path")
                                            image.setValue(NSNumber(value: true), forKey: "inDatabaseFolder")
                                        } else { break }
                                    }
                                }
                            }
                        }

                        request.length = 6 + count.length
                        filesInRequest.removeAllObjects()
                        dbObjsInRequest?.removeAllObjects()
                    }

                    if thread.isCancelled {
                        break
                    }
                }

                if images != nil {
                    try? ((images?.lastObject as? NSManagedObject)?.managedObjectContext)?.save()
                }
            } catch {
                failure = error
            }
        }
        if let raised { throw SharedDatabaseClientFailure.raised(raised) }
        if let failure { throw failure }
    }

    @objc(cacheDataForImage:maxFiles:)
    public func cacheData(for image: DicomImage?, maxFiles: Int) -> String? {
        guard let image else {
            N2LogStackTraceMessage("image == nil")
            return nil
        }

        let localPath = self.localPath(for: image)

        if FileManager.default.fileExists(atPath: localPath ?? "") {
            return localPath
        }

        let localPaths = NSMutableArray()
        let remotePaths = NSMutableArray()

        let seriesImages = (image.series?.images as NSSet?)?.allObjects as NSArray?
        let images: NSArray = seriesImages?.sortedArray(using: (image.series?.sortDescriptorsForImages() as? [NSSortDescriptor]) ?? []) as NSArray? ?? NSArray()

        var size = 0
        var i = images.index(of: image)

        while i < images.count {
            let iImage = images.object(at: i) as! DicomImage
            i += 1
            let iLocalPath = self.localPath(for: iImage)

            if FileManager.default.fileExists(atPath: iLocalPath ?? "") || (iLocalPath.map { localPaths.contains($0) } ?? false) {
                continue
            }

            raisingForObjectiveC {
                try remoteDicomDatabaseAdd(localPaths, iLocalPath)
                try remoteDicomDatabaseAdd(remotePaths, iImage.path())
            }

            let width = iImage.width()?.int32Value ?? 0
            let height = iImage.height()?.int32Value ?? 0
            let frames = iImage.numberOfFrames?.int32Value ?? 0
            size += Int(width &* height &* 2 &* frames)

            if maxFiles == 1 || size >= maxFiles * 512 * 512 * 2 {
                break
            }
        }
        if localPaths.count == 0 {
            return nil
        }

        return raisingForObjectiveC { try self.download(remotePaths as? [Any], to: localPaths as? [Any]) } ? localPath : nil
    }

    @objc(refreshCacheDataForImage:)
    public func refreshCacheData(for image: DicomImage?) -> String? {
        guard let image, let path = image.path(), (path as NSString).length > 0 else { return nil }
        let destination = self.localPath(for: image)
        let remotePaths = NSMutableArray(object: path)
        let localPaths = NSMutableArray()
        return raisingForObjectiveC {
            try remoteDicomDatabaseAdd(localPaths, destination)
            return try self.download(remotePaths as? [Any], to: localPaths as? [Any])
        } ? destination : nil
    }

    @objc(downloadRemotePaths:toLocalPaths:)
    func downloadRemotePaths(_ remotePaths: [Any]?, toLocalPaths localPaths: [Any]?) -> Bool {
        return raisingForObjectiveC { try self.download(remotePaths, to: localPaths) }
    }

    /// -downloadRemotePaths:toLocalPaths:: whether every file arrived, each at
    /// its local path; throws what the Objective-C method raises.
    private func download(_ remotePaths: [Any]?, to localPaths: [Any]?) throws -> Bool {
        let request = NSMutableData(bytes: "DICOM", length: 6)

        RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: localPaths?.count ?? 0))
        for remotePath in remotePaths ?? [] {
            RemoteDicomDatabase._data(request, appendStringUTF8: remotePath)
        }
        for localPath in localPaths ?? [] {
            RemoteDicomDatabase._data(request, appendStringUTF8: localPath)
        }

        let context = NSMutableDictionary(object: localPaths as Any, forKey: "expected" as NSString)
        // The first attempt needs its protocol state as much as a retry does: without it the
        // handler found no files remaining and refused every download.
        horosResetRemoteDownload(context)
        defer { horosCleanupRemoteDownload(context) }
        _ = try self.sendRequest(request, urgent: true, dataHandlerTarget: self, selector: NSSelectorFromString("_connection:handleData_fetchDataForImage:context:"), context: Unmanaged.passUnretained(context).toOpaque())
        return ((context.object(forKey: "remaining") as? NSSet)?.count ?? 0) == 0 && context.object(forKey: "state") != nil
    }

    @objc(_connection:handleData_fetchDataForImage:context:)
    func _connection(_ connection: AnyObject?, handleData_fetchDataForImage data: NSData?, context: NSMutableDictionary) -> Int {
        // Writes what arrived of the files to temporary files and moves each,
        // once whole, to the local path the server named; raises what breaks
        // the protocol or cannot be written.
        return raisingForObjectiveC { () throws -> Int in
            let values = context.object(forKey: "state") as! NSMutableArray
            let remaining = context.object(forKey: "remaining") as! NSMutableSet
            let state = values.object(at: 0) as! N2MutableUInteger
            var readSize = 0
            let length = data?.length ?? 0

            // context[0] state
            // context[1] number of files in response
            // context[2] number of files done handling
            // context[3] size of file
            // context[4] temporary file path
            // context[5] output stream to temporary file
            // context[6] total size written to temporary file
            // context[7] size of filename

            while length > readSize {
                let bytes = data!.bytes
                switch state.unsignedIntegerValue {
                case 0: // expecting number of files in response
                    if length - readSize >= 4 {
                        var big: UInt32 = 0
                        data!.getBytes(&big, range: NSRange(location: readSize, length: 4))
                        let n = UInt32(bigEndian: big)
                        if n == 0 || Int(n) != remaining.count {
                            throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), "Unexpected file count in remote response.")
                        }
                        values.add(NSNumber(value: n)) // [1]
                        values.add(N2MutableUInteger.mutableUInteger(with: 0)) // [2]
                        readSize += 4
                        state.unsignedIntegerValue = 1
                    } else { return readSize }
                case 1: // expecting size of next file
                    if length - readSize >= 4 {
                        var big: UInt32 = 0
                        data!.getBytes(&big, range: NSRange(location: readSize, length: 4))
                        let l = UInt32(bigEndian: big)
                        if l == 0 { throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), "Empty remote image.") }
                        values.add(NSNumber(value: l)) // [3]

                        let path: String? = FileManager.default.tmpFilePath(inDir: self.tempDirPath())
                        try remoteDicomDatabaseAdd(values, path) // [4]
                        let stream = path.flatMap { OutputStream(toFileAtPath: $0, append: false) }
                        stream?.open()
                        try remoteDicomDatabaseAdd(values, stream) // [5]
                        values.add(N2MutableUInteger.mutableUInteger(with: 0)) // [6]

                        readSize += 4
                        state.unsignedIntegerValue = 2
                    } else { return readSize }
                case 2: // expecting file data, its length is in context
                    let l = (values.object(at: 3) as! NSNumber).uint32Value
                    let stream = values.object(at: 5) as! OutputStream
                    let streamSize = values.object(at: 6) as! N2MutableUInteger
                    var ll = UInt32(truncatingIfNeeded: min(UInt(length - readSize), UInt(l) &- streamSize.unsignedIntegerValue))
                    while ll > 0 {
                        let w = stream.write(bytes.assumingMemoryBound(to: UInt8.self) + readSize, maxLength: Int(ll))
                        if w > 0 {
                            ll -= UInt32(truncatingIfNeeded: w)
                            readSize += w
                            streamSize.unsignedIntegerValue = streamSize.unsignedIntegerValue + UInt(w)
                        } else { throw SharedDatabaseClientFailure.failed(.genericException, stream.streamError?.localizedDescription ?? "(null)") }
                    }

                    if streamSize.unsignedIntegerValue >= UInt(l) {
                        state.unsignedIntegerValue = 3
                    }
                case 3: // expecting length of name of received file
                    if length - readSize >= 4 {
                        var big: UInt32 = 0
                        data!.getBytes(&big, range: NSRange(location: readSize, length: 4))
                        let l = UInt32(bigEndian: big)
                        var maximum: UInt = 0
                        for expected in remaining { maximum = max(maximum, UInt((expected as! NSString).lengthOfBytes(using: String.Encoding.utf8.rawValue)) + 1) }
                        if l < 2 || UInt(l) > maximum {
                            throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), "Invalid remote filename length.")
                        }
                        values.add(NSNumber(value: l)) // [7]
                        readSize += 4
                        state.unsignedIntegerValue = 4
                    } else { return readSize }
                case 4:
                    let pathSize = Int((values.object(at: 7) as! NSNumber).uint32Value)
                    if length - readSize >= pathSize {
                        let name = (bytes + readSize).assumingMemoryBound(to: CChar.self)
                        if name[pathSize - 1] != 0 || memchr(name, 0, pathSize - 1) != nil {
                            throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), "Invalid remote filename encoding.")
                        }
                        guard let path = NSString(bytes: name, length: pathSize - 1, encoding: String.Encoding.utf8.rawValue), remaining.contains(path) else {
                            throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), "Unexpected remote destination.")
                        }
                        readSize += pathSize
                        //DLog(@"RDD path is %@", path);
                        values.removeLastObject() // rm [7]
                        values.removeLastObject() // rm [6]
                        (values.object(at: 5) as! OutputStream).close()
                        values.removeLastObject() // rm [5]

                        let existing = try? FileManager.default.attributesOfItem(atPath: path as String)
                        if let existing, (existing[.type] as? String) != FileAttributeType.typeRegular.rawValue {
                            throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), "The cache destination is not a regular file.")
                        }
                        let temporary = values.object(at: 4) as! NSString
                        if rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0 {
                            let installationCode = errno
                            var installationError: NSError? = nil
                            // Normally cache and temporary files share a volume. Only
                            // cross-volume installs need another prepared copy.
                            if installationCode != EXDEV || !HorosReplaceReportFile(temporary as String, path as String, &installationError) {
                                throw SharedDatabaseClientFailure.failed(NSExceptionName(rawValue: "RemoteDownload"), String(format: "Remote cache installation failed (%d).", installationCode))
                            }
                        }
                        try? FileManager.default.removeItem(atPath: temporary as String)
                        remaining.remove(path)

                        values.removeLastObject() // rm [4]
                        values.removeLastObject() // rm [3]
                        state.unsignedIntegerValue = 1

                        let counter = values.object(at: 2) as! N2MutableUInteger
                        // After the last file the response ends with the connection,
                        // which the transport closes; the handler gets no connection.
                        counter.increment()
                    } else { return readSize }
                default:
                    break
                }
            }

            return readSize
        }
    }

    @objc(sendMessage:)
    func sendMessage(_ message: NSDictionary?) -> NSData? { // ------------------------------------ this seems to be unused
        let request = NSMutableData(bytes: "NEWMS", length: 6)

        let data = message.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: data?.count ?? 0))
        if let data { request.append(data) }

        return self.synchronousRequest(request, urgent: true)
    }

    @objc(storeScuImages:toDestinationAETitle:address:port:transferSyntax:)
    public func storeScuImages(_ dicomImages: [Any]?, toDestinationAETitle aet: String?, address: String?, port: Int, transferSyntax exsTransferSyntax: Int32) {
        let imagePaths = NSMutableArray()
        for image in dicomImages ?? [] {
            let path: String? = (image as! DicomImage).path()
            if !(path.map { imagePaths.contains($0) } ?? false) {
                raisingForObjectiveC { try remoteDicomDatabaseAdd(imagePaths, path) }
            }
        }

        let request = NSMutableData(bytes: "DCMSE", length: 6)

        RemoteDicomDatabase._data(request, appendStringUTF8: aet)
        RemoteDicomDatabase._data(request, appendStringUTF8: address)
        RemoteDicomDatabase._data(request, appendStringUTF8: NSNumber(value: Int32(truncatingIfNeeded: port)).stringValue)
        RemoteDicomDatabase._data(request, appendStringUTF8: NSNumber(value: DCMTKStoreSCU.sendSyntax(forListenerSyntax: exsTransferSyntax)).stringValue)

        RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: imagePaths.count))
        for path in imagePaths {
            RemoteDicomDatabase._data(request, appendStringUTF8: path)
        }

        _ = self.synchronousRequest(request, urgent: true)
    }

    public override func cleanForFreeSpaceMB(_ freeMemoryRequested: Int) {
    }

    public override func cleanOldStuff() {
    }

    public override func initiateCleanUnlessAlreadyCleaning() {
    }

    // MARK: Special

    public override func rebuildAllowed() -> Bool {
        return false
    }

    public override func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {
        self.requestPassForFilesThatWait()
    }

    /// The folder of a remote database holds only what was put there for it: a
    /// URL, an archive, what a pass gave back or what conversion returned. The
    /// timer of the incoming folders looks at local databases alone, so the
    /// timer of the updates looks here, and a pass that would find nothing is
    /// not asked for. The files then go to the server as any others added.
    private func requestPassForFilesThatWait() {
        if self.hasFilesToImport() {
            DatabaseIngest.process.schedulePass(over: self)
        }
    }

    public override func rebuild(_ complete: Bool) { // do nothing
    }

    public override func addDefaultAlbums() { // do nothing
    }
}

/// @unchecked Sendable, restated from NSManagedObjectContext: the context's
/// own queue contract governs its use, and this subclass adds nothing to it.
/// The class names the contexts of a remote database.
@objc(RemoteDicomDatabaseManagedObjectContext)
final class RemoteDicomDatabaseManagedObjectContext: N2ManagedObjectContext, @unchecked Sendable {
}
