/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase

// The state of the browser that the former class did not have, by what it is
// about. The former instance variables are fields of the browser itself
// (BrowserController.swift), where a plugin of the former SDK reads them; the
// extensions read both through the horos_ accessors of
// BrowserController+StateAccess.swift. A holder is not tied to the main
// actor: the thumbnails', search and import threads read and write some of
// these values under the locks their users take.

/// The thumbnails and the preview of the selection.
final class BrowserPreviewState: NSObject, @unchecked Sendable {
    /// Which window the preview is showing and why: a DICOM default, one
    /// computed from the pixels, or an adjustment a person made.
    @objc var previewWindowPolicy: PreviewWindowPolicy?
    /// One preview decode per burst of scroll events, not one per notch.
    var previewRedrawCoalescer: PreviewRedrawCoalescer?
    /// The load of the thumbnails in progress, cancelled by a new selection.
    var thumbnailLoad: ThumbnailLoad?
}

/// The study list: the row last selected, of whatever class the list shows.
final class BrowserStudyListState: NSObject, @unchecked Sendable {
    var previousItem: Any?
}

/// The patient's history beside the thumbnails: the studies retrieved from
/// the nodes, so that a study is not retrieved twice at once. The distant
/// studies the list shows are kept by the process's PACSOnDemandSearch.
final class BrowserComparativeState: NSObject, @unchecked Sendable {
    let retrieves = DistantStudyRetrieves()
}

/// The albums: the catalog of the database's albums and their study counts,
/// local and on the nodes, when they are counted, and the refreshes an import
/// asks for.
final class BrowserAlbumState: NSObject, @unchecked Sendable {
    let catalog = DatabaseAlbumCatalog()
    let countScheduler = AlbumCountScheduler<DatabaseAlbumCounter>()
    var lastImportListRefresh: TimeInterval = 0
    var lastImportAlbumsRefresh: TimeInterval = 0
    var importListRefreshPending = false
    var importAlbumsRefreshPending = false
}

/// Deleting files: those removed from the database, waiting to be deleted
/// from the disk.
final class BrowserTransferState: NSObject, @unchecked Sendable {
    let deleteQueue = DatabaseDeleteQueue()
}

/// Opening viewers: why the last study asked for did not open; cleared when
/// one is selected.
final class BrowserViewerOpeningState: NSObject, @unchecked Sendable {
    @objc var lastStudyNotOpenedReason: String?
}

/// Key-value coding of the former instance variables that the browser does
/// not answer through a property of its own: the outlets and the values that
/// a binding of the window, a script or the diagnostic tools still read or
/// set by the name of the variable, with or without its leading underscore.
/// Swift's stored fields are not instance variables to look up by key.
enum BrowserFormerInstanceVariables {
    private static let names: Set<String> = [
        "toolbar", "splitDrawer", "splitComparative", "databaseOutline", "oMatrix", "albumTable",
        "bonjourSourcesBox", "sourcesTableView", "sourcesHelper", "animationSlider", "animationCheck", "imageView",
        "supOpenButtons", "password", "newAlbum", "newAlbumName", "estimatedTime", "warning", "modalityFilterMenu",
        "searchView", "searchField", "searchInEntireDBResult", "searchType", "imageTileMenu", "ZIPpasswordWindow",
        "CDpassword", "reportTemplatesView", "reportTemplatesImageView", "reportTemplatesListPopUpButton",
        "pluginManagerController", "activityTableView", "comparativeTable", "refreshDeferredWhileEditing",
        "previewWindowPolicy", "lastStudyNotOpenedReason"
    ]

    /// Whether a former instance variable of that name is read by key, and
    /// what it holds.
    static func read(_ name: String, of browser: BrowserController) -> (known: Bool, value: Any?) {
        switch name {
        case "toolbar": return (true, browser._toolbar)
        case "splitDrawer": return (true, browser._splitDrawer)
        case "splitComparative": return (true, browser._splitComparative)
        case "databaseOutline": return (true, browser._databaseOutline)
        case "oMatrix": return (true, browser._oMatrix)
        case "albumTable": return (true, browser._albumTable)
        case "bonjourSourcesBox": return (true, browser._bonjourSourcesBox)
        case "sourcesTableView": return (true, browser._sourcesTableView)
        case "sourcesHelper": return (true, browser._sourcesHelper)
        case "animationSlider": return (true, browser._animationSlider)
        case "animationCheck": return (true, browser._animationCheck)
        case "imageView": return (true, browser._imageView)
        case "supOpenButtons": return (true, browser._supOpenButtons)
        case "password": return (true, browser._password)
        case "newAlbum": return (true, browser._newAlbum)
        case "newAlbumName": return (true, browser._newAlbumName)
        case "estimatedTime": return (true, browser._estimatedTime)
        case "warning": return (true, browser._warning)
        case "modalityFilterMenu": return (true, browser._modalityFilterMenu)
        case "searchView": return (true, browser._searchView)
        case "searchField": return (true, browser._searchField)
        case "searchInEntireDBResult": return (true, browser._searchInEntireDBResult)
        case "searchType": return (true, browser._searchType)
        case "imageTileMenu": return (true, browser._imageTileMenu)
        case "ZIPpasswordWindow": return (true, browser._ZIPpasswordWindow)
        case "CDpassword": return (true, browser._CDpassword)
        case "reportTemplatesView": return (true, browser._reportTemplatesView)
        case "reportTemplatesImageView": return (true, browser._reportTemplatesImageView)
        case "reportTemplatesListPopUpButton": return (true, browser._reportTemplatesListPopUpButton)
        case "pluginManagerController": return (true, browser._pluginManagerController)
        case "activityTableView": return (true, browser.activityTableViewOutlet)
        case "comparativeTable": return (true, browser._comparativeTable)
        case "refreshDeferredWhileEditing": return (true, browser._refreshDeferredWhileEditing)
        case "previewWindowPolicy": return (true, browser.previewState.previewWindowPolicy)
        case "lastStudyNotOpenedReason": return (true, browser.viewerOpeningState.lastStudyNotOpenedReason)
        default: return (false, nil)
        }
    }

    /// Sets the former instance variable of that name, observers of `key`
    /// told; false when none of that name is set by key.
    static func write(_ value: Any?, to name: String, notifying key: String, of browser: BrowserController) -> Bool {
        guard names.contains(name) else { return false }
        browser.willChangeValue(forKey: key)
        defer { browser.didChangeValue(forKey: key) }
        switch name {
        case "toolbar": browser._toolbar = value as? NSToolbar
        case "splitDrawer": browser._splitDrawer = value as? NSSplitView
        case "splitComparative": browser._splitComparative = value as? NSSplitView
        case "databaseOutline": browser._databaseOutline = value as? MyOutlineView
        case "oMatrix": browser._oMatrix = value as? BrowserMatrix
        case "albumTable": browser._albumTable = value as? NSTableView
        case "bonjourSourcesBox": browser._bonjourSourcesBox = value as? NSBox
        case "sourcesTableView": browser._sourcesTableView = value as? NSTableView
        case "sourcesHelper": browser._sourcesHelper = value.map { $0 as AnyObject }
        case "animationSlider": browser._animationSlider = value as? NSSlider
        case "animationCheck": browser._animationCheck = value as? NSButton
        case "imageView": browser._imageView = value as? PreviewView
        case "supOpenButtons": browser._supOpenButtons = value as? NSMatrix
        case "password": browser._password = value as? NSTextField
        case "newAlbum": browser._newAlbum = value as? NSWindow
        case "newAlbumName": browser._newAlbumName = value as? NSTextField
        case "estimatedTime": browser._estimatedTime = value as? NSTextField
        case "warning": browser._warning = value as? NSTextField
        case "modalityFilterMenu": browser._modalityFilterMenu = value as? NSPopUpButton
        case "searchView": browser._searchView = value as? NSView
        case "searchField": browser._searchField = value as? NSSearchField
        case "searchInEntireDBResult": browser._searchInEntireDBResult = value as? NSButton
        case "searchType": browser._searchType = (value as? NSNumber)?.int32Value ?? 0
        case "imageTileMenu": browser._imageTileMenu = value as? NSMenu
        case "ZIPpasswordWindow": browser._ZIPpasswordWindow = value as? NSWindow
        case "CDpassword": browser._CDpassword = value as? NSString
        case "reportTemplatesView": browser._reportTemplatesView = value as? NSView
        case "reportTemplatesImageView": browser._reportTemplatesImageView = value as? NSImageView
        case "reportTemplatesListPopUpButton": browser._reportTemplatesListPopUpButton = value as? NSPopUpButton
        case "pluginManagerController": browser._pluginManagerController = value as? PluginManagerController
        case "activityTableView": browser.activityTableViewOutlet = value as? NSTableView
        case "comparativeTable": browser._comparativeTable = value as? NSTableView
        case "refreshDeferredWhileEditing": browser._refreshDeferredWhileEditing = (value as? NSNumber)?.boolValue ?? false
        case "previewWindowPolicy": browser.previewState.previewWindowPolicy = value as? PreviewWindowPolicy
        case "lastStudyNotOpenedReason": browser.viewerOpeningState.lastStudyNotOpenedReason = value as? String
        default: break
        }
        return true
    }
}

/// The instance variables that only older headers of the former Horos and
/// OsiriX plugin SDK declared, and whose state the application keeps
/// elsewhere today: in the database shown, in the controllers of the sheets
/// and windows the browser opens, in the preferences. Each is a field of the
/// browser (BrowserController.swift) that a plugin built with such a header
/// reads at the offset the application exports; this writes them wherever
/// that state changes, and nothing of the application reads them.
final class BrowserOlderInstanceVariables: NSObject, @unchecked Sendable {
    private weak var browser: BrowserController?
    /// The database whose context and time of modification are observed,
    /// under `lock`.
    private var observed: DicomDatabase?
    private let lock = NSLock()
    private static let contextKey = "managedObjectContext", modificationKey = "timeOfLastModification"
    private static let downloadKey = "downloadingIndexOfOlderSDK"
    /// Told when a shared database has opened a new index, which is when it
    /// makes the timer of its updates.
    private var contextChange: NSObjectProtocol?

    /// `database` is the one the browser shows from now on: the variables of
    /// the database follow it. Its context and the time it was last modified
    /// are observed: a database may replace its context while it is shown,
    /// and whoever adds files to it, on any thread, sets that time.
    func show(_ database: DicomDatabase?, in browser: BrowserController) {
        lock.lock()
        self.browser = browser
        let previous = observed
        observed = database
        lock.unlock()
        if previous !== database {
            previous?.removeObserver(self, forKeyPath: Self.contextKey)
            previous?.removeObserver(self, forKeyPath: Self.modificationKey)
            if previous is RemoteDicomDatabase { previous?.removeObserver(self, forKeyPath: Self.downloadKey) }
            database?.addObserver(self, forKeyPath: Self.contextKey, options: [], context: nil)
            database?.addObserver(self, forKeyPath: Self.modificationKey, options: [], context: nil)
            if database is RemoteDicomDatabase { database?.addObserver(self, forKeyPath: Self.downloadKey, options: [], context: nil) }
            followUpdates(of: database as? RemoteDicomDatabase, in: browser)
        }

        browser._database = database
        writeContext(of: database, in: browser)
        let isLocal = database?.isLocal() ?? false
        browser._currentDatabasePath = database?.baseDirPath as NSString?
        browser._isCurrentDatabaseBonjour = !isLocal
        browser._databaseLastModification = database?.timeOfLastModification ?? 0
        writeUpdates(of: database as? RemoteDicomDatabase, in: browser)
        browser._autoroutingQueueTimer = DatabaseRouting.process.drainsTimer

        // The folders of the active local database: a local database that
        // is shown becomes the active one; one that is not local, or none,
        // leaves the active one, and these, as they are. The active database
        // is not asked for here, which would open the default one before a
        // first launch has chosen where it is.
        guard isLocal, let local = database else { return }
        browser._checkIncomingLock = local.importFilesFromIncomingDirLock
        browser._decompressArray = local.horos_decompressQueue
        browser._fixedDocumentsDirectory = local.baseDirPath as NSString?
        let incoming = local.incomingDirPathC()
        Self.copy(local.baseDirPathC(), to: &browser._cfixedDocumentsDirectory)
        Self.copy(incoming, to: &browser._cfixedIncomingDirectory)
        Self.copy(local.tempDirPathC(), to: &browser._cfixedTempNoIndexDirectory)
        Self.copy(incoming, to: &browser._cfixedIncomingNoIndexDirectory)
    }

    private func writeContext(of database: DicomDatabase?, in browser: BrowserController) {
        let context: NSManagedObjectContext? = database?.managedObjectContext
        browser._managedObjectContext = context
        browser._managedObjectModel = database?.managedObjectModel
        browser._persistentStoreCoordinator = context?.persistentStoreCoordinator
        browser._bonjourManagedObjectContext = (database?.isLocal() ?? true) ? nil : context
        // The coordinators by the path of their store: of the database shown alone.
        let coordinators = NSMutableDictionary()
        if let path = database?.sqlFilePath, let coordinator = context?.persistentStoreCoordinator { coordinators[path] = coordinator }
        browser._persistentStoreCoordinatorDictionary = coordinators
    }

    /// The timer and the lock of the updates of a shared database, and
    /// whether its index is being downloaded: nil and NO for a local one.
    private func writeUpdates(of remote: RemoteDicomDatabase?, in browser: BrowserController) {
        let updates = remote?.updatesOfOlderSDK
        browser._bonjourTimer = updates?.timer
        browser._checkBonjourUpToDateThreadLock = updates?.lock
        browser._bonjourDownloading = remote?.downloadingIndexOfOlderSDK ?? false
    }

    /// A shared database makes the timer of its updates on the main thread,
    /// right after it tells that it has opened a new index: the copies are
    /// written again on the turn of the main queue that follows.
    private func followUpdates(of remote: RemoteDicomDatabase?, in browser: BrowserController) {
        if let contextChange { NotificationCenter.default.removeObserver(contextChange) }
        contextChange = remote.map { remote in
            NotificationCenter.default.addObserver(forName: .OsirixDicomDatabaseDidChangeContext, object: remote, queue: nil) { [weak self, weak browser] notice in
                // The database is found again on the main queue, from the
                // browser, by its identity: the object itself does not cross.
                let changed = (notice.object as AnyObject?).map(ObjectIdentifier.init)
                DispatchQueue.main.async {
                    guard let self, let browser, let remote = browser.horos_databaseIvar as? RemoteDicomDatabase,
                          ObjectIdentifier(remote) == changed else { return }
                    self.writeUpdates(of: remote, in: browser)
                }
            }
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        lock.lock()
        let browser = self.browser, database = observed
        lock.unlock()
        guard let browser, let database, database === (object as AnyObject?) else { return }
        if keyPath == Self.contextKey {
            writeContext(of: database, in: browser)
        } else if keyPath == Self.modificationKey {
            browser._databaseLastModification = database.timeOfLastModification
        } else if keyPath == Self.downloadKey {
            browser._bonjourDownloading = (database as? RemoteDicomDatabase)?.downloadingIndexOfOlderSDK ?? false
        }
    }

    deinit {
        observed?.removeObserver(self, forKeyPath: Self.contextKey)
        observed?.removeObserver(self, forKeyPath: Self.modificationKey)
        if observed is RemoteDicomDatabase { observed?.removeObserver(self, forKeyPath: Self.downloadKey) }
        if let contextChange { NotificationCenter.default.removeObserver(contextChange) }
    }

    /// A C string into the bytes a path keeps inside the browser, cut to
    /// their size; an empty string for none.
    private static func copy(_ path: UnsafePointer<CChar>?, to field: inout IsiXBrowserDirectoryPath) {
        withUnsafeMutableBytes(of: &field) { bytes in
            guard let start = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            if let path { strlcpy(start, path, bytes.count) } else { start.pointee = 0 }
        }
    }

    // MARK: The database of the web portal's users

    /// The model of the users' database, which is the web portal's, and the
    /// variable the browser had for it.
    @MainActor static func userModel(of browser: BrowserController) -> NSManagedObjectModel? {
        let model = WebPortal.default()?.database?.managedObjectModel
        browser._userManagedObjectModel = model
        return model
    }

    /// The context of the users' database and its store coordinator, likewise.
    @MainActor static func userContext(of browser: BrowserController) -> NSManagedObjectContext? {
        let context: NSManagedObjectContext? = WebPortal.default()?.database?.managedObjectContext
        browser._userManagedObjectContext = context
        browser._userPersistentStoreCoordinator = context?.persistentStoreCoordinator
        return context
    }

    // MARK: The window and what it opens

    /// The formatters of the dates and of the numbers, which are the
    /// preferences' and the class's, the window, which is the window
    /// controller's, and the publisher of the shared database, which is the
    /// application's: written when the browser sets its own formatters, as
    /// its nib awakes and whenever the format of the dates changes.
    @MainActor static func formattersSet(by browser: BrowserController) {
        browser._DateTimeFormat = UserDefaults.dateTimeFormatter()
        browser._DateOfBirthFormat = UserDefaults.dateFormatter()
        browser._numFmt = BrowserController.horos_decimalNumberFormatter
        browser._mainWindow = browser.window
        browser._bonjourPublisher = PreferencesSource.process.processGraph.bonjourPublisher
        browser._autoroutingQueueTimer = DatabaseRouting.process.drainsTimer
    }

    /// The publisher of the shared database as the application adopts it,
    /// which may be after the browser's nib awoke.
    @MainActor static func adopted(_ publisher: BonjourPublisher) {
        BrowserClassState.current?._bonjourPublisher = publisher
    }

    /// The pop-up button of the time intervals, inside the view the nib
    /// connects: bound to timeIntervalType, with no outlet of its own.
    @MainActor static func popUpButton(in view: NSView?) -> NSPopUpButton? {
        guard let view else { return nil }
        if let button = view as? NSPopUpButton { return button }
        for subview in view.subviews {
            if let button = popUpButton(in: subview) { return button }
        }
        return nil
    }

    /// The panel of the custom time interval, shared by the process, and its
    /// four date pickers: written when the browser reads the interval off it.
    @MainActor static func customIntervalPanel(_ panel: CustomIntervalPanel?, readBy browser: BrowserController) {
        // Not the window itself, which would load the nib of a panel that has not shown it yet.
        browser._customTimeIntervalWindow = panel?.fromPicker?.window
        browser._customStart = panel?.fromPicker
        browser._customEnd = panel?.toPicker
        browser._customStart2 = panel?.textualFromPicker
        browser._customEnd2 = panel?.textualToPicker
    }

    /// The sheet of a send, which a controller of its own shows: its window,
    /// the choice of the images, the transfer syntaxes and the count of the
    /// images, for the browser of the process.
    @MainActor static func sendSheetLoaded(_ window: NSWindow?, keyImages: NSMatrix?, syntaxes: NSPopUpButton?, count: NSTextField?,
                                           of graph: BrowserWindowGraph?) {
        let browser = graph?.browser
        browser?._serverWindow = window
        browser?._keyImageMatrix = keyImages
        browser?._syntaxListOffis = syntaxes
        browser?._noImages = count
    }

    /// The files of a send, which are its controller's: with the browser
    /// while the sheet is open or the send is made, nil once it ends or is
    /// queued. They are taken away as the sheet ends, and its window and
    /// controls with them: the browser shows one send sheet at a time, and
    /// keeps no object of one that is closed.
    @MainActor static func send(files: [Any]?, of graph: BrowserWindowGraph?) {
        graph?.browser._files2Send = files.map { NSMutableArray(array: $0) }
        if files == nil { sendSheetLoaded(nil, keyImages: nil, syntaxes: nil, count: nil, of: graph) }
    }

    /// The destination a send is queued for, which is its controller's; the
    /// files leave the browser with it.
    @MainActor static func send(destination: [AnyHashable: Any]?, of graph: BrowserWindowGraph?) {
        graph?.browser._destinationServer = destination as NSDictionary?
        graph?.browser._files2Send = nil
    }

    /// The sheet of a smart album, which a controller of its own shows: its
    /// window, the field of the name and the editor of the rules; all nil as
    /// the sheet ends.
    @MainActor static func smartAlbumSheetLoaded(_ window: NSWindow?, name: NSTextField?, editor: NSPredicateEditor?,
                                                 in browser: BrowserController?) {
        browser?._smartWindow = window
        browser?._editSmartAlbum = window
        browser?._editSmartAlbumName = name
        browser?._editSmartAlbumPredicate = editor
    }
}
