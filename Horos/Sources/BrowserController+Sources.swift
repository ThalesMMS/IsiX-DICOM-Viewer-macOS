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
import IsiXPreferences
import Synchronization

// The Sources list of the database window. What it lists and how it follows
// the preferences, Bonjour and the mounted volumes is SourceList's; opening the
// database of a source is DatabaseOpener's, copying to a source SourceCopyJob's.
// The selectors of the former Objective-C category stay here, each handing its
// message on, for the nib, the Objective-C callers and the plugins.

public extension BrowserController {

    @objc(removePathFromSources:)
    func removePath(fromSources path: String!) {
        sourceList.removeVolume(atDevicePath: path)
    }

    @objc(awakeSources)
    func awakeSources() {
        sourceList.prepareList()
        let helper = BrowserSourcesHelper(browser: self)
        horos_sourcesHelper = helper
        sourceList.install(helper: helper)
    }

    @objc(deallocSources)
    func deallocSources() {
        (horos_sourcesHelper as? BrowserSourcesHelper)?.invalidate()
        horos_sourcesHelper = nil
    }

    @objc(sourcesCount)
    func sourcesCount() -> Int {
        sourceList.count
    }

    @objc(sourceIdentifierAtRow:)
    func sourceIdentifier(atRow row: Int32) -> DataNodeIdentifier! {
        sourceList.source(atRow: Int(row))
    }

    @objc(rowForSourceIdentifier:)
    func row(forSourceIdentifier source: DataNodeIdentifier!) -> Int32 {
        Int32(truncatingIfNeeded: sourceList.row(of: source))
    }

    @objc(sourceIdentifierForDatabase:)
    func sourceIdentifier(for database: DicomDatabase!) -> DataNodeIdentifier! {
        sourceList.source(for: database)
    }

    @objc(rowForDatabase:)
    func row(for database: DicomDatabase!) -> Int32 {
        Int32(truncatingIfNeeded: sourceList.row(for: database))
    }

    @objc(selectSourceForDatabase:)
    func selectSource(for database: DicomDatabase!) {
        sourceList.selectSource(for: database)
    }

    @objc(selectCurrentDatabaseSource)
    func selectCurrentDatabaseSource() {
        sourceList.selectShownDatabase()
    }

    @objc(setDatabaseOnMainThread:)
    func setDatabaseOnMainThread(_ db: DicomDatabase!) {
        databaseOpener.showLater(db)
    }

    @objc(initiateSetDatabaseAtPath:name:)
    @discardableResult
    func initiateSetDatabase(atPath path: String!, name: String!) -> Thread! {
        databaseOpener.openLocal(path: path, name: name)
    }

    @objc(initiateSetRemoteDatabaseWithAddress:port:name:)
    @discardableResult
    func initiateSetRemoteDatabase(withAddress address: String!, port: Int, name: String!) -> Thread! {
        databaseOpener.openRemote(address: address, port: port, name: name)
    }

    @objc(setDatabaseWithModalWindow:)
    func setDatabaseWithModalWindow(_ db: DicomDatabase!) {
        databaseOpener.showWithProgress(db)
    }

    @objc(setDatabaseFromSourceIdentifier:)
    func setDatabase(fromSourceIdentifier dni: DataNodeIdentifier!) {
        databaseOpener.show(source: dni)
    }

    @objc(redrawSources)
    nonisolated func redrawSources() {
        onMainActor { self.sourceList.redraw() }
    }
}

/// The data source and delegate of the Sources table, and the Bonjour and
/// volume callbacks of the former helper, each handed to the browser's
/// SourceList. The class and its selectors stay for the plugins of the former
/// SDK; the properties named as its former instance variables stay for the
/// key-value readers that ask for them.
@MainActor
@objc(BrowserSourcesHelper)
public final class BrowserSourcesHelper: NSObject, @MainActor HorosBonjourBrowserDelegate, @MainActor NetServiceDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let sourceList: SourceList?

    /// Starts following the preferences, Bonjour and the volumes for the
    /// browser's list.
    @objc(initWithBrowser:)
    public init(browser: BrowserController!) {
        sourceList = browser?.sourceList
        super.init()
        sourceList?.start()
    }

    @objc(invalidate)
    public func invalidate() {
        sourceList?.invalidate()
    }

    @objc var _bonjourServices: [NetService] { sourceList?.bonjourServices ?? [] }
    @objc var _bonjourSources: [DataNodeIdentifier] { sourceList?.bonjourSources ?? [] }
    @objc var _nsbOsirix: HorosBonjourBrowser? { sourceList?.sharedDatabaseBrowser }
    @objc var _nsbDicom: HorosBonjourBrowser? { sourceList?.dicomNodeBrowser }

    /// The key path, the object, the change and the context (an NSValue) of a
    /// change of the preferences the list follows.
    @objc(_observeValueForKeyPathOfObjectChangeContext:)
    func _observeValueForKeyPathOfObjectChangeContext(_ args: [Any]) {
        guard args.count >= 4 else { return }
        sourceList?.observeValue(forKeyPath: args[0] as? String, of: args[1], change: args[2] as? [NSKeyValueChangeKey: Any],
                                 context: (args[3] as? NSValue)?.pointerValue)
    }

    @objc(host:isEqualToHost:)
    public nonisolated class func host(_ h1: Host!, isEqualTo h2: Host!) -> Bool {
        SourceList.host(h1, isEqualTo: h2)
    }

    @objc(netServiceDidResolveAddress:)
    public func netServiceDidResolveAddress(_ service: NetService) {
        sourceList?.netServiceDidResolveAddress(service)
    }

    @objc(netService:didNotResolve:)
    public func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sourceList?.netService(service, didNotResolve: errorDict)
    }

    @objc(horosBonjourBrowser:didFindService:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didFind service: BonjourService) {
        sourceList?.horosBonjourBrowser(nsb, didFind: service)
    }

    @objc(horosBonjourBrowser:didUpdateService:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didUpdate service: BonjourService) {
        sourceList?.horosBonjourBrowser(nsb, didUpdate: service)
    }

    @objc(horosBonjourBrowser:didNotSearch:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didNotSearch errorDict: [String: Any]) {
        sourceList?.horosBonjourBrowser(nsb, didNotSearch: errorDict)
    }

    @objc(horosBonjourBrowser:didRemoveService:)
    public func horosBonjourBrowser(_ nsb: HorosBonjourBrowser, didRemove service: BonjourService) {
        sourceList?.horosBonjourBrowser(nsb, didRemove: service)
    }

    @objc(_analyzeVolumeAtPath:)
    public nonisolated func _analyzeVolume(atPath path: String!) {
        guard let path, !path.isEmpty else { return }
        onMainActor { self.sourceList?.analyzeVolume(atPath: path) }
    }

    @objc(_observeVolumeNotification:)
    nonisolated func _observeVolumeNotification(_ notification: Notification) {
        sourceList?.volumeDidChange(notification)
    }

    @objc(_observeVolumeWillUnmountNotification:)
    func _observeVolumeWillUnmountNotification(_ notification: Notification) {
        sourceList?.volumeWillUnmount(notification)
    }

    @objc(tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:)
    public func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn tc: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        sourceList?.toolTip(atRow: row) ?? ""
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    public func tableView(_ aTableView: NSTableView, willDisplayCell cellObject: Any, for tableColumn: NSTableColumn?, row: Int) {
        if let cell = cellObject as? PrettyCell { sourceList?.willDisplay(cell, atRow: row) }
    }

    @objc(toggleFederatedSearch:)
    func toggleFederatedSearch(_ sender: NSButton!) {
        sourceList?.toggleFederatedSearch(sender)
    }

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        sourceList?.validateDrop(on: tableView, proposedRow: row, operation: operation) ?? []
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        sourceList?.acceptDrop(info, row: row) ?? false
    }

    @objc(tableViewSelectionDidChange:)
    public func tableViewSelectionDidChange(_ notification: Notification) {
        sourceList?.selectionDidChange(in: notification.object as? NSTableView)
    }
}

/// The browser's own database, first in the Sources list.
@objc(DefaultLocalDatabaseNodeIdentifier)
public final class DefaultLocalDatabaseNodeIdentifier: LocalDatabaseNodeIdentifier {

    /// The Sources list's, on the main thread.
    @MainActor private static var _identifier: DefaultLocalDatabaseNodeIdentifier? = nil

    @objc(identifier)
    @MainActor
    public class func identifier() -> DefaultLocalDatabaseNodeIdentifier! {
        if _identifier == nil {
            _identifier = self.localDatabaseNodeIdentifier(withPath: DicomDatabase.default().baseDirPath) as? DefaultLocalDatabaseNodeIdentifier
        }
        return _identifier
    }

    /// In bold, at the size the list gave the cell just before.
    public override func willDisplay(_ cell: PrettyCell!) {
        // The sources table asks while it draws, on the main thread.
        MainActor.assumeIsolated {
            cell.font = NSFont.boldSystemFont(ofSize: cell.font?.pointSize ?? 0)
            cell.image = NSImage(named: "Isis.icns")
        }
    }

    /// The name the list of local databases gives its folder, or the folder's name.
    public override var description: String! {
        get {
            let folder = (self.location as NSString?)?.deletingLastPathComponent
            if let entry = SourceListRules.source(of: PreferencesSource.process.preferences[DatabasePreferences.localDatabaseSources], at: folder) {
                return entry.name
            }
            return ((folder as NSString?)?.lastPathComponent as NSString?)?.appending(NSLocalizedString(" DB", comment: "DB = DataBase"))
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

/// A mounted volume handed to the thread that scans it and back to the main
/// thread. `@unchecked Sendable`: the scan thread reads the volume's device
/// path and database, which are set before it starts, and everything it says
/// of the volume to the list goes through the main thread.
private struct ScannedVolume: @unchecked Sendable {
    let node: MountedDatabaseNodeIdentifier
}

/// A mounted volume: a disc or a device whose DICOM files are scanned into a
/// database of its own, or an Horos Data folder read in place.
@objc(MountedDatabaseNodeIdentifier)
public final class MountedDatabaseNodeIdentifier: LocalDatabaseNodeIdentifier {
    // Every stored property is an optional or a scalar, valid as the zeroed
    // memory +alloc hands over.
    private var _database: DicomDatabase?
    /// The thread that scans the volume, while it runs.
    private let scanThread = Mutex<Thread?>(nil)
    private var _unmountButton: NSButton?

    /// The list that shows the volume, which the scan tells what it found;
    /// set by the list right after it makes the volume, before the scan
    /// reports anything on the main thread.
    @MainActor weak var sourceList: SourceList?

    /// Both are set once, by the factory below, before the scan thread starts.
    @objc public var devicePath: String?
    @objc public var mountType: Int = 0

    // -initWithLocation:port:aetitle:description:dictionary: sends -init, as the
    // factories of LocalDatabaseNodeIdentifier use it: the button is made there.
    public override init() {
        super.init()
        // Made on the main thread: by the sources list, when it sees a volume.
        _unmountButton = assumeMainActor(self) { node -> NSButton in
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
            cell?.highlightsBy = .contentsCellMask

            unmountButton.target = node
            unmountButton.action = #selector(_eject(_:))
            return unmountButton
        }
    }

    // -initWithLocation:port:aetitle:description:dictionary: is unavailable to Swift
    // (DataNodeIdentifier.h), so no trapping stub is generated for it here: the
    // factory's call reaches the Objective-C implementation, which sends -init.

    /// Unmounts and ejects the device, off the main thread: a busy disc can
    /// take seconds to answer.
    @objc(_eject:)
    func _eject(_ sender: Any?) {
        let url = URL(fileURLWithPath: devicePath ?? "")
        ActivityThread.startUnlisted(name: "Eject") { _ in
            try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }
    }

    @objc(initiateVolumeScan)
    func initiateVolumeScan() {
        let database = DicomDatabase(atPath: self.location)
        _database = database
        database?.isReadOnly = true
        database?.sourcePath = self.devicePath
        database?.name = self.description
        database?.hasPotentiallySlowDataAccess = true
        for case let album as NSManagedObject in database?.albums() ?? [] {
            database?.managedObjectContext.delete(album)
        }

        try? database?.managedObjectContext.save()

        // -volumeScanThread lists itself in the Activity window.
        let volume = ScannedVolume(node: self)
        ActivityThread.startUnlisted(name: NSLocalizedString("Scanning disc...", comment: "")) { _ in
            volume.node.volumeScanThread()
        }
    }

    /// Scans the device into the volume's database on the current thread,
    /// listed in the Activity window. A volume with no image leaves the list;
    /// one with images is shown when the user asked for it, or when the
    /// preferences select a disc that is still there.
    @objc(volumeScanThread)
    func volumeScanThread() {
        autoreleasepool {
            let raised = HorosObjCException.caught {
                NSLog("--- volumeScanThread: start")

                // The lock keeps its own reference: the one this scan goes on using
                // cannot be handed to it.
                scanThread.withLock { $0 = Thread.current }
                let thread = Thread.current

                // A private-queue database: the scan enters its queue to index and
                // leaves it to ask the user, and the count is read inside it.
                let database = self._database?.privateQueueIndependentDatabase() as? DicomDatabase

                thread.name = NSLocalizedString("Scanning disc...", comment: "")
                ThreadsManager.default().addThreadAndStart(thread)

                let scanSelectsIt = database?.scan(atPath: self.devicePath) ?? false
                var imageCount = 0
                N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
                    imageCount = database?.objects(forEntity: database?.imageEntity())?.count ?? 0
                }

                // The list and what it shows are the main thread's: this thread scans the disc.
                let volume = ScannedVolume(node: self)
                if imageCount == 0 {
                    onMainActor { volume.node.sourceList?.volumeScanFoundNothing(volume.node) }
                    return
                }

                let preferences = PreferencesSource.process.preferences
#if OSIRIX_LIGHT
                let mountAction = 0 // the source is always shown
#else
                let mountAction = preferences[DatabasePreferences.mountAction]
#endif
                // The table shows `description`, which follows `detected`, through
                // its bindings, and KVO runs on the thread that writes: here the
                // table's observer would open a Core Animation transaction whose
                // commit, when this thread exits, draws the table off the main thread.
                let commandDown = onMainRunLoopSync {
                    volume.node.detected = true
                    return NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                }
                let selects = SourceListRules.selectsScannedVolume(
                    mountAction: mountAction, commandDown: commandDown, scanSelectsIt: scanSelectsIt,
                    autoSelectsMedia: preferences[DatabasePreferences.autoSelectSourceCDDVD],
                    deviceStillThere: FileManager.default.fileExists(atPath: self.devicePath ?? ""))
                onMainActor { volume.node.sourceList?.volumeScanned(volume.node, selects: selects) }
            }
            if let raised {
                BrowserObjC.log(raised, stack: true, "-[MountedDatabaseNodeIdentifier volumeScanThread]")
            }
            scanThread.withLock { $0 = nil }
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

        // Does it contain a data folder?
        if let devicePath, DatabaseLocation.existingDataDirectory(inFolder: devicePath) != nil {
            path = devicePath
            scan = false
        }

        if type == SourceListRules.MountKind.iPod.rawValue {
            path = devicePath
            scan = false
        }

        if scan { path = FileManager.default.tmpDirectoryPathInTmp() }

        guard let volume = self.localDatabaseNodeIdentifier(withPath: path, description: description, dictionary: dictionary) as? MountedDatabaseNodeIdentifier else {
            return nil
        }
        volume.devicePath = devicePath
        volume.mountType = type
        if let path {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }

        if scan {
            volume.initiateVolumeScan()
        } else {
            volume.detected = true
        }

        return volume
    }

    deinit {
        if let button = _unmountButton { onMainActor { button.removeFromSuperview() } }
        autoreleaseLater(_unmountButton)
        _unmountButton = nil

        // The folder of a scanned volume is not deleted here: threads may still use
        // its SQL file. The whole folder goes when the application quits or starts.
    }

    public override func willDisplay(_ cell: PrettyCell!) {
        super.willDisplay(cell)

        // The sources table asks while it draws, on the main thread.
        let devicePath = self.devicePath, detected = self.detected, unmountButton = _unmountButton
        MainActor.assumeIsolated {
            let im = NSWorkspace.shared.icon(forFile: devicePath ?? "")
            im.size = im.sizeByScalingProportionally(toSize: cell.image != nil ? cell.image!.size : NSMakeSize(16, 16))
            cell.image = im

            if !detected {
                cell.textColor = NSColor.gray
            }

            if let unmountButton {
                cell.rightSubviews?.add(unmountButton)
            }
        }
    }

    public override func toolTip() -> String! {
        return self.devicePath
    }

    public override func isReadOnly() -> Bool {
        mountType != SourceListRules.MountKind.iPod.rawValue
    }

    @objc(sortValue)
    public func sortValue() -> CGFloat {
        return CGFloat.leastNormalMagnitude + 1 // CGFLOAT_MIN+1
    }

    /// The volume is going: its scan stops, and its row and eject button go.
    @objc(willUnmount)
    public func willUnmount() {
        DCMPix.purgeCachedDictionaries()
        scanThread.withLock { $0?.cancel() }

        let volume = ScannedVolume(node: self)
        onMainActor { volume.node.sourceList?.redraw() }

        if let button = _unmountButton { onMainActor { button.removeFromSuperview() } }
        autoreleaseLater(_unmountButton)
        _unmountButton = nil
    }
}

/// `[object autorelease]`: released when the current pool drains.
@inline(__always)
private func autoreleaseLater(_ object: AnyObject?) {
    if let object {
        _ = Unmanaged.passUnretained(object).retain().autorelease()
    }
}

/// Raised when a source cannot be opened: its @catch shows the reason in a
/// sheet instead of letting the exception go on.
@objc(UnavaliableDataNodeException)
public final class UnavaliableDataNodeException: NSException {
}
