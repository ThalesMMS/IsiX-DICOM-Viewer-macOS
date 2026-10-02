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

/// How many requests that are not urgent may be connected to one remote database at once.
private let MAX_SIMULTANEOUS_NONURGENT_CONNECTIONS = 4

/// [NSException raise:name format:@"%@", reason].
private func remoteDicomDatabaseRaise(_ name: NSExceptionName, _ reason: String) -> Never {
    NSException(name: name, reason: reason, userInfo: nil).raise()
    preconditionFailure(reason)
}

/// The NSException that HorosObjCException.perform caught.
private func remoteDicomDatabaseException(_ error: Error) -> NSException {
    let error = error as NSError
    return error.userInfo[HorosObjCExceptionKey] as? NSException
        ?? NSException(name: .genericException, reason: error.localizedDescription, userInfo: nil)
}

/// -[NSMutableArray addObject:], which raises on nil where Swift would add NSNull.
private func remoteDicomDatabaseAdd(_ array: NSMutableArray, _ object: Any?) {
    guard let object else {
        remoteDicomDatabaseRaise(.invalidArgumentException, "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
    }
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

// One request on one NWConnection, on the calling thread's terms (#607). The
// six-byte command, the integer order, the archives and the end-of-response by
// close are the protocol's, unchanged; the thread and run loop per request are
// gone, and a partial response is an error rather than a short success.
private func horosSendDatabaseRequest(_ request: NSData, _ address: String?, _ port: Int,
                                      _ handler: ((NSData?) -> Int)?) -> NSData {
    let thread = Thread.current
    var receiving: DatabaseTransport.Receiver? = nil
    if let handler {
        receiving = { data, handlerError in
            // An Objective-C exception must not cross into Swift.
            var consumed = 0
            do {
                try HorosObjCException.perform { consumed = handler(data as NSData?) }
            } catch {
                let exception = remoteDicomDatabaseException(error)
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
        remoteDicomDatabaseRaise(.objectInaccessibleException, (error as NSError).localizedDescription)
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

        if (host?.addresses.count ?? 0) == 0 && (host?.names.count ?? 0) == 0 {
            remoteDicomDatabaseRaise(.genericException, NSLocalizedString("This remote database is unaccessible because its address could not be resolved.", comment: ""))
        }

        let dbs = DicomDatabase.allDatabases() ?? []
        for case let db as RemoteDicomDatabase in dbs {
            if db.port == outputPort, let dbAddress = db.host?.address, let hostAddress = host?.address,
               (dbAddress as NSString).isEqual(to: hostAddress) {
                if flagUpdate {
                    db.update()
                }
                return db
            }
        }

        NSLog("-- Remote database created")

        // With the port the lookup above compared, the one the location
        // resolves to: the port given is 0 when the default one is meant, and
        // a database created with it was never found again (#847).
        let db = RemoteDicomDatabase(host: host, port: outputPort, update: flagUpdate)
        if name != nil {
            db?.name = name
        }

        return db
    }

    // MARK: Instance

    public override func dataNodeIdentifier() -> DataNodeIdentifier! {
        return RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: self.address, port: UInt(bitPattern: self.port), description: self.description, dictionary: nil) as? DataNodeIdentifier
    }

    public dynamic override var name: String! {
        get {
            let displayedHost: String = self.host?.name ?? self.address ?? "(null)"
            return String(format: NSLocalizedString("%@ database at %@", comment: ""), self.horos_name ?? "Isis DICOM Viewer", displayedHost)
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
                try HorosObjCException.perform { self.update() }
            } catch {
                let exception = remoteDicomDatabaseException(error)
                // [self autorelease]; self = nil; @throw;
                _ = Unmanaged.passUnretained(self).autorelease()
                exception.raise()
            }
        }
    }

    deinit {
        _updateTimer?.invalidate()

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
    }

    @objc(_updateTimerCallbackClass:)
    class func _updateTimerCallbackClass(_ timer: Timer) {
        let rddp = timer.userInfo as? NSValue
        guard let pointer = rddp?.pointerValue else { return }
        let rdd = Unmanaged<RemoteDicomDatabase>.fromOpaque(pointer).takeUnretainedValue()
        rdd._updateTimerCallback()
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

    public override func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) -> [Any]! {

        let objectIDs = super.addFilesDescribed(inDictionaries: dicomFilesArray, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, returnArray: true)

        let r = (self.objects(withIDs: objectIDs) as NSArray?) ?? NSArray()

        let filesToSend = NSMutableArray(capacity: r.count)
        let filesToSendObjectIDs = NSMutableArray(capacity: r.count)
        for i in 0..<r.count {
            let image = r.object(at: i) as! DicomImage
            var path = image.completePath()
            if let imagePath = path, (imagePath as NSString).hasPrefix(self.dataDirPath()) { // is in DATABASE dir, remote databases work in TEMP dir only
                let tpath = self.localPath(for: image)
                if let tpath {
                    try? FileManager.default.removeItem(atPath: tpath)
                    try? FileManager.default.moveItem(atPath: imagePath, toPath: tpath)
                }
                path = tpath
            }

            remoteDicomDatabaseAdd(filesToSend, path)
            filesToSendObjectIDs.add(image.objectID)
        }

        if filesToSend.count > 0 {
            (RemoteDicomDatabase.self as AnyObject).performSelector(inBackground: #selector(RemoteDicomDatabase._uploadFilesAtPathsGeneratedByOsiriX(_:)),
                                                                    with: NSArray(objects: filesToSend, filesToSendObjectIDs, NSNumber(value: generatedByOsiriX), self))
        }
        return objectIDs
    }

    @objc(_uploadFilesAtPathsGeneratedByOsiriX:)
    class func _uploadFilesAtPathsGeneratedByOsiriX(_ io: NSArray) {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    let paths = io.object(at: 0) as? [Any]
                    let objIDs = io.object(at: 1) as! NSArray
                    let byOsiriX = (io.object(at: 2) as! NSNumber).boolValue
                    let remoteDB = io.object(at: 3) as! RemoteDicomDatabase
                    // A private-queue context: the images are read and sent from
                    // inside its queue (#966).
                    let iContext = remoteDB.privateQueueIndependentContext()

                    let thread = Thread.current
                    thread.name = NSLocalizedString("Remote DICOM add...", comment: "name of thread that sends dicom files to the remote database after local addFiles")
                    thread.status = NSLocalizedString("Sending data...", comment: "")
                    ThreadsManager.default().addThreadAndStart(thread)

                    N2ManagedObjectContextPerformAndWait(iContext) {
                    let images = NSMutableArray(capacity: objIDs.count)
                    for oid in objIDs {
                        do {
                            try HorosObjCException.perform {
                                if let iContext, let oid = oid as? NSManagedObjectID {
                                    images.add(iContext.object(with: oid))
                                }
                            }
                        } catch {
                            // nothing, just look for other objects
                        }
                    }

                    remoteDB.uploadFiles(atPaths: paths, imageObjects: images as? [Any], generatedByOsiriX: byOsiriX)
                    }
                }
            } catch {
                _N2LogExceptionImpl(remoteDicomDatabaseException(error), true, "+[RemoteDicomDatabase _uploadFilesAtPathsGeneratedByOsiriX:]")
            }
        }
    }

    // MARK: Communication

    @objc(synchronousRequest:urgent:dataHandlerTarget:selector:context:)
    func synchronousRequest(_ request: NSData?, urgent: Bool, dataHandlerTarget target: AnyObject?, selector sel: Selector?, context: UnsafeMutableRawPointer?) -> NSData? {
        var request: NSData = request ?? NSData()
        if request.length >= 6 {
            let command = NSString(bytes: request.bytes, length: 5, encoding: String.Encoding.ascii.rawValue)
            if !SharedDatabaseAuthorization.isPublicCommand((command as String?) ?? "") {
                // Upload-only destinations are created with update:NO and have not
                // downloaded an index, so authentication cannot depend on fetchIndex.
                if !self.authenticationKnown && !self.prepareAuthentication() { return nil }
                if self.requiresAuthenticatedRequests {
                    guard let authenticated = SharedDatabaseAuthorization.authenticatedRequest(request as Data, password: self.password ?? "") else {
                        remoteDicomDatabaseRaise(.invalidArgumentException, NSLocalizedString("Authentication is required for this shared database operation.", comment: ""))
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
                    remoteDicomDatabaseRaise(.genericException, NSLocalizedString("The shared-database request was cancelled.", comment: ""))
                }
                acquired = semaphore.wait(timeout: .now() + .milliseconds(100)) == .success
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

        var response: NSData? = nil
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                // The old client replayed every failed request up to five times. A read
                // may be sent again once its partial local state is discarded; a command
                // that changes the remote database or uploads files may not, because a
                // repeat can duplicate what it did (#607).
                let attempts = SharedDatabaseCommand.isRetryable(request as Data) ? 3 : 1
                var lastFailure: NSException? = nil
                for attempt in 0..<attempts {
                    if Thread.current.isCancelled { break }
                    var sent: NSData? = nil
                    do {
                        try HorosObjCException.perform {
                            if attempt > 0 {
                                // Never append a second response to a partial first one.
                                if sel == NSSelectorFromString("_connection:handleData_fetchDatabaseIndex:context:") {
                                    let indexContext = Unmanaged<NSMutableArray>.fromOpaque(context!).takeUnretainedValue()
                                    (indexContext.object(at: 2) as? Stream)?.close()
                                    guard let stream = OutputStream(toFileAtPath: indexContext.object(at: 4) as! String, append: false) else {
                                        remoteDicomDatabaseRaise(.invalidArgumentException, "*** -[__NSArrayM replaceObjectAtIndex:withObject:]: object cannot be nil")
                                    }
                                    stream.open()
                                    indexContext.replaceObject(at: 2, with: stream)
                                    (indexContext.object(at: 3) as! N2MutableUInteger).unsignedIntegerValue = 0
                                }
                                if sel == NSSelectorFromString("_connection:handleData_fetchDataForImage:context:") {
                                    horosResetRemoteDownload(Unmanaged<NSMutableDictionary>.fromOpaque(context!).takeUnretainedValue())
                                }
                                Thread.sleep(forTimeInterval: 0.1 * Double(attempt) * Double(attempt))
                            }
                            sent = horosSendDatabaseRequest(request, self.address, self.port, handler)
                        }
                    } catch {
                        let e = remoteDicomDatabaseException(error)
                        lastFailure = e
                        _N2LogExceptionImpl(e, true, "-[RemoteDicomDatabase synchronousRequest:urgent:dataHandlerTarget:selector:context:]")
                        continue
                    }
                    response = sent
                    return
                }
                if let lastFailure {
                    let guidance = SharedDatabaseCommand.actionRequired(for: request as Data)
                    if let guidance, !guidance.isEmpty {
                        NSLog("---- shared database: %@ %@", lastFailure.reason ?? lastFailure.name.rawValue, guidance)
                    }
                }
            }
        } catch {
            raised = remoteDicomDatabaseException(error)
        }
        // @finally
        if acquired {
            _connectionsSemaphoreId?.signal()
        }
        if let raised {
            raised.raise()
        }

        return response
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
        let request = NSMutableData(bytes: "DBVER", length: 6)
        let response = self.synchronousRequest(request, urgent: true)
        if (response?.length ?? 0) == 0 { remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: "")) }
        return NSString(data: response! as Data, encoding: String.Encoding.utf8.rawValue) as String?
    }

    @objc func fetchIsPasswordProtected() -> Bool {
        let request = NSMutableData(bytes: "ISPWD", length: 6)
        let response = self.synchronousRequest(request, urgent: true)
        if (response?.length ?? 0) == 0 { remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: "")) }
        if response!.length != MemoryLayout<Int32>.size { remoteDicomDatabaseRaise(.internalInconsistencyException, NSLocalizedString("Invalid response data from remote host.", comment: "")) }
        var big: Int32 = 0
        response!.getBytes(&big, length: 4)
        self.requiresAuthenticatedRequests = Int32(bigEndian: big) != 0
        if !self.requiresAuthenticatedRequests { self.password = nil }
        return self.requiresAuthenticatedRequests
    }

    @objc func supportsAuthenticatedRequests() -> Bool {
        let response = self.synchronousRequest(NSData(bytes: "AUTHV", length: 6), urgent: true)
        if response?.length != 4 { return false }
        var version: UInt32 = 0
        response!.getBytes(&version, length: 4)
        return UInt32(bigEndian: version) == 1
    }

    @objc(fetchIsRightPassword:)
    func fetchIsRightPassword(_ pwd: String?) -> Bool {
        let request = NSMutableData(bytes: "PASWD", length: 6)
        RemoteDicomDatabase._data(request, appendStringUTF8: pwd)
        let response = self.synchronousRequest(request, urgent: true)
        if (response?.length ?? 0) == 0 { remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: "")) }
        if response!.length != MemoryLayout<Int32>.size { remoteDicomDatabaseRaise(.internalInconsistencyException, NSLocalizedString("Invalid response data from remote host.", comment: "")) }
        var big: Int32 = 0
        response!.getBytes(&big, length: 4)
        return Int32(bigEndian: big) != 0
    }

    @objc func fetchDatabaseIndexSize() -> UInt32 {
        let request = NSMutableData(bytes: "DBSIZ", length: 6)
        let response = self.synchronousRequest(request, urgent: true)
        if (response?.length ?? 0) == 0 { remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: "")) }
        if response!.length != MemoryLayout<Int32>.size { remoteDicomDatabaseRaise(.internalInconsistencyException, NSLocalizedString("Invalid response data from remote host.", comment: "")) }
        var big: UInt32 = 0
        response!.getBytes(&big, length: 4)
        let size = UInt32(bigEndian: big)
        // A server that cannot describe its index in four bytes says so (#637).
        if size == SharedDatabaseRequests.indexTooLargeForReply {
            remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("The remote database index is 4 GB or larger and cannot be transferred by database sharing.", comment: ""))
        }
        return size
    }

    @objc func requestDatabasePasswordOnMainThread() {
        RemoteDicomDatabaseAssertPasswordDialogOnMainThread(self, #selector(RemoteDicomDatabase.requestDatabasePasswordOnMainThread))
        self.password = MainActor.assumeIsolated { BrowserController.currentBrowser()?.askPassword() }
    }

    @objc func prepareAuthentication() -> Bool {
        self.authenticationKnown = false
        let isPasswordProtected = self.fetchIsPasswordProtected()

        if isPasswordProtected {
            if !self.supportsAuthenticatedRequests() {
                remoteDicomDatabaseRaise(.destinationInvalidException, NSLocalizedString("The protected database server must be updated to support authenticated requests. Unauthenticated fallback is disabled.", comment: ""))
            }
            if self.password == nil {
                if Thread.isMainThread { self.requestDatabasePasswordOnMainThread() }
                else { self.performSelector(onMainThread: #selector(RemoteDicomDatabase.requestDatabasePasswordOnMainThread), with: nil, waitUntilDone: true) }
                if self.password == nil { return false } // the user cancelled the prompt
            }

            let isRightPassword = self.fetchIsRightPassword(self.password)
            if !isRightPassword {
                self.password = nil
                remoteDicomDatabaseRaise(.invalidArgumentException, NSLocalizedString("Wrong password for remote database.", comment: ""))
            }
        }

        self.authenticationKnown = true
        return true
    }

    @objc func fetchDatabaseIndex() -> String? {
        let thread = Thread.current
        thread.status = NSLocalizedString("Negotiating...", comment: "")

        let version = self.fetchDatabaseVersion()

        if version != CurrentDatabaseVersion {
            remoteDicomDatabaseRaise(.destinationInvalidException, String(format: NSLocalizedString("Invalid remote database model %@. When sharing databases, make sure both ends are running the same software versions.", comment: ""), version ?? "(null)"))
        }

        if !self.prepareAuthentication() { return nil }

        let databaseIndexSize = UInt(self.fetchDatabaseIndexSize())

        if databaseIndexSize == 0 {
            remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("The remote database index is empty.", comment: ""))
        }

        thread.enterOperation()
        thread.status = NSLocalizedString("Transferring database index...", comment: "")
        var path: String? = nil
        var context: NSMutableArray? = nil
        var complete = false
        var result: String? = nil
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                path = FileManager.default.tmpFilePath(inDir: self.baseDirPath)
                let fileStream = path.flatMap { OutputStream(toFileAtPath: $0, append: false) }
                fileStream?.open()
                // +arrayWithObjects:…, nil: the array ends at the first nil.
                let items: [Any?] = [thread, NSNumber(value: databaseIndexSize), fileStream, N2MutableUInteger.mutableUInteger(with: 0), path]
                let array = NSMutableArray()
                for case let item? in items.prefix(while: { $0 != nil }) { array.add(item) }
                context = array
                let request = NSData(bytes: "DATAB", length: 6)
                _ = self.synchronousRequest(request, urgent: true, dataHandlerTarget: self, selector: NSSelectorFromString("_connection:handleData_fetchDatabaseIndex:context:"), context: Unmanaged.passUnretained(array).toOpaque())
                if thread.isCancelled { return }
                let received = (array.object(at: 3) as! N2MutableUInteger).unsignedIntegerValue
                if received != databaseIndexSize {
                    remoteDicomDatabaseRaise(.objectInaccessibleException, String(format: NSLocalizedString("Incomplete remote database index: received %lu of %lu bytes.", comment: ""), received, databaseIndexSize))
                }
                complete = true
                thread.status = NSLocalizedString("Done.", comment: "")
                result = path
            }
        } catch {
            raised = remoteDicomDatabaseException(error)
        }
        // @finally
        if let context, context.count > 2 { (context.object(at: 2) as? Stream)?.close() }
        if !complete, let path { try? FileManager.default.removeItem(atPath: path) }
        thread.exitOperation()
        if let raised { raised.raise() }
        return result
    }

    @objc(_connection:handleData_fetchDatabaseIndex:context:)
    func _connection(_ connection: N2Connection?, handleData_fetchDatabaseIndex data: NSData?, context: NSArray) -> Int {
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
            } else { remoteDicomDatabaseRaise(.genericException, fileStream.streamError?.localizedDescription ?? "(null)") }
        }

        thread.progress = 1.0 * Double(obtainedSize.unsignedIntegerValue) / Double(databaseIndexSize)
        thread.progressDetails = String(format: NSLocalizedString("Received %lu of %lu bytes", comment: ""), obtainedSize.unsignedIntegerValue, UInt(bitPattern: databaseIndexSize))

        return data?.length ?? 0
    }

    @objc func fetchDatabaseTimestamp() -> TimeInterval {
        let request = NSMutableData(bytes: "VERSI", length: 6)
        let response = self.synchronousRequest(request, urgent: true)
        if (response?.length ?? 0) == 0 { remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: "")) }
        if response!.length != MemoryLayout<UInt64>.size { remoteDicomDatabaseRaise(.internalInconsistencyException, NSLocalizedString("Invalid response data from remote host.", comment: "")) }
        var swapped: UInt64 = 0
        response!.getBytes(&swapped, length: 8)
        return Double(bitPattern: UInt64(bigEndian: swapped))
    }

    @objc(fetchDicomDestinationInfoForAddress:port:)
    public class func fetchDicomDestinationInfo(forAddress address: String?, port: Int) -> NSDictionary? {
        var port = port
        if port == 0 { port = 8780 }
        let request = NSMutableData(bytes: "GETDI", length: 6)
        let response = N2Connection.sendSynchronousRequest(request as Data, toAddress: address, port: port)
        if (response?.count ?? 0) == 0 {
            NSException(name: .objectInaccessibleException, reason: NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: ""), userInfo: nil).raise()
        }
        // The peer's NSArchiver data, read as a dictionary of strings without
        // instantiating any class it names; NSUnarchiver let the peer choose (#817).
        let info = SharedDatabaseDestinationInfo.dictionary(fromReply: response!)
        if info == nil {
            NSException(name: .internalInconsistencyException, reason: NSLocalizedString("Invalid response data from remote host.", comment: ""), userInfo: nil).raise()
        }
        return info
    }

    @objc public func fetchDicomDestinationInfo() -> NSDictionary? {
        return RemoteDicomDatabase.fetchDicomDestinationInfo(forAddress: self.address, port: self.port)
    }

    @objc(updateOnMainThread:)
    func updateOnMainThread(_ path: String?) {
        _updateLock?.lock()
        defer { _updateLock?.unlock() }

        do {
            try HorosObjCException.perform {
                let context = self.context(atPath: path)
                // Synchronize with both contexts before publishing the replacement.
                // The coordinators remain owned by their contexts; no stores are
                // mutated here. Keep the UI and its notifications on the main
                // thread rather than entering a coordinator's private queue.
                N2ManagedObjectContextPerformAndWait(self.managedObjectContext) {}
                N2ManagedObjectContextPerformAndWait(context) {}
                // -updateOnMainThread: runs where its name says.
                MainActor.assumeIsolated {
                    for vc in ViewerController.getDisplayed2DViewers() ?? NSMutableArray() {
                        (vc as? ViewerController)?.window?.orderOut(nil)
                    }
                }

                self._sqlFileName = (path as NSString?)?.lastPathComponent
                // [_sqlFilePath autorelease]; _sqlFilePath = [path retain];
                self.horos_sqlFilePath = path

                let previousContext = self.managedObjectContext
                if let previousContext { _ = Unmanaged.passRetained(previousContext).autorelease() }

                MainActor.assumeIsolated { BrowserController.currentBrowser()?.willChangeContext() }

                self.managedObjectContext = context

                NotificationCenter.default.post(name: .OsirixAddToDB, object: self)
                NotificationCenter.default.post(name: ._O2AddToDBAnyway, object: self)
                NotificationCenter.default.post(name: .OsirixDicomDatabaseDidChangeContext, object: self)

                // delete old index file(s)
                (previousContext as? RemoteDicomDatabaseManagedObjectContext)?.cleanupOnDealloc = true

                if self._updateTimer == nil {
                    let timer = Timer(timeInterval: TimeInterval(UserDefaults.standard.integer(forKey: "DatabaseRefreshInterval")), target: RemoteDicomDatabase.self as AnyObject, selector: #selector(RemoteDicomDatabase._updateTimerCallbackClass(_:)), userInfo: NSValue(pointer: Unmanaged.passUnretained(self).toOpaque()), repeats: true)
                    self._updateTimer = timer
                    RunLoop.main.add(timer, forMode: .modalPanel)
                    RunLoop.main.add(timer, forMode: .default)
                }
            }
        } catch {
            _N2LogExceptionImpl(remoteDicomDatabaseException(error), true, "-[RemoteDicomDatabase updateOnMainThread:]")
        }
    }

    @objc func update() {
        let thread = Thread.current

        NSLog("-- Remote database update")

        thread.enterOperation()
        _updateLock?.lock()
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                thread.status = NSLocalizedString("Downloading index...", comment: "")
                let path = self.fetchDatabaseIndex()
                if path == nil {
                    remoteDicomDatabaseRaise(.genericException, "Cancelled.")
                }

                self._timestamp = self.fetchDatabaseTimestamp()

                self.performSelector(onMainThread: #selector(RemoteDicomDatabase.updateOnMainThread(_:)), with: path, waitUntilDone: false)
            }
        } catch {
            raised = remoteDicomDatabaseException(error)
        }
        // @finally
        _updateLock?.unlock()
        thread.exitOperation()
        if let raised { raised.raise() }
    }

    @objc(updateThread:)
    func updateThread(_ obj: Any?) {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    let thread = Thread.current
                    thread.name = NSLocalizedString("Updating remote database...", comment: "")
                    ThreadsManager.default().addThreadAndStart(thread)
                    self.update()
                }
            } catch {
                _N2LogExceptionImpl(remoteDicomDatabaseException(error), true, "-[RemoteDicomDatabase updateThread:]")
            }
        }
    }

    @objc public func initiateUpdate() -> Thread? {

        if onMainActorSync({ ViewerController.getDisplayed2DViewers()?.count ?? 0 }) > 0 {
            return nil
        }

        if let updateLock = _updateLock, updateLock.try() {
            var thread: Thread? = nil
            do {
                try HorosObjCException.perform {
                    let started = Thread(target: self, selector: #selector(RemoteDicomDatabase.updateThread(_:)), object: nil)
                    started.start()
                    thread = started
                }
            } catch {
                _N2LogExceptionImpl(remoteDicomDatabaseException(error), true, "-[RemoteDicomDatabase initiateUpdate]")
            }
            // @finally
            updateLock.unlock()
            return thread
        }

        return nil
    }

    @objc func needsUpdate() -> Bool {
        let timestamp = self.fetchDatabaseTimestamp()
        return timestamp != _timestamp
    }

    @objc(fetchFileModificationDate:)
    func fetchFileModificationDate(_ path: String?) -> String? { // ------------------------------------ this seems to be unused
        let request = NSMutableData(bytes: "MFILE", length: 6)
        let pathData = (path as NSString?)?.data(using: String.Encoding.unicode.rawValue)
        RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: pathData?.count ?? 0))
        if let pathData { request.append(pathData) }
        let response = self.synchronousRequest(request, urgent: true)
        if (response?.length ?? 0) == 0 { remoteDicomDatabaseRaise(.objectInaccessibleException, NSLocalizedString("Failed to connect to the remote host. Is database sharing activated on the distant computer?", comment: "")) }
        return NSString(data: response! as Data, encoding: String.Encoding.unicode.rawValue) as String?
    }

    @objc(object:setValue:forKey:)
    public func object(_ object: NSManagedObject?, setValue value: Any?, forKey key: String?) {
        let request = NSMutableData(bytes: "SETVA", length: 6)
        RemoteDicomDatabase._data(request, appendStringUTF8: object?.objectID.uriRepresentation().absoluteString)
        RemoteDicomDatabase._data(request, appendStringUTF8: (value as? NSNumber)?.stringValue ?? value)
        RemoteDicomDatabase._data(request, appendStringUTF8: key)
        _ = self.synchronousRequest(request, urgent: true)
        _timestamp = self.fetchDatabaseTimestamp()
    }

    private enum RemoteDicomDatabaseStudiesAlbumAction { case add, remove }

    private func _studies(_ dicomStudies: [Any]?, album dicomAlbum: DicomAlbum?, action: RemoteDicomDatabaseStudiesAlbumAction) {
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

        _ = self.synchronousRequest(request, urgent: true)

        _timestamp = self.fetchDatabaseTimestamp()
    }

    public override func addStudies(_ dicomStudies: [Any]!, to dicomAlbum: DicomAlbum!) {
        super.addStudies(dicomStudies, to: dicomAlbum)
        self._studies(dicomStudies, album: dicomAlbum, action: .add)
    }

    @objc(removeStudies:fromAlbum:)
    public func removeStudies(_ dicomStudies: [Any]?, fromAlbum dicomAlbum: DicomAlbum?) {
        self._studies(dicomStudies, album: dicomAlbum, action: .remove)
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
        let paths: NSArray = (paths as NSArray?) ?? NSArray()
        let images = images as NSArray?
        let thread = Thread.current
        thread.enterOperation()
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                for path in paths {
                    if !FileManager.default.fileExists(atPath: (path as? String) ?? "") {
                        remoteDicomDatabaseRaise(.invalidArgumentException, "File not available.")
                    }
                }

                let request = NSMutableData(bytes: generatedByOsiriX ? "SENDG" : "SENDD", length: 6)
                RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: paths.count))
                let filesInRequest = NSMutableArray()
                let dbObjsInRequest: NSMutableArray? = images != nil ? NSMutableArray() : nil

                for i in 0..<paths.count {
                    let path = paths.object(at: i)
                    thread.progress = 1.0 * Double(i - filesInRequest.count / 2) / Double(paths.count)

                    filesInRequest.add(path)
                    if let dbObjsInRequest { remoteDicomDatabaseAdd(dbObjsInRequest, images!.object(at: i)) }

                    let fileData = NSData(contentsOfFile: (path as? String) ?? "")
                    RemoteDicomDatabase._data(request, appendInt: UInt32(truncatingIfNeeded: fileData?.length ?? 0))
                    if let fileData { request.append(fileData as Data) }

                    if request.length > 32 * 1024 * 1024 || ((path as AnyObject) === (paths.lastObject as AnyObject?) && filesInRequest.count > 0) { // we split the send in smaller chunks to avoid allocation problems
                        let count = NSMutableData()
                        RemoteDicomDatabase._data(count, appendInt: UInt32(truncatingIfNeeded: filesInRequest.count))
                        request.replaceBytes(in: NSRange(location: 6, length: count.length), withBytes: count.bytes, length: count.length)

                        let response = self.synchronousRequest(request, urgent: true)?.mutableCopy() as? NSMutableData
                        if let dbObjsInRequest, dbObjsInRequest.count > 0, let response, response.length > 0 {
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
            }
        } catch {
            raised = remoteDicomDatabaseException(error)
        }
        // @finally
        thread.exitOperation()
        if let raised { raised.raise() }
    }

    @objc(cacheDataForImage:maxFiles:)
    public func cacheData(for image: DicomImage?, maxFiles: Int) -> String? {
        guard let image else {
            RemoteDicomDatabaseLogStackTrace("image == nil")
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

            remoteDicomDatabaseAdd(localPaths, iLocalPath)
            remoteDicomDatabaseAdd(remotePaths, iImage.path())

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

        return self.downloadRemotePaths(remotePaths as? [Any], toLocalPaths: localPaths as? [Any]) ? localPath : nil
    }

    @objc(refreshCacheDataForImage:)
    public func refreshCacheData(for image: DicomImage?) -> String? {
        guard let image, let path = image.path(), (path as NSString).length > 0 else { return nil }
        let destination = self.localPath(for: image)
        let remotePaths = NSMutableArray(object: path)
        let localPaths = NSMutableArray()
        remoteDicomDatabaseAdd(localPaths, destination)
        return self.downloadRemotePaths(remotePaths as? [Any], toLocalPaths: localPaths as? [Any]) ? destination : nil
    }

    @objc(downloadRemotePaths:toLocalPaths:)
    func downloadRemotePaths(_ remotePaths: [Any]?, toLocalPaths localPaths: [Any]?) -> Bool {
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
        // handler found no files remaining and refused every download (#644).
        horosResetRemoteDownload(context)
        var downloaded = false
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                _ = self.synchronousRequest(request, urgent: true, dataHandlerTarget: self, selector: NSSelectorFromString("_connection:handleData_fetchDataForImage:context:"), context: Unmanaged.passUnretained(context).toOpaque())
                downloaded = ((context.object(forKey: "remaining") as? NSSet)?.count ?? 0) == 0 && context.object(forKey: "state") != nil
            }
        } catch {
            raised = remoteDicomDatabaseException(error)
        }
        // @finally
        horosCleanupRemoteDownload(context)
        if let raised { raised.raise() }
        return downloaded
    }

    @objc(_connection:handleData_fetchDataForImage:context:)
    func _connection(_ connection: N2Connection?, handleData_fetchDataForImage data: NSData?, context: NSMutableDictionary) -> Int {
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
                        remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), "Unexpected file count in remote response.")
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
                    if l == 0 { remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), "Empty remote image.") }
                    values.add(NSNumber(value: l)) // [3]

                    let path: String? = FileManager.default.tmpFilePath(inDir: self.tempDirPath())
                    remoteDicomDatabaseAdd(values, path) // [4]
                    let stream = path.flatMap { OutputStream(toFileAtPath: $0, append: false) }
                    stream?.open()
                    remoteDicomDatabaseAdd(values, stream) // [5]
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
                    } else { remoteDicomDatabaseRaise(.genericException, stream.streamError?.localizedDescription ?? "(null)") }
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
                        remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), "Invalid remote filename length.")
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
                        remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), "Invalid remote filename encoding.")
                    }
                    guard let path = NSString(bytes: name, length: pathSize - 1, encoding: String.Encoding.utf8.rawValue), remaining.contains(path) else {
                        remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), "Unexpected remote destination.")
                    }
                    readSize += pathSize
                    //DLog(@"RDD path is %@", path);
                    values.removeLastObject() // rm [7]
                    values.removeLastObject() // rm [6]
                    (values.object(at: 5) as! OutputStream).close()
                    values.removeLastObject() // rm [5]

                    let existing = try? FileManager.default.attributesOfItem(atPath: path as String)
                    if let existing, (existing[.type] as? String) != FileAttributeType.typeRegular.rawValue {
                        remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), "The cache destination is not a regular file.")
                    }
                    let temporary = values.object(at: 4) as! NSString
                    if rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0 {
                        let installationCode = errno
                        var installationError: NSError? = nil
                        // Normally cache and temporary files share a volume. Only
                        // cross-volume installs need another prepared copy.
                        if installationCode != EXDEV || !HorosReplaceReportFile(temporary as String, path as String, &installationError) {
                            remoteDicomDatabaseRaise(NSExceptionName(rawValue: "RemoteDownload"), String(format: "Remote cache installation failed (%d).", installationCode))
                        }
                    }
                    try? FileManager.default.removeItem(atPath: temporary as String)
                    remaining.remove(path)

                    values.removeLastObject() // rm [4]
                    values.removeLastObject() // rm [3]
                    state.unsignedIntegerValue = 1

                    let counter = values.object(at: 2) as! N2MutableUInteger
                    counter.increment()
                    if counter.unsignedIntegerValue == (values.object(at: 1) as! NSNumber).uintValue {
                        connection?.close()
                    }
                } else { return readSize }
            default:
                break
            }
        }

        return readSize
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
                remoteDicomDatabaseAdd(imagePaths, path)
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

    public override func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() { // don't
    }

    public override func rebuild(_ complete: Bool) { // do nothing
    }

    public override func addDefaultAlbums() { // do nothing
    }
}

/// @unchecked Sendable, restated from NSManagedObjectContext: the context's
/// own queue contract (#947) governs its use; this subclass adds only
/// `cleanupOnDealloc`, set once by the database that creates it.
@objc(RemoteDicomDatabaseManagedObjectContext)
final class RemoteDicomDatabaseManagedObjectContext: N2ManagedObjectContext, @unchecked Sendable {
    @objc var cleanupOnDealloc = false

    deinit {
        if self.cleanupOnDealloc {
            if let url = self.persistentStoreCoordinator?.persistentStores.first?.url {
                (type(of: self) as AnyObject).perform(#selector(RemoteDicomDatabaseManagedObjectContext.postDeallocCleanup(_:)), with: url as NSURL, afterDelay: 0)
            }
        }
    }

    @objc(postDeallocCleanup:)
    class func postDeallocCleanup(_ url: NSURL) {
        let dir = url.deletingLastPathComponent
        try? FileManager.default.removeItem(at: url as URL)
        if let shm = dir?.appendingPathComponent((url.lastPathComponent ?? "") + "-shm") {
            try? FileManager.default.removeItem(at: shm)
        }
    }
}
