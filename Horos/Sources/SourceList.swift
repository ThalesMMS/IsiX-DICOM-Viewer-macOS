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
import IsiXDatabase
import IsiXDICOMNetwork
import IsiXPreferences

private let localDatabasesContext = IdentityToken()
private let sharedDatabasesContext = IdentityToken()
private let dicomNodesContext = IdentityToken()
private let bonjourDatabasesContext = IdentityToken()
private let bonjourNodesContext = IdentityToken()

/// The preference lists the Sources list follows, each with the context its
/// observation is registered with.
private enum ObservedList: CaseIterable, Sendable {
    case localDatabases, sharedDatabases, dicomNodes, bonjourDatabases, bonjourNodes

    var key: String {
        switch self {
        case .localDatabases: return DatabasePreferences.localDatabaseSources.name
        case .sharedDatabases: return NetworkPreferences.osirixServers.name
        case .dicomNodes: return NetworkPreferences.dicomNodes.name
        case .bonjourDatabases: return SourceListPreferences.doNotSearchForBonjourServices.name
        case .bonjourNodes: return NetworkPreferences.searchDICOMBonjour.name
        }
    }

    var context: UnsafeMutableRawPointer {
        switch self {
        case .localDatabases: return localDatabasesContext.pointer
        case .sharedDatabases: return sharedDatabasesContext.pointer
        case .dicomNodes: return dicomNodesContext.pointer
        case .bonjourDatabases: return bonjourDatabasesContext.pointer
        case .bonjourNodes: return bonjourNodesContext.pointer
        }
    }

    init?(context: UnsafeMutableRawPointer?) {
        guard let found = ObservedList.allCases.first(where: { $0.context == context }) else { return nil }
        self = found
    }
}

/// The "UID" a Bonjour TXT record carries, nil when it has none or cannot be
/// read. Both services IsiX publishes carry it, so this is how the list
/// recognises this application. NetService's Objective-C parser is asked
/// directly: a key without a value comes as NSNull, which the Swift overlay's
/// `[String: Data]` cannot hold, and a record whose "AETitle" or "port" is not
/// UTF-8 must not drop the DICOM node.
private func bonjourTXTRecordUID(_ data: Data?) -> String? {
    guard let data,
          let record = (NetService.self as AnyObject).perform(NSSelectorFromString("dictionaryFromTXTRecordData:"), with: data)?
            .takeUnretainedValue() as? [AnyHashable: Any],
          let value = record["UID"] as? Data else { return nil }
    return String(data: value, encoding: .utf8)
}

/// The addresses a resolved service answers on, in the order NetService gives them.
private func serviceAddresses(_ service: NetService) -> [SourceListRules.ServiceAddress] {
    var found: [SourceListRules.ServiceAddress] = []
    for address in service.addresses ?? [] {
        address.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            switch Int32(base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family) {
            case AF_INET:
                let socket = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                if let text = inet_ntoa(socket.sin_addr) {
                    found.append(.init(host: String(cString: text), port: Int(UInt16(bigEndian: socket.sin_port)), isIPv4: true))
                }
            case AF_INET6:
                let socket = base.assumingMemoryBound(to: sockaddr_in6.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var address = socket.sin6_addr
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    found.append(.init(host: host, port: Int(UInt16(bigEndian: socket.sin6_port)), isIPv4: false))
                }
            default:
                break
            }
        }
    }
    return found
}

/// Code unit by code unit, as `-isEqualToString:` compares; never for nil.
private func literallyEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return a.utf16.elementsEqual(b.utf16)
}

/// The Sources list of the database window: the local databases and the shared
/// databases and DICOM nodes the preferences hold, what Bonjour announces, the
/// mounted volumes, and the table that shows them.
///
/// The list itself is the browser's array controller, which the nib makes and
/// binds; this keeps it up to date and answers what the browser asks of it.
/// It lives on the main actor because the table, the array controller and the
/// Bonjour browsers are the main thread's. The callbacks that may come from
/// another thread (the shared defaults controller, the workspace) are handed
/// to the main thread first; asking whether a shared database is this computer
/// runs on a thread of its own, since resolving a host can take seconds.
@MainActor
final class SourceList: NSObject, @MainActor HorosBonjourBrowserDelegate, @MainActor NetServiceDelegate {
    /// Nil once invalidated: what still arrives then does nothing.
    private weak var browser: BrowserController?
    let preferences: any PreferenceStore
    private let volumeDiscovery = HorosVolumeDiscovery()
    private let deferred = DeferredCalls()

    /// The browsers of the two Bonjour service types: shared databases and DICOM nodes.
    private(set) var sharedDatabaseBrowser: HorosBonjourBrowser?
    private(set) var dicomNodeBrowser: HorosBonjourBrowser?
    /// Each service Bonjour found, with the source that stands for it, in the
    /// order they were found.
    private var bonjourEntries: [(service: NetService, source: DataNodeIdentifier)] = []
    /// The federated-search box of each local database, by its location.
    private var federatedCheckboxes: [String: NSButton] = [:]
    /// Off while the list is rebuilt, so that the table's selection changes
    /// do not open databases.
    private var followsSelection = true
    private var observesPreferences = false

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
        super.init()
    }

    /// The services Bonjour found, in order.
    var bonjourServices: [NetService] { bonjourEntries.map { $0.service } }
    /// The sources that stand for them, in the same order.
    var bonjourSources: [DataNodeIdentifier] { bonjourEntries.map { $0.source } }

    // MARK: The table and the list

    private var arrayController: NSArrayController? { browser?.sources }
    private var table: NSTableView? { browser?.horos_sourcesTableView }

    /// The sources in the order the table shows them.
    private var arranged: [Any] { arrayController?.arrangedObjects as? [Any] ?? [] }
    /// Every source of the list, in no order.
    private var content: [Any] { arrayController?.content as? [Any] ?? [] }

    private func listed(_ source: DataNodeIdentifier) -> Bool {
        content.contains { ($0 as? NSObject)?.isEqual(source) == true }
    }

    /// Sorts the list and puts the default database in it, before anything
    /// else is listed.
    func prepareList() {
        guard let controller = arrayController else { return }
        controller.sortDescriptors = [NSSortDescriptor(key: "self", ascending: true)]
        controller.automaticallyRearrangesObjects = true
        if let defaultSource = DefaultLocalDatabaseNodeIdentifier.identifier() { controller.addObject(defaultSource) }
        controller.selectsInsertedObjects = false
    }

    /// Makes the table show the list: the browser's helper as its data source
    /// and delegate, the cell, the drop types, the first row selected, and the
    /// size of the database under it.
    func install(helper: BrowserSourcesHelper) {
        guard let browser else { return }
        table?.dataSource = helper
        table?.delegate = helper
        table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Source"))?.dataCell = PrettyCell()
        table?.registerForDraggedTypes(BrowserController.databaseObjectXIDsPasteboardTypes().map { NSPasteboard.PasteboardType($0) })
        // The NSUInteger index 0 Objective-C passed.
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        DatabaseStorageStatus.install(in: browser)
    }

    var count: Int { arranged.count }

    func source(atRow row: Int) -> DataNodeIdentifier? {
        row >= 0 && row < arranged.count ? arranged[row] as? DataNodeIdentifier : nil
    }

    /// The row of `source`, -1 when it is not listed.
    func row(of source: DataNodeIdentifier?) -> Int {
        guard let source else { return -1 }
        return arranged.firstIndex { ($0 as? DataNodeIdentifier)?.isEqual(to: source) == true } ?? -1
    }

    /// The source a database is shown as.
    func source(for database: DicomDatabase?) -> DataNodeIdentifier? {
        if database === DicomDatabase.default() {
            return DefaultLocalDatabaseNodeIdentifier.identifier()
        }
        if let database, database.isLocal() {
            return LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: database.baseDirPath) as? DataNodeIdentifier
        }
        let remote = database as? RemoteDicomDatabase
        return RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: remote?.address, port: UInt(bitPattern: remote?.port ?? 0),
                                                                        description: nil, dictionary: nil) as? DataNodeIdentifier
    }

    func row(for database: DicomDatabase?) -> Int {
        row(of: source(for: database))
    }

    func selectSource(for database: DicomDatabase?) {
        let row = row(for: database)
        if row >= 0 {
            table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            NSLog("Warning: couldn't find database in sources (%@)", database?.description ?? "(null)")
        }
    }

    /// Selects the row of the database shown. A local database that is not
    /// listed is remembered in the preferences first, which lists it, unless
    /// it was opened from a temporary place - a CD copied under the user's
    /// temporary directory is the ordinary case - which is not somewhere to
    /// come back to: remembering it leaves an entry that putting the media
    /// back cannot make available again.
    func selectShownDatabase() {
        guard let database = browser?.database else {
            table?.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
        }
        var row = row(for: database)
        if row == -1 && database !== DicomDatabase.default() {
            let folder = (database.baseDirPath as NSString?)?.deletingLastPathComponent
            if let folder {
                let name = (folder as NSString).lastPathComponent + NSLocalizedString(" DB", comment: "DB = DataBase")
                let update = SourceListRules.sources(preferences[DatabasePreferences.localDatabaseSources], addingShownFolder: folder,
                                                     name: name, isTemporary: SourceLocation.isTemporaryLocation(folder))
                if case .write(let sources) = update {
                    preferences.set(sources, for: DatabasePreferences.localDatabaseSources)
                }
            }
            row = self.row(for: database)
        }
        if row != (table?.selectedRow ?? 0) {
            // The index as the NSUInteger Objective-C passed, -1 included.
            table?.selectRowIndexes(NSIndexSet(index: row) as IndexSet, byExtendingSelection: false)
        }
    }

    /// Asks the table to draw again.
    func redraw() {
        table?.needsDisplay = true
    }

    /// Keeps `source` for a minute after it leaves the list: a drag or a cell
    /// may still use it.
    private func keepForAMinute(_ source: DataNodeIdentifier) {
        deferred.perform("keep", after: 60, inModes: [.common]) { withExtendedLifetime(source) {} }
    }

    /// Removes `source` from the list, kept for a minute.
    func remove(_ source: DataNodeIdentifier) {
        keepForAMinute(source)
        arrayController?.removeObject(source)
    }

    /// Shows `database` after the event that asked for it: never in the middle
    /// of a drag and drop.
    private func showLater(_ database: DicomDatabase?) {
        browser?.databaseOpener.showLater(database)
    }

    /// The mounted volume at `devicePath`, gone or ejected: it leaves the list,
    /// and the default database is shown if it was the one shown.
    func removeVolume(atDevicePath devicePath: String?) {
        guard let volume = arranged.lazy.compactMap({ $0 as? MountedDatabaseNodeIdentifier })
                .first(where: { literallyEqual($0.devicePath, devicePath) }) else { return }
        if let browser, source(for: browser.database)?.isEqual(to: volume) == true {
            showLater(DicomDatabase.default())
        }
        remove(volume)
        volume.willUnmount()
    }

    // MARK: Starting and stopping

    /// Follows the preferences, Bonjour and the mounted volumes; lists the
    /// DICOMDIR beside the application, or else the removable volumes mounted
    /// already.
    func start() {
        guard !observesPreferences else { return }
        let defaultsController = NSUserDefaultsController.shared
        for list in ObservedList.allCases {
            defaultsController.addObserver(self, forValuesKey: list.key, options: .initial, context: list.context)
        }
        observesPreferences = true

        let sharedDatabases = HorosBonjourBrowser()
        sharedDatabaseBrowser = sharedDatabases
        sharedDatabases.delegate = self
        sharedDatabases.searchForServices(ofType: "_osirixdb._tcp.", inDomain: "")
        let dicomNodes = HorosBonjourBrowser()
        dicomNodeBrowser = dicomNodes
        dicomNodes.delegate = self
        dicomNodes.searchForServices(ofType: "_dicom._tcp.", inDomain: "")

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(volumeDidChange(_:)), name: name, object: nil)
        }
        workspaceCenter.addObserver(self, selector: #selector(volumeWillUnmount(_:)), name: NSWorkspace.willUnmountNotification, object: nil)

        listVolumesAtLaunch()
    }

    private func listVolumesAtLaunch() {
        // Is there a DICOMDIR at the same level as the application?
        let appFolder = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: (appFolder as NSString).appendingPathComponent("DICOMDIR")) {
            addVolume(atPath: appFolder, kind: .generic)
        } else if fileManager.fileExists(atPath: (appFolder as NSString).appendingPathComponent("DICOMDIRPATH")) {
            // Written by the OsiriX Lite launcher.
            let dicomdir = try? String(contentsOfFile: (appFolder as NSString).appendingPathComponent("DICOMDIRPATH"), encoding: .utf8)
            if let dicomdir, fileManager.fileExists(atPath: dicomdir) {
                addVolume(atPath: (dicomdir as NSString).deletingLastPathComponent, kind: .generic)
            }
        } else if SourceListRules.listsMountedVolumes(mountAction: mountAction) {
            for url in fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: []) ?? []
                where (try? url.resourceValues(forKeys: [.volumeIsRemovableKey]))?.volumeIsRemovable == true {
                analyzeVolume(atPath: url.path)
            }
        }
    }

    private var mountAction: Int {
#if OSIRIX_LIGHT
        0 // the source is always shown
#else
        preferences[DatabasePreferences.mountAction]
#endif
    }

    /// Stops following the volumes; what still arrives finds no browser.
    func invalidate() {
        volumeDiscovery.cancelAll()
        browser = nil
    }

    isolated deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.removeObserver(self)
        if observesPreferences {
            for list in ObservedList.allCases.reversed() {
                NSUserDefaultsController.shared.removeObserver(self, forValuesKey: list.key)
            }
        }
        dicomNodeBrowser?.delegate = nil
        dicomNodeBrowser?.stop()
        sharedDatabaseBrowser?.delegate = nil
        sharedDatabaseBrowser?.stop()
    }

    // MARK: The lists of the preferences

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let list = ObservedList(context: context) else { return }
        // The shared defaults controller reports a default on the thread that
        // wrote it; the list is rebuilt on the main thread.
        onMainActor { self.reload(list) }
    }

    /// Rebuilds the part of the list `list` holds; then shows the default
    /// database if the one shown left the list, or selects its row again.
    private func reload(_ list: ObservedList) {
        followsSelection = false
        let previous = source(for: browser?.database)
        if let exception = HorosObjCException.caught({
            // Once invalidated there is no browser, and no list to change.
            guard browser != nil else { return }
            switch list {
            case .localDatabases: reloadLocalDatabases()
            case .sharedDatabases: reloadSharedDatabases()
            case .dicomNodes: reloadDICOMNodes()
            case .bonjourDatabases: reloadBonjour(.sharedDatabase)
            case .bonjourNodes: reloadBonjour(.dicomNode)
            }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserSourcesHelper observeValueForKeyPath:ofObject:change:context:]")
        }
        followsSelection = true

        guard let browser else { return }
        if row(of: previous) == -1 {
            showLater(DicomDatabase.default())
        } else {
            selectSource(for: browser.database)
        }
    }

    /// The entered sources of one kind that the stored list no longer has
    /// stop being entered, and leave the list unless detected.
    private func forgetEntered<Kind: DataNodeIdentifier>(_ kind: Kind.Type, stillStored: (Kind) -> Bool) {
        for case let source as Kind in content where source.entered {
            switch SourceListRules.fate(stillStored: stillStored(source), detected: source.detected) {
            case .kept:
                break
            case .notEntered:
                source.entered = false
            case .removed:
                source.entered = false
                remove(source)
            }
        }
    }

    /// The listed source whose location is `location`.
    private func listedSource(at location: String?) -> DataNodeIdentifier? {
        guard let location else { return nil }
        return content.lazy.compactMap { $0 as? DataNodeIdentifier }.first { literallyEqual($0.location, location) }
    }

    private func reloadLocalDatabases() {
        let stored = preferences[DatabasePreferences.localDatabaseSources]?.sources ?? []
        forgetEntered(LocalDatabaseNodeIdentifier.self) { source in stored.contains { literallyEqual($0.path, source.location) } }
        let defaultBase = DicomDatabase.default()?.baseDirPath
        for entry in stored {
            // Listed already as the default database.
            if literallyEqual(DicomDatabase.baseDirPath(forPath: entry.path), defaultBase) { continue }
            let dictionary = entry.propertyList.object as? [AnyHashable: Any]
            if let source = listedSource(at: entry.path) {
                source.entered = true
                source.description = entry.name
                source.dictionary = dictionary
            } else if let source = LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: entry.path, description: entry.name,
                                                                                           dictionary: dictionary) as? DataNodeIdentifier {
                source.entered = true
                arrayController?.addObject(source)
            }
        }
    }

    /// The shared databases of the preferences, as dictionaries.
    private func storedSharedDatabases() -> [[String: Any]] {
        (preferences[NetworkPreferences.osirixServers] ?? []).compactMap { $0.object as? [String: Any] }
    }

    private func reloadSharedDatabases() {
        let stored = storedSharedDatabases()
        forgetEntered(RemoteDatabaseNodeIdentifier.self) { source in stored.contains { literallyEqual($0["Address"] as? String, source.location) } }
        for entry in stored {
            let address = entry["Address"] as? String
            // This computer's own host is asked for on a thread of its own: at
            // launch its resolution can take tens of seconds, and this runs on
            // the main thread from the nib's awaking, before the listener starts.
            Task {
                let isThisComputer = await ActivityThread.runUnlisted(name: "Sources: shared database host") {
                    SourceList.host(Host.host(withAddressOrName: (address ?? "") as NSString), isEqualTo: DefaultPreferences.currentHost())
                }
                if !isThisComputer { listSharedDatabase(entry, address: address) }
            }
        }
    }

    private func listSharedDatabase(_ entry: [String: Any], address: String?) {
        guard let arrayController else { return }
        let name = entry["Description"] as? String
        if let source = listedSource(at: address) {
            source.entered = true
            source.description = name
            source.dictionary = entry
        } else if let source = RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(
                    withLocation: address, port: UInt(bitPattern: PropertyListValue(entry["Port"] ?? "")?.intValue ?? 0),
                    description: name, dictionary: nil) as? DataNodeIdentifier {
            source.dictionary = entry
            source.entered = true
            arrayController.addObject(source)
        }
    }

    private func reloadDICOMNodes() {
        // The stored nodes that are on and send, one per address, port (when
        // stored as a number) and AE title: the last one wins.
        var nodes: [String: DICOMNode] = [:]
        for node in DICOMNodeService.store.dicomNodes()
            where node[DICOMNode.Key.activated]?.boolValue == true && node[DICOMNode.Key.send]?.boolValue == true {
            nodes[SourceListRules.enteredNodeKey(address: node[DICOMNode.Key.address], port: node[DICOMNode.Key.port],
                                                 aeTitle: node[DICOMNode.Key.aeTitle])] = node
        }
        // A node is found by its host, port and AE title: its location is the
        // server's address, never the key above, so that a node Bonjour merged
        // into an entered one stays one row.
        let entered: [[AnyHashable: Any]] = nodes.values.map(\.propertyList)
        forgetEntered(DicomNodeIdentifier.self) { source in entered.contains { source.isEqual(to: $0) } }
        for node in nodes.values {
            let server: [AnyHashable: Any] = node.propertyList
            if let source = content.lazy.compactMap({ $0 as? DicomNodeIdentifier }).first(where: { $0.isEqual(to: server) }) {
                source.entered = true
                source.dictionary = server
                source.description = node.nodeDescription
            } else if let source = DicomNodeIdentifier.dicomNodeIdentifier(withLocation: node.address,
                                                                           port: UInt(bitPattern: Int(Int32(truncatingIfNeeded: node.port))),
                                                                           aetitle: node.aeTitle, description: node.nodeDescription,
                                                                           dictionary: nil) as? DataNodeIdentifier {
                source.dictionary = server
                source.entered = true
                arrayController?.addObject(source)
            }
        }
    }

    // MARK: Bonjour

    private var doesNotSearchSharedDatabases: Bool { preferences[SourceListPreferences.doNotSearchForBonjourServices] }
    private var searchesDICOMNodes: Bool { preferences[NetworkPreferences.searchDICOMBonjour] }

    private func kind(of source: DataNodeIdentifier) -> SourceListRules.BonjourSourceKind? {
        if source is RemoteDatabaseNodeIdentifier { return .sharedDatabase }
        if source is DicomNodeIdentifier { return .dicomNode }
        return nil
    }

    private func listsBonjour(_ source: DataNodeIdentifier) -> Bool {
        guard let kind = kind(of: source) else { return false }
        return SourceListRules.listsBonjourSources(kind, doNotSearchSharedDatabases: doesNotSearchSharedDatabases,
                                                   searchDICOMNodes: searchesDICOMNodes)
    }

    /// The search of `kind` was turned on or off: the sources Bonjour found
    /// of that kind join the list or leave it.
    private func reloadBonjour(_ kind: SourceListRules.BonjourSourceKind) {
        let listed = SourceListRules.listsBonjourSources(kind, doNotSearchSharedDatabases: doesNotSearchSharedDatabases,
                                                         searchDICOMNodes: searchesDICOMNodes)
        for source in bonjourSources where self.kind(of: source) == kind {
            if listed {
                if !source.detected && source.location != nil {
                    source.detected = true
                    if !self.listed(source) { arrayController?.addObject(source) }
                }
            } else if source.detected {
                source.detected = false
                if !source.entered && self.listed(source) { remove(source) }
            }
        }
    }

    private func entryIndex(of service: NetService) -> Int? {
        bonjourEntries.firstIndex { $0.service.isEqual(service) }
    }

    private nonisolated static let hostComparisons = DispatchSemaphore(value: 10)

    /// Whether two hosts are one: the same address, or the same name. At most
    /// ten comparisons run at once, since each may ask the resolver.
    nonisolated static func host(_ first: Host?, isEqualTo second: Host?) -> Bool {
        let comparisons = hostComparisons
        guard comparisons.wait(timeout: .distantFuture) == .success else { return false }
        var equal = false
        let raised = HorosObjCException.caught {
            if let a = first?.address, let b = second?.address, literallyEqual(a, b) {
                equal = true
            } else if let a = first?.name, let b = second?.name, literallyEqual(a, b) {
                equal = true
            }
        }
        comparisons.signal()
        raised?.raise()
        return equal
    }

    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didFind service: BonjourService) {
        let source: DataNodeIdentifier?
        if browser === sharedDatabaseBrowser {
            source = RemoteDatabaseNodeIdentifier.remoteDatabaseNodeIdentifier(withLocation: nil, port: 0, description: service.name,
                                                                              dictionary: nil) as? DataNodeIdentifier
        } else {
            source = DicomNodeIdentifier.dicomNodeIdentifier(withLocation: nil, port: 0, aetitle: "", description: service.name,
                                                             dictionary: nil) as? DataNodeIdentifier
        }
        guard let source else { return }
        bonjourEntries.append((service, source))
        NSLog("Find Service: %@", service)

        // Resolves the address and port of the service.
        service.delegate = self
        service.resolve(withTimeout: 30)
    }

    // The same peer on another interface, or with a new TXT record: what is
    // there is refreshed. Removing and adding the row again would drop its
    // selection and its liveness for a peer that never went away.
    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didUpdate service: BonjourService) {
        guard entryIndex(of: service) != nil else {
            horosBonjourBrowser(browser, didFind: service)
            return
        }
        NSLog("Update Service: %@", service)
        service.delegate = self
        service.resolve(withTimeout: 30)
    }

    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didNotSearch errorDict: [String: Any]) {
        NSLog("Bonjour search failed: %@", errorDict.description)
    }

    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didRemove service: BonjourService) {
        NSLog("Bonjour service gone: %@", service)
        guard let index = entryIndex(of: service) else { return }
        let (known, source) = bonjourEntries[index]
        if listsBonjour(source) {
            source.detected = false
            if !source.entered && listed(source) { remove(source) }
        }
        // If the source that goes is the one shown, the default database is shown.
        if let shown = self.browser, self.source(for: shown.database)?.isEqual(to: source) == true {
            showLater(DicomDatabase.default())
        }
        NSLog("Remove Service: %@", known)
        bonjourEntries.remove(at: index)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        if let exception = HorosObjCException.caught({ resolved(service) }) {
            BrowserObjC.log(exception, "-[BrowserSourcesHelper netServiceDidResolveAddress:]")
        }
    }

    private func resolved(_ service: NetService) {
        service.stop() // Technical Q&A QA1297
        guard let index = entryIndex(of: service) else {
            NSLog("***** unknown didResolve Service")
            return
        }
        var source = bonjourEntries[index].source

        // This application's shared database and DICOM node both carry its UID.
        if let uid = bonjourTXTRecordUID(service.txtRecordData()), literallyEqual(uid, AppController.uid()) {
            NSLog("Remove Service: %@", service)
            bonjourEntries.remove(at: index)
            return
        }

        if source.location == nil, let address = SourceListRules.preferredAddress(serviceAddresses(service)) {
            if source is RemoteDatabaseNodeIdentifier || source is DicomNodeIdentifier {
                source.location = address.host
                source.port = UInt(bitPattern: address.port)
            }
            if source is DicomNodeIdentifier {
                source.aetitle = source.description
            }
        }

        // Already listed: the source of the list stands for the service.
        if let known = content.lazy.compactMap({ $0 as? DataNodeIdentifier }).first(where: { $0.isEqual(source) }) {
            source = known
            bonjourEntries[index].source = known
        }

        // A DICOM node entered in the preferences that Bonjour announces too is
        // one node: it keeps the server the user entered (its transfer syntax,
        // its description) and is flagged detected.
        if source is RemoteDatabaseNodeIdentifier {
            source.dictionary = BonjourPublisher.dictionaryFromXTRecordData(service.txtRecordData()) as? [AnyHashable: Any]
        } else if !source.entered {
            source.dictionary = DICOMNodeService.nodeInfo(fromTXTRecordData: service.txtRecordData()) as? [AnyHashable: Any]
        }

        if source.location != nil && listsBonjour(source) {
            source.detected = true
            if !listed(source) { arrayController?.addObject(source) }
        }
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        service.stop()
        guard let index = entryIndex(of: service) else { return }
        NSLog("Remove Service: %@", bonjourEntries[index].service)
        bonjourEntries.remove(at: index)
    }

    // MARK: Mounted volumes

    /// Asks what the volume at `path` is, off the main thread, and lists it if
    /// it is a source that no listed local database covers.
    func analyzeVolume(atPath path: String) {
        guard browser != nil, !path.isEmpty else { return }
        _ = volumeDiscovery.discoverPath(path, worker: {
            var failure: NSError?
            let output = HorosRunBoundedTask("/usr/sbin/diskutil", ["info", "-plist", path], 5.0, &failure)
            if let failure { NSLog("Volume metadata discovery failed: %@", failure.localizedDescription) }
            let info = output.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [String: Any]
            let kind = SourceListRules.mountKind(
                opticalMediaType: info?["OpticalMediaType"] as? String, mediaType: info?["MediaType"] as? String,
                holdsDICOMDIR: FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("DICOMDIR")),
                holdsDatabaseFolder: DatabaseLocation.existingDataDirectory(inFolder: path) != nil)
            return kind.map { NSNumber(value: $0.rawValue) }
        }, completion: { [weak self] value in
            guard let self, let raw = (value as? NSNumber)?.intValue, let kind = SourceListRules.MountKind(rawValue: raw) else { return }
            MainActor.assumeIsolated { self.volumeAnalyzed(atPath: path, kind: kind) }
        })
    }

    private func volumeAnalyzed(atPath path: String, kind: SourceListRules.MountKind) {
        guard browser != nil else { return }
#if !OSIRIX_LIGHT
        if !SourceListRules.listsMountedVolumes(mountAction: preferences[DatabasePreferences.mountAction]) { return }
#endif
        let localLocations = arranged.compactMap { ($0 as? LocalDatabaseNodeIdentifier)?.location }
        if SourceListRules.isListedAsLocalDatabase(volume: path, localLocations: localLocations) { return }
        addVolume(atPath: path, kind: kind)
    }

    private func addVolume(atPath path: String, kind: SourceListRules.MountKind) {
        if let exception = HorosObjCException.caught({
            guard let volume = MountedDatabaseNodeIdentifier.mountedDatabaseNodeIdentifier(
                withPath: path, description: (path as NSString).lastPathComponent, dictionary: nil, type: kind.rawValue) else { return }
            // Before its scan ends: the scan reports to the list from the main
            // thread, which runs this first.
            volume.sourceList = self
            arrayController?.addObject(volume)
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserSourcesHelper _analyzeVolumeAtPath:]")
        }
    }

    /// A volume was mounted, unmounted or renamed. The workspace may say so on
    /// another thread; only the paths reach the main thread.
    @objc(_observeVolumeNotification:)
    nonisolated func volumeDidChange(_ notification: Notification) {
        let name = notification.name
        let path = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
        let oldPath = (notification.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL)?.path
        onMainActor { self.volumeDidChange(name, path: path, oldPath: oldPath) }
    }

    private func volumeDidChange(_ name: Notification.Name, path: String?, oldPath: String?) {
        let unmounted = name == NSWorkspace.didUnmountNotification
        let renamed = name == NSWorkspace.didRenameVolumeNotification
        if unmounted { volumeDiscovery.cancelPath(path) }
        if renamed { volumeDiscovery.cancelPath(oldPath) }
        guard SourceListRules.listsMountedVolumes(mountAction: mountAction) else { return }

        redraw()
        if name == NSWorkspace.didMountNotification, let path { analyzeVolume(atPath: path) }
        if unmounted || renamed { removeVolume(atDevicePath: renamed ? oldPath : path) }
        // Probed again even if the discovery at the old path was still pending.
        if renamed, let path { analyzeVolume(atPath: path) }
    }

    /// A volume is about to be unmounted: its scan stops, and if it is the
    /// database shown, the active local database is shown, or the default one.
    @objc(_observeVolumeWillUnmountNotification:)
    func volumeWillUnmount(_ notification: Notification) {
        let devicePath = notification.userInfo?["NSDevicePath"] as? String
        DCMPix.purgeCachedDictionaries()
        let volume = arranged.lazy.compactMap { $0 as? MountedDatabaseNodeIdentifier }.first { literallyEqual($0.devicePath, devicePath) }
        volume?.willUnmount()
        if let volume, let browser, source(for: browser.database)?.isEqual(to: volume) == true {
            let active = DicomDatabase.activeLocal()
            showLater(active === browser.database ? DicomDatabase.default() : active)
        }
    }

    /// A scanned volume found nothing to show: it leaves the list.
    func volumeScanFoundNothing(_ volume: MountedDatabaseNodeIdentifier) {
        remove(volume)
        volume.willUnmount()
    }

    /// A scanned volume is ready: it is shown when the rules say so, from the
    /// run loop in its default mode, else its row is drawn again.
    func volumeScanned(_ volume: MountedDatabaseNodeIdentifier, selects: Bool) {
        if selects {
            deferred.perform("scanned", after: 0) { [weak self] in self?.browser?.databaseOpener.show(source: volume) }
        } else {
            redraw()
        }
    }

    // MARK: The table's data source and delegate

    func toolTip(atRow row: Int) -> String {
        source(atRow: row)?.toolTip() ?? ""
    }

    func willDisplay(_ cell: PrettyCell, atRow row: Int) {
        cell.image = nil
        cell.font = NSFont.systemFont(ofSize: CGFloat(browser?.fontSize("dbSourceFont") ?? 0))
        cell.textColor = nil
        cell.rightSubviews?.removeAllObjects()
        let source = source(atRow: row)
        cell.title = source?.description ?? ""
        source?.willDisplay(cell)
        guard let source, source is LocalDatabaseNodeIdentifier, !(source is MountedDatabaseNodeIdentifier) else { return }
        let key = source.location ?? ""
        let box = federatedCheckboxes[key] ?? {
            let box = NSButton(frame: NSMakeRect(0, 0, 18, 18))
            box.setButtonType(.switch)
            box.title = ""
            box.toolTip = NSLocalizedString("Include in federated search (UI and web portal)", comment: "")
            box.target = self
            box.action = #selector(toggleFederatedSearch(_:))
            federatedCheckboxes[key] = box
            return box
        }()
        box.tag = row
        let included = FederatedSearch.isPath(source.location, includedIn: storedLocalDatabases(),
                                              defaultPath: DicomDatabase.default().baseDirPath,
                                              defaultIncluded: FederatedSearch.isDefaultDatabaseIncluded)
        box.state = included ? .on : .off
        cell.rightSubviews?.add(box)
    }

    private func storedLocalDatabases() -> [[String: Any]]? {
        preferences[DatabasePreferences.localDatabaseSources]?.propertyList.object as? [[String: Any]]
    }

    /// The federated-search box of a local database was clicked.
    @objc(toggleFederatedSearch:)
    func toggleFederatedSearch(_ sender: NSButton?) {
        guard let sender, let source = source(atRow: sender.tag), source is LocalDatabaseNodeIdentifier else { return }
        let included = sender.state == .on
        if source is DefaultLocalDatabaseNodeIdentifier {
            FederatedSearch.isDefaultDatabaseIncluded = included
        } else {
            let updated = FederatedSearch.updatingLocalDatabasePaths(storedLocalDatabases(), path: source.location, included: included)
            preferences.set(updated, forKey: DatabasePreferences.localDatabaseSources.name)
        }
        if let browser, (browser.searchString?.count ?? 0) > 0 {
            browser.searchString = browser.searchString
        }
    }

    func validateDrop(on table: NSTableView, proposedRow row: Int, operation: NSTableView.DropOperation) -> NSDragOperation {
        guard operation == .on, let browser else { return [] }
        if row == self.row(for: browser.database) { return [] }
        if row >= count && browser.database !== DicomDatabase.default() {
            table.setDropRow(self.row(for: DicomDatabase.default()), dropOperation: .on)
            return .copy
        }
        if row < count {
            if source(atRow: row)?.isReadOnly() == true { return [] }
            table.setDropRow(row, dropOperation: .on)
            return .copy
        }
        return []
    }

    /// Copies the studies, series or images dropped on a row to its source.
    func acceptDrop(_ info: NSDraggingInfo, row: Int) -> Bool {
        guard let browser else { return false }
        let objects = (BrowserController.databaseObjectXIDs(on: info.draggingPasteboard) ?? []).compactMap { xid in
            (xid as? String).flatMap { browser.database?.object(withID: NSManagedObject.uid(forXid: $0)) }
        }
        return copy(DicomImage.dicomImages(in: objects) as? [Any], to: source(atRow: row))
    }

    /// Copies images of the database shown to `destination`; false when there
    /// is no way to.
    func copy(_ images: [Any]?, to destination: DataNodeIdentifier?) -> Bool {
        guard let browser else { return false }
        return SourceCopyJob.initiate(images: images, to: destination, from: browser, preferences: preferences)
    }

    func selectionDidChange(in table: NSTableView?) {
        guard followsSelection else { return }
        browser?.databaseOpener.show(source: source(atRow: table?.selectedRow ?? 0))
    }
}
