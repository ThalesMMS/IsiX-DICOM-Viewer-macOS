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
import UniformTypeIdentifiers

/// A database opened on another thread, handed to the main thread once.
/// `@unchecked Sendable`: the opening thread does not use it after handing it
/// over, and the main thread only shows it.
private struct OpenedDatabase: @unchecked Sendable {
    let database: DicomDatabase?
}

/// What the database window opens on a thread of its own.
private enum OpenRequest: Sendable {
    /// A local database folder, under the name the Sources list gives it.
    case local(path: String?, name: String?)
    /// The database another IsiX or OsiriX shares.
    case remote(address: String?, port: Int, name: String?)
}

/// Which database the database window shows: a source chosen in the Sources
/// list, a local or shared database opened on a thread of its own behind a
/// progress sheet, a database folder or index file chosen in an open panel,
/// and the default database again when the preferences change it.
///
/// The browser's `database` setter does the switch itself, on the main
/// thread; this decides what to switch to and hands it over after the event
/// that asked for it, so that a switch never happens in the middle of a drag
/// and drop.
@MainActor
final class DatabaseOpener {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore
    private let deferred = DeferredCalls()

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: Switching

    /// What the browser's `database` setter does, on the main thread: saves
    /// the database it leaves, forgets what the browser held of it, closes the
    /// viewers, and shows `db` (which may be nil) in every list of the browser,
    /// following its notifications.
    func switchTo(_ db: DicomDatabase?, closingViewers: () -> Void) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("setDatabase MUST be performed on MAIN thread")
        }
        guard browser.horos_databaseIvar !== db else { return }

        let raised = HorosObjCException.caught {
            (LogManager.currentLogManager() as? LogManager)?.resetLogs()

            browser.willChangeValue(forKey: "database")

            browser.saveLoadAlbumsSortDescriptors()
            browser.waitForRunningProcesses()

            _ = browser.horos_databaseIvar?.save(nil)
            browser.horos_databaseIvar = nil

            browser.willChangeContext()
            browser.horos_reportFilesToCheck?.removeAllObjects()

            browser.window?.display()

            DCMPix.purgeCachedDictionaries()
            DCMView.purgeStringTextureCache()

            browser.resetLogWindowController()
            closingViewers()

            _ = HorosObjCException.caught {
                if preferences[DatabasePreferences.clearsSearchWhenSelectingAlbum] {
                    browser.showEntireDatabase()
                }
            }

            browser.horos_databaseIvar = db
            // Its own 'clean' managed object context, used by no other thread.
            db?.renewManagedObjectContext()

            if let db, UserDefaults.canActivateAnyLocalDatabase() && db.isLocal() && !db.isReadOnly {
                DicomDatabase.setActiveLocal(db)
            }
            Monochrome1Thumbnails.rebuildOnce(in: db)
            if db != nil {
                browser.sourceList.selectShownDatabase()
            }

            let center = NotificationCenter.default
            center.addObserver(browser, selector: #selector(BrowserController._observeDatabaseAddNotification(_:)),
                               name: ._O2AddToDBAnyway, object: db)
            center.addObserver(browser, selector: #selector(BrowserController._observeDatabaseDidChangeContextNotification(_:)),
                               name: .OsirixDicomDatabaseDidChangeContext, object: db)
            center.addObserver(browser, selector: #selector(BrowserController._observeDatabaseInvalidateAlbumsCacheNotification(_:)),
                               name: .O2DatabaseInvalidateAlbumsCache, object: db)
            center.addObserver(browser, selector: #selector(BrowserController._newStudiesRefreshComparativeStudies(_:)),
                               name: .OsirixAddNewStudiesDB, object: db)

            browser.horos_albumTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            browser.saveLoadAlbumsSortDescriptors()

            // The album catalog keeps the counts under its own lock; each access
            // is a new object, so locking it held nothing.
            browser.horos_albumNoOfStudiesCache?.removeAllObjects()
            browser.horos_distantAlbumNoOfStudiesCache?.removeAllObjects()

            N2ManagedObjectContextPerformAndWait(db?.managedObjectContext) {
                if let exception = HorosObjCException.caught({ showDatabaseInEveryList() }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController setDatabase:]")
                }
            }

            (LogManager.currentLogManager() as? LogManager)?.resetLogs()
        }
        browser.didChangeValue(forKey: "database")
        raised?.raise()
    }

    /// Forgets everything the browser holds of the database it is leaving.
    func forgetDatabaseShown() {
        browser.waitForRunningProcesses()

        // @synchronized on the thumbnails, as the matrix takes it; nothing here raises.
        do {
            let lock = browser.horos_previewPixThumbnails
            if let lock { objc_sync_enter(lock) }
            defer { if let lock { objc_sync_exit(lock) } }
            browser.horos_matrixLoadIconsThread?.cancel()
            browser.horos_matrixLoadIconsThread = nil
        }

        browser.comparativePatientUID = nil
        browser.comparativeStudies = nil

        // The PACS On-Demand studies of the list, which their store keeps for any thread.
        browser.pacsOnDemand.listStudies.replace(with: nil)

        browser.horos_outlineViewArray = nil

        browser.horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles = nil
        browser.horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects = nil
        browser.horos_cachedFilesForDatabaseOutlineSelectionTreeObjects = nil
        browser.horos_cachedFilesForDatabaseOutlineSelectionIndex = nil

        browser.forgetROIsAndKeyImages()
        browser.forgetCachedAlbums()

        browser.horos_databaseOutline?.reloadData()
        browser.horos_albumTable?.reloadData()
        browser.horos_comparativeTable?.reloadData()
    }

    /// Reloads every list of the browser from the database just shown.
    private func showDatabaseInEveryList() {
        browser.horos_databaseOutline?.reloadData()
        browser.horos_albumTable?.reloadData()
        browser.horos_comparativeTable?.reloadData()

        browser.window?.display()
        browser.setDBWindowTitle()
        browser.refreshPACSOnDemandResults(browser)

        browser.setNetworkLogs()
        _ = browser.outlineViewRefresh()
        browser.refreshMatrix(browser)
        browser.refreshAlbums()

        if let query = QueryController.current() {
            query.refresh(browser)
        } else if let query = QueryController.currentAuto() {
            query.refresh(browser)
        }
    }

    // MARK: Showing a database

    /// Shows `database` once the current event is over, in the default run
    /// loop mode: never while a drag is tracked.
    func showLater(_ database: DicomDatabase?) {
        deferred.perform("show", after: 0.01) { [browser] in browser.database = database }
    }

    // MARK: A source of the Sources list

    /// Shows the database of a source: at once when the source has it open,
    /// else opened on a thread of its own. A DICOM node, or a disc still
    /// being scanned, says why it cannot be browsed.
    func show(source: DataNodeIdentifier?) {
        if source?.isEqual(to: browser.sourceList.source(for: browser.database)) == true {
            return
        }
        let raised = HorosObjCException.caught {
            if let database = source?.database() {
                deferred.perform("show", after: 0.01) { [weak self] in self?.showWithProgress(database) }
            } else if let source = source as? LocalDatabaseNodeIdentifier {
                openLocal(path: source.location, name: source.description)
            } else if let source = source as? RemoteDatabaseNodeIdentifier {
                var host: NSString?
                var port = -1
                _ = RemoteDatabaseNodeIdentifier.location(source.location, port: source.port, toAddress: &host, port: &port)
                if let host, port != -1 {
                    openRemote(address: host as String, port: port, name: source.description)
                }
            } else {
                UnavaliableDataNodeException(name: .genericException,
                                             reason: NSLocalizedString("This is a DICOM destination node: you cannot browse its content. You can only drag & drop studies on them.", comment: ""),
                                             userInfo: nil).raise()
            }
        }
        if let raised {
            // Only a source that cannot be browsed is said in a sheet; the rest goes on.
            guard raised is UnavaliableDataNodeException else {
                raised.raise()
                return
            }
            browser.horos_beginSourcesAlertSheet(withTitle: NSLocalizedString("Sources", comment: ""), message: raised.reason)
            browser.sourceList.selectShownDatabase()
        }
    }

    /// Shows `database` behind the progress sheet of the current thread.
    func showWithProgress(_ database: DicomDatabase?) {
        let thread = Thread.current
        thread.name = NSLocalizedString("Opening database...", comment: "")
        thread.status = NSLocalizedString("Opening database...", comment: "")
        thread.supportsCancel = true
        let modal = thread.startModal(for: browser.window)
        browser.database = database
        modal?.invalidate()
    }

    // MARK: Opening on a thread of its own

    /// Opens the local database at `path` on a thread of its own, behind a
    /// progress sheet with a Cancel button, and shows it.
    @discardableResult
    func openLocal(path: String?, name: String?) -> Thread {
        open(.local(path: path, name: name), activity: NSLocalizedString("Loading database...", comment: ""),
             status: NSLocalizedString("Reading data...", comment: ""))
    }

    /// Opens the database another IsiX or OsiriX shares, as `openLocal` does.
    @discardableResult
    func openRemote(address: String?, port: Int, name: String?) -> Thread {
        open(.remote(address: address, port: port, name: name), activity: NSLocalizedString("Loading remote database...", comment: ""),
             status: nil)
    }

    /// The thread is not listed in the Activity window: the sheet shows it,
    /// with its name, its status and its Cancel button.
    private func open(_ request: OpenRequest, activity: String, status: String?) -> Thread {
        let window = browser.window
        return ActivityThread.startUnlisted(name: activity, configure: { thread in
            thread.supportsCancel = true
            if let status { thread.status = status }
            _ = thread.startModal(for: window)
        }) { [self] _ in
            DatabaseOpener.open(request, for: self)
        }
    }

    /// Opens the database on the current thread and hands it to the main
    /// thread, keeping the sheet up a second longer while the browser shows
    /// it. A failure selects the row of the database shown again and is said
    /// in a sheet, unless the user cancelled.
    private nonisolated static func open(_ request: OpenRequest, for opener: DatabaseOpener) {
        autoreleasepool {
            let raised = HorosObjCException.caught {
                let database: DicomDatabase?
                switch request {
                case .local(let path, let name):
                    if !FileManager.default.fileExists(atPath: path ?? "") {
                        var message = NSLocalizedString("The selected database's data was not found on your computer.", comment: "")
                        if SourceListRules.missingDatabaseMayBeOnDrive(path) {
                            message += " " + NSLocalizedString("If it is stored on an external drive? If so, please make sure the device in connected and on.", comment: "")
                        }
                        NSException(name: .genericException, reason: message, userInfo: nil).raise()
                    }
                    database = DicomDatabase(atPath: path, name: name)
                case .remote(let address, let port, let name):
                    database = RemoteDicomDatabase.database(forLocation: address, port: UInt(bitPattern: port), name: name, update: true)
                }
                let opened = OpenedDatabase(database: database)
                onMainRunLoop { opener.showLater(opened.database) }
                Thread.sleep(forTimeInterval: 1)
            }
            guard let raised else { return }
            let reason = raised.description
            let cancelled = reason.utf16.elementsEqual("Cancelled.".utf16)
            if !cancelled {
                BrowserObjC.log(raised, stack: true, "-[BrowserController(Sources) setDatabaseThread:]")
            }
            onMainRunLoop { opener.failed(reason: reason, cancelled: cancelled) }
        }
    }

    private func failed(reason: String, cancelled: Bool) {
        browser.sourceList.selectShownDatabase()
        guard !cancelled else { return }
        deferred.perform("complain", after: 0.1) { [browser] in
            browser.horos_beginSourcesAlertSheet(withTitle: NSLocalizedString("Error", comment: ""), message: reason)
        }
    }

    // MARK: Folders and files chosen by the user

    /// Shows the database of a folder, refusing a folder whose Database.sql is
    /// not a database index; on failure, the local database again.
    func openFolder(_ path: String?) {
        let thread = Thread.current
        thread.name = NSLocalizedString("Opening database...", comment: "")
        let modal = thread.startModal(for: browser.window)

        if let raised = HorosObjCException.caught({
            let indexPath = (DicomDatabase.baseDirPath(forPath: path) as NSString?)?.appendingPathComponent("Database.sql")
            if let indexPath, FileManager.default.fileExists(atPath: indexPath), !HorosIsDatabaseFile(indexPath) {
                NSException(name: .genericException, reason: "The selected folder contains an unrecognized database index.", userInfo: nil).raise()
            }
            guard let database = DicomDatabase(atPath: path) else {
                NSException(name: .genericException, reason: "DicomDatabase == nil", userInfo: nil).raise()
                return
            }
            browser.database = database
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController openDatabasePath:]")
            HorosAlertPanel.run(title: NSLocalizedString("IsiX DICOM Viewer Database", comment: ""),
                                message: NSLocalizedString("IsiX DICOM Viewer cannot read/create this file/folder. Permissions error?", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            browser.resetToLocalDatabase()
        }

        modal?.invalidate()
    }

    /// File > Open Database: an index file, or in the App Store build a folder.
    func chooseIndexFile() {
        let panel = NSOpenPanel()
        #if MACAPPSTORE
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        #else
        panel.allowedContentTypes = [UTType(filenameExtension: "sql")!]
        #endif
        if let sqlFilePath = browser.database?.sqlFilePath {
            panel.directoryURL = URL(fileURLWithPath: sqlFilePath)
        }

        panel.begin { [self] result in
            guard result == .OK, let url = panel.url,
                  BrowserObjC.literallyEqual(browser.database?.sqlFilePath, url.path) == false else { return }
            #if MACAPPSTORE
            if SandboxFileAccess.remember(url) && ForeignDatabaseChoice.confirmOpening(path: url.path) {
                openFolder(url.path)
            }
            #else
            browser.subSelectFilesAndFolders(toAdd: [url.path])
            #endif
        }
    }

    /// "Create a Database Folder" (`creating`) and "Open a Database Folder".
    func chooseFolder(creating: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if creating {
            panel.prompt = NSLocalizedString("Create", comment: "")
            panel.title = NSLocalizedString("Create a Database Folder", comment: "")
        } else {
            panel.prompt = NSLocalizedString("Open", comment: "")
            panel.title = NSLocalizedString("Open a Database Folder", comment: "")
        }
        if let base = browser.database?.baseDirPath {
            panel.directoryURL = URL(fileURLWithPath: (base as NSString).deletingLastPathComponent)
        }

        panel.begin { [self] result in
            guard result == .OK, let url = panel.url, SandboxFileAccess.remember(url) else { return }
            // A Horos database is opened only after the user has read what that
            // does to it, and then as itself, not as the folder holding it.
            guard var location = ForeignDatabaseChoice.confirmedPath(forChosenPath: url.path) else { return }
            #if !MACAPPSTORE
            if DatabaseLocation.isOwnDataDirectoryName((location as NSString).lastPathComponent) {
                location = (location as NSString).deletingLastPathComponent
            }
            let parent = (location as NSString).deletingLastPathComponent
            if (location as NSString).lastPathComponent == "DATABASE.noindex"
                && DatabaseLocation.isOwnDataDirectoryName((parent as NSString).lastPathComponent) {
                location = (parent as NSString).deletingLastPathComponent
            }
            #endif
            openFolder(location)
        }
    }

    /// Back to the local default database, unless it is the one shown.
    func resetToDefaultIfNeeded() {
        let defaultPath = DicomDatabase.baseDirPath(forMode: Int32(truncatingIfNeeded: preferences[DatabasePreferences.defaultDatabaseLocation]),
                                                    path: preferences[DatabasePreferences.defaultDatabaseLocationURL])
        if DefaultDatabase.needsReset(shown: browser.database?.baseDirPath, defaultPath: defaultPath) {
            browser.resetToLocalDatabase()
        }
    }
}
