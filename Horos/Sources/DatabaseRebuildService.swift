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
import IsiXContracts
import IsiXDatabase

/// The exception a rebuild stops with. A save can fail without an error, and
/// then there is no underlying error to name, rather than a nil one.
private func rebuildFailure(_ error: NSError?) -> NSException {
    return NSException(name: NSExceptionName("DatabaseRebuildFailure"),
                       reason: error?.localizedDescription ?? NSLocalizedString("unknown error", comment: ""),
                       userInfo: error.map { [NSUnderlyingErrorKey: $0] })
}

/// A rebuild that stopped, with the exception it is said and logged with:
/// the one the rebuild throws, or the one Core Data or the database raised.
/// `@unchecked Sendable`: the exception is made once and only read after.
private struct RebuildStopped: Error, @unchecked Sendable {
    let exception: NSException
}

/// `[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL]`.
private func contentsOfDirectory(_ path: String?) -> [String]? {
    guard let path else { return nil }
    return try? FileManager.default.contentsOfDirectory(atPath: path)
}

/// N2LocalizedSingularPluralCount(c, s, p) of N2Stuff.h.
private func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), count == 1 ? singular : plural)
}

/// Rebuilds the index of a database, from its files and from its SQL file.
///
/// `RemoteDicomDatabase` overrides `rebuild(_:)` and `rebuildAllowed()` to do
/// nothing. Whatever leads to them here goes through the method of the
/// database, so that a remote database keeps rebuilding nothing.
///
/// A rebuild holds `importFilesFromIncomingDirLock` from start to end, so that
/// the import of the INCOMING folder waits for it. The lock is nil, and nothing
/// waits, for a rebuild that an upgrade starts while the database opens: nothing
/// knows of that database yet. The rebuild of the SQL file also holds the
/// writer gate while it replaces the index, for those that add files directly.
/// Both are listed in `IndexRebuildsUnderWay` while they run, and quitting
/// waits for them.
///
/// `@unchecked Sendable`: `DicomDatabase` is not Sendable, and a conformance
/// would have to be in the file of the class. The reference here never changes,
/// and the work on the database is on the queue of its context.
final class DatabaseRebuildService: DatabaseRebuilding, @unchecked Sendable {
    private let database: DicomDatabase
    private let processGraph: ProcessGraph

    convenience init(database: DicomDatabase) {
        self.init(database: database, processGraph: ProcessGraph.process)
    }

    init(database: DicomDatabase, processGraph: ProcessGraph) {
        self.database = database
        self.processGraph = processGraph
    }

    // MARK: The port

    var rebuildAllowed: Bool {
        database.rebuildAllowed()
    }

    func rebuildIndex(complete: Bool) {
        // What this thread autoreleases of the database meanwhile, its context of
        // the main queue among it, goes before the main thread replaces that
        // context: drained after, the pool of this thread would release the former
        // context last, and it would end off the main thread it belongs to.
        let opensTheNewIndex: Bool = autoreleasepool {
            let formerIndex = fileNumber(atPath: database.sqlFilePath)
            // On a private-queue database; the rebuild works on its context's queue.
            (database.privateQueueIndependentDatabase() as? DicomDatabase)?.rebuild(complete)

            // The rebuild, on a database of its own, leaves a new file in the place of
            // the index. This database opens it itself: with no store, after an opening
            // that left its index closed, it has nothing to show, and with one, that
            // store is the former file, and its rows in memory would answer for the
            // new index, whichever context is renewed over it. An index that stayed
            // stays as it is: the rebuild said why, and opening it again would repeat
            // the opening's upgrade and alerts.
            guard let index = fileNumber(atPath: database.sqlFilePath), index != formerIndex else { return false }
            return !DatabaseModelUpgrade(database: database, processGraph: processGraph).indexAwaitsUpgrade
        }
        guard opensTheNewIndex else { return }
        if Thread.isMainThread {
            openRebuiltIndex()
            return
        }
        // Waited for, so that the browser shows it open. From the main run loop:
        // an alert of the opening must not stop the main queue.
        let opened = DispatchSemaphore(value: 0)
        onMainRunLoop {
            self.openRebuiltIndex()
            opened.signal()
        }
        opened.wait()
    }

    /// On the main thread, where the context of the database is the UI's.
    private func openRebuiltIndex() {
        if let e = HorosObjCException.caught({
            database.managedObjectContext = nil
            database.managedObjectContext = database.context(atPath: database.sqlFilePath)
        }) {
            DicomDatabaseObjC.log(e, stack: true, "-[DatabaseRebuildService openRebuiltIndex]")
        }
    }

    func rebuildSQLFile() {
        // RemoteDicomDatabase overrides -rebuild: and not this.
        guard rebuildAllowed else { return }
        database.rebuildSqlFile()
    }

    func checkReportsConsistency() {
        database.checkReportsConsistencyWithDICOMSR()
    }

    // MARK: The rebuild

    /// The models an index of this database can be of: the current one, then
    /// the former ones the application carries, newest first.
    private func indexModels() -> [NSManagedObjectModel] {
        var models: [NSManagedObjectModel] = []
        if let current = database.managedObjectModel { models.append(current) }
        let former = Bundle.main.paths(forResourcesOfType: "mom", inDirectory: nil)
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("OsiriXDB_Previous_DataModel") }
            .sorted { ($0 as NSString).lastPathComponent.compare(($1 as NSString).lastPathComponent, options: .numeric) == .orderedDescending }
        for path in former {
            if let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) { models.append(model) }
        }
        return models
    }

    /// Whether the context of the database has its index open. One with no
    /// store is what an opening that could not upgrade the index leaves: the
    /// index is still the file in its place, and the context has nothing to save
    /// and no albums to give.
    private var indexIsOpen: Bool {
        return database.managedObjectContext?.persistentStoreCoordinator?.persistentStores.isEmpty == false
    }

    /// A new folder beside the recovery folders of the complete rebuild.
    private func newRecoveryFolder() throws -> String {
        let folder = (((database.sqlFilePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Index Backups") as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return folder
    }

    /// The recovery folder of an index no verified copy can be made of. The index
    /// goes there as it is once the rebuild retires it, and a copy of what is
    /// beside it goes now, as what the log holds of it is not in the index, with
    /// the file that says what model it is of.
    private func recoveryFolderForDamagedIndex(metadataPath: String?) throws -> String {
        let folder = try newRecoveryFolder()
        let retired = (folder as NSString).appendingPathComponent(IndexRepairRules.retiredName)
        do {
            for suffix in IndexRepairRules.companionSuffixes where DicomDatabaseObjC.fileExists(database.sqlFilePath + suffix) {
                try FileManager.default.copyItem(atPath: database.sqlFilePath + suffix, toPath: retired + suffix)
            }
            if let metadataPath {
                try FileManager.default.copyItem(atPath: metadataPath, toPath: (folder as NSString).appendingPathComponent((metadataPath as NSString).lastPathComponent))
            }
        } catch {
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
        return folder
    }

    /// The alert of a rebuild, with the database working on: it comes from the
    /// main run loop, so that it does not stop the main queue while it is open.
    private func present(_ error: NSError) {
        onMainRunLoop { _ = NSApp.presentError(error) }
    }

    func rebuild(complete: Bool) {
        let thread = Thread.current

        IndexRebuildsUnderWay.shared.begin()
        defer { IndexRebuildsUnderWay.shared.end() }
        database.importFilesFromIncomingDirLock?.lock()

        var recoveryFolder: String? = nil
        var savedAlbumsPath: String? = nil
        var albumsLost = false
        var indexWasDamaged = false
        do {
            // Core Data, the database and the indexing may raise.
            try HorosObjCException.throwing({ RebuildStopped(exception: $0) }) {
                if complete {
                    var error: NSError? = nil
                    if indexIsOpen && !database.save(&error) {
                        throw RebuildStopped(exception: rebuildFailure(error))
                    }

                    // Finish a verified recovery snapshot before retiring any active
                    // file. A damaged index has none to give, and this rebuild is the
                    // way out of it: the index itself goes to the recovery folder.
                    if DicomDatabaseObjC.fileExists(database.sqlFilePath) {
                        let metadata = DicomDatabaseObjC.fileExists(database.modelVersionFilePath()) ? database.modelVersionFilePath() : nil
                        do {
                            recoveryFolder = try DatabaseIndexBackup.snapshot(atPath: database.sqlFilePath, metadataPath: metadata)
                        } catch let snapshotError {
                            error = snapshotError as NSError
                            if IndexRepairRules.snapshotFoundDamage(snapshotError as NSError) {
                                indexWasDamaged = true
                                do {
                                    recoveryFolder = try recoveryFolderForDamagedIndex(metadataPath: metadata)
                                } catch let folderError {
                                    error = folderError as NSError
                                }
                            }
                        }
                        if recoveryFolder == nil {
                            throw RebuildStopped(exception: rebuildFailure(error))
                        }
                    } else {
                        do {
                            recoveryFolder = try newRecoveryFolder()
                        } catch let createError {
                            error = createError as NSError
                            throw RebuildStopped(exception: rebuildFailure(error))
                        }
                    }
                    savedAlbumsPath = DicomDatabaseObjC.appending(recoveryFolder, "Albums.plist")
                    database.performBlockAndWait { database.saveAlbums(toPath: savedAlbumsPath) }

                    // A rebuild started while the database opens its index (an
                    // upgrade that failed), or after an opening that left it closed,
                    // has no store to save the albums from: they are read from the
                    // verified copy instead, and when they cannot be, the default ones
                    // are created again and the person is told where the copy is. A
                    // damaged index has no copy, and is read where it is.
                    if !indexIsOpen,
                       let copy = indexWasDamaged ? database.sqlFilePath : DicomDatabaseObjC.appending(recoveryFolder, (database.sqlFilePath as NSString).lastPathComponent),
                       DicomDatabaseObjC.fileExists(copy) {
                        if let albums = albumsFileEntries(ofIndexAtPath: copy, models: indexModels()) {
                            if albums.count != 0, let savedAlbumsPath, !albums.write(toFile: savedAlbumsPath, atomically: true) {
                                NSLog("--- albums could not be saved to %@", savedAlbumsPath as NSString)
                                albumsLost = true
                            }
                        } else {
                            NSLog("--- the albums of %@ could not be read", copy as NSString)
                            albumsLost = true
                        }
                    } else if indexWasDamaged, !DicomDatabaseObjC.fileExists(savedAlbumsPath) {
                        albumsLost = true
                    }

                    thread.status = NSLocalizedString("Locking database...", comment: "")
                    let oldContext = database.managedObjectContext
                    // What raises on the queue goes on outside it.
                    var indexStayed = false
                    N2ManagedObjectContextPerformAndWait(oldContext) {
                        database.managedObjectContext = nil
                        if DicomDatabaseObjC.fileExists(database.sqlFilePath) {
                            let retiredPath = DicomDatabaseObjC.appending(recoveryFolder, "RetiredDatabase.sql")!
                            do {
                                try FileManager.default.moveItem(atPath: database.sqlFilePath, toPath: retiredPath)
                            } catch let moveError {
                                error = moveError as NSError
                                database.managedObjectContext = oldContext
                                indexStayed = true
                            }
                        }
                    }
                    if indexStayed {
                        throw RebuildStopped(exception: rebuildFailure(error))
                    }
                    // The new index is made in the current model. Written only now,
                    // with the former index retired: a rebuild that stops before this
                    // leaves the file describing the index that is still there.
                    if let path = database.modelVersionFilePath() {
                        try? (CurrentDatabaseVersion as NSString).write(toFile: path, atomically: true, encoding: String.Encoding.utf8.rawValue)
                    }
                    database.managedObjectContext = database.context(atPath: database.sqlFilePath)
                    if database.managedObjectContext == nil {
                        throw RebuildStopped(exception: NSException(name: NSExceptionName("DatabaseRebuildFailure"), reason: NSLocalizedString("The reconstructed database index could not be opened.", comment: ""), userInfo: nil))
                    }
                } else {
                    _ = database.save(nil)
                }

                // The index is rebuilt on the queue of the context it ends up with,
                // new or kept: a private queue off the main thread.
                var notSaved: RebuildStopped? = nil
                database.performBlockAndWait {
                    thread.status = NSLocalizedString("Scanning database directory...", comment: "")

                    // SCAN THE DATABASE FOLDER, TO BE SURE WE HAVE EVERYTHING!

                    NSLog("Scan the Database folder")

                    moveFilesInDataFolderToIncoming()

                    NSLog("Start Rebuild")

                    let files = database.dataDirPath().map {
                        RebuildScan.files(dataFolder: $0, roisFolder: database.roisDirPath(), contents: contentsOfDirectory)
                    } ?? []

                    // ** Finish the rebuild

                    thread.status = String(format: NSLocalizedString("Adding %@...", comment: "rebuild database thread status: Adding %@ (%@ = '120 files')"), singularPluralCount(files.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: "")))

                    autoreleasepool { () -> Void in
                        _ = processGraph.databaseIngest.index(files, preset: .rebuild, in: database)
                    }

                    NSLog("End Rebuild")

                    var studiesThatLeft: [String] = []
                    if !complete {
                        studiesThatLeft = removeWhatIsGone(thread)
                    } else {
                        //Restore albums
                        if DicomDatabaseObjC.fileExists(savedAlbumsPath) {
                            database.loadAlbums(fromPath: savedAlbumsPath)
                            if let savedAlbumsPath { try? FileManager.default.removeItem(atPath: savedAlbumsPath) }
                        }
                        if albumsLost {
                            database.addDefaultAlbums()
                        }
                    }

                    var saveError: NSError? = nil
                    if !database.save(&saveError) {
                        notSaved = RebuildStopped(exception: rebuildFailure(saveError))
                        return
                    }

                    // Their placeholders of series a node's rule left out go with them,
                    // once they left: a save that fails leaves them in the index.
                    if let folder = database.dataBaseDirPath, !folder.isEmpty {
                        for uid in studiesThatLeft { ExcludedSeries.forget(study: uid, database: folder) }
                    }

                    thread.status = NSLocalizedString("Checking reports consistency...", comment: "")
                    database.checkReportsConsistencyWithDICOMSR()

                    if albumsLost, let recoveryFolder {
                        let description = String(format: NSLocalizedString("The albums of the former database index could not be read, and the default albums were created again. The former index is kept in: %@", comment: ""), recoveryFolder)
                        present(NSError(domain: "HorosDatabaseRebuild", code: 2, userInfo: [NSLocalizedDescriptionKey: description]))
                    } else if indexWasDamaged, let recoveryFolder {
                        let description = String(format: NSLocalizedString("The former database index was damaged, and the image files were indexed again. What only the index held, such as comments, stays in the former index, kept in: %@", comment: ""), recoveryFolder)
                        present(NSError(domain: "HorosDatabaseRebuild", code: 2, userInfo: [NSLocalizedDescriptionKey: description]))
                    }
                }
                if let notSaved { throw notSaved }
            }
        } catch {
            let e = (error as? RebuildStopped)?.exception ?? rebuildFailure(error as NSError)
            DicomDatabaseObjC.log(e, stack: true, "-[DicomDatabase rebuild:]")
            let description: String
            switch RebuildStop(recoveryFolder: recoveryFolder, complete: complete) {
            case .recoveryFilesIn(let folder):
                description = String(format: NSLocalizedString("Database reconstruction stopped: %@\nRecovery files: %@", comment: ""), DicomDatabaseObjC.arg(e.reason), folder)
            case .beforeTheIndexWasCopied:
                description = String(format: NSLocalizedString("Database reconstruction stopped before the index could be backed up: %@", comment: ""), DicomDatabaseObjC.arg(e.reason))
            case .maintenance:
                description = String(format: NSLocalizedString("Database maintenance stopped: %@", comment: ""), DicomDatabaseObjC.arg(e.reason))
            }
            present(NSError(domain: "HorosDatabaseRebuild", code: 1, userInfo: [NSLocalizedDescriptionKey: description]))
        }
        database.importFilesFromIncomingDirLock?.unlock()
    }

    /// In the DATABASE FOLDER, we have only folders! Moves all files that are
    /// wrongly there to the INCOMING folder.
    private func moveFilesInDataFolderToIncoming() {
        let dataFolder = database.dataDirPath()
        let incomingFolder = processGraph.databaseIngest.admissionFolder(of: database).path
        autoreleasepool {
            for name in contentsOfDirectory(dataFolder) ?? [] {
                let itemPath = DicomDatabaseObjC.appending(dataFolder, name)!
                let attributes = try? FileManager.default.attributesOfItem(atPath: itemPath)
                if (attributes?[.type] as? FileAttributeType) == .typeRegular {
                    if let destination = DicomDatabaseObjC.appending(incomingFolder, (itemPath as NSString).lastPathComponent) {
                        try? FileManager.default.moveItem(atPath: itemPath, toPath: destination)
                    }
                }
            }
        }
    }

    /// Takes out of the kept index the images whose files are gone, the series
    /// left without images and the studies left with nothing, on the queue of the
    /// context, and answers the UIDs of the studies that left. A study goes with
    /// the files it still has, so what still has any stays: see KeptIndexCleanup.
    private func removeWhatIsGone(_ thread: Thread) -> [String] {
        thread.status = NSLocalizedString("Checking for missing files...", comment: "")

        // remove non-available images. An image whose record names the file of
        // another one has lost its own: it no longer names that file, and goes
        // with the others.
        StrangerImageRecords.leaveTheFilesOfOthers(in: database)
        let dataFolderIsThere = database.dataDirPath().map { FileManager.default.fileExists(atPath: $0) } ?? false
        for case let aFile as DicomImage in database.objects(forEntity: database.imageEntity()) ?? [] {
            let path = aFile.completePath()
            var fp: UnsafeMutablePointer<FILE>? = nil
            var openError = ENOENT
            if let path {
                fp = fopen(path, "r")
                openError = errno
            }
            if let fp {
                fclose(fp)
            } else if KeptIndexCleanup.fileIsGone(openError: openError,
                                                  volumeIsThere: path.flatMap { MissingFileReason.volumeOf(path: $0) }.map { FileManager.default.fileExists(atPath: $0) } ?? true,
                                                  inDatabaseFolder: aFile.inDatabaseFolder()?.boolValue ?? false,
                                                  dataFolderIsThere: dataFolderIsThere) {
                // noFiles answers the stored counts, not what is left, and the
                // thumbnail may be of this image: it is made again when asked for.
                aFile.series?.study?.numberOfImages = nil
                aFile.series?.numberOfImages = nil
                aFile.series?.thumbnail = nil
                database.managedObjectContext?.delete(aFile)
            }
        }

        // remove empty series, also those a former rebuild left
        var studiesThatLostSeries = Set<DicomStudy>()
        for case let series as DicomSeries in database.objects(forEntity: database.seriesEntity()) ?? [] {
            if KeptIndexCleanup.removesSeries(name: series.name, id: series.id?.int32Value ?? 0, imageCount: series.images?.count ?? 0) {
                if let study = series.study {
                    study.numberOfImages = nil
                    studiesThatLostSeries.insert(study)
                }
                database.managedObjectContext?.delete(series)
            }
        }

        // remove empty studies
        thread.status = NSLocalizedString("Checking for empty studies...", comment: "")
        var studiesThatLeft: [String] = []
        for case let study as DicomStudy in database.objects(forEntity: database.studyEntity()) ?? [] {
            database.checkForExistingReport(forStudy: study)
            let series = (study.series ?? []).compactMap { $0 as? DicomSeries }
            // The stored value: during a rebuild the browser has no database, and
            // reportURL answers nil for the path of a report inside this one.
            let hasReport = ReportAttachment.isReachable(stored: study.primitiveValue(forKey: "reportURL") as? String, inDatabaseAt: database.baseDirPath,
                                                         fileExists: FileManager.default.fileExists(atPath:))
            if KeptIndexCleanup.removesStudy(imagesLeft: series.reduce(0) { $0 + ($1.images?.count ?? 0) },
                                             hasNoAutodeletionSeries: series.contains { SelectionImages.isNoAutodeletionSeries(name: $0.name, id: $0.id?.int32Value ?? 0) },
                                             hasReport: hasReport, isLocked: study.lockedStudy?.boolValue ?? false) {
                if let uid = study.studyInstanceUID, !uid.isEmpty { studiesThatLeft.append(uid) }
                database.managedObjectContext?.delete(study)
            } else {
                // A study with only its marker, or its hidden series, has no series
                // to take the modality from, and keeps the one it has.
                if studiesThatLostSeries.contains(study), study.numberOfImageSeries() > 0 {
                    study.modality = study.modalities()
                }
                // Stores the count again: the albums read it without asking.
                _ = study.noFiles()
            }
        }
        return studiesThatLeft
    }

    // MARK: The SQL file

    /// An exception goes on once the lock is free: left held, the import of the
    /// INCOMING folder would never run again.
    ///
    /// Only an index that was replaced is opened again. One that stayed goes
    /// back to its context: opened anew, an index Core Data cannot read would be
    /// set aside and an empty one made in its place. The file says which it was,
    /// since `dumpSqlFile()` answers nothing and is a selector plugins see.
    ///
    /// What adds files directly, without the incoming folder, waits at the
    /// writer gate from the dump until the database has a context over the new
    /// index: written meanwhile, its rows went into the former file on its way to
    /// the backups. The coordinator of that file is named retired, so that a
    /// writer that waited with a context over it takes one over the new index.
    /// Nothing done inside the gate waits for the main thread, which can be
    /// waiting there: a former context on the main queue is given back after.
    ///
    /// A context of the main queue belongs to the main thread, from its save to
    /// its end: it is saved from the main run loop before the lock is taken, and
    /// one this thread let go is released there, once the pool of the gate has
    /// drained what this thread held of it.
    func rebuildSqlFile() {
        IndexRebuildsUnderWay.shared.begin()
        saveOnTheThreadOfTheContext()
        database.importFilesFromIncomingDirLock?.lock()

        let raised = HorosObjCException.caught {
            let sqlFilePath: String = database.sqlFilePath
            var givenBack: NSManagedObjectContext? = nil
            var replaced = false
            var letGo: NSManagedObjectContext? = nil

            let raisedInGate = autoreleasepool { database.databaseWriterGate.withExclusiveWrite {
                HorosObjCException.caught {
                    let formerIndex = fileNumber(atPath: sqlFilePath)
                    let formerContext = database.managedObjectContext
                    letGo = formerContext
                    database.managedObjectContext = nil

                    database.dumpSqlFile()
                    //	[self upgradeSqlFileFromModelVersion:CurrentDatabaseVersion]; // removing this line reflects antoine's commit 9758

                    guard let index = fileNumber(atPath: sqlFilePath), index != formerIndex else {
                        givenBack = formerContext
                        return
                    }

                    // The dump keeps the model of the index. One that waits for its upgrade
                    // stays closed: opened here, the upgrade and its alerts would run on
                    // this thread, where no alert can open, and possibly a whole rebuild.
                    if DatabaseModelUpgrade(database: database, processGraph: processGraph).indexAwaitsUpgrade {
                        givenBack = formerContext
                        present(NSError(domain: "HorosDatabaseRebuild", code: 3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The database index was rebuilt in its former model and stays closed. Its upgrade will be tried again the next time this database opens.", comment: "")]))
                        return
                    }
                    if let formerCoordinator = formerContext?.persistentStoreCoordinator {
                        database.databaseWriterGate.retire(formerCoordinator)
                    }

                    database.managedObjectContext = database.context(atPath: database.sqlFilePath)
                    replaced = true
                }
            } }

            if let givenBack { database.managedObjectContext = givenBack }
            releaseOnTheMainThread(&letGo)
            if let raisedInGate { raisedInGate.raise() }
            if replaced { database.checkReportsConsistencyWithDICOMSR() }
        }

        database.importFilesFromIncomingDirLock?.unlock()
        IndexRebuildsUnderWay.shared.end()
        if let raised { raised.raise() }
    }

    /// The save before the dump, of what the context has not written yet. One of
    /// the main queue is saved from the main run loop, waited for: from here it
    /// would run on this thread. Nothing is held yet that the main thread may be
    /// waiting for.
    private func saveOnTheThreadOfTheContext() {
        let onTheMainQueue = autoreleasepool { database.managedObjectContext?.concurrencyType == .mainQueueConcurrencyType }
        if onTheMainQueue && !Thread.isMainThread {
            _ = onMainRunLoopSync { self.database.save(nil) }
        } else {
            _ = database.save(nil)
        }
    }

    /// Lets go of a context this thread holds the last reference to, as far as it
    /// knows: one of the main queue ends on the main thread, from its run loop,
    /// since its end touches it. Nothing waits for that. The reference goes to the
    /// main thread before it is asked to release it, so that no reference of this
    /// thread outlives that release.
    private func releaseOnTheMainThread(_ context: inout NSManagedObjectContext?) {
        let handed = context.flatMap { held in
            held.concurrencyType == .mainQueueConcurrencyType && !Thread.isMainThread ? Unmanaged.passRetained(held) : nil
        }
        context = nil
        if let handed { onMainRunLoop { handed.release() } }
    }

    private func fileNumber(atPath path: String) -> Int? {
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }

    /// Remakes the index from what sqlite3 reads of it, and moves the former one
    /// to `Index Backups`. Whatever stops it says why and leaves the index byte
    /// for byte as it was, with the temporary files gone. The repair is SQLite,
    /// sqlite3 and the file manager, whose failures it answers: nothing raises.
    func dumpSqlFile() {
        let sqlFilePath: String = database.sqlFilePath
        removeTemporaryFiles(ofIndexAtPath: sqlFilePath)
        let failure = replaceIndexWithItsDump(atPath: sqlFilePath)
        removeTemporaryFiles(ofIndexAtPath: sqlFilePath)
        if let failure {
            NSLog("--- the index was not rebuilt: %@", failure as NSString)
            present(NSError(domain: "HorosDatabaseRebuild", code: 3, userInfo: [NSLocalizedDescriptionKey: failure]))
        }
    }

    private func removeTemporaryFiles(ofIndexAtPath sqlFilePath: String) {
        for path in IndexRepairRules.temporaryFiles(forIndexAtPath: sqlFilePath) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// What the person is told when the index was not replaced; nil when it was.
    private func replaceIndexWithItsDump(atPath sqlFilePath: String) -> String? {
        let fileManager = FileManager.default
        guard let header = IndexFileProbe.header(ofFileAtPath: sqlFilePath) else { return refusalDescription(.unreadable) }
        guard IndexRepairRules.isSQLite(header: header) else { return refusalDescription(.notSQLite) }

        let logExists = fileManager.fileExists(atPath: sqlFilePath + "-wal")
        let indexURI = IndexRepairRules.readingURI(forIndexAtPath: sqlFilePath, usesWriteAheadLog: IndexRepairRules.usesWriteAheadLog(header: header), logExists: logExists)
        let original = IndexFileProbe.tableScans(ofIndexAt: indexURI)
        if let refusal = IndexRepairRules.refusal(original: original) { return refusalDescription(refusal) }

        let temporaryFiles = IndexRepairRules.temporaryFiles(forIndexAtPath: sqlFilePath)
        let repairedDBFile = temporaryFiles[0], repairedDBFinalFile = temporaryFiles[1]

        let limit = IndexRepairRules.workLimit(indexBytes: fileSize(atPath: sqlFilePath))
        let dump: FileHandle
        do {
            try Data().write(to: URL(fileURLWithPath: repairedDBFile))
            dump = try FileHandle(forWritingTo: URL(fileURLWithPath: repairedDBFile))
        } catch {
            return refusalDescription(.notPutInPlace(error.localizedDescription))
        }
        guard runSqlite3(IndexRepairRules.dumpArguments(indexURI: indexURI), input: .nullDevice, output: dump, limit: limit, writing: temporaryFiles) else {
            return refusalDescription(.dumpFailed)
        }
        guard let input = FileHandle(forReadingAtPath: repairedDBFile),
              runSqlite3(IndexRepairRules.loadArguments(newIndexPath: repairedDBFinalFile), input: input, output: .nullDevice, limit: limit, writing: temporaryFiles) else {
            return refusalDescription(.loadFailed)
        }
        if let refusal = IndexRepairRules.refusal(new: IndexFileProbe.state(ofRepairedIndexAtPath: repairedDBFinalFile), original: original ?? []) {
            return refusalDescription(refusal)
        }

        let folder: String
        do {
            folder = try newRecoveryFolder()
        } catch {
            return refusalDescription(.notPutInPlace(error.localizedDescription))
        }
        switch IndexRepairRules.replaceIndex(atPath: sqlFilePath, with: repairedDBFinalFile, retiringTo: folder, exists: fileManager.fileExists(atPath:),
                                             move: fileManager.moveItem(atPath:toPath:), keep: IndexFileSwap.keep(_:as:), replace: IndexFileSwap.replace(_:with:),
                                             remove: { try? fileManager.removeItem(atPath: $0) }) {
        case .replaced:
            return nil
        case .formerBack(let reason):
            rmdir(folder)
            return refusalDescription(.notPutInPlace(reason))
        case .companionsInBackupFolder(let reason):
            return String(format: NSLocalizedString("The new database index could not be put in place (%@), and the files beside the former index could not be moved back. The index is in its place, and they are in: %@", comment: ""), reason as NSString, folder as NSString)
        }
    }

    private func fileSize(atPath path: String) -> Int {
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    }

    /// Runs sqlite3 until it ends or goes past `limit`, counting what it wrote
    /// in `files`; true when it says it went well. The kernel holds it to `limit`
    /// too, for when this process is gone and nothing watches it.
    private func runSqlite3(_ arguments: [String], input: FileHandle, output: FileHandle, limit: IndexRepairWorkLimit, writing files: [String]) -> Bool {
        let launch = IndexRepairRules.boundedLaunch(of: arguments, limit: limit)
        let theTask = Process()
        theTask.executableURL = URL(fileURLWithPath: launch.executable)
        theTask.standardInput = input
        theTask.standardOutput = output
        theTask.arguments = launch.arguments
        do {
            try theTask.run()
        } catch {
            NSLog("--- sqlite3 did not start: %@", error.localizedDescription as NSString)
            return false
        }

        let start = Date()
        while theTask.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
            if limit.isExceeded(seconds: -start.timeIntervalSinceNow, bytes: files.reduce(0) { $0 + fileSize(atPath: $1) }) {
                theTask.terminate()
            }
        }

        //[theTask waitUntilExit];		// <- This is VERY DANGEROUS : the main runloop is continuing...

        return theTask.terminationReason == .exit && theTask.terminationStatus == 0
    }

    /// The alert of a refused repair: the reason, and what is left to do.
    private func refusalDescription(_ refusal: IndexRepairRefusal) -> String {
        let reason: String
        switch refusal {
        case .notSQLite:
            reason = NSLocalizedString("the file is not a SQLite database.", comment: "")
        case .unreadable:
            reason = NSLocalizedString("the file cannot be read as a database index.", comment: "")
        case .damagedTable(let table):
            reason = String(format: NSLocalizedString("the table %@ has a page that cannot be read, and its rows after that page would be lost.", comment: ""), table as NSString)
        case .dumpFailed:
            reason = NSLocalizedString("sqlite3 could not read the index.", comment: "")
        case .loadFailed:
            reason = NSLocalizedString("sqlite3 could not load the contents of the index into a new file.", comment: "")
        case .newIndexDamaged:
            reason = NSLocalizedString("the new index failed its integrity check.", comment: "")
        case .missingTable(let table):
            reason = String(format: NSLocalizedString("the new index does not have the table %@.", comment: ""), table as NSString)
        case .rowsLost(let table, let kept, let readable):
            reason = String(format: NSLocalizedString("the new index would keep %ld rows of the table %@, and the damaged one can still give %ld.", comment: ""), kept, table as NSString, readable)
        case .notPutInPlace(let detail):
            reason = String(format: NSLocalizedString("the new index could not be put in place (%@).", comment: ""), detail as NSString)
        }
        return String(format: NSLocalizedString("The database index was not rebuilt and has not changed: %@\nA complete rebuild (Rebuild Entire Database...) can index the image files again.", comment: ""), reason as NSString)
    }
}

// MARK: Who waits for a rebuild

extension DatabaseRebuildService {
    /// Inside the writer gate, for an import of `database` that entered the
    /// queue of `entered`: true when it has to start again, on the context now
    /// in place. The rebuild of the SQL file replaces the index while it holds
    /// the gate, and a writer that waited comes in with the context it had. An
    /// independent database's is over the former file, gone to the backups, and
    /// what it wrote there would be lost: it takes a context over the new index,
    /// as one would be made now. The main database has the new context already.
    /// The import starts again from the beginning once out of the gate, so that
    /// it enters the new context's queue first, as the gate requires, and does
    /// all it does with the images there.
    static func contextWasReplaced(of database: DicomDatabase, since entered: NSManagedObjectContext?) -> Bool {
        if !database.isMainDatabase(), database.databaseWriterGate.isRetired(database.managedObjectContext?.persistentStoreCoordinator),
           let inPlace = database.privateQueueIndependentContext() {
            database.managedObjectContext = inPlace
        }
        return database.managedObjectContext != nil && database.managedObjectContext !== entered
    }

    /// Quitting from the Quit command while an index is being rebuilt. A rebuild
    /// cannot be cancelled, and the exit of the process would stop it with the
    /// index half written: the alert says so and stays until the rebuild ends,
    /// then closes by itself, and quitting goes on. Cancel gives up quitting.
    /// True when quitting may go on. From the main run loop, as quitting is
    /// asked. What quits through -[NSApplication terminate:], as the Dock does,
    /// AppKit refuses while the rebuild's sheet is on the browser.
    @MainActor
    static func waitForRebuildsBeforeQuitting() -> Bool {
        let rebuilds = IndexRebuildsUnderWay.shared
        if rebuilds.isEmpty { return true }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Background Operations", comment: "")
        alert.informativeText = NSLocalizedString("The database index is being rebuilt, and quitting now would leave it incomplete. Quitting goes on once the rebuild has ended.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
            if rebuilds.isEmpty {
                MainActor.assumeIsolated { NSApplication.shared.stopModal(withCode: .OK) }
            }
        }
        RunLoop.current.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()

        return response == .OK && rebuilds.isEmpty
    }
}

/// The image records of an index that name the data file of another image.
///
/// A record names its file by a number. When the files with the highest
/// numbers left the data folder from outside while their records stayed, an
/// import after the next launch was given those numbers again, and the old
/// records have named the new files since: their images show those of
/// another study, nothing says that their own files are gone, and deleting
/// them deletes the files of the other images. A new file no longer gets such
/// a number; this is for the records an index already has.
enum StrangerImageRecords {
    /// Gives each record of `database` that names the file of another image
    /// a number of its own, which no file has nor will have: the record then
    /// says that its file is missing, and what removes it no longer removes
    /// the file of the other image. Returns how many records there were. On
    /// the queue of the context of the database.
    @discardableResult
    static func leaveTheFilesOfOthers(in database: DicomDatabase, identifiers: (String) -> Set<Data>? = identifiers(inFileAt:)) -> Int {
        let strangers = find(in: database, identifiers: identifiers)
        for image in strangers {
            guard let own = database.uniquePathForNewDataFile(withExtension: "dcm") else { continue }
            image.setPath((own as NSString).lastPathComponent)
        }
        return strangers.count
    }

    /// The records of `database` that name a data file another record is the
    /// one of. On the queue of the context of the database.
    ///
    /// The numbers more than one record names are asked of the store in one
    /// request, with no object read. Only their records are read, and only
    /// the files that records of different SOP Instance UIDs name are opened:
    /// the frames of a multiframe file are records of one. `identifiers`
    /// reads a file as the import does, so its records are compared with
    /// what the import would give them, also for a file that is not DICOM.
    /// SharedDataFile says which records are not of the file.
    static func find(in database: DicomDatabase, identifiers: (String) -> Set<Data>? = identifiers(inFileAt:)) -> [DicomImage] {
        guard let context = database.managedObjectContext,
              let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Image"], let name = entity.name,
              entity.attributesByName["pathNumber"] != nil, entity.attributesByName["compressedSopInstanceUID"] != nil else { return [] }

        let counted = NSExpressionDescription()
        counted.name = "records"
        counted.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "pathNumber")])
        counted.expressionResultType = .integer64AttributeType
        let shared = NSFetchRequest<NSFetchRequestResult>(entityName: name)
        shared.resultType = .dictionaryResultType
        shared.predicate = NSPredicate(format: "pathNumber != nil")
        shared.propertiesToFetch = ["pathNumber", counted]
        shared.propertiesToGroupBy = ["pathNumber"]
        // The count is named as the request names it: the store refuses the function itself here.
        shared.havingPredicate = NSPredicate(format: "%@ > 1", NSExpression(forVariable: counted.name))
        let numbers = (((try? context.fetch(shared)) as? [[String: Any]]) ?? []).compactMap { $0["pathNumber"] as? NSNumber }

        var strangers: [DicomImage] = []
        var filesRead = 0, filesThatToldNothing = 0
        for start in stride(from: 0, to: numbers.count, by: 500) {
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "pathNumber IN %@", Array(numbers[start..<min(start + 500, numbers.count)]))
            var sharing: [Int64: [DicomImage]] = [:]
            for case let image as DicomImage in (try? context.fetch(request)) ?? [] {
                sharing[image.pathNumber?.int64Value ?? 0, default: []].append(image)
            }
            for number in sharing.keys.sorted() {
                let images = sharing[number] ?? []
                let recorded = images.map { identifier(of: $0.compressedSopInstanceUID) }
                guard SharedDataFile.needsReading(recordIdentifiers: recorded), let path = images.first?.completePath() else { continue }
                filesRead += 1
                let held = identifiers(path)
                let notOfTheFile = SharedDataFile.strangers(recordIdentifiers: recorded, fileIdentifiers: held)
                // Nothing to say of a file whose records are all of it, as the series of one that is not DICOM.
                if notOfTheFile.isEmpty, !recorded.allSatisfy({ $0.map { held?.contains($0) ?? false } ?? true }) {
                    filesThatToldNothing += 1
                }
                strangers += notOfTheFile.map { images[$0] }
            }
        }
        if filesRead > 0 {
            NSLog("--- rebuild: %ld data files are named by records of different images; %ld records are not of the file they name, and count as images whose files are gone; %ld files told nothing of their records, which stay as they are", filesRead, strangers.count, filesThatToldNothing)
        }
        return strangers
    }

    /// The SOP Instance UIDs the import gives the records of the file at
    /// `path`, one for each series the file holds, as a record stores them;
    /// nil for a file the import does not read.
    static func identifiers(inFileAt path: String) -> Set<Data>? {
        var file: DicomFile?
        if HorosObjCException.caught({ file = DicomFile(path) }) != nil { return nil }
        guard let file, let elements = file.dicomElements() else { return nil }
        let found = (0..<max(1, file.noOfSeries())).compactMap { series -> Data? in
            guard let uid = elements.object(forKey: series == 0 ? "SOPUID" : "SOPUID\(series)") as? String, !uid.isEmpty else { return nil }
            return identifier(of: DicomImage.sopInstanceUIDEncode(uid))
        }
        return found.isEmpty ? nil : Set(found)
    }

    /// A stored SOP Instance UID without the zero byte some records end it
    /// with, nil for none.
    private static func identifier(of stored: Data?) -> Data? {
        guard let stored, !stored.isEmpty else { return nil }
        let trimmed = stored.last == 0 ? stored.dropLast() : stored
        return trimmed.isEmpty ? nil : Data(trimmed)
    }
}
