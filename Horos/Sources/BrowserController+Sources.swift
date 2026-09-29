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

import AppKit

// BrowserController (Sources) is implemented in Swift since #722: a Swift
// extension of BrowserController, which stays Objective-C, with the selectors
// of the former category. The instance variables it used are read through
// BrowserController (SwiftIvars). The helper classes of the former file keep
// their Objective-C names and stay exported.
//
// Retain/release: the former file retained a removed source and autoreleased it
// one minute later ("performSelector:@selector(autorelease) ... afterDelay:60"),
// so that a drag or a cell still using it does not end with a freed object.
// keepForAMinute below does the same, on the main queue. An @synchronized is
// objcSynchronized, the same recursive lock on the same object; an @try is
// HorosObjCException.perform.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// Keeps `object` alive for a minute, then lets it go on the main queue.
///
/// The former pair retained the object and sent `-performSelector:
/// @selector(autorelease) withObject:nil afterDelay:60`, which schedules the
/// autorelease on the current thread's run loop. -volumeScanThread runs on a
/// thread of its own that never runs its run loop: the autorelease never came
/// and the source leaked (#779). The main queue always runs.
fileprivate func keepForAMinute(_ object: NSObject, delay: TimeInterval = 60) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        withExtendedLifetime(object) {}
    }
}

/// The "UID" a Bonjour TXT record carries, nil when it has none or cannot be
/// read. Both services Horos publishes carry it, so this is how a browser
/// recognises itself. The former code meant to pick the parser by the
/// service's type but compared its domain ("local.") with a type, so it always
/// used BonjourPublisher's, which raises on a record whose "AETitle" or "port"
/// is not UTF-8 or has no value: such a DICOM node was dropped (#779).
fileprivate func bonjourTXTRecordUID(_ data: Data?) -> String? {
    guard let data else { return nil }
    // The Objective-C method: a key without a value comes as NSNull, which the
    // Swift overlay's [String: Data] cannot hold.
    guard let record = (NetService.self as AnyObject).perform(NSSelectorFromString("dictionaryFromTXTRecordData:"), with: data)?
            .takeUnretainedValue() as? NSDictionary,
          let value = record.object(forKey: "UID") as? Data else { return nil }
    return String(data: value, encoding: .utf8)
}

/// `[object autorelease]`: released when the current pool drains.
@inline(__always)
fileprivate func autoreleaseLater(_ object: AnyObject?) {
    if let object {
        _ = Unmanaged.passUnretained(object).retain().autorelease()
    }
}

/// `[NSArray arrayWithObjects: a, b, …, nil]`: the list ends at the first nil.
fileprivate func objcArray(_ items: Any?...) -> NSArray {
    let array = NSMutableArray()
    for item in items {
        guard let item else { break }
        array.add(item)
    }
    return array
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[object intValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// `[object boolValue]` of an NSNumber or an NSString, NO for nil.
fileprivate func objcBoolValue(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
}

/// `[array valueForKey:key]` of an `id` that is an NSArray, or nil.
fileprivate func arrayValues(_ array: Any?, forKey key: String) -> NSArray? {
    return (array as? NSArray)?.value(forKey: key) as? NSArray
}

/// `[array containsObject:object]`, NO for a nil array or a nil object.
fileprivate func objcContains(_ array: NSArray?, _ object: Any?) -> Bool {
    guard let array, let object else { return false }
    return array.contains(object)
}

/// `[array indexOfObject:object]`, NSNotFound for a nil array or a nil object.
fileprivate func objcIndex(_ array: NSArray?, _ object: Any?) -> Int {
    guard let array, let object else { return NSNotFound }
    return array.index(of: object)
}

/// `[NSIndexSet indexSetWithIndex:index]`, with the index as the NSUInteger
/// Objective-C passed (-1 included).
fileprivate func objcIndexSet(_ index: Int) -> IndexSet {
    return NSIndexSet(index: index) as IndexSet
}

fileprivate enum MountType {
    static let generic = 0
    static let iPod = 1
}

public extension BrowserController {

    @objc(removePathFromSources:)
    func removePath(fromSources path: String!) {
        var mbs: MountedDatabaseNodeIdentifier? = nil
        for case let ibs as MountedDatabaseNodeIdentifier in (sources?.arrangedObjects as? NSArray) ?? [] {
            if (ibs.devicePath as NSString?)?.isEqual(to: path) == true {
                mbs = ibs
                break
            }
        }
        if let mbs {
            if sourceIdentifier(for: database)?.isEqual(to: mbs) == true {
                perform(#selector(setter: BrowserController.database), with: DicomDatabase.default(), afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
            }

            keepForAMinute(mbs)
            sources?.removeObject(mbs)
            mbs.willUnmount()
        }
    }

    @objc(awakeSources)
    func awakeSources() {
        let sourcesArrayController = sources!
        sourcesArrayController.sortDescriptors = [NSSortDescriptor(key: "self", ascending: true)]
        sourcesArrayController.automaticallyRearrangesObjects = true
        sourcesArrayController.addObject(DefaultLocalDatabaseNodeIdentifier.identifier()!)
        sourcesArrayController.selectsInsertedObjects = false

        let helper = BrowserSourcesHelper(browser: self)
        horos_sourcesHelper = helper
        horos_sourcesTableView?.dataSource = helper
        horos_sourcesTableView?.delegate = helper

        let cell = PrettyCell()
        horos_sourcesTableView?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Source"))?.dataCell = cell

        horos_sourcesTableView?.registerForDraggedTypes(BrowserController.databaseObjectXIDsPasteboardTypes().map { NSPasteboard.PasteboardType($0) })

        horos_sourcesTableView?.selectRowIndexes(objcIndexSet(0), byExtendingSelection: false)
    }

    @objc(deallocSources)
    func deallocSources() {
        (horos_sourcesHelper as? BrowserSourcesHelper)?.invalidate()
        horos_sourcesHelper = nil
    }

    @objc(sourcesCount)
    func sourcesCount() -> Int {
        return (sources?.arrangedObjects as? NSArray)?.count ?? 0
    }

    @objc(sourceIdentifierAtRow:)
    func sourceIdentifier(atRow row: Int32) -> DataNodeIdentifier! {
        let arranged = sources?.arrangedObjects as? NSArray
        return ((arranged?.count ?? 0) > Int(row)) ? arranged!.object(at: Int(row)) as? DataNodeIdentifier : nil
    }

    @objc(rowForSourceIdentifier:)
    func row(forSourceIdentifier source: DataNodeIdentifier!) -> Int32 {
        var i = 0
        while i < ((sources?.arrangedObjects as? NSArray)?.count ?? 0) {
            if ((sources?.arrangedObjects as? NSArray)?.object(at: i) as? DataNodeIdentifier)?.isEqual(to: source) == true {
                return Int32(truncatingIfNeeded: i)
            }
            i += 1
        }
        return -1
    }

    @objc(sourceIdentifierForDatabase:)
    func sourceIdentifier(for database: DicomDatabase!) -> DataNodeIdentifier! { // TODO: move this to -[DicomDatabase dataNodeIdentifier]
        if database === DicomDatabase.default() {
            return DefaultLocalDatabaseNodeIdentifier.identifier()
        }
        if database?.isLocal() == true {
            return LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: database.baseDirPath) as? DataNodeIdentifier
        } else {
            let remote = database as? RemoteDicomDatabase
            return RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: remote?.address, port: UInt(bitPattern: remote?.port ?? 0), description: nil, dictionary: nil) as? DataNodeIdentifier
        }
    }

    @objc(rowForDatabase:)
    func row(for database: DicomDatabase!) -> Int32 {
        return row(forSourceIdentifier: sourceIdentifier(for: database))
    }

    @objc(selectSourceForDatabase:)
    func selectSource(for database: DicomDatabase!) {
        let row = Int(self.row(for: database))
        if row >= 0 {
            horos_sourcesTableView?.selectRowIndexes(objcIndexSet(row), byExtendingSelection: false)
        } else {
            NSLog("Warning: couldn't find database in sources (%@)", objcFormatArgument(database))
        }
    }

    @objc(selectCurrentDatabaseSource)
    func selectCurrentDatabaseSource() {
        guard let database = self.database else {
            horos_sourcesTableView?.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
        }

        var i = Int(row(for: database))
        if i == -1 && database !== DicomDatabase.default() {
            let path = (database.baseDirPath as NSString?)?.deletingLastPathComponent

            // A database opened from a temporary place - a CD copied under the
            // user's temporary directory is the ordinary case - is not somewhere to
            // come back to. Remembering it leaves an entry that cannot be made
            // available again by putting the media back.
            if SourceLocation.isTemporaryLocation(path) == false {
                let description = ((path as NSString?)?.lastPathComponent as NSString?)?.appending(NSLocalizedString(" DB", comment: "DB = DataBase"))
                let source = objcDictionary(path, "Path", description, "Description")
                let defaults = UserDefaults.standard
                defaults.set((defaults.object(forKey: "localDatabasePaths") as? NSArray)?.adding(source), forKey: "localDatabasePaths")
            }

            i = Int(row(for: database))
        }
        if i != (horos_sourcesTableView?.selectedRow ?? 0) {
            horos_sourcesTableView?.selectRowIndexes(objcIndexSet(i), byExtendingSelection: false)
        }
    }

    @objc(setDatabaseOnMainThread:)
    func setDatabaseOnMainThread(_ db: DicomDatabase!) {
        perform(#selector(setter: BrowserController.database), with: db, afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
    }

    @objc(setDatabaseThread:)
    func setDatabaseThread(_ io: NSArray!) {
        autoreleasepool {
            let raised = objcTry {
                let type = io.object(at: 0) as? NSString
                var db: DicomDatabase? = nil

                if type?.isEqual(to: "Local") == true {
                    let path = io.object(at: 1) as? String
                    if FileManager.default.fileExists(atPath: path ?? "") == false {
                        var message = NSLocalizedString("The selected database's data was not found on your computer.", comment: "")
                        if (path as NSString?)?.hasPrefix("/Volumes/") == true {
                            message = message.appendingFormat(" %@", NSLocalizedString("If it is stored on an external drive? If so, please make sure the device in connected and on.", comment: ""))
                        }
                        NSException(name: .genericException, reason: message, userInfo: nil).raise()
                    }

                    let name = io.count > 2 ? io.object(at: 2) as? String : nil
                    db = DicomDatabase(atPath: path, name: name)
                }

                if type?.isEqual(to: "Remote") == true {
                    let address = io.object(at: 1) as? String
                    let port = Int(objcIntValue(io.object(at: 2)))
                    let name = io.count > 3 ? io.object(at: 3) as? String : nil
                    db = RemoteDicomDatabase.database(forLocation: address, port: UInt(bitPattern: port), name: name, update: true)
                }

                self.performSelector(onMainThread: #selector(setDatabaseOnMainThread(_:)), with: db, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])

                Thread.sleep(forTimeInterval: 1)
            }
            if let e = raised {
                self.performSelector(onMainThread: #selector(selectCurrentDatabaseSource), with: nil, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
                if (e.description as NSString).isEqual(to: "Cancelled.") == false {
                    _N2LogExceptionImpl(e, true, "-[BrowserController(Sources) setDatabaseThread:]")
                    self.performSelector(onMainThread: #selector(_complain(_:)), with: objcArray(NSNumber(value: Float(0.1)), NSLocalizedString("Error", comment: ""), e.description), waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
                }
            }
        }
    }

    @objc(_complain:)
    func _complain(_ why: NSArray!) { // if 1st obj in array is a number then execute this after the delay specified by that number, with the rest of the array
        if let delay = why.object(at: 0) as? NSNumber {
            perform(#selector(_complain(_:)), with: why.subarray(with: NSRange(location: 1, length: why.count - 1)), afterDelay: TimeInterval(delay.floatValue))
        } else {
            horos_beginSourcesAlertSheet(withTitle: why.object(at: 0) as? String, message: why.object(at: 1) as? String)
        }
    }

    @objc(initiateSetDatabaseAtPath:name:)
    @discardableResult
    func initiateSetDatabase(atPath path: String!, name: String!) -> Thread! {
        let io = objcArray("Local", path, name) as! NSMutableArray

        let thread = Thread(target: self, selector: #selector(setDatabaseThread(_:)), object: io)
        thread.name = NSLocalizedString("Loading database...", comment: "")
        thread.supportsCancel = true
        thread.status = NSLocalizedString("Reading data...", comment: "")

        _ = thread.startModal(for: self.window)
        thread.start()

        return thread
    }

    @objc(initiateSetRemoteDatabaseWithAddress:port:name:)
    @discardableResult
    func initiateSetRemoteDatabase(withAddress address: String!, port: Int, name: String!) -> Thread! {
        let io = objcArray("Remote", address, NSNumber(value: port), name) as! NSMutableArray

        let thread = Thread(target: self, selector: #selector(setDatabaseThread(_:)), object: io)
        thread.name = NSLocalizedString("Loading remote database...", comment: "")
        thread.supportsCancel = true
        _ = thread.startModal(for: self.window)
        thread.start()

        return thread
    }

    @objc(setDatabaseWithModalWindow:)
    func setDatabaseWithModalWindow(_ db: DicomDatabase!) {
        let thread = Thread.current
        thread.name = NSLocalizedString("Opening database...", comment: "")
        thread.status = NSLocalizedString("Opening database...", comment: "")
        thread.supportsCancel = true

        let tmc = thread.startModal(for: self.window)

        self.database = db

        tmc?.invalidate()
    }

    @objc(setDatabaseFromSourceIdentifier:)
    func setDatabase(fromSourceIdentifier dni: DataNodeIdentifier!) {
        if dni?.isEqual(to: sourceIdentifier(for: self.database)) == true {
            return
        }

        let raised = objcTry {
            let db = dni?.database()

            if let db {
                self.perform(#selector(setDatabaseWithModalWindow(_:)), with: db, afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
            } else if dni is LocalDatabaseNodeIdentifier {
                self.initiateSetDatabase(atPath: dni.location, name: dni.description)
            } else if dni is RemoteDatabaseNodeIdentifier {
                var host: NSString? = nil
                var port: Int = -1
                RemoteDatabaseNodeIdentifier.location(dni.location, port: dni.port, toAddress: &host, port: &port)

                if host != nil && port != -1 {
                    self.initiateSetRemoteDatabase(withAddress: host as String?, port: port, name: dni.description)
                }
            } else {
                UnavaliableDataNodeException(name: .genericException, reason: NSLocalizedString("This is a DICOM destination node: you cannot browse its content. You can only drag & drop studies on them.", comment: ""), userInfo: nil).raise()
            }
        }
        if let e = raised {
            guard e is UnavaliableDataNodeException else {
                e.raise() // not caught before either
                return
            }
            horos_beginSourcesAlertSheet(withTitle: NSLocalizedString("Sources", comment: ""), message: e.reason)
            selectCurrentDatabaseSource()
        }
    }

    @objc(redrawSources)
    func redrawSources() {
        if Thread.isMainThread {
            horos_sourcesTableView?.needsDisplay = true
        } else {
            performSelector(onMainThread: #selector(redrawSources), with: nil, waitUntilDone: false)
        }
    }

    @available(*, deprecated)
    @objc(findDBPath:dbFolder:)
    func findDBPath(_ path: String!, dbFolder DBFolderLocation: String!) -> Int32 { // __deprecated
        var i = Int(row(forSourceIdentifier: LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: path) as? DataNodeIdentifier))
        if i < 0 { i = Int(row(forSourceIdentifier: LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: DBFolderLocation) as? DataNodeIdentifier)) }
        return Int32(truncatingIfNeeded: i)
    }
}

/// `[NSDictionary dictionaryWithObjectsAndKeys: o1, k1, o2, k2, nil]`: the
/// list ends at the first nil object.
fileprivate func objcDictionary(_ pairs: Any?...) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    var index = 0
    while index + 1 < pairs.count {
        guard let object = pairs[index], let key = pairs[index + 1] as? NSCopying else { break }
        dictionary.setObject(object, forKey: key)
        index += 2
    }
    return dictionary
}

fileprivate let LocalBrowserSourcesContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
fileprivate let RemoteBrowserSourcesContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
fileprivate let DicomBrowserSourcesContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
fileprivate let SearchBonjourNodesContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
fileprivate let SearchDicomNodesContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

/// The data source and delegate of the Sources list, and the observer of what
/// fills it: the databases and nodes of the defaults, Bonjour and mounted
/// volumes.
@objc(BrowserSourcesHelper)
public final class BrowserSourcesHelper: NSObject, HorosBonjourBrowserDelegate, NetServiceDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Not retained, as before: the browser owns the helper, and -invalidate
    /// clears it.
    private weak var _browser: BrowserController?
    private let _volumeDiscovery: HorosVolumeDiscovery
    // Discovery is Network.framework and resolution is DNS-SD (#606); the
    // services handed to the rest of this file are still NSNetService.
    private var _nsbOsirix: HorosBonjourBrowser?
    private var _nsbDicom: HorosBonjourBrowser?
    private let _bonjourSources: NSMutableArray
    private let _bonjourServices: NSMutableArray
    private var _federatedCheckboxes: NSMutableDictionary?

    private var dontListenToSourcesChanges = false

    @objc(initWithBrowser:)
    public init(browser: BrowserController!) {
        _browser = browser
        _volumeDiscovery = HorosVolumeDiscovery()
        _bonjourSources = NSMutableArray()
        _bonjourServices = NSMutableArray()
        _federatedCheckboxes = NSMutableDictionary()
        super.init()

        let defaultsController = NSUserDefaultsController.shared
        defaultsController.addObserver(self, forValuesKey: "localDatabasePaths", options: .initial, context: LocalBrowserSourcesContext)
        defaultsController.addObserver(self, forValuesKey: "OSIRIXSERVERS", options: .initial, context: RemoteBrowserSourcesContext)
        defaultsController.addObserver(self, forValuesKey: "SERVERS", options: .initial, context: DicomBrowserSourcesContext)
        defaultsController.addObserver(self, forValuesKey: "searchDICOMBonjour", options: .initial, context: SearchDicomNodesContext)
        defaultsController.addObserver(self, forValuesKey: "DoNotSearchForBonjourServices", options: .initial, context: SearchBonjourNodesContext)
        let nsbOsirix = HorosBonjourBrowser()
        _nsbOsirix = nsbOsirix
        nsbOsirix.delegate = self
        nsbOsirix.searchForServices(ofType: "_osirixdb._tcp.", inDomain: "")
        let nsbDicom = HorosBonjourBrowser()
        _nsbDicom = nsbDicom
        nsbDicom.delegate = self
        nsbDicom.searchForServices(ofType: "_dicom._tcp.", inDomain: "")
        // mounted devices
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeNotification(_:)), name: NSWorkspace.didMountNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeNotification(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeNotification(_:)), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeWillUnmountNotification(_:)), name: NSWorkspace.willUnmountNotification, object: nil)

        // Is there a DICOMDIR at the same level of OsiriX ?
        let appFolder = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: (appFolder as NSString).appendingPathComponent("DICOMDIR")) {
            if let e = objcTry({
                self._browser?.sources?.addObject(MountedDatabaseNodeIdentifier.mountedDatabaseNodeIdentifier(withPath: appFolder, description: (appFolder as NSString).lastPathComponent, dictionary: nil, type: MountType.generic)!)
            }) {
                _N2LogExceptionImpl(e, true, "-[BrowserSourcesHelper initWithBrowser:]")
            }
        } else if FileManager.default.fileExists(atPath: (appFolder as NSString).appendingPathComponent("DICOMDIRPATH")) { // Created by OsiriX Lite App Launcher (see main.mm)
            let dicomdir = try? NSString(contentsOfFile: (appFolder as NSString).appendingPathComponent("DICOMDIRPATH"), encoding: String.Encoding.utf8.rawValue)

            if FileManager.default.fileExists(atPath: (dicomdir as String?) ?? "") {
                if let e = objcTry({
                    let folder = dicomdir!.deletingLastPathComponent
                    self._browser?.sources?.addObject(MountedDatabaseNodeIdentifier.mountedDatabaseNodeIdentifier(withPath: folder, description: (folder as NSString).lastPathComponent, dictionary: nil, type: MountType.generic)!)
                }) {
                    _N2LogExceptionImpl(e, true, "-[BrowserSourcesHelper initWithBrowser:]")
                }
            }
        } else {
            var mode = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "MOUNT"))
#if OSIRIX_LIGHT
            mode = 0 //display the source
#endif

            if mode != 2 {
                for case let path as String in (NSWorkspace.shared.mountedRemovableMedia() as NSArray?) ?? [] {
                    _analyzeVolume(atPath: path)
                }
            }
        }
    }

    @objc(invalidate)
    public func invalidate() {
        _volumeDiscovery.cancelAll()
        _browser = nil
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.removeObserver(self, name: NSWorkspace.didMountNotification, object: nil)
        workspaceCenter.removeObserver(self, name: NSWorkspace.didUnmountNotification, object: nil)
        workspaceCenter.removeObserver(self, name: NSWorkspace.willUnmountNotification, object: nil)
        workspaceCenter.removeObserver(self, name: NSWorkspace.didRenameVolumeNotification, object: nil)

        let defaultsController = NSUserDefaultsController.shared
        defaultsController.removeObserver(self, forValuesKey: "DoNotSearchForBonjourServices")
        defaultsController.removeObserver(self, forValuesKey: "searchDICOMBonjour")
        defaultsController.removeObserver(self, forValuesKey: "SERVERS")
        defaultsController.removeObserver(self, forValuesKey: "OSIRIXSERVERS")
        defaultsController.removeObserver(self, forValuesKey: "localDatabasePaths")

        _nsbDicom?.delegate = nil; _nsbDicom?.stop(); _nsbDicom = nil
        _nsbOsirix?.delegate = nil; _nsbOsirix?.stop(); _nsbOsirix = nil
        _federatedCheckboxes = nil

        _browser = nil
    }

    @objc(_observeValueForKeyPathOfObjectChangeContext:)
    func _observeValueForKeyPathOfObjectChangeContext(_ args: NSArray) {
        observeValue(forKeyPath: args.object(at: 0) as? String, of: args.object(at: 1), change: args.object(at: 2) as? [NSKeyValueChangeKey: Any], context: (args.object(at: 3) as? NSValue)?.pointerValue)
    }

    private static let isEqualToHostSemaphore = DispatchSemaphore(value: 10) // MAC_CONCURRENT_ISEQUALTOHOST

    @objc(host:isEqualToHost:)
    public class func host(_ h1: Host!, isEqualTo h2: Host!) -> Bool {
        let sid = isEqualToHostSemaphore

        if sid.wait(timeout: .distantFuture) == .success {
            var equal = false
            let raised = objcTry {
                if let a1 = h1?.address, let a2 = h2?.address, (a1 as NSString).isEqual(to: a2) {
                    equal = true
                    return
                }
                if let n1 = h1?.name, let n2 = h2?.name, (n1 as NSString).isEqual(to: n2) {
                    equal = true
                    return
                }
            }
            sid.signal()
            if let raised { raised.raise() }
            if equal { return true }
        }

        return false
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if !Thread.isMainThread {
            performSelector(onMainThread: #selector(_observeValueForKeyPathOfObjectChangeContext(_:)), with: objcArray(keyPath, object, change, NSValue(pointer: context)), waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
            return
        }

        dontListenToSourcesChanges = true

        let previousNode = _browser?.sourceIdentifier(for: _browser?.database)

        let raised = objcTry {
            // _browser is nil once the helper is invalidated: the messages to it
            // did nothing, and neither do the optional chains below.
            let sources = self._browser?.sources

            if context == LocalBrowserSourcesContext {
                let a = UserDefaults.standard.object(forKey: "localDatabasePaths") as? NSArray
                // remove old items
                for case let dni as DataNodeIdentifier in (sources?.content as? NSArray)?.copy() as? NSArray ?? [] {
                    if dni is LocalDatabaseNodeIdentifier && dni.entered { // is a local database and is flagged as "entered"
                        if !objcContains(arrayValues(a, forKey: "Path"), dni.location) { // is no longer in the entered list
                            dni.entered = false                                             // mark it as not entered
                            if !dni.detected {
                                keepForAMinute(dni)
                                sources?.removeObject(dni) // not entered, not detected.. remove it
                            }
                        }
                    }
                }
                // add new items
                for case let d as NSObject in a ?? [] {
                    let dpath = d.value(forKey: "Path") as? String
                    if (DicomDatabase.baseDirPath(forPath: dpath) as NSString?)?.isEqual(to: DicomDatabase.default().baseDirPath) == true { // is already listed as "default database"
                        continue
                    }
                    // [nil indexOfObject:] was 0 and [nil objectAtIndex:0] nil: nothing to update.
                    guard let sources, let content = sources.content as? NSArray else { continue }
                    let dni: DataNodeIdentifier
                    let i = objcIndex(arrayValues(content, forKey: "location"), dpath)
                    if i == NSNotFound {
                        dni = LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: dpath, description: d.value(forKey: "Description") as? String, dictionary: d as? [AnyHashable: Any]) as! DataNodeIdentifier
                        dni.entered = true
                        sources.addObject(dni)
                    } else {
                        dni = content.object(at: i) as! DataNodeIdentifier
                        dni.entered = true
                        dni.description = d.value(forKey: "Description") as? String
                        dni.dictionary = d as? [AnyHashable: Any]
                    }
                }
            }

            if context == RemoteBrowserSourcesContext {
                let currentHost = DefaultsOsiriX.currentHost()
                let a = UserDefaults.standard.object(forKey: "OSIRIXSERVERS") as? NSArray
                // remove old items
                for case let dni as DataNodeIdentifier in (sources?.content as? NSArray)?.copy() as? NSArray ?? [] {
                    if dni is RemoteDatabaseNodeIdentifier && dni.entered { // is a remote database and is flagged as "entered"
                        if !objcContains(arrayValues(a, forKey: "Address"), dni.location) { // is no longer in the entered list
                            dni.entered = false                                                // mark it as not entered
                            if !dni.detected {
                                keepForAMinute(dni)
                                sources?.removeObject(dni) // not entered, not detected.. remove it
                            }
                        }
                    }
                }
                // add new items
                //        NSOperationQueue* queue = [[[NSOperationQueue alloc] init] autorelease];
                for case let d as NSObject in a ?? [] {
                    Thread.performBlock(inBackground: {
                        // we're now in a background thread
                        let dadd = d.value(forKey: "Address") as? String
                        if BrowserSourcesHelper.host(Host.host(withAddressOrName: (dadd ?? "") as NSString), isEqualTo: currentHost) { // don't list self
                            return
                        }
                        OperationQueue.main.addOperation {
                            // we're now back in the main thread
                            guard let sources = self._browser?.sources, let content = sources.content as? NSArray else { return }
                            let dni: DataNodeIdentifier
                            let i = objcIndex(arrayValues(content, forKey: "location"), dadd)
                            if i == NSNotFound {
                                dni = RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: dadd, port: UInt(bitPattern: Int(objcIntValue(d.value(forKey: "Port")))), description: d.value(forKey: "Description") as? String, dictionary: d as? NSDictionary) as! DataNodeIdentifier
                                dni.entered = true
                                sources.addObject(dni)
                            } else {
                                dni = content.object(at: i) as! DataNodeIdentifier
                                dni.entered = true
                                dni.description = d.value(forKey: "Description") as? String
                                dni.dictionary = d as? [AnyHashable: Any]
                            }
                        }
                    })
                }
            }

            if context == DicomBrowserSourcesContext {
                let a = UserDefaults.standard.object(forKey: "SERVERS") as? NSArray
                let aa = NSMutableDictionary()
                for case let ai as NSObject in a ?? [] {
                    if objcBoolValue(ai.value(forKey: "Activated")) && objcBoolValue(ai.value(forKey: "Send")) {
                        let uniqueKey = NSString(format: "%@%d%@", objcFormatArgument(ai.value(forKey: "Address")), (ai.value(forKey: "Port") as? NSNumber)?.uint32Value ?? 0, objcFormatArgument(ai.value(forKey: "AETitle")))
                        aa.setObject(ai, forKey: uniqueKey)
                    }
                }
                // A node is found by its host, port and AE title: its location is
                // the server's address, never the key above, so every change of
                // the servers dropped the entered nodes and added them anew, and a
                // node Bonjour had merged into one of them stayed beside the new
                // copy (#805).
                let enteredServers = aa.allValues.compactMap { $0 as? [AnyHashable: Any] }
                // remove old items
                for case let dni as DataNodeIdentifier in (sources?.content as? NSArray)?.copy() as? NSArray ?? [] {
                    if dni is DicomNodeIdentifier && dni.entered { // is a dicom node and is flagged as "entered"
                        if !enteredServers.contains(where: { dni.isEqual(to: $0) }) {    // is no longer in the entered list
                            dni.entered = false                                          // mark it as not entered
                            if !dni.detected {
                                keepForAMinute(dni)
                                sources?.removeObject(dni) // not entered, not detected.. remove it
                            }
                        }
                    }
                }
                // add new items
                for case let aak as NSString in aa.keyEnumerator() {
                    guard let sources, let content = sources.content as? NSArray else { continue }
                    let dni: DataNodeIdentifier
                    let server = aa.object(forKey: aak) as? [AnyHashable: Any]
                    let i = content.indexOfObject(passingTest: { node, _, _ in
                        (node as? DicomNodeIdentifier)?.isEqual(to: server) == true
                    })
                    if i == NSNotFound {
                        let k = aa.object(forKey: aak) as? NSDictionary
                        dni = DicomNodeIdentifier.dicomNodeIdentifier(withLocation: k?.object(forKey: "Address") as? String, port: UInt(bitPattern: Int(objcIntValue(k?.object(forKey: "Port")))), aetitle: k?.object(forKey: "AETitle") as? String, description: k?.object(forKey: "Description") as? String, dictionary: aa.object(forKey: aak) as? NSDictionary) as! DataNodeIdentifier
                        dni.entered = true
                        sources.addObject(dni)
                    } else {
                        dni = content.object(at: i) as! DataNodeIdentifier
                        dni.entered = true
                        dni.dictionary = aa.object(forKey: aak) as? [AnyHashable: Any]
                        dni.description = (dni.dictionary as NSDictionary?)?.object(forKey: "Description") as? String
                    }
                }
            }

            self.updateBonjourLists(context: context)
        }
        if let raised {
            _N2LogExceptionImpl(raised, true, "-[BrowserSourcesHelper observeValueForKeyPath:ofObject:change:context:]")
        }

        dontListenToSourcesChanges = false

        if let browser = _browser {
            if browser.row(forSourceIdentifier: previousNode) == -1 {
                browser.perform(#selector(setter: BrowserController.database), with: DicomDatabase.default(), afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
            } else {
                browser.selectSource(for: browser.database)
            }
        }
    }

    /// The SearchBonjourNodesContext and SearchDicomNodesContext parts of
    /// -observeValueForKeyPath:ofObject:change:context:.
    private func updateBonjourLists(context: UnsafeMutableRawPointer?) {
        if context == SearchBonjourNodesContext {
            objcSynchronized(_bonjourSources) {
                if UserDefaults.standard.bool(forKey: "DoNotSearchForBonjourServices") { // add remote databases detected with bonjour
                    // remove remote databases detected with bonjour
                    for case let dni as DataNodeIdentifier in _bonjourSources {
                        if dni is RemoteDatabaseNodeIdentifier && dni.detected {
                            dni.detected = false
                            if !dni.entered && objcContains(_browser?.sources?.content as? NSArray, dni) {
                                keepForAMinute(dni)
                                _browser?.sources?.removeObject(dni) // not entered, not detected.. remove it
                            }
                        }
                    }
                } else {
                    // add remote databases detected with bonjour
                    for case let dni as DataNodeIdentifier in _bonjourSources {
                        if dni is RemoteDatabaseNodeIdentifier && !dni.detected && dni.location != nil {
                            dni.detected = true
                            if !objcContains(_browser?.sources?.content as? NSArray, dni) {
                                _browser?.sources?.addObject(dni)
                            }
                        }
                    }
                }
            }
        }

        if context == SearchDicomNodesContext {
            objcSynchronized(_bonjourSources) {
                if !UserDefaults.standard.bool(forKey: "searchDICOMBonjour") {
                    // remove dicom nodes detected with bonjour
                    for case let dni as DataNodeIdentifier in _bonjourSources {
                        if dni is DicomNodeIdentifier && dni.detected {
                            dni.detected = false
                            if !dni.entered && objcContains(_browser?.sources?.content as? NSArray, dni) {
                                keepForAMinute(dni)
                                _browser?.sources?.removeObject(dni) // not entered, not detected.. remove it
                            }
                        }
                    }
                } else {
                    // add dicom nodes detected with bonjour
                    for case let dni as DataNodeIdentifier in _bonjourSources {
                        if dni is DicomNodeIdentifier && !dni.detected && dni.location != nil {
                            dni.detected = true
                            if !objcContains(_browser?.sources?.content as? NSArray, dni) {
                                _browser?.sources?.addObject(dni)
                            }
                        }
                    }
                }
            }
        }
    }

    @objc(netServiceDidResolveAddress:)
    public func netServiceDidResolveAddress(_ service: NetService) {
        let outer = objcTry {
            service.stop() //Technical Q&A QA1297

            var source0: DataNodeIdentifier? = nil
            objcSynchronized(self._bonjourSources) {
                if self._bonjourServices.index(of: service) != NSNotFound {
                    source0 = self._bonjourSources.object(at: self._bonjourServices.index(of: service)) as? DataNodeIdentifier
                } else {
                    NSLog("***** unknown didResolve Service")
                }
            }
            guard var source = source0 else {
                return
            }

            var itIsMe = false
            if let e = objcTry({
                // Our database (_osirixdb._tcp.) and our DICOM node (_dicom._tcp.)
                // both publish our UID in their TXT record: it is read the same
                // way for both (#779).
                if let uid = bonjourTXTRecordUID(service.txtRecordData()), (uid as NSString).isEqual(to: AppController.uid()) {
                    objcSynchronized(self._bonjourSources) {
                        NSLog("Remove Service: %@", service)
                        if self._bonjourServices.index(of: service) != NSNotFound {
                            self._bonjourSources.removeObject(at: self._bonjourServices.index(of: service))
                            self._bonjourServices.remove(service)
                        } else {
                            NSLog("***** unknown didResolve Service")
                        }
                    }
                    itIsMe = true // it's me
                }
            }) {
                _N2LogExceptionImpl(e, false, "-[BrowserSourcesHelper netServiceDidResolveAddress:]")
                return
            }
            if itIsMe {
                return
            }

            if let e = objcTry({
                // we're now back in the main thread
                let addresses = NSMutableArray()
                // Prefer IP4
                for address in service.addresses ?? [] {
                    address.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        guard let base = bytes.baseAddress else { return }
                        let sockAddr = base.assumingMemoryBound(to: sockaddr.self)
                        if sockAddr.pointee.sa_family == sa_family_t(AF_INET) {
                            let sockAddrIn = base.assumingMemoryBound(to: sockaddr_in.self)
                            if let str = inet_ntoa(sockAddrIn.pointee.sin_addr) {
                                let host = NSString(utf8String: str)
                                let port = Int(UInt16(bigEndian: sockAddrIn.pointee.sin_port))
                                addresses.add(objcArray(host, NSNumber(value: port)))
                            }
                        }
                    }
                }
                // And search IPv6
                for address in service.addresses ?? [] {
                    address.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        guard let base = bytes.baseAddress else { return }
                        let sockAddr = base.assumingMemoryBound(to: sockaddr.self)
                        if sockAddr.pointee.sa_family == sa_family_t(AF_INET6) {
                            let sockAddrIn6 = base.assumingMemoryBound(to: sockaddr_in6.self)
                            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                            var sin6Addr = sockAddrIn6.pointee.sin6_addr
                            if inet_ntop(AF_INET6, &sin6Addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                                let host = NSString(utf8String: buffer)
                                let port = Int(UInt16(bigEndian: sockAddrIn6.pointee.sin6_port))
                                addresses.add(objcArray(host, NSNumber(value: port)))
                            }
                        }
                    }
                }

                for case let address as NSArray in addresses {
                    if source.location == nil && address.count >= 2 {
                        if source is RemoteDatabaseNodeIdentifier || source is DicomNodeIdentifier {
                            source.location = address.object(at: 0) as? String
                            source.port = UInt(bitPattern: ((address.object(at: 1) as AnyObject).integerValue ?? 0))
                        }

                        if source is DicomNodeIdentifier {
                            source.aetitle = source.description
                        }
                    }
                }

                let content = self._browser?.sources?.content as? NSArray
                // [nil indexOfObject:] was 0, not NSNotFound.
                let i = content != nil ? objcIndex(content, source) : 0
                if i != NSNotFound { // Already known
                    objcSynchronized(self._bonjourSources) {
                        if self._bonjourServices.index(of: service) != NSNotFound {
                            guard let known = content?.object(at: i) as? DataNodeIdentifier else {
                                // [nil objectAtIndex:] was nil, which -replaceObjectAtIndex:withObject: refused.
                                NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM replaceObjectAtIndex:withObject:]: object cannot be nil", userInfo: nil).raise()
                                return
                            }
                            source = known
                            self._bonjourSources.replaceObject(at: self._bonjourServices.index(of: service), with: source)
                        } else {
                            NSLog("***** unknown didResolve Service")
                        }
                    }
                }

                // A DICOM node entered in the preferences that Bonjour announces
                // too is one node: it keeps the server the user entered (its
                // transfer syntax, its description) and is flagged detected
                // (#805).
                if source is RemoteDatabaseNodeIdentifier {
                    source.dictionary = BonjourPublisher.dictionaryFromXTRecordData(service.txtRecordData()) as? [AnyHashable: Any]
                } else if !source.entered {
                    source.dictionary = DCMNetServiceDelegate.dicomNodeInfo(fromTXTRecord: service.txtRecordData()) as? [AnyHashable: Any]
                }

                if source.location != nil {
                    if (source is RemoteDatabaseNodeIdentifier && !UserDefaults.standard.bool(forKey: "DoNotSearchForBonjourServices")) ||
                        (source is DicomNodeIdentifier && UserDefaults.standard.bool(forKey: "searchDICOMBonjour")) {

                        source.detected = true
                        if !objcContains(self._browser?.sources?.content as? NSArray, source) {
                            self._browser?.sources?.addObject(source)
                        }
                    }
                }
            }) {
                _N2LogExceptionImpl(e, false, "-[BrowserSourcesHelper netServiceDidResolveAddress:]")
            }
        }
        if let outer {
            _N2LogExceptionImpl(outer, false, "-[BrowserSourcesHelper netServiceDidResolveAddress:]")
        }
    }

    @objc(netService:didNotResolve:)
    public func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        service.stop()

        objcSynchronized(_bonjourSources) {
            var bsk: NetService? = nil
            for case let ibsk as NetService in _bonjourServices {
                if ibsk.isEqual(service) {
                    bsk = ibsk
                    break
                }
            }

            guard let bsk else {
                return
            }

            NSLog("Remove Service: %@", bsk)
            _bonjourSources.removeObject(at: _bonjourServices.index(of: bsk))
            _bonjourServices.remove(bsk)
        }
    }

    @objc(horosBonjourBrowser:didFindService:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didFind service: BonjourService) {

        let source: DataNodeIdentifier
        if nsb === _nsbOsirix {
            source = RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: nil, port: 0, description: service.name, dictionary: nil) as! DataNodeIdentifier
        } else {
            source = DicomNodeIdentifier.dicomNodeIdentifier(withLocation: nil, port: 0, aetitle: "", description: service.name, dictionary: nil) as! DataNodeIdentifier
        }

        objcSynchronized(_bonjourSources) {
            _bonjourServices.add(service)
            _bonjourSources.add(source)
        }
        NSLog("Find Service: %@", service)

        // resolve the address and port for this NSNetService
        service.delegate = self
        service.resolve(withTimeout: 30)
    }

    // The same peer on another interface, or with a new TXT record: refresh what
    // is already there. Removing and re-adding the row would drop its selection and
    // its liveness state for a peer that never went away (#606).
    @objc(horosBonjourBrowser:didUpdateService:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didUpdate service: BonjourService) {
        var known = false
        objcSynchronized(_bonjourSources) {
            known = _bonjourServices.index(of: service) != NSNotFound
        }
        if !known {
            horosBonjourBrowser(nsb, didFind: service)
            return
        }
        NSLog("Update Service: %@", service)
        service.delegate = self
        service.resolve(withTimeout: 30)
    }

    @objc(horosBonjourBrowser:didNotSearch:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didNotSearch errorDict: [String: Any]) {
        NSLog("Bonjour search failed: %@", errorDict as NSDictionary)
    }

    @objc(horosBonjourBrowser:didRemoveService:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didRemove service: BonjourService) {
        NSLog("Bonjour service gone: %@", service)

        objcSynchronized(_bonjourSources) {
            var bsk: NetService? = nil
            for case let ibsk as NetService in _bonjourServices {
                if ibsk.isEqual(service) {
                    bsk = ibsk
                    break
                }
            }

            guard let bsk else {
                return
            }

            let dni = _bonjourSources.object(at: _bonjourServices.index(of: bsk)) as! DataNodeIdentifier

            if (dni is RemoteDatabaseNodeIdentifier && !UserDefaults.standard.bool(forKey: "DoNotSearchForBonjourServices")) ||
                (dni is DicomNodeIdentifier && UserDefaults.standard.bool(forKey: "searchDICOMBonjour")) {

                dni.detected = false
                if !dni.entered && objcContains(_browser?.sources?.content as? NSArray, dni) {
                    keepForAMinute(dni)
                    _browser?.sources?.removeObject(dni) // not entered, not detected.. remove it
                }
            }

            // if the disappearing node is active, select the default DB
            if let browser = _browser, browser.sourceIdentifier(for: browser.database)?.isEqual(to: dni) == true {
                browser.perform(#selector(setter: BrowserController.database), with: DicomDatabase.default(), afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
            }
            NSLog("Remove Service: %@", bsk)
            _bonjourSources.removeObject(at: _bonjourServices.index(of: bsk))
            _bonjourServices.remove(bsk)
        }
    }

    @objc(_analyzeVolumeAtPath:)
    public func _analyzeVolume(atPath path: String!) {
        guard let path, !path.isEmpty else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { self._analyzeVolume(atPath: path) }
            return
        }
        if _browser == nil { return }
        _ = _volumeDiscovery.discoverPath(path, worker: {
            var discoveryError: NSError? = nil
            let output = HorosRunBoundedTask("/usr/sbin/diskutil", ["info", "-plist", path], 5.0, &discoveryError)
            let plist: Any? = output.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            let result = plist as? NSDictionary
            if let discoveryError { NSLog("Volume metadata discovery failed: %@", discoveryError.localizedDescription) }
            let optical = result?.object(forKey: "OpticalMediaType"), media = result?.object(forKey: "MediaType")
            if let optical = optical as? NSString, optical.length > 0 { return NSNumber(value: Int32(MountType.generic)) }
            if let media = media as? NSString, media.isEqual(to: "iPod") { return NSNumber(value: Int32(MountType.iPod)) }
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("DICOMDIR")) ||
                FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(OsirixDataDirName)) {
                return NSNumber(value: Int32(MountType.generic))
            }
            return nil
        }, completion: { value in
            let type = value as? NSNumber
            guard let browser = self._browser, let type else { return }
#if !OSIRIX_LIGHT
            if UserDefaults.standard.integer(forKey: "MOUNT") == 2 { return }
#endif
            for case let source as DataNodeIdentifier in (browser.sources?.arrangedObjects as? NSArray) ?? [] {
                if source is LocalDatabaseNodeIdentifier,
                   let location = source.location as NSString?,
                   location.isEqual(to: path) || location.hasPrefix((path as NSString).appending("/")) {
                    return
                }
            }
            if let exception = objcTry({
                browser.sources?.addObject(MountedDatabaseNodeIdentifier.mountedDatabaseNodeIdentifier(withPath: path, description: (path as NSString).lastPathComponent, dictionary: nil, type: type.intValue)!)
            }) { _N2LogExceptionImpl(exception, true, "-[BrowserSourcesHelper _analyzeVolumeAtPath:]_block_invoke_2") }
        })
    }

    @objc(_observeVolumeNotification:)
    func _observeVolumeNotification(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self._observeVolumeNotification(notification) }
            return
        }
        let userInfo = notification.userInfo as NSDictionary?
        let name = notification.name.rawValue as NSString
        let changedPath = (userInfo?.object(forKey: NSWorkspace.volumeURLUserInfoKey) as? NSURL)?.path
        if name.isEqual(to: NSWorkspace.didUnmountNotification.rawValue) {
            _volumeDiscovery.cancelPath(changedPath)
        }
        if name.isEqual(to: NSWorkspace.didRenameVolumeNotification.rawValue) {
            _volumeDiscovery.cancelPath((userInfo?.object(forKey: NSWorkspace.oldVolumeURLUserInfoKey) as? NSURL)?.path)
        }
        var mode = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "MOUNT"))
#if OSIRIX_LIGHT
        mode = 0 //display the source
#endif

        if mode == 2 {
            return
        }

        var path = (userInfo?.object(forKey: NSWorkspace.volumeURLUserInfoKey) as? NSURL)?.path

        _browser?.redrawSources()

        if name.isEqual(to: NSWorkspace.didMountNotification.rawValue) {
            _analyzeVolume(atPath: (userInfo?.object(forKey: NSWorkspace.volumeURLUserInfoKey) as? NSURL)?.path)
        }

        if name.isEqual(to: NSWorkspace.didRenameVolumeNotification.rawValue) {
            path = (userInfo?.object(forKey: NSWorkspace.oldVolumeURLUserInfoKey) as? NSURL)?.path
        }

        if name.isEqual(to: NSWorkspace.didUnmountNotification.rawValue) || name.isEqual(to: NSWorkspace.didRenameVolumeNotification.rawValue) {
            var mbs: MountedDatabaseNodeIdentifier? = nil
            for case let ibs as MountedDatabaseNodeIdentifier in (_browser?.sources?.arrangedObjects as? NSArray) ?? [] {
                if (ibs.devicePath as NSString?)?.isEqual(to: path) == true {
                    mbs = ibs
                    break
                }
            }
            if let mbs, let browser = _browser {
                if browser.sourceIdentifier(for: browser.database)?.isEqual(to: mbs) == true {
                    browser.perform(#selector(setter: BrowserController.database), with: DicomDatabase.default(), afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
                }
                keepForAMinute(mbs)
                browser.sources?.removeObject(mbs)
                mbs.willUnmount()
            }
        }

        if name.isEqual(to: NSWorkspace.didRenameVolumeNotification.rawValue) { // Re-probe even if discovery at the old path was still pending
            _analyzeVolume(atPath: (userInfo?.object(forKey: NSWorkspace.volumeURLUserInfoKey) as? NSURL)?.path)
        }
    }

    @objc(_observeVolumeWillUnmountNotification:)
    func _observeVolumeWillUnmountNotification(_ notification: Notification) {
        let path = (notification.userInfo as NSDictionary?)?.object(forKey: "NSDevicePath") as? String

        DCMPix.purgeCachedDictionaries()

        var mbs: MountedDatabaseNodeIdentifier? = nil
        for case let ibs as MountedDatabaseNodeIdentifier in (_browser?.sources?.arrangedObjects as? NSArray) ?? [] {
            if (ibs.devicePath as NSString?)?.isEqual(to: path) == true {
                mbs = ibs
                break
            }
        }

        mbs?.willUnmount()

        if let mbs, let browser = _browser, browser.sourceIdentifier(for: browser.database)?.isEqual(to: mbs) == true {
            var db = DicomDatabase.activeLocal()
            if db === browser.database {
                db = DicomDatabase.default()
            }

            browser.perform(#selector(setter: BrowserController.database), with: db, afterDelay: 0.01) //This will guarantee that this will not happen in middle of a drag & drop, for example
        }
    }

    @objc(tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:)
    public func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn tc: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        let bs = _browser?.sourceIdentifier(atRow: Int32(truncatingIfNeeded: row))
        if let tip = bs?.toolTip() {
            return tip
        }
        return ""
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    public func tableView(_ aTableView: NSTableView, willDisplayCell cellObject: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let cell = cellObject as? PrettyCell else { return }
        cell.image = nil
        cell.font = NSFont.systemFont(ofSize: CGFloat(_browser?.fontSize("dbSourceFont") ?? 0))
        cell.textColor = nil
        cell.rightSubviews?.removeAllObjects()
        let bs = _browser?.sourceIdentifier(atRow: Int32(truncatingIfNeeded: row))
        cell.title = bs?.description ?? ""
        bs?.willDisplay(cell)
        if let bs, bs is LocalDatabaseNodeIdentifier && (bs is MountedDatabaseNodeIdentifier) == false {
            let key = bs.location ?? ""
            var box = _federatedCheckboxes?.object(forKey: key) as? NSButton
            if box == nil {
                let newBox = NSButton(frame: NSMakeRect(0, 0, 18, 18))
                newBox.setButtonType(.switch)
                newBox.title = ""
                newBox.toolTip = NSLocalizedString("Include in federated search (UI and web portal)", comment: "")
                newBox.target = self
                newBox.action = #selector(toggleFederatedSearch(_:))
                _federatedCheckboxes?.setObject(newBox, forKey: key as NSString)
                box = newBox
            }
            box!.tag = row
            let included = FederatedSearch.isPath(bs.location,
                                                  includedIn: UserDefaults.standard.object(forKey: "localDatabasePaths") as? [[String: Any]],
                                                  defaultPath: DicomDatabase.default().baseDirPath,
                                                  defaultIncluded: FederatedSearch.isDefaultDatabaseIncluded)
            box!.state = included ? .on : .off
            cell.rightSubviews?.add(box!)
        }
    }

    @objc(toggleFederatedSearch:)
    func toggleFederatedSearch(_ sender: NSButton!) {
        let bs = _browser?.sourceIdentifier(atRow: Int32(truncatingIfNeeded: sender.tag))
        if (bs is LocalDatabaseNodeIdentifier) == false {
            return
        }
        let included = sender.state == .on
        if bs is DefaultLocalDatabaseNodeIdentifier {
            FederatedSearch.isDefaultDatabaseIncluded = included
        } else {
            let updated = FederatedSearch.updatingLocalDatabasePaths(UserDefaults.standard.object(forKey: "localDatabasePaths") as? [[String: Any]],
                                                                    path: bs!.location,
                                                                    included: included)
            UserDefaults.standard.set(updated, forKey: "localDatabasePaths")
        }
        if let browser = _browser, (browser.searchString?.count ?? 0) > 0 {
            browser.searchString = browser.searchString
        }
    }

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if operation != .on {
            return []
        }
        guard let browser = _browser else { return [] }

        let selectedDatabaseIndex = Int(browser.row(for: browser.database))
        if row == selectedDatabaseIndex {
            return []
        }

        if row >= browser.sourcesCount() && browser.database !== DicomDatabase.default() {
            tableView.setDropRow(Int(browser.row(for: DicomDatabase.default())), dropOperation: .on)
            return .copy
        }

        if row < browser.sourcesCount() {
            if browser.sourceIdentifier(atRow: Int32(truncatingIfNeeded: row))?.isReadOnly() == true {
                return []
            }
            tableView.setDropRow(row, dropOperation: .on)
            return .copy
        }

        return []
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let browser = _browser else { return false }
        let pb = info.draggingPasteboard
        let xids = BrowserController.databaseObjectXIDs(on: pb) as NSArray? // every dragged row (#605)
        let items = NSMutableArray()
        for case let xid as String in xids ?? [] {
            // -addObject: raises on nil, as it did.
            items.perform(#selector(NSMutableArray.add(_:)), with: browser.database?.object(withID: NSManagedObject.uid(forXid: xid)))
        }

        let dicomImages = DicomImage.dicomImages(in: items as? [Any])

        return browser.initiateCopyImages(dicomImages as? [Any], toSource: browser.sourceIdentifier(atRow: Int32(truncatingIfNeeded: row)))
    }

    @objc(tableViewSelectionDidChange:)
    public func tableViewSelectionDidChange(_ notification: Notification) {
        if dontListenToSourcesChanges == false {
            let row = (notification.object as? NSTableView)?.selectedRow ?? 0
            let bs = _browser?.sourceIdentifier(atRow: Int32(truncatingIfNeeded: row))
            _browser?.setDatabase(fromSourceIdentifier: bs)
        }
    }
}

/// The browser's own database, first in the Sources list.
@objc(DefaultLocalDatabaseNodeIdentifier)
public final class DefaultLocalDatabaseNodeIdentifier: LocalDatabaseNodeIdentifier {

    private static var _identifier: DefaultLocalDatabaseNodeIdentifier? = nil

    @objc(identifier)
    public class func identifier() -> DefaultLocalDatabaseNodeIdentifier! {
        if _identifier == nil {
            _identifier = self.localDatabaseNodeIdentifier(withPath: DicomDatabase.default().baseDirPath) as? DefaultLocalDatabaseNodeIdentifier
        }
        return _identifier
    }

    public override func willDisplay(_ cell: PrettyCell!) {
        cell.font = NSFont.boldSystemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("dbSourceFont") ?? 0))
        cell.image = NSImage(named: "Horos.icns")
    }

    public override var description: String! {
        get {
            for case let d as NSObject in (UserDefaults.standard.object(forKey: "localDatabasePaths") as? NSArray) ?? [] {
                if let entryPath = d.value(forKey: "Path") as? NSString, let folder = (self.location as NSString?)?.deletingLastPathComponent, entryPath.isEqual(to: folder) {
                    return d.value(forKey: "Description") as? String
                }
            }

            return ((((self.location as NSString?)?.deletingLastPathComponent as NSString?)?.lastPathComponent) as NSString?)?.appending(NSLocalizedString(" DB", comment: "DB = DataBase"))
        }
        set {
            super.description = newValue
        }
    }

    @objc(sortValue)
    public func sortValue() -> CGFloat {
        return CGFloat.leastNormalMagnitude // CGFLOAT_MIN
    }
}

/// A mounted volume: a disc or a device whose DICOM files are scanned into a
/// database of their own, or an Horos Data folder read in place.
@objc(MountedDatabaseNodeIdentifier)
public final class MountedDatabaseNodeIdentifier: LocalDatabaseNodeIdentifier {
    // Every stored property is an optional or a scalar, valid as the zeroed
    // memory +alloc hands over.
    private var _database: DicomDatabase?
    /// Not retained, as before: the scan thread sets it while it runs.
    private weak var _scanThread: Thread?
    private var _unmountButton: NSButton?

    /// The former properties were atomic. Both are set once, by the factory
    /// below, before the scan thread starts: they are plain properties now.
    @objc public var devicePath: String?
    @objc public var mountType: Int = 0

    // -initWithLocation:port:aetitle:description:dictionary: sends -init, as the
    // factories of LocalDatabaseNodeIdentifier use it: the button is made there.
    public override init() {
        super.init()
        let unmountButton = NSButton(frame: NSMakeRect(0, 0, 14, 14))
        unmountButton.image = NSImage(named: "Eject_gray")
        unmountButton.image?.size = NSMakeSize(10, 11)
        unmountButton.alternateImage = NSImage(named: "Eject_lightgray")
        unmountButton.alternateImage?.size = NSMakeSize(10, 11)
        unmountButton.imagePosition = .imageOnly
        unmountButton.bezelStyle = NSButton.BezelStyle(rawValue: 0)!
        unmountButton.setButtonType(.momentaryLight)
        unmountButton.isBordered = false
        let cell = unmountButton.cell as? NSButtonCell
        cell?.gradientType = .none
        cell?.highlightsBy = .contentsCellMask

        unmountButton.target = self
        unmountButton.action = #selector(_eject(_:))
        _unmountButton = unmountButton
    }

    // -initWithLocation:port:aetitle:description:dictionary: is unavailable to Swift
    // (DataNodeIdentifier.h), so no trapping stub is generated for it here: the
    // factory's call reaches the Objective-C implementation, which sends -init.

    @objc(_eject:)
    func _eject(_ sender: Any?) {
        NSWorkspace.shared.performSelector(inBackground: NSSelectorFromString("unmountAndEjectDeviceAtPath:"), with: self.devicePath)
    }

    @objc(initiateVolumeScan)
    func initiateVolumeScan() {
        let database = DicomDatabase(atPath: self.location)
        _database = database
        database?.isReadOnly = true
        database?.sourcePath = self.devicePath
        database?.name = self.description
        database?.hasPotentiallySlowDataAccess = true
        for case let obj as NSManagedObject in (database?.albums() as NSArray?) ?? [] {
            database?.managedObjectContext.delete(obj)
        }

        try? database?.managedObjectContext.save()

        self.performSelector(inBackground: #selector(volumeScanThread), with: nil)
    }

    @objc(volumeScanThread)
    func volumeScanThread() {
        autoreleasepool {
            var raised: NSException? = nil
            raised = objcTry {
                NSLog("--- volumeScanThread: start")

                let thread = Thread.current
                objcSynchronized(self) {
                    self._scanThread = thread
                }

                let database = self._database?.independentDatabase() as? DicomDatabase

                thread.name = NSLocalizedString("Scanning disc...", comment: "")
                ThreadsManager.default().addThreadAndStart(thread)

                let autoselect = database?.scan(atPath: self.devicePath) ?? false

                if ((database?.objects(forEntity: database?.imageEntity()) as NSArray?)?.count ?? 0) == 0 {
                    keepForAMinute(self)
                    BrowserController.currentBrowser()?.sources?.removeObject(self)
                    self.willUnmount()

                    return
                }

                self.detected = true

                var selectSource = false

                var mode = UserDefaults.standard.integer(forKey: "MOUNT")
//        BOOL autoSelectSourceCDDVD = [[NSUserDefaults standardUserDefaults] boolForKey:@"autoSelectSourceCDDVD"];

#if OSIRIX_LIGHT
                mode = 0 //display the source
#endif

                if mode == -1 || (NSApp.currentEvent?.modifierFlags.contains(.command) ?? false) { //The user clicked on the dialog box
                    if autoselect {
                        selectSource = true
                    }
                } else if UserDefaults.standard.bool(forKey: "autoSelectSourceCDDVD") && FileManager.default.fileExists(atPath: self.devicePath ?? "") {
                    selectSource = true
                }

                if selectSource {
                    BrowserController.currentBrowser()?.performSelector(onMainThread: #selector(BrowserController.setDatabase(fromSourceIdentifier:)), with: self, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
                } else {
                    BrowserController.currentBrowser()?.redrawSources()
                }
            }
            if let raised {
                _N2LogExceptionImpl(raised, true, "-[MountedDatabaseNodeIdentifier volumeScanThread]")
            }
            objcSynchronized(self) {
                self._scanThread = nil
            }
        }

        NSLog("--- volumeScanThread: end")
    }

    public override func database() -> DicomDatabase! {
        if !self.detected {
            UnavaliableDataNodeException(name: .genericException, reason: NSLocalizedString("This disk is being processed. It is currently not available.", comment: ""), userInfo: nil).raise()
        }
        return _database
    }

    @objc(mountedDatabaseNodeIdentifierWithPath:description:dictionary:type:)
    public class func mountedDatabaseNodeIdentifier(withPath devicePath: String!, description: String!, dictionary: [AnyHashable: Any]!, type: Int) -> MountedDatabaseNodeIdentifier! {
        var scan = true
        var path: String? = nil

        // does it contain an Horos Data folder?
        var isDir: ObjCBool = false
        if let devicePath, FileManager.default.fileExists(atPath: (devicePath as NSString).appendingPathComponent(OsirixDataDirName), isDirectory: &isDir) && isDir.boolValue {
            path = devicePath
            scan = false
        }

        if type == MountType.iPod {
            path = devicePath
            scan = false
        }

        if scan { path = FileManager.default.tmpDirectoryPathInTmp() }

        let bs = self.localDatabaseNodeIdentifier(withPath: path, description: description, dictionary: dictionary) as! MountedDatabaseNodeIdentifier
        bs.devicePath = devicePath
        bs.mountType = type
        if let path {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }

        if scan {
            bs.initiateVolumeScan()
        } else {
            bs.detected = true
        }

        return bs
    }

    deinit {
        _unmountButton?.removeFromSuperview()
        autoreleaseLater(_unmountButton)
        _unmountButton = nil

        //    [[NSFileManager defaultManager] removeItemAtPath:self.location error:NULL]; We cannot do it, because there was maybe threads attached to this sql file. The entire folder will be deleted when quitting or restarting OsiriX
    }

    public override func willDisplay(_ cell: PrettyCell!) {
        super.willDisplay(cell)

        let im = NSWorkspace.shared.icon(forFile: self.devicePath ?? "")
        im.size = im.sizeByScalingProportionally(toSize: cell.image != nil ? cell.image!.size : NSMakeSize(16, 16))
        cell.image = im

        if !self.detected {
            cell.textColor = NSColor.gray
        }

        if let unmountButton = _unmountButton {
            cell.rightSubviews?.add(unmountButton)
        }
    }

    public override func toolTip() -> String! {
        return self.devicePath
    }

    public override func isReadOnly() -> Bool {
        if self.mountType == MountType.iPod {
            return false
        }
        return true
    }

    @objc(sortValue)
    public func sortValue() -> CGFloat {
        return CGFloat.leastNormalMagnitude + 1 // CGFLOAT_MIN+1
    }

    @objc(willUnmount)
    public func willUnmount() {
        objcSynchronized(self) {
            DCMPix.purgeCachedDictionaries()

            if let scanThread = _scanThread {
                scanThread.cancel()
            }

            BrowserController.currentBrowser()?.redrawSources()

            _unmountButton?.removeFromSuperview()
            autoreleaseLater(_unmountButton)
            _unmountButton = nil
        }
    }
}

/// Raised when a source cannot be opened: its @catch shows the reason in a
/// sheet instead of letting the exception go on.
@objc(UnavaliableDataNodeException)
public final class UnavaliableDataNodeException: NSException {
}
