//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import CoreData

/// A line under the database window's list of sources: how much room the
/// local database's folder takes, and how much is left on its disk.
///
/// The folder can hold millions of files, so its size is added up on a
/// background queue, and again only when the database changes (images
/// indexed or deleted, another database chosen), at most once a minute. The
/// free space is read at the same time and every 30 seconds; it is the
/// figure the database itself checks before taking new files, and the line
/// turns to the alert colour when that check says the disk is full. A remote
/// database has no folder here, and the line is left empty.
@objc(HorosDatabaseStorageStatus)
@MainActor
public final class DatabaseStorageStatus: NSObject {

    // MARK: Figures

    /// A file size as the system writes it, with the fewest digits it allows
    /// (163 MB, 12,3 GB): the line has the width of the sidebar.
    public nonisolated static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    /// «Database: 12,3 GB · Free: 210 GB»; an ellipsis while the size is
    /// being added up, a dash when the free space cannot be read.
    public nonisolated static func text(databaseBytes: Int64?, freeBytes: Int64?) -> String {
        String(format: NSLocalizedString("Database: %@ · Free: %@", comment: "Under the list of sources: the size of the database folder, then the free space on its disk"),
               databaseBytes.map(size) ?? "…", freeBytes.map(size) ?? "—")
    }

    /// The room the files under `url` take on disk; links are not followed.
    public nonisolated static func folderSize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    public nonisolated static func freeBytes(at path: String) -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Whether the folder may be added up again `now`, the last time having
    /// been `last` (0: never).
    public nonisolated static func mayRecompute(now: TimeInterval, last: TimeInterval) -> Bool {
        last <= 0 || now - last >= sizeInterval
    }

    public nonisolated static let sizeInterval: TimeInterval = 60
    public nonisolated static let freeInterval: TimeInterval = 30

    // MARK: Line

    private static var installed: DatabaseStorageStatus?

    @objc public let label: NSTextField
    private weak var browser: BrowserController?
    private var databaseObservation: NSKeyValueObservation?
    private var timer: Timer?

    private var path: String?
    private var coordinator: ObjectIdentifier?
    private var databaseBytes: Int64?
    private var freeBytes: Int64?
    private var lastSize: TimeInterval = 0
    private var computing = false
    private var sizeWanted = false
    private var sizeScheduled = false

    /// Puts the line under the list of sources of `browser`, once.
    @objc(installInBrowser:)
    @discardableResult
    static func install(in browser: BrowserController) -> DatabaseStorageStatus? {
        if let installed { return installed }
        guard let scroll = browser.horos_sourcesTableView?.enclosingScrollView, let pane = scroll.superview else {
            return nil
        }
        let status = DatabaseStorageStatus(browser: browser)
        let label = status.label
        let height = ceil(label.intrinsicContentSize.height) + 2
        var frame = scroll.frame
        frame.size.height = max(0, frame.height - height)
        if pane.isFlipped {
            label.frame = NSRect(x: frame.minX, y: frame.maxY, width: frame.width, height: height)
            label.autoresizingMask = [.width, .minYMargin]
        } else {
            label.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
            label.autoresizingMask = [.width, .maxYMargin]
            frame.origin.y += height
        }
        // The pane itself draws nothing under the list: the line takes the
        // list's background, so that its text reads as the list's does.
        label.drawsBackground = true
        label.backgroundColor = (scroll.documentView as? NSTableView)?.backgroundColor ?? scroll.backgroundColor
        scroll.frame = frame
        pane.addSubview(label)
        installed = status
        status.start()
        return status
    }

    @objc public static var current: DatabaseStorageStatus? { installed }

    private init(browser: BrowserController) {
        self.browser = browser
        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityIdentifier("DatabaseStorageStatus")
        super.init()
    }

    private func start() {
        databaseObservation = browser?.observe(\.database, options: [.initial]) { _, _ in
            MainActor.assumeIsolated { DatabaseStorageStatus.installed?.databaseDidChange() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(contextDidSave(_:)),
                                               name: .NSManagedObjectContextDidSave, object: nil)
        let timer = Timer(timeInterval: Self.freeInterval, repeats: true) { _ in
            MainActor.assumeIsolated { DatabaseStorageStatus.installed?.refreshFreeSpace() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func databaseDidChange() {
        let database = browser?.database
        guard let database, database.isLocal(), let folder = database.dataBaseDirPath, !folder.isEmpty else {
            path = nil
            coordinator = nil
            databaseBytes = nil
            freeBytes = nil
            label.stringValue = ""
            label.toolTip = nil
            return
        }
        coordinator = database.managedObjectContext?.persistentStoreCoordinator.map { ObjectIdentifier($0) }
        if folder != path {
            path = folder
            databaseBytes = nil
            lastSize = 0
        }
        requestSize()
    }

    /// Images indexed or deleted, in any context of the database shown.
    @objc nonisolated private func contextDidSave(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext,
              let info = notification.userInfo,
              (info[NSInsertedObjectsKey] as? NSSet)?.count ?? 0 > 0 || (info[NSDeletedObjectsKey] as? NSSet)?.count ?? 0 > 0,
              let saved = context.persistentStoreCoordinator.map({ ObjectIdentifier($0) }) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let status = DatabaseStorageStatus.installed, status.coordinator == saved else { return }
                status.requestSize()
            }
        }
    }

    /// Adds the folder up now, or as soon as a minute has passed since the
    /// last time.
    @objc public func requestSize() {
        guard path != nil else { return }
        sizeWanted = true
        let now = ProcessInfo.processInfo.systemUptime
        if computing || sizeScheduled { return }
        if Self.mayRecompute(now: now, last: lastSize) {
            computeSize()
        } else {
            sizeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.sizeInterval - (now - lastSize))) {
                MainActor.assumeIsolated {
                    guard let status = DatabaseStorageStatus.installed else { return }
                    status.sizeScheduled = false
                    if status.sizeWanted { status.computeSize() }
                }
            }
        }
    }

    private func computeSize() {
        guard let path, !computing else { return }
        computing = true
        sizeWanted = false
        lastSize = ProcessInfo.processInfo.systemUptime
        show()
        DispatchQueue.global(qos: .utility).async {
            let bytes = DatabaseStorageStatus.folderSize(at: URL(fileURLWithPath: path, isDirectory: true))
            let free = DatabaseStorageStatus.freeBytes(at: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let status = DatabaseStorageStatus.installed else { return }
                    status.computing = false
                    guard status.path == path else { status.requestSize(); return }
                    status.databaseBytes = bytes
                    status.freeBytes = free
                    status.show()
                    if status.sizeWanted { status.requestSize() }
                }
            }
        }
    }

    @objc public func refreshFreeSpace() {
        guard let path else { return }
        freeBytes = Self.freeBytes(at: path)
        show()
    }

    private func show() {
        guard path != nil else { return }
        label.stringValue = Self.text(databaseBytes: databaseBytes, freeBytes: freeBytes)
        // The whole line again, should the sidebar be too narrow for it.
        label.toolTip = label.stringValue + "\n" + (path ?? "")
        let full = browser?.database?.isFileSystemFreeSizeLimitReached() ?? false
        label.textColor = full ? .systemRed : .secondaryLabelColor
    }

    /// For the checks: the bytes last added up, nil while they are not known.
    @objc public var shownDatabaseBytes: NSNumber? { databaseBytes.map { NSNumber(value: $0) } }
}
