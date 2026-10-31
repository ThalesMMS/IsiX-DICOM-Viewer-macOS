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
import CoreData
import IsiXDatabase
import IsiXPreferences
import IsiXStorage
import Synchronization

// DicomDatabase is implemented in Swift under the interface DicomDatabase.h
// declares (@objc @implementation): this file holds its state, the registry of
// the databases by path, the default and the active local database, the
// initializer and the life cycle. Each category of the header is its own file:
//
//   DicomFileIndexer.swift              -addFilesAtPaths: and -addFilesDescribedInDictionaries:, which
//                                       forward to the indexer, DicomFileIndexer
//   IncomingAdmission.swift             the selectors of the scan of the incoming folder and its timer
//   DatabaseFileConversion.swift        the selectors of compression and decompression
//   MediaImportJob.swift                -copyFilesThread:, a folder or a medium copied in
//   ImportFeedback.swift                the refusals, the full volume and the notifications, which
//                                       forward to ImportFeedback and its ImportFeedbackLog
//
// What becomes of the files an import does not index is ImportDisposal. The
// numbers of the data files are DataFileAllocator, in IsiXStorage. The pure
// rules of the import are in IsiXDatabase (DatabaseImportRules.swift).
// DicomDatabase+CAPI.m keeps what Swift cannot write: the exported constants,
// -release, which takes the registry's lock, and the import's C helpers.
//
// The registry holds the databases without retaining them, as NSValues of their
// pointers. A lookup retains a database under the registry's lock, and its last
// -release (DicomDatabase+CAPI.m) holds the same lock, so a lookup can never
// find a database being deallocated: the first deinit to run removes it from
// the registry and leaves that lock before anything else (DicomDatabaseRegistry).
//
// An @try is HorosObjCException.caught, an
// @synchronized is HorosObjCException.synchronized on the same object. The
// methods run on any thread, as the Objective-C ones did.

/// The databases by base path, and by pointer for a second database of the
/// same path: NSValues of their pointers, not retained.
nonisolated(unsafe) private let databasesDictionary = NSMutableDictionary()

/// How a deallocated database leaves the registry. Its last -release holds the
/// registry's lock, and every lookup, +allDatabases and every other release of
/// a database wait for that lock. Swift runs the deinit of the most-derived
/// class first, and RemoteDicomDatabase's waits for an update of the shared
/// index in progress, which may need the main thread: each deinit therefore
/// calls leave(_:) first, so the database is out of the registry and the lock
/// left before any deinit waits for anything. The later calls do nothing.
enum DicomDatabaseRegistry {
    static func leave(_ database: DicomDatabase) {
        guard !database.leftRegistry else { return }
        database.leftRegistry = true
        let me = Unmanaged.passUnretained(database).toOpaque()
        var found = false
        for case let (key, value as NSValue) in NSDictionary(dictionary: databasesDictionary) where value.pointerValue == me {
            databasesDictionary.removeObject(forKey: key)
            found = true
        }
        if !found {
            // A database whose -initWithPath: threw - the usual cause is its volume
            // going away under it - never reached the registry, so this is a real
            // situation and not a mystery. Name it instead of logging a stack trace
            // under "WTF", which said nothing about what had happened.
            NSLog("---- database at %@ was released without ever being registered; it did not finish opening", database.storedBaseDirPath ?? "an unknown path")
        }

        #if DEBUG
        if databasesDictionary.count > 50 {
            NSLog("******** WARNING databasesDictionary.count is very high = %lu", UInt(databasesDictionary.count))
        }
        #endif

        DicomDatabaseRegistryUnlockForDealloc()
    }
}

/// +defaultDatabase, retained for the life of the application.
private let defaultDatabaseInstance = DatabaseSlot()
/// +activeLocalDatabase, retained.
private let activeLocalDatabaseInstance = DatabaseSlot()
/// The location +baseDirPathForMode:path: said last.
private let lastReportedLocation = Mutex<String?>(nil)
/// The observer of OsirixCanActivateDefaultDatabaseOnlyDefaultsKey that
/// +initializeDicomDatabaseClass registers.
private let defaultDatabaseActivation = Mutex<DicomDatabaseDefaultActivation?>(nil)

/// A database kept for every thread, behind a lock that covers only the
/// reference: the default and the active local database of the process, and
/// the database a browser shows. Opening a database, posting a notification
/// and the last release of the one replaced all happen outside it: each runs
/// code that can come back here, or raise.
final class DatabaseSlot: Sendable {
    /// @unchecked Sendable: only the reference crosses threads here; what a
    /// database holds stays on the queue of its context.
    private struct Held: @unchecked Sendable {
        let database: DicomDatabase?
    }

    private let held = Mutex(Held(database: nil))

    var database: DicomDatabase? {
        held.withLock { $0 }.database
    }

    /// What the slot held goes after the lock is left: the last release of a
    /// database saves its context and posts.
    func replace(with database: DicomDatabase?) {
        withExtendedLifetime(exchange(with: database)) {}
    }

    /// Puts `database` in the slot and answers what it held, for the caller
    /// to release outside the lock.
    func exchange(with database: DicomDatabase?) -> DicomDatabase? {
        let new = Held(database: database)
        return held.withLock { current in
            let replaced = current
            current = new
            return replaced
        }.database
    }
}

/// The three C paths the DICOM listener reads: a zeroed buffer of 4096 bytes
/// for each, as the former instance variables were, for the life of the database.
final class DicomDatabaseListenerPaths {
    static let capacity = 4096
    let baseDirPath = DicomDatabaseListenerPaths.buffer()
    let incomingDirPath = DicomDatabaseListenerPaths.buffer()
    let tempDirPath = DicomDatabaseListenerPaths.buffer()

    private static func buffer() -> UnsafeMutablePointer<CChar> {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        return buffer
    }

    /// strncpy(buffer, path.fileSystemRepresentation, 4096), or "" for no path.
    static func copy(_ path: String?, into buffer: UnsafeMutablePointer<CChar>) {
        if let path {
            strncpy(buffer, (path as NSString).fileSystemRepresentation, capacity)
        } else {
            buffer[0] = 0
        }
    }

    deinit {
        baseDirPath.deallocate()
        incomingDirPath.deallocate()
        tempDirPath.deallocate()
    }
}

extension DicomDatabaseObjC {
    /// N2LocalizedSingularPluralCount(count, singular, plural) of N2Stuff.h.
    static func localizedCount(_ count: Int, _ singular: String, _ plural: String) -> String {
        return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), count == 1 ? singular : plural)
    }

    /// N2LocalizedSingularPluralCount(count, NSLocalizedString(@"file", nil), NSLocalizedString(@"files", nil)).
    static func localizedFileCount(_ count: Int) -> String {
        return localizedCount(count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
    }

    /// `[array addObject:object]`: nothing for a nil array, an exception for a nil object.
    static func add(_ object: Any?, to array: NSMutableArray?) {
        guard let array else { return }
        if let object { array.add(object) } else { _ = array.perform(#selector(NSMutableArray.add(_:)), with: nil) }
    }
}

/// The window shown on the main thread while the default database is erased at launch.
@MainActor private func erasingDatabaseWindow() -> WaitRendering? {
    let shown: WaitRendering? = WaitRendering(NSLocalizedString("Erase Entire Database...", comment: ""))
    shown?.showWindow(DicomDatabase.self)
    return shown
}

/// Activates the default database when the preferences allow only it: what
/// the class itself observed, registered by +initializeDicomDatabaseClass.
private final class DicomDatabaseDefaultActivation: NSObject, @unchecked Sendable {
    /// The observation's own context: the observer's address, which no other
    /// observation of the controller uses and which stays while it observes.
    private var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    override init() {
        super.init()
        NSUserDefaultsController.shared.addObserver(self, forValuesKey: OsirixCanActivateDefaultDatabaseOnlyDefaultsKey,
                                                    options: .initial, context: context)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == self.context else { return }
        if keyPath == valuesKeyPath(OsirixCanActivateDefaultDatabaseOnlyDefaultsKey), UserDefaults.canActivateOnlyDefaultDatabase() {
            DicomDatabase.setActiveLocal(DicomDatabase.default())
        }
    }
}

@objc @implementation extension DicomDatabase {

    // MARK: - State

    final var storedBaseDirPath: String?
    final var storedDataBaseDirPath: String?
    /// The name given, without the default -name makes of the path, which
    /// RemoteDicomDatabase overrides.
    final var assignedName: String?
    final var storedSourcePath: String?
    /// The numbers of the data files; a main database shares its own with its independent databases.
    final let dataFileAllocator: DataFileAllocator
    /// Held while files are compressed or decompressed; shared with the independent databases.
    final var processFilesLock: NSRecursiveLock?
    /// Held while the incoming folder is imported; shared with the independent databases.
    final var importFilesFromIncomingDirLock: NSRecursiveLock?
    /// What a diagnostic probe leaves for ConversionQueue, under their own
    /// @synchronized; shared with the independent databases.
    final var horos_compressQueue: NSMutableArray?
    final var horos_decompressQueue: NSMutableArray?
    final var timeOfLastFreeSizeVerification: TimeInterval = 0
    final var freeSizeLimitReached = false
    /// What the imports refused and whether the full volume was said; the
    /// main database shares it with its independent databases.
    final let importFeedbackLog: ImportFeedbackLog
    // DicomDatabase+Clean.swift: the main database shares it with its
    // independent databases.
    final var cleanLock: NSRecursiveLock?
    final let listenerPaths = DicomDatabaseListenerPaths()
    /// One import writes at a time; the main database shares it with its independent databases.
    final let databaseWriterGate: DatabaseWriterGate
    /// Set by the first deinit to run, once the database is out of the registry.
    final var leftRegistry = false

    var timeOfLastModification: TimeInterval = 0
    var isReadOnly: Bool = false
    var hasPotentiallySlowDataAccess: Bool = false

    var baseDirPath: String! {
        storedBaseDirPath
    }

    var dataBaseDirPath: String! {
        storedDataBaseDirPath
    }

    var name: String! {
        get { assignedName ?? String(format: NSLocalizedString("Local Database (%@)", comment: ""), DicomDatabaseObjC.arg(self.baseDirPath)) }
        set { assignedName = newValue }
    }

    var sourcePath: String! {
        get { storedSourcePath }
        set { storedSourcePath = newValue }
    }

    // MARK: - Class

    class func initializeDicomDatabaseClass() {
        // Made outside the lock: it observes with .initial, so making it can
        // open the default database and activate it.
        let activation = DicomDatabaseDefaultActivation()
        defaultDatabaseActivation.withLock { $0 = activation }
    }

    class func baseDirPath(forPath path: String!) -> String! {
        // A folder that carries the data directory's name only when it has not been
        // renamed; a backup usually has been. HorosDatabaseLocation also recognises
        // a folder by the index inside it, and the index file itself.
        return DatabaseLocation.baseDirectory(forPath: path)
    }

    class func baseDirPath(forMode mode: Int32, path: String!) -> String! {
        var path: String? = path
        switch mode {
        case 0:
            path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            #if MACAPPSTORE
            path = FileManager.default.userApplicationSupportFolderForApp()
            #endif
        case 1:
            break
        default:
            path = nil
        }

        path = self.baseDirPath(forPath: path)
        guard let path else {
            DicomDatabaseObjC.logError("nil path", "+[DicomDatabase baseDirPathForMode:path:]")
            return nil
        }
        let pathSeparated = path.components(separatedBy: "/")
        if pathSeparated.count >= 3 {
            let volPath = pathSeparated[0..<3].joined(separator: "/")
            if path.hasPrefix("/Volumes/") && !FileManager.default.fileExists(atPath: volPath) {
                return nil // not mounted
            }
        }

        // Reopening a database that moved and creating one are different events,
        // and the folder that was chosen is not always the one that ends up
        // being used. Say which, once, where the location is decided.
        let existing = DatabaseLocation.pathHoldsExistingDatabase(path)
        FileManager.default.confirmDirectory(atPath: path)
        // This is asked repeatedly for the same location; say it when it changes.
        let changed = lastReportedLocation.withLock { reported in
            if DicomDatabaseObjC.isEqual(reported, path) { return false }
            reported = path
            return true
        }
        if changed {
            NSLog("---- database location: %@ (%@)", path, existing ? "opening the database already there" : "no index there yet; a new database will be created")
        }
        return path
    }

    class func defaultBaseDirPath() -> String! {
        var path: String? = nil
        if let exception = HorosObjCException.caught({
            let defaults = PreferencesSource.process.preferences
            path = self.baseDirPath(forMode: Int32(truncatingIfNeeded: defaults[DatabasePreferences.location].mode), path: defaults[DatabasePreferences.location].folder)
            if path == nil || !FileManager.default.fileExists(atPath: path!) { // STILL NOT AVAILABLE?? Use the default folder.. and reset this strange URL..
                defaults.set(0, for: DatabasePreferences.databaseLocation)
                defaults.set(0, for: DatabasePreferences.defaultDatabaseLocation)
                path = self.baseDirPath(forMode: Int32(truncatingIfNeeded: defaults[DatabasePreferences.location].mode), path: defaults[DatabasePreferences.location].folder)
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase defaultBaseDirPath]")
        }
        return path
    }

    // MARK: - Factory

    @objc(defaultDatabase)
    class func `default`() -> DicomDatabase! {
        // Nib loading can request the database before first-use setup is complete.
        if DatabaseFirstUse.hasPendingChoice { return nil }
        // One opening at a time: this lock is held while the database opens, which
        // can ask for the default database again on this thread. The slot's is not.
        HorosObjCException.synchronized(self as AnyObject) {
            if defaultDatabaseInstance.database == nil {
                let defaults = PreferencesSource.process.preferences
                // Shown only on the main thread, where it was made.
                var wait: WaitRendering? = nil

                if defaults[DatabasePreferences.erasesEntireDatabaseAtStartup] {
                    let databaseDir = (DicomDatabaseObjC.appending(self.defaultBaseDirPath(), "DATABASE.noindex") as NSString?)?.resolvingSymlinksAndAliases()

                    if Thread.isMainThread {
                        wait = MainActor.assumeIsolated { erasingDatabaseWindow() }
                    }

                    if let databaseDir {
                        try? FileManager.default.removeItem(atPath: databaseDir)
                        try? FileManager.default.createDirectory(atPath: databaseDir, withIntermediateDirectories: false, attributes: nil)
                    }
                }

                var dbName: String? = nil

                for source in defaults[DatabasePreferences.localDatabaseSources]?.sources ?? [] {
                    if DicomDatabaseObjC.isEqual(source.path, (self.defaultBaseDirPath() as NSString?)?.deletingLastPathComponent) {
                        dbName = source.name
                    }
                }

                if dbName == nil {
                    dbName = ((((self.defaultBaseDirPath() as NSString?)?.deletingLastPathComponent as NSString?)?.lastPathComponent) as NSString?)?
                        .appending(NSLocalizedString(" DB", comment: "DB = DataBase"))
                }

                let opened: DicomDatabase? = DicomDatabase(atPath: self.defaultBaseDirPath(), name: dbName)
                defaultDatabaseInstance.replace(with: opened)

                if defaults[DatabasePreferences.erasesEntireDatabaseAtStartup], let database = opened {
                    let studies = database.objects(forEntity: database.studyEntity()) as NSArray?

                    for case let study as DicomStudy in studies ?? [] {
                        database.managedObjectContext.delete(study)
                    }

                    _ = database.save(nil)
                }

                if let wait {
                    MainActor.assumeIsolated { wait.close() }
                }
            }
        }

        return defaultDatabaseInstance.database
    }

    class func allDatabases() -> [Any]! {
        let lock = DicomDatabaseRegistryLock()
        lock.lock()

        let mainDatabases = NSMutableArray()

        for case let value as NSValue in databasesDictionary.allValues {
            if let pointer = value.pointerValue {
                let db = Unmanaged<DicomDatabase>.fromOpaque(pointer).takeUnretainedValue()
                if db.isMainDatabase() {
                    mainDatabases.add(db)
                }
            }
        }

        lock.unlock()

        return mainDatabases as? [Any]
    }

    /// Registers the database under its base path, or under its pointer when
    /// another database has that path.
    private static func knowAbout(_ db: DicomDatabase?) {
        guard let db, let baseDirPath = db.baseDirPath else { return }
        let lock = DicomDatabaseRegistryLock()
        lock.lock()

        let pointer = NSValue(pointer: Unmanaged.passUnretained(db).toOpaque())
        if !(databasesDictionary.allValues as NSArray).contains(pointer) && databasesDictionary.object(forKey: baseDirPath) == nil {
            databasesDictionary.setObject(pointer, forKey: baseDirPath as NSString)
        } else if databasesDictionary.object(forKey: pointer) == nil {
            databasesDictionary.setObject(pointer, forKey: pointer)
        }

        lock.unlock()
    }

    /// The database registered under a base path: a strong reference taken
    /// under the registry's lock, where it was a weak link. The factory methods
    /// of DicomDatabase+CAPI.m ask it too.
    @objc(horos_registeredDatabaseAtBaseDirPath:)
    private class func registeredDatabase(atBaseDirPath key: String?) -> DicomDatabase? {
        guard let key else { return nil }
        let lock = DicomDatabaseRegistryLock()
        lock.lock()
        defer { lock.unlock() }
        guard let pointer = (databasesDictionary.object(forKey: key) as? NSValue)?.pointerValue else { return nil }
        return Unmanaged<DicomDatabase>.fromOpaque(pointer).takeUnretainedValue()
    }

    class func existingDatabase(atPath path: String!) -> DicomDatabase! {
        return registeredDatabase(atBaseDirPath: self.baseDirPath(forPath: path))
    }

    @objc(activeLocalDatabase)
    class func activeLocal() -> DicomDatabase! {
        return activeLocalDatabaseInstance.database ?? self.default()
    }

    @objc(setActiveLocalDatabase:)
    class func setActiveLocal(_ ldb: DicomDatabase!) {
        guard let ldb, ldb.isLocal() else { return }
        if ldb !== self.activeLocal() {
            activeLocalDatabaseInstance.replace(with: ldb)
            NotificationCenter.default.post(name: .OsirixActiveLocalDatabaseDidChange, object: nil)
        }
    }

    // MARK: - Life cycle

    // -[N2ManagedDatabase initWithPath:] and -initWithPath:context: reach this
    // one, as they did; Swift needs them restated to inherit them.
    override convenience init!(path sqlFilePath: String!) {
        self.init(path: sqlFilePath, context: nil)
    }

    override convenience init!(path sqlFilePath: String!, context: NSManagedObjectContext!) {
        self.init(path: sqlFilePath, context: context, mainDatabase: nil)
    }

    // The context may be nil: -[N2ManagedDatabase initWithPath:context:mainDatabase:]
    // then opens it at the path. An Objective-C exception raised while the
    // database opens is logged, told on the main thread, and the database is
    // not made, as the former @try did; the superclass's own initializer is
    // outside it, as Swift cannot call it inside a block.
    override init?(path p: String!, context c: NSManagedObjectContext!, mainDatabase mainDbReference: N2ManagedDatabase!) {
        var basePath: String? = nil
        var main: N2ManagedDatabase? = mainDbReference
        var sqlFilePath: String? = nil
        var isNewFile = false
        var dataBasePath: String? = nil
        var isNewDb = false

        if let exception = HorosObjCException.caught({
            basePath = (DicomDatabase.baseDirPath(forPath: p) as NSString?)?.resolvingSymlinksAndAliases()

            if main == nil {
                main = DicomDatabase.existingDatabase(atPath: basePath)
            }

            FileManager.default.confirmDirectory(atPath: basePath)

            sqlFilePath = DicomDatabase.sqlFilePath(forBasePath: basePath)
            isNewFile = !DicomDatabaseObjC.fileExists(sqlFilePath)

            dataBasePath = DicomDatabaseObjC.appending(basePath, "DBFOLDER_LOCATION").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            if dataBasePath == nil { dataBasePath = basePath } // TODO: what if this path is not mounted?

            // -dataDirPath, which needs the object.
            isNewDb = !DicomDatabaseObjC.fileExists((DicomDatabaseObjC.appending(dataBasePath, "DATABASE.noindex") as NSString?)?.resolvingSymlinksAndAliases())
        }) {
            DicomDatabase.reportOpeningFailure(exception)
            return nil
        }

        // init and register

        storedBaseDirPath = basePath
        storedDataBaseDirPath = dataBasePath
        databaseWriterGate = (main as? DicomDatabase)?.databaseWriterGate ?? DatabaseWriterGate()
        dataFileAllocator = (main as? DicomDatabase)?.dataFileAllocator ?? DataFileAllocator()
        importFeedbackLog = (main as? DicomDatabase)?.importFeedbackLog ?? ImportFeedbackLog()

        super.init(path: sqlFilePath, context: c, mainDatabase: main)

        if let exception = HorosObjCException.caught({
            self.finishOpening(basePath: basePath, isNewFile: isNewFile, isNewDb: isNewDb, mainDbReference: main)
        }) {
            DicomDatabase.reportOpeningFailure(exception)
            return nil
        }
    }

    /// The @catch of the former initializer.
    private static func reportOpeningFailure(_ exception: NSException) {
        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase initWithPath:context:mainDatabase:]")

        if Thread.isMainThread {
            let reason = exception.reason ?? "(null)"
            MainActor.assumeIsolated {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Database", comment: ""), message: reason,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    /// What the initializer does once the superclass has opened the index.
    private final func finishOpening(basePath p: String?, isNewFile: Bool, isNewDb: Bool, mainDbReference: N2ManagedDatabase?) {
        DicomDatabase.knowAbout(self)

        // post-init

        if self.isMainDatabase() { // is main (not independent)
            if let loading = self.loadingFilePath() { try? FileManager.default.removeItem(atPath: loading) }

            processFilesLock = NSRecursiveLock()
            importFilesFromIncomingDirLock = NSRecursiveLock()

            horos_compressQueue = NSMutableArray()
            horos_decompressQueue = NSMutableArray()

            // create dirs if necessary
            FileManager.default.confirmDirectory(atPath: self.dataDirPath())
            FileManager.default.confirmDirectory(atPath: self.incomingDirPath())
            FileManager.default.confirmDirectory(atPath: self.tempDirPath())
            FileManager.default.confirmDirectory(atPath: self.reportsDirPath())
            FileManager.default.confirmDirectory(atPath: self.dumpDirPath())

            DicomDatabaseListenerPaths.copy(self.baseDirPath, into: listenerPaths.baseDirPath)
            DicomDatabaseListenerPaths.copy(self.incomingDirPath(), into: listenerPaths.incomingDirPath)
            DicomDatabaseListenerPaths.copy(self.tempDirPath(), into: listenerPaths.tempDirPath)

            // if a TOBEINDEXED dir exists, move it into INCOMING so we will import the data

            if let toBeIndexed = self.toBeIndexedDirPath(), FileManager.default.fileExists(atPath: toBeIndexed),
               let destination = DicomDatabaseObjC.appending(self.incomingDirPath(), (toBeIndexed as NSString).lastPathComponent) {
                try? FileManager.default.moveItem(atPath: toBeIndexed, toPath: destination)
            }

            // report templates
            #if !MACAPPSTORE
            #if !OSIRIX_LIGHT

            for rfn in ["ReportTemplate.rtf", "ReportTemplate.odt"] {
                if let rfp = DicomDatabaseObjC.appending(self.baseDirPath, rfn), !FileManager.default.fileExists(atPath: rfp) {
                    if let resourcePath = Bundle.main.resourcePath {
                        try? FileManager.default.copyItem(atPath: (resourcePath as NSString).appendingPathComponent(rfn), toPath: rfp)
                    }
                    _ = FileManager.default.applyFileModeOfParentToItem(atPath: rfp)
                }
            }

            Reports.checkForPagesTemplate()
            Reports.checkForWordTemplates()

            #endif
            #endif

            DatabaseTemplateInstaller(database: self).install()

            let tmpDirPath = FileManager.default.tmpDirPath()
            if isNewFile && Thread.isMainThread && !(p?.hasPrefix("/tmp/") ?? false) && !(p?.hasPrefix(tmpDirPath) ?? false) && !isNewDb {
                // This thread is the main thread (checked above), which the
                // modal window controller watches while the rebuild runs on it.
                let thread = Thread.current
                thread.enterOperation()
                thread.name = NSLocalizedString("Rebuilding default IsiX DICOM Viewer database...", comment: "")
                let tmfwc = MainActor.assumeIsolated { ThreadModalForWindowController(thread: Thread.main, window: nil) }
                self.rebuild(true)
                tmfwc.invalidate()
                thread.exitOperation()
            }

            // On the queue of the database's context: the main queue for one
            // opened on the main thread, its private queue otherwise.
            self.performBlockAndWait {
                if isNewFile && !(p?.hasPrefix("/tmp/") ?? false) && !(p?.hasPrefix(tmpDirPath) ?? false) {
                    self.addDefaultAlbums()
                }
                self.modifyDefaultAlbums()
                DatabaseStartupRepairs.repairEmptySeriesIdentifiers(in: self.managedObjectContext)
                DatabaseStartupRepairs.repairFabricatedPatientIdentifiers(in: self.managedObjectContext)
            }

            // In the background: it reads files, and only once per database.
            DatabaseStartupRepairs(database: self).repairDatesLostToFractionalTimesUnlessDone()

            DicomDatabase.syncImportFilesFromIncomingDirTimerWithUserDefaults()
        } else { // is independentDatabase
            let main = self.mainDatabase as? DicomDatabase
            processFilesLock = main?.processFilesLock
            importFilesFromIncomingDirLock = main?.importFilesFromIncomingDirLock
            hasPotentiallySlowDataAccess = main?.hasPotentiallySlowDataAccess ?? false

            horos_compressQueue = main?.horos_compressQueue
            horos_decompressQueue = main?.horos_decompressQueue

            if let mainDbReference {
                let center = NotificationCenter.default
                let selector = #selector(DicomDatabase.observeIndependentDatabaseNotification(_:))
                center.addObserver(mainDbReference, selector: selector, name: ._O2AddToDBAnyway, object: self)
                center.addObserver(mainDbReference, selector: selector, name: ._O2AddToDBAnywayComplete, object: self)
                // the followindo notifications look like the previous ones but they're not the same. do not remove them! viewercontroller needs them ot it won't update the preview matrix with the added images
                center.addObserver(mainDbReference, selector: selector, name: .OsirixAddToDB, object: self)
                center.addObserver(mainDbReference, selector: selector, name: .OsirixAddToDBComplete, object: self)
                center.addObserver(mainDbReference, selector: selector, name: .OsirixAddNewStudiesDB, object: self)
                center.addObserver(mainDbReference, selector: selector, name: .O2DatabaseInvalidateAlbumsCache, object: self)
            }
        }

        self.initRouting()
        self.initClean()
    }

    deinit {
        // Unless a subclass's deinit, which runs first, left the registry already.
        DicomDatabaseRegistry.leave(self)

        self.deallocClean()
        self.deallocRouting()

        if self.isMainDatabase() {
            // if currently importing, wait until finished
            if let temp = importFilesFromIncomingDirLock {
                temp.lock()
                importFilesFromIncomingDirLock = nil
                temp.unlock()
            }

            if let temp = processFilesLock {
                temp.lock()
                processFilesLock = nil
                temp.unlock()
            }
        } else {
            importFilesFromIncomingDirLock = nil
            processFilesLock = nil
            if let main = self.mainDatabase {
                NotificationCenter.default.removeObserver(main, name: nil, object: self)
            }
        }
    }

    // MARK: - The C paths of the DICOM listener

    func baseDirPathC() -> UnsafePointer<CChar>! {
        return UnsafePointer(listenerPaths.baseDirPath)
    }

    func incomingDirPathC() -> UnsafePointer<CChar>! {
        return UnsafePointer(listenerPaths.incomingDirPath)
    }

    func tempDirPathC() -> UnsafePointer<CChar>! {
        return UnsafePointer(listenerPaths.tempDirPath)
    }
}
