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
import UniformTypeIdentifiers

// The browser's database: switching to another one, the notifications of the
// database shown, the refreshes they cause (throttled during an import), the
// study asked for by a viewer, a link or a plugin, and the deprecated
// accessors of the database's contexts. -setDatabase:, the property's setter
// (BrowserController.swift), hands the switch to -horos_switchToDatabase:. The selectors are those of the former
// Objective-C methods.

extension BrowserController {

    // MARK: Switching databases

    @objc(resetToLocalDatabase)
    func resetToLocalDatabase() {
        self.database = DicomDatabase.activeLocal()
    }

    /// Forgets everything the browser holds of the database it is leaving.
    @objc(willChangeContext)
    func willChangeContext() {
        waitForRunningProcesses()

        BrowserObjC.synchronized(horos_previewPixThumbnails) {
            horos_matrixLoadIconsThread?.cancel()
            horos_matrixLoadIconsThread = nil
        }

        self.comparativePatientUID = nil
        self.comparativeStudies = nil

        BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
            horos_smartAlbumDistantArray = nil
        }

        horos_outlineViewArray = nil

        horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles = nil
        horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects = nil
        horos_cachedFilesForDatabaseOutlineSelectionTreeObjects = nil
        horos_cachedFilesForDatabaseOutlineSelectionIndex = nil

        forgetROIsAndKeyImages()
        forgetCachedAlbums()

        horos_databaseOutline?.reloadData()
        horos_albumTable?.reloadData()
        horos_comparativeTable?.reloadData()
    }

    /// The ROIs and key images found for the selection, kept until the
    /// database changes.
    private func forgetROIsAndKeyImages() {
        horos_ROIsAndKeyImagesCache = nil
        horos_ROIsImagesCache = nil
        horos_KeyImagesCache = nil
        horos_lastROIsAndKeyImagesSelectedFiles = nil
        horos_lastROIsImagesSelectedFiles = nil
        horos_lastKeyImagesSelectedFiles = nil
    }

    /// -setDatabase:: closes the viewers, saves the database it leaves and
    /// shows `db` (which may be nil) in every list of the browser. Main thread.
    @objc(horos_switchToDatabase:)
    func horos_switchToDatabase(_ db: DicomDatabase?) {
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("setDatabase MUST be performed on MAIN thread")
        }
        guard horos_databaseIvar !== db else { return }

        let raised = BrowserObjC.attempt {
            (LogManager.currentLogManager() as? LogManager)?.resetLogs()

            willChangeValue(forKey: "database")

            saveLoadAlbumsSortDescriptors()
            waitForRunningProcesses()

            _ = horos_databaseIvar?.save(nil)
            horos_databaseIvar = nil

            willChangeContext()
            horos_reportFilesToCheck?.removeAllObjects()

            self.window?.display()

            DCMPix.purgeCachedDictionaries()
            DCMView.purgeStringTextureCache()

            resetLogWindowController()
            AppController.shared()?.closeAllViewers(self)

            _ = BrowserObjC.attempt {
                if UserDefaults.standard.bool(forKey: "clearSearchAndTimeIntervalWhenSelectingAlbum") {
                    showEntireDatabase()
                }
            }

            horos_databaseIvar = db
            // Our own 'clean' managed object context, used by no other thread.
            db?.renewManagedObjectContext()

            if let db, UserDefaults.canActivateAnyLocalDatabase() && db.isLocal() && !db.isReadOnly {
                DicomDatabase.setActiveLocal(db)
            }
            Monochrome1Thumbnails.rebuildOnce(in: db)
            if db != nil {
                selectCurrentDatabaseSource()
            }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(_observeDatabaseAddNotification(_:)),
                               name: ._O2AddToDBAnyway, object: db)
            center.addObserver(self, selector: #selector(_observeDatabaseDidChangeContextNotification(_:)),
                               name: .OsirixDicomDatabaseDidChangeContext, object: db)
            center.addObserver(self, selector: #selector(_observeDatabaseInvalidateAlbumsCacheNotification(_:)),
                               name: .O2DatabaseInvalidateAlbumsCache, object: db)
            center.addObserver(self, selector: #selector(_newStudiesRefreshComparativeStudies(_:)),
                               name: .OsirixAddNewStudiesDB, object: db)

            horos_albumTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            saveLoadAlbumsSortDescriptors()

            BrowserObjC.synchronized(horos_albumNoOfStudiesCache) {
                horos_albumNoOfStudiesCache?.removeAllObjects()
                horos_distantAlbumNoOfStudiesCache?.removeAllObjects()
            }

            N2ManagedObjectContextPerformAndWait(db?.managedObjectContext) {
                if let exception = BrowserObjC.attempt({ showDatabaseInEveryList() }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController setDatabase:]")
                }
            }

            (LogManager.currentLogManager() as? LogManager)?.resetLogs()
        }
        didChangeValue(forKey: "database")
        raised?.raise()
    }

    /// Reloads every list of the browser from the database just shown.
    private func showDatabaseInEveryList() {
        horos_databaseOutline?.reloadData()
        horos_albumTable?.reloadData()
        horos_comparativeTable?.reloadData()

        self.window?.display()
        setDBWindowTitle()
        refreshPACSOnDemandResults(self)

        setNetworkLogs()
        outlineViewRefresh()
        refreshMatrix(self)
        refreshAlbums()

        if let query = QueryController.current() {
            query.refresh(self)
        } else if let query = QueryController.currentAuto() {
            query.refresh(self)
        }
    }

    @objc(openDatabase:)
    func openDatabase(_ sender: Any!) {
        let panel = NSOpenPanel()
        #if MACAPPSTORE
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        #else
        panel.allowedContentTypes = [UTType(filenameExtension: "sql")!]
        #endif
        if let sqlFilePath = self.database?.sqlFilePath {
            panel.directoryURL = URL(fileURLWithPath: sqlFilePath)
        }

        panel.begin { result in
            guard result == .OK, let url = panel.url,
                  BrowserObjC.literallyEqual(self.database?.sqlFilePath, url.path) == false else { return }
            #if MACAPPSTORE
            if SandboxFileAccess.remember(url) && ForeignDatabaseChoice.confirmOpening(path: url.path) {
                self.openDatabasePath(url.path)
            }
            #else
            self.subSelectFilesAndFolders(toAdd: [url.path])
            #endif
        }
    }

    /// "Create a Database Folder" (tag 1) and "Open a Database Folder".
    @objc(createDatabaseFolder:)
    func createDatabaseFolder(_ sender: Any!) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if ((sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0) == 1 {
            panel.prompt = NSLocalizedString("Create", comment: "")
            panel.title = NSLocalizedString("Create a Database Folder", comment: "")
        } else {
            panel.prompt = NSLocalizedString("Open", comment: "")
            panel.title = NSLocalizedString("Open a Database Folder", comment: "")
        }
        if let base = self.database?.baseDirPath {
            panel.directoryURL = URL(fileURLWithPath: (base as NSString).deletingLastPathComponent)
        }

        panel.begin { result in
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
            self.openDatabasePath(location)
        }
    }

    /// Every study: no time interval, modality, album or search.
    @objc(showEntireDatabase)
    func showEntireDatabase() {
        self.timeIntervalType = 0
        self.modalityFilter = nil
        horos_albumTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        self.searchString = ""
    }

    /// The window's title is the database's name; it represents the database
    /// folder, or the source of a temporary or remote database.
    @objc(setDBWindowTitle)
    func setDBWindowTitle() {
        let database = horos_databaseIvar
        self.window?.title = database?.name ?? ""

        let base = (database?.baseDirPath ?? "") as NSString
        let temporary = database != nil && (base.hasPrefix("/tmp/") || base.hasPrefix(FileManager.default.tmpDirPath()))
        if temporary || (database?.isLocal() ?? false) == false {
            let source = database?.sourcePath ?? ""
            self.window?.representedFilename = (source as NSString).length > 0 ? source : ""
        } else {
            self.window?.representedFilename = database?.baseDirPath ?? ""
        }
    }

    // MARK: Notifications of the database

    /// Files were added to the database: on the main thread, the lists are
    /// refreshed (throttled during an import) and the comparative studies
    /// that are now complete locally are swapped in.
    @objc(_observeDatabaseAddNotification:)
    nonisolated func _observeDatabaseAddNotification(_ notification: NSNotification!) {
        if self.database == nil { return }
        guard Thread.isMainThread else {
            performSelector(onMainThread: #selector(_observeDatabaseAddNotification(_:)), with: notification, waitUntilDone: false,
                            modes: [RunLoop.Mode.common.rawValue])
            return
        }
        nonisolated(unsafe) let added = notification
        MainActor.assumeIsolated {
            forgetROIsAndKeyImages()
            _refreshDatabaseDisplayAfterImport()
            let images = (added?.userInfo as NSDictionary?)?.value(forKey: OsirixAddToDBNotificationImagesArray) as AnyObject?
            checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: images?.value(forKeyPath: "series.study") as? [Any])
        }
    }

    /// A study arriving reloads the outline. Reloading it under someone typing
    /// in a comment tears down the field editor: the partial text and the
    /// insertion point go, and studies arrive one after another. The
    /// timer-driven -refreshDatabase: has always known to stay out of the way;
    /// the refresh waits for the edit to end.
    @objc(_refreshDatabaseDisplay)
    func _refreshDatabaseDisplay() {
        if let outline = horos_databaseOutline, outline.editedRow != -1 {
            horos_refreshDeferredWhileEditing = true
            return
        }
        horos_refreshDeferredWhileEditing = false
        outlineViewRefresh()
        refreshAlbums()
    }

    /// An import reports every batch it indexes. Each report refetched every
    /// study on the main thread and started an album count, both waiting on
    /// the importer's commits. During an import the list and the albums are
    /// refreshed at most every ImportRefreshSchedule interval; the first
    /// report of a quiet period is shown at once, and a trailing refresh shows
    /// the last batch of a burst.
    @objc(_refreshDatabaseDisplayAfterImport)
    func _refreshDatabaseDisplayAfterImport() {
        let now = Date.timeIntervalSinceReferenceDate
        if !horos_importListRefreshPending {
            let wait = ImportRefreshSchedule.wait(lastRefresh: horos_lastImportListRefresh, interval: ImportRefreshSchedule.listInterval, now: now)
            if wait <= 0 {
                _importListRefreshFire()
            } else {
                horos_importListRefreshPending = true
                perform(#selector(_importListRefreshFire), with: nil, afterDelay: wait, inModes: [.common])
            }
        }
        if !horos_importAlbumsRefreshPending {
            let wait = ImportRefreshSchedule.wait(lastRefresh: horos_lastImportAlbumsRefresh, interval: ImportRefreshSchedule.albumsInterval, now: now)
            if wait <= 0 {
                _importAlbumsRefreshFire()
            } else {
                horos_importAlbumsRefreshPending = true
                perform(#selector(_importAlbumsRefreshFire), with: nil, afterDelay: wait, inModes: [.common])
            }
        }
    }

    @objc(_importListRefreshFire)
    func _importListRefreshFire() {
        horos_importListRefreshPending = false
        horos_lastImportListRefresh = Date.timeIntervalSinceReferenceDate
        // The same deferral as -_refreshDatabaseDisplay: an edit in progress
        // keeps its field editor, and the end of the edit shows what arrived.
        if let outline = horos_databaseOutline, outline.editedRow != -1 {
            horos_refreshDeferredWhileEditing = true
            return
        }
        outlineViewRefresh()
    }

    @objc(_importAlbumsRefreshFire)
    func _importAlbumsRefreshFire() {
        horos_importAlbumsRefreshPending = false
        horos_lastImportAlbumsRefresh = Date.timeIntervalSinceReferenceDate
        refreshAlbums()
    }

    /// Called when an edit finishes, so that what arrived meanwhile is shown as
    /// soon as showing it can no longer take the editor away.
    @objc(_refreshDatabaseDisplayIfDeferred)
    func _refreshDatabaseDisplayIfDeferred() {
        if !horos_refreshDeferredWhileEditing { return }
        // Still editing: the next end of edit comes back here.
        if let outline = horos_databaseOutline, outline.editedRow != -1 { return }
        _refreshDatabaseDisplay()
    }

    @objc(_observeDatabaseDidChangeContextNotification:)
    nonisolated func _observeDatabaseDidChangeContextNotification(_ notification: NSNotification!) {
        guard Thread.isMainThread else {
            performSelector(onMainThread: #selector(_observeDatabaseDidChangeContextNotification(_:)), with: notification,
                            waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
            return
        }
        MainActor.assumeIsolated {
            outlineViewRefresh()
            refreshAlbums()
        }
    }

    @objc(_observeDatabaseInvalidateAlbumsCacheNotification:)
    nonisolated func _observeDatabaseInvalidateAlbumsCacheNotification(_ notification: NSNotification!) {
        forgetCachedAlbums()
    }

    /// With PACS On-Demand, a comparative study of the patient shown that is
    /// now in the database with at least as many images as on the node is
    /// listed as the local study. Without studies, the one selected.
    @objc(checkIfLocalStudyHasMoreOrSameNumberOfImagesOfADistantStudy:)
    func checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy studiesToCheck: [Any]!) {
        var studies = studiesToCheck as NSArray?
        if studies == nil, let outline = horos_databaseOutline {
            let row = outline.selectedRowIndexes.first ?? NSNotFound
            let item = row == NSNotFound ? nil : outline.item(atRow: row) as AnyObject?
            let selected = BrowserObjC.literallyEqual(item?.value(forKey: "type") as? String, "Study") ? item : item?.value(forKey: "study") as AnyObject?
            if let selected { studies = [selected] }
        }

        let patientStudies = NSMutableArray()
        for study in studies ?? [] {
            let object = study as AnyObject
            guard object !== NSNull(), !patientStudies.contains(study),
                  let patient = self.comparativePatientUID as NSString?,
                  let uid = object.value(forKey: "patientUID") as? String,
                  patient.compare(uid, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame else { continue }
            patientStudies.add(study)
        }

        guard patientStudies.count > 0, let comparatives = self.comparativeStudies as NSArray?, comparatives.count > 0 else { return }
        let updated = NSMutableArray(array: comparatives)
        var modified = false
        for case let distant as DCMTKStudyQueryNode in comparatives {
            var local: AnyObject?
            for candidate in patientStudies where BrowserObjC.literallyEqual((candidate as AnyObject).value(forKey: "studyInstanceUID") as? String,
                                                                            distant.value(forKey: "studyInstanceUID") as? String) {
                local = candidate as AnyObject
            }
            if let local = local as? DicomStudy, (local.rawNoFiles()?.intValue ?? 0) >= (distant.noFiles()?.intValue ?? 0) {
                modified = true
                updated.replaceObject(at: updated.index(of: distant), with: local)
            }
        }
        if modified {
            refreshComparativeStudies(updated as? [Any])
        }
    }

    // MARK: Selecting a study

    @objc(selectStudyWithObjectID:)
    func selectStudy(withObjectID oid: NSManagedObjectID!) {
        let object = self.database?.object(withID: oid) as AnyObject?
        var study: DicomStudy?
        if let object = object as? DicomStudy { study = object }
        if let object = object as? DicomSeries { study = object.value(forKey: "study") as? DicomStudy }
        if let object = object as? DicomImage { study = object.value(forKeyPath: "series.study") as? DicomStudy }
        if let study {
            _ = selectThisStudy(study)
        }
    }

    /// Every order from outside - XML-RPC, a horos:// link, a plugin - ends at
    /// -selectThisStudy:, and a NO from there used to be the whole story: no
    /// viewer, and nothing said why. The reason is kept for the caller.
    @discardableResult
    @objc(refuseToSelectStudy:reason:)
    func refuseToSelectStudy(_ study: NSManagedObject!, reason: String!) -> Bool {
        self.lastStudyNotOpenedReason = reason
        NSLog("%@%@", StudyNotOpenedReason.logPrefix(), reason ?? "(null)")
        return false
    }

    /// Selects the study in the list, switching to its database, and to the
    /// whole database when an album, a search or a time interval hides it.
    /// A local study or a study on a PACS node; NO, with the reason, when it
    /// cannot be listed.
    @discardableResult
    @objc(selectThisStudy:)
    func selectThisStudy(_ study: Any!) -> Bool {
        guard self.database != nil else {
            return refuseToSelectStudy(study as? NSManagedObject, reason: StudyNotOpenedReason.reasonForNoDatabase())
        }
        guard let study = study as AnyObject? else {
            return refuseToSelectStudy(nil, reason: StudyNotOpenedReason.reasonForNoStudy())
        }
        let managedStudy = study as? NSManagedObject
        let uid = study.value(forKey: "studyInstanceUID") as? String

        var answer: Bool?
        if let exception = BrowserObjC.attempt({ answer = selectListedStudy(study, uid: uid) }) {
            BrowserObjC.log(exception, "-[BrowserController selectThisStudy:]")
        }
        // Only an exception leaves no answer, and it does not mean the study is gone.
        return answer ?? refuseToSelectStudy(managedStudy, reason: StudyNotOpenedReason.reasonForErrorWhileSelecting())
    }

    private func selectListedStudy(_ study: AnyObject, uid: String?) -> Bool {
        let managedStudy = study as? NSManagedObject
        let outline = horos_databaseOutline
        let selectedRow = outline?.selectedRowIndexes.first ?? NSNotFound
        let item = selectedRow == NSNotFound ? nil : outline?.item(atRow: selectedRow) as AnyObject?
        let selected = BrowserObjC.literallyEqual(item?.value(forKey: "type") as? String, "Study") ? item : item?.value(forKey: "study") as AnyObject?
        if BrowserObjC.literallyEqual(uid, selected?.value(forKey: "studyInstanceUID") as? String) {
            return true
        }

        if let local = study as? DicomStudy {
            guard let studyCoordinator = local.managedObjectContext?.persistentStoreCoordinator else {
                return refuseToSelectStudy(local, reason: StudyNotOpenedReason.reasonForStudyOutsideAnyDatabase(uid))
            }
            // Another database is selected: select the study's.
            if studyCoordinator !== self.database?.managedObjectContext?.persistentStoreCoordinator {
                guard let database = DicomDatabase(for: local.managedObjectContext) else {
                    return refuseToSelectStudy(local, reason: StudyNotOpenedReason.reasonForUnknownDatabase(uid))
                }
                self.database = database
            }
        }

        // Rebuilt even in a hidden window: the study may have arrived since.
        refreshStudyList(whileHidden: true)
        var row = rowOfListedStudy(uid)

        let filtered = (horos_albumTable?.selectedRow ?? 0) > 0 || ((self.searchString as NSString?)?.length ?? 0) > 0 || self.timeIntervalType != 0
        if row == nil && filtered && study is DicomStudy {
            // A local study HAS to be found: the entire database is listed.
            showEntireDatabase()
            refreshStudyList(whileHidden: true)
            row = rowOfListedStudy(uid)
        }

        if let row, row != -1, let outline {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(outline.selectedRow)
            self.lastStudyNotOpenedReason = nil
            return true
        }

        // In the list is where a viewer is opened from, so a study that is in
        // the database and not in the list - imported a moment ago, or hidden
        // behind an album, a search or a date filter - stops here.
        return refuseToSelectStudy(managedStudy, reason: StudyNotOpenedReason.reasonForStudyNotListed(uid))
    }

    /// The outline's row of the listed study with this UID: a DicomStudy or a
    /// study on a node alike. Nil when it is not listed, -1 when listed with
    /// no row.
    private func rowOfListedStudy(_ uid: String?) -> Int? {
        guard let uid, let listed = horos_outlineViewArray as NSArray? else { return nil }
        let index = (listed.value(forKey: "studyInstanceUID") as? NSArray)?.index(of: uid) ?? NSNotFound
        guard index != NSNotFound else { return nil }
        return horos_databaseOutline?.row(forItem: listed.object(at: index)) ?? -1
    }

    // MARK: Deprecated accessors

    @available(*, deprecated)
    @objc(databaseLastModification)
    var databaseLastModification: TimeInterval {
        get { return self.database?.timeOfLastModification ?? 0 }
        set { self.database?.timeOfLastModification = newValue }
    }

    @available(*, deprecated)
    @discardableResult
    @objc(managedObjectModel)
    func managedObjectModel() -> NSManagedObjectModel! {
        return self.database?.managedObjectModel
    }

    @available(*, deprecated)
    @discardableResult
    @objc(localManagedObjectContextIndependentContext:)
    func localManagedObjectContextIndependentContext(_ independentContext: Bool) -> NSManagedObjectContext! {
        return DicomDatabase.activeLocal()?.independentContext(independentContext)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(localManagedObjectContext)
    func localManagedObjectContext() -> NSManagedObjectContext! {
        return localManagedObjectContextIndependentContext(false)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(defaultManagerObjectContext)
    func defaultManagerObjectContext() -> NSManagedObjectContext! {
        return defaultManagerObjectContextIndependentContext(false)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(defaultManagerObjectContextIndependentContext:)
    func defaultManagerObjectContextIndependentContext(_ independentContext: Bool) -> NSManagedObjectContext! {
        return DicomDatabase.default()?.independentContext(independentContext)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(managedObjectContext)
    func managedObjectContext() -> NSManagedObjectContext! {
        return managedObjectContextIndependentContext(false)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(managedObjectContextIndependentContext:)
    func managedObjectContextIndependentContext(_ independentContext: Bool) -> NSManagedObjectContext! {
        return managedObjectContextIndependentContext(independentContext, path: self.database?.baseDirPath)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(managedObjectContextIndependentContext:path:)
    func managedObjectContextIndependentContext(_ independentContext: Bool, path: String!) -> NSManagedObjectContext! {
        guard let path else { return nil }
        if BrowserObjC.literallyEqual(path, self.database?.baseDirPath) {
            return self.database?.independentContext(independentContext)
        }
        BrowserObjC.logStackTrace("******* __deprecated BrowserController managedObjectContextIndependentContext : unknown DicomDatabase")
        return DicomDatabase.existingDatabase(atPath: path)?.independentContext(independentContext)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(isBonjour:)
    func isBonjour(_ c: NSManagedObjectContext!) -> Bool {
        return !(DicomDatabase(for: c)?.isLocal() ?? false)
    }

    @available(*, deprecated)
    @objc(loadDatabase:)
    func loadDatabase(_ path: String!) {
        self.database = DicomDatabase(atPath: path)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(saveDatabase:context:)
    func saveDatabase(_ path: String!, context: NSManagedObjectContext!) -> Int {
        var error: NSError?
        _ = DicomDatabase(for: context)?.save(&error)
        return error?.code ?? 0
    }

    @available(*, deprecated)
    @discardableResult
    @objc(saveDatabase)
    func saveDatabase() -> Int {
        return saveDatabase(nil, context: self.database?.managedObjectContext)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(saveDatabase:)
    func saveDatabase(_ path: String!) -> Int {
        return saveDatabase(path, context: self.database?.managedObjectContext)
    }

    @available(*, deprecated)
    @objc(openDatabaseIn:Bonjour:)
    func openDatabase(in a: String!, bonjour isBonjour: Bool) {
        openDatabase(in: a, bonjour: isBonjour, refresh: false)
    }

    @available(*, deprecated)
    @objc(openDatabaseIn:Bonjour:refresh:)
    func openDatabase(in a: String!, bonjour isBonjour: Bool, refresh: Bool) {
        if isBonjour {
            NSException(name: .genericException, reason: "TODO do something smart :P", userInfo: nil).raise()
        }
        self.database = DicomDatabase(atPath: a)
    }

    @available(*, deprecated)
    @objc(openDatabaseInBonjour:)
    func openDatabaseInBonjour(_ path: String!) {
        openDatabase(in: path, bonjour: true, refresh: true)
    }

    /// The database folder of an index file, or the folder itself.
    @available(*, deprecated)
    @discardableResult
    @objc(getDatabaseFolderFor:)
    func getDatabaseFolder(for path: String!) -> String! {
        var isDirectory: ObjCBool = false
        guard let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return path }

        // An SQL file.
        if (path as NSString).pathExtension != "sql" { NSLog("**** No SQL extension ???") }
        let folder = (path as NSString).deletingLastPathComponent as NSString
        if let location = try? NSString(contentsOfFile: folder.appendingPathComponent("DBFOLDER_LOCATION"), usedEncoding: nil) {
            return location as String
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("DATABASE.noindex")) {
            return folder.deletingLastPathComponent
        }
        return ((self.database?.baseDirPath ?? "") as NSString).deletingLastPathComponent
    }

    /// The index file of a database folder, or the file itself.
    @available(*, deprecated)
    @discardableResult
    @objc(getDatabaseIndexFileFor:)
    func getDatabaseIndexFile(for path: String!) -> String! {
        var isDirectory: ObjCBool = false
        guard let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return path }
        let index = ((DatabaseLocation.existingDataDirectory(inFolder: path) ?? "") as NSString).appendingPathComponent("Database.sql")
        return FileManager.default.fileExists(atPath: index) ? index : nil
    }
}
