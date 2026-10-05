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

/// @synchronized(object) { body }: the same recursive lock (objc_sync_enter).
/// An NSException that body raises releases it and then goes on to the
/// caller, as it did through @synchronized. A nil object takes no lock, as
/// @synchronized(nil) did.
fileprivate func webPortalSynchronized(_ object: AnyObject?, _ body: () -> Void) {
    guard let object = object else {
        body()
        return
    }
    objc_sync_enter(object)
    var raised: NSException? = nil
    do {
        try HorosObjCException.perform(body)
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    raised?.raise()
}

/// What a caught NSException (or another error) prints as with %@.
fileprivate func webPortalCaught(_ error: Error) -> NSObject {
    return ((error as NSError).userInfo[HorosObjCExceptionKey] as? NSObject) ?? (error as NSError)
}

/// The HTTP server of a portal: it hands each new connection to the run loop
/// of the portal's thread pool that has the fewest.
///
/// Implemented in Swift since #718: the Objective-C name, the selectors and
/// <Horos/WebPortal.h> are those of the former class.
@objc(WebPortalServer)
public final class WebPortalServer: HTTPServer {
    /// `assign` in the former header: the portal owns the server and outlives
    /// it. Weak here, so a reference never dangles.
    @objc public internal(set) weak var portal: WebPortal!

    public override init() {
        super.init()
        webPortalServerInstallListener(HorosPortalSocket(delegate: self))
        setDomain("local.")
        setName("")
    }

    /// AsyncSocket's delegate: the run loop the new connection runs on.
    @objc(onSocket:wantsRunLoopForNewSocket:)
    public func onSocket(_ sock: AsyncSocket!, wantsRunLoopForNewSocket newSocket: AsyncSocket!) -> RunLoop! {
        // Figure out what thread/runloop to run the new connection on.
        // We choose the thread/runloop with the lowest number of connections.

        var m: UInt32 = 0
        var mLoop: RunLoop? = nil
        var mLoad: UInt32 = 0

        webPortalSynchronized(portal?.runLoops) {
            mLoop = self.portal?.runLoops?.object(at: 0) as? RunLoop
            mLoad = (self.portal?.runLoopsLoad?.object(at: 0) as? NSNumber)?.uint32Value ?? 0

            var i: UInt32 = 1
            while i < UInt32(THREAD_POOL_SIZE) {
                let iLoad = (self.portal?.runLoopsLoad?.object(at: Int(i)) as? NSNumber)?.uint32Value ?? 0

                if iLoad < mLoad {
                    m = i
                    mLoop = self.portal?.runLoops?.object(at: Int(i)) as? RunLoop
                    mLoad = iLoad
                }
                i += 1
            }

            self.portal?.runLoopsLoad?.replaceObject(at: Int(m), with: NSNumber(value: mLoad &+ 1))
        }
        // And finally, return the proper run loop
        return mLoop
    }

    /// Called when an HTTPConnection dies: the number of connections of its
    /// thread goes down. Called on the thread/runloop that posted the
    /// notification.
    public override func connectionDidDie(_ notification: Notification!) {
        webPortalSynchronized(portal?.runLoops) {
            let runLoopIndex = UInt32(truncatingIfNeeded: self.portal?.runLoops?.index(of: RunLoop.current) ?? 0)

            if Int(runLoopIndex) < (self.portal?.runLoops?.count ?? 0) {
                let runLoopLoad = (self.portal?.runLoopsLoad?.object(at: Int(runLoopIndex)) as? NSNumber)?.uint32Value ?? 0

                let newLoad = NSNumber(value: runLoopLoad &- 1)

                self.portal?.runLoopsLoad?.replaceObject(at: Int(runLoopIndex), with: newLoad)
            }
        }

        // Don't forget to call super, or the connection won't get proper deallocated!
        super.connectionDidDie(notification)
    }
}

/// The web portal: its HTTP server and thread pool, its sessions, and the
/// files of its pages.
///
/// Implemented in Swift since #718: the Objective-C name, the selectors and
/// <Horos/WebPortal.h> are those of the former class. +initialize stays in
/// WebPortal+CAPI.m, and runs for WebPortal only, not for the subclass KVO
/// makes; the class methods are `dynamic`, so a call from Swift is a message
/// to the class, as from Objective-C, and runs +initialize first.
@objc(WebPortal)
public final class WebPortal: NSObject {
    /// Guards the three statics below: the portal's connection threads ask
    /// for the portals while the main thread makes or finalizes them. Recursive,
    /// because making a portal reads the path again.
    private static let instancesLock = NSRecursiveLock()
    // nonisolated(unsafe): read and written only inside `instancesLock.withLock`.
    nonisolated(unsafe) private static var defaultWebPortalDatabasePath: String? = nil
    nonisolated(unsafe) private static var defaultWebPortalInstance: WebPortal? = nil
    nonisolated(unsafe) private static var wadoOnlyWebPortalInstance: WebPortal? = nil

    /// What the former +initialize did, called by it (WebPortal+CAPI.m).
    @objc(horosInitializeWebPortalClass)
    public dynamic class func horosInitializeWebPortalClass() {
        #if MACAPPSTORE
        var databasePath = ("~/Library/Application Support/Horos App/WebUsers.sql" as NSString).expandingTildeInPath
        #else
        var databasePath = ("~/Library/Application Support/Horos/WebUsers.sql" as NSString).expandingTildeInPath
        #endif
        // The accounts of the Web Portal live outside the DICOM database, so a build
        // pointed at an isolated database still read and wrote the accounts of the
        // installed application. An explicit path keeps a development or test run
        // from touching them; unset, the location is the one above.
        let configuredPath = (UserDefaults.standard.string(forKey: "WebPortalDatabasePath") as NSString?)?.expandingTildeInPath
        if let configuredPath = configuredPath, (configuredPath as NSString).length != 0 {
            databasePath = configuredPath
            NSLog("---- Web Portal accounts: %@", configuredPath as NSString)
        }
        instancesLock.withLock { defaultWebPortalDatabasePath = databasePath }
        NSUserDefaultsController.shared.addObserver(classObserver(self), forValuesKey: OsirixWadoServiceEnabledDefaultsKey, options: .initial, context: nil)
    }

    /// The class object a class method runs on, which observes the defaults
    /// (the former `(id)self` of a class method).
    private class func classObserver(_ cls: AnyClass) -> NSObject {
        return unsafeBitCast(cls as AnyObject, to: NSObject.self)
    }

    /// The portal passed as the context of the class's observations.
    private static func observationContext(_ portal: WebPortal?) -> UnsafeMutableRawPointer? {
        return portal.map { Unmanaged.passUnretained($0).toOpaque() }
    }

    // called from AppController
    @objc(initializeWebPortalClass)
    public dynamic class func initializeWebPortalClass() {
        #if !OSIRIX_LIGHT
        let defaults = NSUserDefaultsController.shared
        let observer = classObserver(self)
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalPortNumberDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalAddressDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalUsesSSLDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalPrefersCustomWebPagesKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalRequiresAuthenticationDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalUsersCanRestorePasswordDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalUsesWeasisDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalPrefersFlashDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWadoServiceEnabledDefaultsKey, options: .initial, context: observationContext(self.default()))

        // last because this starts the listener
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalEnabledDefaultsKey, options: .initial, context: observationContext(self.default()))

        defaults.addObserver(observer, forValuesKey: OsirixWebPortalNotificationsIntervalDefaultsKey, options: .initial, context: observationContext(self.default()))
        defaults.addObserver(observer, forValuesKey: OsirixWebPortalNotificationsEnabledDefaultsKey, options: .initial, context: observationContext(self.default()))

        if UserDefaults.webPortalEnabled() {
            _ = CSMailMailClient.mailClient() //If authentication is required to read email password: ask it now !
        }

        if UserDefaults.standard.bool(forKey: "wadoOnlyServer") && ProtectedMode.isActive {
            ProtectedMode.skip("WADO server")
        } else if UserDefaults.standard.bool(forKey: "wadoOnlyServer") {
            let w: WebPortal! = self.wadoOnly()

            w?.usesSSL = false
            w?.portNumber = UserDefaults.standard.integer(forKey: "wadoOnlyServerPort")
            w?.address = UserDefaults.standard.string(forKey: "wadoOnlyServerURL")
            w?.authenticationRequired = false
            w?.weasisEnabled = false
            w?.flashEnabled = false
            w?.wadoEnabled = true
            w?.notificationsEnabled = false
            w?.startAcceptingConnections()
        }
        #endif
    }

    @objc(observeValueForKeyPath:ofObject:change:context:)
    public dynamic override class func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let context = context else {
            if keyPath == valuesKeyPath(OsirixWadoServiceEnabledDefaultsKey) {
                if !UserDefaults.wadoServiceEnabled() {
                    NSUserDefaultsController.shared.setBool(false, forKey: OsirixWebPortalUsesWeasisDefaultsKey)
                }
            }
            return
        }

        let webPortal = Unmanaged<WebPortal>.fromOpaque(context).takeUnretainedValue()

        if keyPath == valuesKeyPath(OsirixWebPortalEnabledDefaultsKey) {
            if UserDefaults.webPortalEnabled() && ProtectedMode.isActive {
                ProtectedMode.skip("Web Portal")
            } else if UserDefaults.webPortalEnabled() {
                webPortal.startAcceptingConnections()
            } else {
                webPortal.stopAcceptingConnections()
            }
        } else if keyPath == valuesKeyPath(OsirixWebPortalUsesSSLDefaultsKey) {
            webPortal.usesSSL = UserDefaults.webPortalUsesSSL()
        } else if keyPath == valuesKeyPath(OsirixWebPortalPortNumberDefaultsKey) {
            webPortal.portNumber = UserDefaults.webPortalPortNumber()
        } else if keyPath == valuesKeyPath(OsirixWebPortalAddressDefaultsKey) {
            webPortal.address = UserDefaults.webPortalAddress()
        } else if keyPath == valuesKeyPath(OsirixWebPortalPrefersCustomWebPagesKey) {
            let dirsToScanForFiles = NSMutableArray(capacity: 2)
            #if MACAPPSTORE
            if UserDefaults.webPortalPrefersCustomWebPages() { dirsToScanForFiles.add(("~/Library/Application Support/Horos App/WebServicesHTML" as NSString).expandingTildeInPath) }
            #else
            if UserDefaults.webPortalPrefersCustomWebPages() { dirsToScanForFiles.add(("~/Library/Application Support/Horos/WebServicesHTML" as NSString).expandingTildeInPath) }
            #endif
            dirsToScanForFiles.add(((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("WebServicesHTML"))
            let dirs = dirsToScanForFiles as! [Any]
            webPortal.dirsToScanForFiles = dirs
        } else if keyPath == valuesKeyPath(OsirixWebPortalRequiresAuthenticationDefaultsKey) {
            webPortal.authenticationRequired = UserDefaults.webPortalRequiresAuthentication()
        } else if keyPath == valuesKeyPath(OsirixWebPortalUsersCanRestorePasswordDefaultsKey) {
            webPortal.passwordRestoreAllowed = UserDefaults.webPortalUsersCanRestorePassword()
        } else if keyPath == valuesKeyPath(OsirixWebPortalUsesWeasisDefaultsKey) {
            webPortal.weasisEnabled = UserDefaults.webPortalUsesWeasis()
        } else if keyPath == valuesKeyPath(OsirixWebPortalPrefersFlashDefaultsKey) {
            webPortal.flashEnabled = UserDefaults.webPortalPrefersFlash()
        } else if keyPath == valuesKeyPath(OsirixWadoServiceEnabledDefaultsKey) {
            webPortal.wadoEnabled = UserDefaults.wadoServiceEnabled()
        } else if keyPath == valuesKeyPath(OsirixWebPortalNotificationsIntervalDefaultsKey) {
            webPortal.notificationsInterval = UserDefaults.webPortalNotificationsInterval()
        } else if keyPath == valuesKeyPath(OsirixWebPortalNotificationsEnabledDefaultsKey) {
            webPortal.notificationsEnabled = UserDefaults.webPortalNotificationsEnabled()
        }
    }

    @objc(finalizeWebPortalClass)
    public dynamic class func finalizeWebPortalClass() {
        //	[NSUserDefaultsController.sharedUserDefaultsController removeObserver:self forValuesKey:OsirixWebPortalNotificationsIntervalDefaultsKey];
        // This used to release the portal once more than anything retained
        // it, and to make one first to do so. The static reference stays: the
        // observations of the defaults carry the portal, unretained, as their
        // context. What its deallocation would have ended ends here: its
        // timers, which call it back.
        instancesLock.withLock { defaultWebPortalInstance }?.invalidateTimers()
    }

    @objc(defaultWebPortal)
    public dynamic class func `default`() -> WebPortal! {
        return instancesLock.withLock { () -> WebPortal? in
            guard let path = defaultWebPortalDatabasePath else { return nil }

            if defaultWebPortalInstance == nil {
                defaultWebPortalInstance = self.init(databaseAtPath: path, dicomDatabase: DicomDatabase.default())
            }

            return defaultWebPortalInstance
        }
    }

    @objc(wadoOnlyWebPortal)
    public dynamic class func wadoOnly() -> WebPortal! {
        return instancesLock.withLock { () -> WebPortal? in
            guard let path = defaultWebPortalDatabasePath else { return nil }

            if wadoOnlyWebPortalInstance == nil {
                wadoOnlyWebPortalInstance = self.init(databaseAtPath: path, dicomDatabase: DicomDatabase.default())
            }

            return wadoOnlyWebPortalInstance
        }
    }

    // MARK: Instance

    @objc public private(set) var database: WebPortalDatabase!
    @objc public private(set) var dicomDatabase: DicomDatabase!
    @objc public private(set) var cache: NSMutableDictionary!

    /// The DICOM database to read on this thread: the portal's own on the main
    /// thread; the web connection's, inside its queue, while a connection
    /// answers a request on this thread; otherwise a new private-queue
    /// database, whose caller wraps its reads in -performBlockAndWait: (#966).
    @objc public func threadDicomDatabase() -> DicomDatabase? {
        if Thread.isMainThread {
            return dicomDatabase
        }
        if let database = Thread.current.threadDictionary[WebPortalConnection.threadDicomDatabaseKey] as? DicomDatabase,
           (database.mainDatabase as AnyObject?) === dicomDatabase {
            return database
        }
        return dicomDatabase?.privateQueueIndependentDatabase() as? DicomDatabase
    }

    /// The portal database to read on this thread, as `threadDicomDatabase()`.
    @objc public func threadWebDatabase() -> WebPortalDatabase? {
        if Thread.isMainThread {
            return database
        }
        if let database = Thread.current.threadDictionary[WebPortalConnection.threadWebDatabaseKey] as? WebPortalDatabase,
           (database.mainDatabase as AnyObject?) === self.database {
            return database
        }
        return database?.privateQueueIndependentDatabase() as? WebPortalDatabase
    }
    @objc public private(set) var locks: NSMutableDictionary!
    @objc public private(set) var sessions: NSMutableArray!

    /// Atomic in the former header; a BOOL is read and written as one word.
    @objc public private(set) var isAcceptingConnections: Bool = false

    @objc public private(set) var runLoops: NSMutableArray!
    @objc public private(set) var runLoopsLoad: NSMutableArray!

    private var _usesSSL: Bool = false
    @objc public dynamic var usesSSL: Bool {
        get { return _usesSSL }
        set {
            if newValue != _usesSSL {
                _usesSSL = newValue
                self.restartIfRunning()
            }
        }
    }

    private var _portNumber: Int = 0
    @objc public dynamic var portNumber: Int {
        get { return _portNumber }
        set {
            if newValue != _portNumber {
                _portNumber = newValue
                self.restartIfRunning()
            }
        }
    }

    /// Atomic and retained in the former header; an object reference is read
    /// and written as one word.
    @objc public dynamic var address: String!

    /// Atomic and retained in the former header, as address.
    @objc public dynamic var dirsToScanForFiles: [Any]!

    // Atomic in the former header, as isAcceptingConnections.
    @objc public dynamic var authenticationRequired: Bool = false
    @objc public dynamic var passwordRestoreAllowed: Bool = false

    @objc public dynamic var wadoEnabled: Bool = false
    @objc public dynamic var weasisEnabled: Bool = false
    @objc public dynamic var flashEnabled: Bool = false

    private var _notificationsEnabled: Bool = false
    @objc public dynamic var notificationsEnabled: Bool {
        get { return _notificationsEnabled }
        set { setNotificationsEnabledValue(newValue) }
    }

    private var _notificationsInterval: Int = 0
    @objc public dynamic var notificationsInterval: Int {
        get { return _notificationsInterval }
        set { setNotificationsIntervalValue(newValue) }
    }

    private let sessionsArrayLock: NSLock
    private let sessionCreateLock: NSLock
    private var notificationsTimer: Timer? = nil
    private var temporaryUsersTimer: Timer? = nil
    private var preferredLocalizations: NSArray? = nil
    private var httpThreads: NSMutableArray? = nil
    private var server: WebPortalServer? = nil
    private var serverThread: Thread? = nil
    /// Guards the start of a server: a server is being started and none of
    /// its connection threads has yet marked the portal as accepting.
    private let startLock = NSLock()
    private var serverStarting = false

    @objc(initWithDatabase:dicomDatabase:)
    public init(database db: WebPortalDatabase!, dicomDatabase dd: DicomDatabase!) {
        sessions = NSMutableArray(capacity: 64)
        sessionsArrayLock = NSLock()
        sessionCreateLock = NSLock()

        super.init()

        // Nothing observes the portal while it is being made: the properties
        // are set directly, as the former setters would have.
        self.database = db
        self.dicomDatabase = dd
        self.cache = NSMutableDictionary()
        self.locks = NSMutableDictionary()

        // -deleteTemporaryUsers: is in WebPortal+Email+Log.
        temporaryUsersTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: Selector(("deleteTemporaryUsers:")), userInfo: nil, repeats: true)

        preferredLocalizations = Bundle.main.preferredLocalizations as NSArray
    }

    @objc(initWithDatabaseAtPath:dicomDatabase:)
    public convenience init(databaseAtPath sqlFilePath: String!, dicomDatabase dd: DicomDatabase!) {
        // The database at the path given; it used to be the default one
        // whatever the path. Both portals of the class pass the default path.
        self.init(database: WebPortalDatabase(path: sqlFilePath ?? WebPortal.instancesLock.withLock { WebPortal.defaultWebPortalDatabasePath }), dicomDatabase: dd)
    }

    @objc(threadForRunLoopRef:)
    public func thread(forRunLoopRef runloopref: CFRunLoop!) -> Thread! {
        var index = NSNotFound

        if let runLoops = runLoops {
            for rl in runLoops {
                if let rl = rl as? RunLoop, rl.getCFRunLoop() === runloopref {
                    index = runLoops.index(of: rl)
                    break
                }
            }
        }

        if index != NSNotFound {
            return httpThreads?.object(at: index) as? Thread
        }

        NSLog("******* threadForRunLoop runloop not found !")

        return nil
    }

    @objc(invalidate)
    public func invalidate() {
        self.stopAcceptingConnections()
    }

    deinit {
        self.invalidate()

        notificationsTimer?.invalidate()
        notificationsTimer = nil

        temporaryUsersTimer?.invalidate()
        temporaryUsersTimer = nil

        setNotificationsEnabledValue(false)
    }

    /// Stops the timers that call the portal back: its notifications and the
    /// deletion of its temporary users.
    private func invalidateTimers() {
        notificationsTimer?.invalidate()
        notificationsTimer = nil

        temporaryUsersTimer?.invalidate()
        temporaryUsersTimer = nil
    }

    @objc(restartIfRunning)
    public func restartIfRunning() {
        if isAcceptingConnections {
            NSLog("----- cannot restart web server -> you have to restart Horos")
            //		[self stopAcceptingConnections];
            //		[self startAcceptingConnections];
        }
    }

    /// This is the main thread for the socket connections, then, the
    /// connections are distributed in our thread pool.
    @objc(startServerThread)
    public func startServerThread() {
        autoreleasepool {
            Thread.current.name = "WebPortal server thread"

            // Start threads
            var i: UInt32 = 0
            while i < UInt32(THREAD_POOL_SIZE) {
                Thread.detachNewThreadSelector(#selector(connectionsThread(_:)), toTarget: self, with: NSNumber(value: i))
                i += 1
            }

            // A message to a nil server answered NO, with no error.
            var err: NSError? = nil
            var started = false
            if let server = server {
                do {
                    try server.start()
                    started = true
                } catch {
                    err = error as NSError
                }
            }
            if !started {
                var bindErrno = AsyncSocket.lastBindErrno()
                if bindErrno == 0 {
                    bindErrno = errno
                }
                NSLog("Exception: [WebPortal startAcceptingConnectionsThread:] %@", err.map { $0 as NSObject } ?? ("(null)" as NSString))
                AppController.shared()?.reportListenBindFailure(forService: "web portal",
                                                                             port: self.portNumber,
                                                                             errnoCode: bindErrno)
                return
            }

            while !Thread.current.isCancelled {
                autoreleasepool {
                    do {
                        try HorosObjCException.perform {
                            _ = RunLoop.current.run(mode: .default, before: Date.distantFuture)
                        }
                    } catch {
                        if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                            _N2LogExceptionImpl(e, true, "-[WebPortal startServerThread]")
                        }
                    }
                }
            }

            _ = server?.stop()

            NSLog("[WebPortal startServerThread:] finishing")
        }
    }

    @objc(startAcceptingConnections)
    public func startAcceptingConnections() {
        // The portal accepts connections once one of the connection threads
        // has started. A second start before that used to make a second
        // server, which took the arrays of the first and could not bind its
        // port: one start at a time, until a thread marks the portal.
        startLock.lock()
        let start = !isAcceptingConnections && !serverStarting
        if start {
            serverStarting = true
        }
        startLock.unlock()

        if start {
            do {
                try HorosObjCException.perform {
                    // Initialize an array to reference all the threads
                    self.runLoops = NSMutableArray(capacity: Int(THREAD_POOL_SIZE))

                    // Initialize an array to hold the number of connections being processed for each thread
                    self.runLoopsLoad = NSMutableArray(capacity: Int(THREAD_POOL_SIZE))

                    self.httpThreads = NSMutableArray(capacity: Int(THREAD_POOL_SIZE))

                    let server = WebPortalServer()
                    self.server = server
                    server.portal = self

                    server.setConnectionClass(NSClassFromString("WebPortalConnection"))

                    if self.usesSSL {
                        server.setType("_https._tcp.")
                    } else {
                        server.setType("_http._tcp.")
                    }

                    server.setTXTRecord(["ServerType": "OsiriX"])
                    server.setPort(UInt16(truncatingIfNeeded: self.portNumber))
                    server.setDocumentRoot(URL(fileURLWithPath: ("~/Sites" as NSString).expandingTildeInPath))

                    self.serverThread = Thread(target: self, selector: #selector(self.startServerThread), object: nil)

                    self.serverThread?.start()
                }
            } catch {
                NSLog("Exception: [WebPortal startAcceptingConnections] %@", webPortalCaught(error))
                // No thread will mark the portal: a later start may try again.
                startLock.lock()
                serverStarting = false
                startLock.unlock()
            }
        }
    }

    @objc(connectionsThread:)
    public func connectionsThread(_ obj: Any?) {
        autoreleasepool {
            Thread.current.name = "WebPortal connection thread"

            do {
                try HorosObjCException.perform {
                    webPortalSynchronized(self.runLoops) {
                        self.runLoops?.add(RunLoop.current)
                        self.runLoopsLoad?.add(NSNumber(value: UInt32(0)))
                        self.httpThreads?.add(Thread.current)
                    }

                    self.startLock.lock()
                    self.isAcceptingConnections = true
                    self.serverStarting = false
                    self.startLock.unlock()
                    // A timer that never fires keeps the run loop running. It
                    // used to target -ignore:, which nobody implements; it has
                    // nothing to call now.
                    RunLoop.current.add(Timer(fire: Date.distantFuture, interval: 0, repeats: false) { _ in }, forMode: .default)
                    while !Thread.current.isCancelled {
                        autoreleasepool {
                            _ = RunLoop.current.run(mode: .default, before: Date.distantFuture)
                        }
                    }
                    NSLog("[WebPortal connectionsThread:] finishing")
                }
            } catch {
                NSLog("Warning: [WebPortal connetionsThread] %@", webPortalCaught(error))
            }
        }
    }

    @objc(stopAcceptingConnections)
    public func stopAcceptingConnections() {
        if isAcceptingConnections {
            isAcceptingConnections = false
            //		@try
            //		{
            //			[serverThread cancel];
            //			[NSThread sleepForTimeInterval: 5];
            //
            //			for( NSThread *thread in httpThreads)
            //				[thread cancel];
            //
            //		} @catch (NSException* e) {
            //			NSLog(@"Exception: [WebPortal stopAcceptingConnections] %@", e);
            //		}

            notificationsTimer?.invalidate()
            notificationsTimer = nil

            temporaryUsersTimer?.invalidate()
            temporaryUsersTimer = nil

            NSLog("----- cannot stop web server -> you have to restart Horos")
        }
    }

    @objc(dataForPath:)
    public func data(forPath file: String!) -> Data! {
        let dirsToScanForFile = (self.dirsToScanForFiles as NSArray?)?.mutableCopy() as? NSMutableArray

        let DefaultLanguage = "English"
        var isDirectory: ObjCBool = false

        if let dirsToScanForFile = dirsToScanForFile {
            var i = 0
            while i < dirsToScanForFile.count {
                let path = (dirsToScanForFile.object(at: i) as! NSString).resolvingSymlinksAndAliases() as NSString?

                // path not on disk, ignore
                guard let path = path, FileManager.default.fileExists(atPath: path as String, isDirectory: &isDirectory), isDirectory.boolValue else {
                    dirsToScanForFile.removeObject(at: i)
                    continue
                }

                // path exists, look for a localized subdir first, otherwise in the dir itself

                for lang in preferredLocalizations?.adding(DefaultLanguage) ?? [] {
                    let langPath = path.appendingPathComponent(lang as! String) as NSString
                    let resolvedLanguagePath = langPath.resolvingSymlinksInPath as NSString
                    let rootPrefix = path.hasSuffix("/") ? path as String : path.appending("/")
                    if resolvedLanguagePath.hasPrefix(rootPrefix) && FileManager.default.fileExists(atPath: langPath as String, isDirectory: &isDirectory) && isDirectory.boolValue {
                        dirsToScanForFile.insert(langPath, at: i)
                        i += 1
                        break
                    }
                }
                i += 1
            }

            for dirToScanForFile in dirsToScanForFile {
                guard let path = HorosWebFilePath(dirToScanForFile as? String, file) else { continue }
                var data: Data? = nil
                do {
                    try HorosObjCException.perform {
                        data = NSData(contentsOfFile: path) as Data?
                    }
                } catch {
                    // do nothing, just try next
                }
                if let data = data { return data }
            }
        }

        //	NSLog( @"****** File not found: %@", file);

        return nil
    }

    @objc(stringForPath:)
    public func string(forPath file: String!) -> String! {
        guard let data = self.data(forPath: file) else {
            NSLog("Warning: [WebPortal stringForPath] is returning NULL for %@", file.map { $0 as NSString } ?? "(null)")
            return nil
        }

        guard let html = NSMutableString(data: data, encoding: String.Encoding.utf8.rawValue) else {
            return nil
        }

        var range: NSRange
        while true {
            range = html.range(of: "%INCLUDE:")
            if range.length == 0 { break }
            let rangeEnd = html.range(of: "%", options: .literal, range: NSRange(location: range.location + range.length, length: html.length - (range.location + range.length)))
            let replaceFilename = html.substring(with: NSRange(location: range.location + range.length, length: rangeEnd.location - (range.location + range.length)))
            let replaceFilepath = (file as NSString?)?.stringByComposingPath(with: replaceFilename as NSString)
            html.replaceCharacters(in: NSRange(location: range.location, length: rangeEnd.location + rangeEnd.length - range.location), with: self.string(forPath: replaceFilepath.map { $0 as String }) ?? "")
        }

        return html as String
    }

    /// This is the public URL (see OSIWebPreferences) - it can be different of
    /// the real address.
    @objc(URL)
    public func url() -> String! {
        var add = self.address as NSString?
        var `protocol`: String? = nil

        //The user can "force" to have a different public address, compared to the 'real' address (usefull for port forwarding)
        //Search if the protocol and port are specified

        if add?.hasPrefix("http://") ?? false {
            `protocol` = "http://"
            add = add?.substring(from: ("http://" as NSString).length) as NSString?
        }

        if add?.hasPrefix("https://") ?? false {
            `protocol` = "https://"
            add = add?.substring(from: ("https://" as NSString).length) as NSString?
        }

        if `protocol` == nil {
            if self.usesSSL {
                `protocol` = "https://"
            } else {
                `protocol` = "http://"
            }
        }

        if !(add?.n2Contains(":") ?? false) {
            var isDefaultPort = false
            if `protocol` == "http://" && self.portNumber == 80 { isDefaultPort = true }
            if `protocol` == "https://" && self.portNumber == 443 { isDefaultPort = true }

            if !isDefaultPort {
                add = add?.appendingFormat(":%d", Int32(truncatingIfNeeded: self.portNumber))
            }
        } else {
            if `protocol` == "http://" && (add?.hasSuffix(":80") ?? false) {
                add = add?.substring(with: NSRange(location: 0, length: add!.length - 3)) as NSString?
            }

            if `protocol` == "https://" && (add?.hasSuffix(":443") ?? false) {
                add = add?.substring(with: NSRange(location: 0, length: add!.length - 4)) as NSString?
            }
        }

        return String(format: "%@%@", `protocol`! as NSString, add ?? "(null)")
    }

    // MARK: Sessions

    @objc(sessionForId:)
    public func session(forId sid: String!) -> WebPortalSession! {
        sessionsArrayLock.lock()
        var session: WebPortalSession? = nil

        for isession in sessions {
            guard let isession = isession as? WebPortalSession else { continue }
            if let sid = sid, (isession.sid as NSString?)?.isEqual(to: sid) ?? false {
                session = isession
                break
            }
        }

        sessionsArrayLock.unlock()
        return session
    }

    @objc(sessionForUsername:token:)
    public func session(forUsername username: String!, token: String!) -> WebPortalSession! {
        return self.session(forUsername: username, token: token, doConsume: true) as? WebPortalSession
    }

    @objc(sessionForUsername:token:doConsume:)
    public func session(forUsername username: String!, token: String!, doConsume: Bool) -> Any! {
        sessionsArrayLock.lock()
        var session: WebPortalSession? = nil

        for isession in sessions {
            guard let isession = isession as? WebPortalSession else { continue }
            let sameName = username.map { ((isession.object(forKey: SessionUsernameKey) as? NSString)?.isEqual(to: $0)) ?? false } ?? false
            if doConsume {
                if sameName && isession.consumeToken(token) {
                    session = isession
                    break
                }
            } else {
                if sameName && isession.containsToken(token) {
                    session = isession
                    break
                }
            }
        }
        sessionsArrayLock.unlock()
        return session
    }

    @objc(addSession:)
    public func addSession(_ sid: String!) -> WebPortalSession! {
        let session: WebPortalSession = WebPortalSession(id: sid)

        sessionsArrayLock.lock()
        sessions.add(session)
        sessionsArrayLock.unlock()

        return session
    }

    /// -newSession. Swift returns it retained (+1), as the "new" family says;
    /// the former implementation returned it autoreleased.
    @objc(newSession)
    public func newSession() -> WebPortalSession! {
        sessionCreateLock.lock()

        // The sid is the session: whoever presents it is the person who logged in. It
        // used to be the MD5 of random(), whose generator this application seeds once
        // from time(NULL) - at most 31 bits, and replayable in order by anyone who
        // knows the second the application started.
        var sid: String
        repeat {
            sid = WebPortalIdentifier.unguessable()
        } while self.session(forId: sid) != nil

        let session = self.addSession(sid)

        sessionCreateLock.unlock()

        return session
    }

    // MARK: Notifications

    private func setNotificationsEnabledValue(_ flag: Bool) {
        if self.notificationsEnabled != flag {
            _notificationsEnabled = flag
            if !flag {
                notificationsTimer?.invalidate()
                notificationsTimer = nil
            } else if self.notificationsInterval > 0 {
                notificationsTimer = Timer.scheduledTimer(timeInterval: TimeInterval(self.notificationsInterval * 60), target: self, selector: #selector(notificationsTimerCallback(_:)), userInfo: nil, repeats: true)
            }
        }
    }

    private func setNotificationsIntervalValue(_ value: Int) {
        if self.notificationsInterval != value {
            _notificationsInterval = value
            if self.notificationsEnabled {
                notificationsTimer?.invalidate()
                notificationsTimer = nil

                if self.notificationsInterval > 0 {
                    notificationsTimer = Timer.scheduledTimer(timeInterval: TimeInterval(self.notificationsInterval * 60), target: self, selector: #selector(notificationsTimerCallback(_:)), userInfo: nil, repeats: true)
                }
            }
        }
    }

    @objc(notificationsTimerCallback:)
    public func notificationsTimerCallback(_ timer: Timer?) {
        if self.isAcceptingConnections {
            // -emailNotifications is in WebPortal+Email+Log.
            _ = self.perform(Selector(("emailNotifications")))
        }
    }
}
