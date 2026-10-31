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

// The upgrade of an index of a former model of the database, which
// -upgradeSqlFileFromModelVersion: of DicomDatabase runs from -contextAtPath:,
// while the database opens, with its context and its locks still nil.
//
// An @try is HorosObjCException.caught: an
// @throw inside it is an NSException raised and caught by the same block, and
// the code of an @finally runs after it, raising again what it caught. The
// NSAutoreleasePools are autoreleasepool blocks.
//
// The upgrade closes the stores it opened before it renames their files, and
// again after the upgrade whether or not it finished, so that no coordinator
// keeps Database3.sql open once it is Database.sql.
//
// It runs on the thread that opens the database: the main one at launch, where
// its alerts open at once, as they always did, and another one for a source
// chosen in the browser, where it waits for them. They go through
// onMainRunLoopSync, outside the queues of its contexts: the opening holds nothing
// the main thread waits for, and with the default database, whose opening holds
// the lock of the class, it is the main thread that opens.

/// `[NSEntityDescription entityForName:name inManagedObjectContext:context]`,
/// which raised for a nil context. DatabaseStartupRepairs asks it too.
func entityNamed(_ name: String, _ context: NSManagedObjectContext?) -> NSEntityDescription? {
    if let context { return NSEntityDescription.entity(forEntityName: name, in: context) }
    return (NSEntityDescription.self as AnyObject).perform(#selector(NSEntityDescription.entity(forEntityName:in:)), with: name, with: nil)?.takeUnretainedValue() as? NSEntityDescription
}

/// `[[entity attributesByName] allKeys]`, in the order of the NSDictionary.
private func attributeNames(_ entity: NSEntityDescription?) -> [String] {
    return ((entity?.value(forKey: "attributesByName") as? NSDictionary)?.allKeys as? [String]) ?? []
}

/// Forgets what the contexts hold and removes every store of the coordinators,
/// which closes their SQLite files. Removing a store that is already gone is a
/// no-op, so this can run more than once.
private func closeUpgradeStores(_ contexts: [NSManagedObjectContext], _ coordinators: [NSPersistentStoreCoordinator]) {
    if let exception = HorosObjCException.caught({
        for context in contexts { N2ManagedObjectContextPerformAndWait(context) { context.reset() } }
        for coordinator in coordinators {
            for store in coordinator.persistentStores {
                do {
                    try coordinator.remove(store)
                } catch {
                    DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                }
            }
        }
    }) {
        DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
    }
}

/// What -upgradeSqlFileFromModelVersion: lists for a study it could not copy.
private func upgradeProblemName(_ studyName: Any?) -> String {
    if let name = studyName as? String, !name.isEmpty { return name }
    return NSLocalizedString("Unnamed", comment: "")
}

/// What a study the upgrade kept lost: the series that could not be copied, and
/// the images that could not be copied of the series it kept.
private struct UpgradeLoss {
    let study: String
    let series: Int
    let images: Int
}

/// What the alert at the end of an upgrade says, nil for nothing to say: the
/// studies that left the index, and the studies that stayed without something,
/// which did not leave it. Their files stay where they are.
private func upgradeProblemMessage(removed: [String], losses: [UpgradeLoss]) -> String? {
    var paragraphs: [String] = []
    if !removed.isEmpty {
        paragraphs.append(String(format: NSLocalizedString("The upgrade encountered %d errors. These corrupted studies have been removed: %@", comment: ""),
                                 Int32(truncatingIfNeeded: removed.count), removed.joined(separator: ", ")))
    }
    if !losses.isEmpty {
        let studies = losses.sorted { $0.study < $1.study }.map {
            String(format: NSLocalizedString("%@ (%d series, %d images)", comment: ""), $0.study, Int32(truncatingIfNeeded: $0.series), Int32(truncatingIfNeeded: $0.images))
        }
        paragraphs.append(String(format: NSLocalizedString("The upgrade could not copy some series or images. These studies stay in the database without them, and their files were not removed: %@", comment: ""),
                                 studies.joined(separator: ", ")))
    }
    return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\r\r")
}

/// The exception the upgrade stops with when it cannot read the former index
/// or write the new one. It stops before the files are renamed, so the index is
/// not replaced by an incomplete copy, and its error path warns the user.
private func upgradeFailure(_ error: Error) -> NSException {
    let error = error as NSError
    return NSException(name: NSExceptionName("DatabaseUpgradeFailure"), reason: error.localizedDescription, userInfo: [NSUnderlyingErrorKey: error])
}

/// Removes what an earlier upgrade that did not finish left of Database3.sql:
/// the file, its rollback journal, and its write-ahead log and shared memory,
/// which SQLite would otherwise replay into the new file.
private func removeLeftoverUpgradeIndex(_ baseDirPath: String?) {
    guard let baseDirPath else { return }
    for name in ["Database3.sql", "Database3.sql-journal", "Database3.sql-wal", "Database3.sql-shm"] {
        try? FileManager.default.removeItem(atPath: (baseDirPath as NSString).appendingPathComponent(name))
    }
}

/// Saves the studies the upgrade copied since the last save. A save fails as a
/// whole, so when it does the batch is rolled back and copied again one study
/// at a time, each saved on its own: a study that still does not save is rolled
/// back and listed in `problems`, and the others are kept. `copy` copies a study
/// into the context and returns false, having listed the study itself, when the
/// copy raised.
private func saveUpgradeBatch(_ context: NSManagedObjectContext, _ batch: [NSManagedObject], problems: NSMutableArray,
                              copy: (NSManagedObject) -> Bool, name: (NSManagedObject) -> String) {
    do {
        try context.save()
        return
    } catch {
        DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
    }

    context.rollback()
    for study in batch {
        guard copy(study) else {
            context.rollback()
            continue
        }
        do {
            try context.save()
        } catch {
            DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
            context.rollback()
            problems.add(name(study))
        }
    }
}

/// The studies of the former index, sorted by patientUID as the upgrade copies
/// them, by object identifier: an identifier stays valid when the context is
/// reset, where the study fetched with it does not.
private func upgradeStudyIdentifiers(_ fetched: [Any]) -> [NSManagedObjectID] {
    let sorted = (fetched as NSArray).sortedArray(using: [NSSortDescriptor(key: "patientUID", ascending: true)])
    return sorted.compactMap { ($0 as? NSManagedObject)?.objectID }
}

/// Hands each study to `copy` exactly once, read again from `context`, a
/// hundred at a time: `betweenChunks` saves and forgets a hundred before the
/// next, and the last one, shorter or not, is left to the caller. Within a
/// hundred the studies go from the last to the first, as the former loop took
/// them.
private func forEachUpgradeStudy(_ identifiers: [NSManagedObjectID], in context: NSManagedObjectContext, chunkSize: Int = 100,
                                 copy: (NSManagedObject) -> Void, betweenChunks: () -> Void) {
    var start = 0
    while start < identifiers.count {
        if start > 0 { betweenChunks() }
        let end = min(start + chunkSize, identifiers.count)
        for identifier in identifiers[start..<end].reversed() {
            autoreleasepool { copy(context.object(with: identifier)) }
        }
        start = end
    }
}

/// Copies the activity history of the former index into the new one, in batches
/// that are saved and forgotten, once the studies are in: it can be far longer
/// than the list of studies. No study depends on it, so what cannot be copied is
/// logged and the upgrade goes on, with the rows in the former index it leaves
/// beside the new one. Every attribute of an entry is optional, so a batch fails as
/// a whole, for a reason a row by row retry would meet again.
private func copyUpgradeLogEntries(from oldContext: NSManagedObjectContext, to newContext: NSManagedObjectContext, batchSize: Int = 500) {
    guard let formerEntity = oldContext.persistentStoreCoordinator?.managedObjectModel.entitiesByName["LogEntry"],
          let newEntity = newContext.persistentStoreCoordinator?.managedObjectModel.entitiesByName["LogEntry"] else { return }
    let attributes = attributeNames(formerEntity).filter { newEntity.attributesByName[$0] != nil }

    var lost = 0
    func logFailure(_ error: Error) {
        DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
    }
    if let exception = HorosObjCException.caught({
        let request = NSFetchRequest<NSManagedObjectID>()
        request.entity = formerEntity
        request.resultType = .managedObjectIDResultType
        let identifiers: [NSManagedObjectID]
        do {
            identifiers = try oldContext.fetch(request)
        } catch {
            logFailure(error)
            return
        }
        for start in stride(from: 0, to: identifiers.count, by: batchSize) {
            let batch = Array(identifiers[start..<min(start + batchSize, identifiers.count)])
            autoreleasepool {
                do {
                    let page = NSFetchRequest<NSManagedObject>()
                    page.entity = formerEntity
                    page.predicate = NSPredicate(format: "SELF IN %@", argumentArray: [batch])
                    page.returnsObjectsAsFaults = false
                    for old in try oldContext.fetch(page) {
                        let new = NSEntityDescription.insertNewObject(forEntityName: "LogEntry", into: newContext)
                        for name in attributes {
                            new.setPrimitiveValue(old.primitiveValue(forKey: name), forKey: name)
                        }
                    }
                    try newContext.save()
                } catch {
                    logFailure(error)
                    newContext.rollback()
                    lost += batch.count
                }
                newContext.reset()
                oldContext.reset()
            }
        }
    }) {
        DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
        newContext.rollback()
    }
    if lost != 0 {
        DicomDatabaseObjC.logError(String(format: "The upgraded index lacks %d activity entries, which stay in the former index", Int32(truncatingIfNeeded: lost)),
                                   "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
    }
}

/// Copies the albums of the former index into the new one, with the attributes
/// named, and returns the object identifier of each copy by the identifier of
/// the album it copies. The copies get their permanent identifiers here, so the
/// identifiers stay valid when the contexts are reset, where the objects do not.
private func copyUpgradeAlbums(_ formerAlbums: [Any], attributes: [String], into context: NSManagedObjectContext) throws -> [NSManagedObjectID: NSManagedObjectID] {
    var copies: [(former: NSManagedObjectID, copy: NSManagedObject)] = []
    for case let formerAlbum as NSManagedObject in formerAlbums {
        let copy = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        for name in attributes {
            copy.setValue(formerAlbum.value(forKey: name), forKey: name)
        }
        copies.append((formerAlbum.objectID, copy))
    }
    try context.obtainPermanentIDs(for: copies.map { $0.copy })
    var identifiers: [NSManagedObjectID: NSManagedObjectID] = [:]
    for (former, copy) in copies {
        identifiers[former] = copy.objectID
    }
    return identifiers
}

/// Adds a study of the new index to the copies of the albums it was in, found
/// by the identity of the former album, not by its name, which two albums may
/// share. `copies` gives the identifier of each copy by the identifier of the
/// former album, and `albums` the albums of the new index by their identifier.
/// An album whose copy is not among them is logged and skipped, and the study
/// is still added to the others.
private func addUpgradedStudy(_ study: NSManagedObject, toCopiesOf formerAlbums: [Any],
                              copies: [NSManagedObjectID: NSManagedObjectID], albums: [NSManagedObjectID: NSManagedObject]) {
    for case let formerAlbum as NSManagedObject in formerAlbums {
        guard let identifier = copies[formerAlbum.objectID], let album = albums[identifier] else {
            DicomDatabaseObjC.logError(String(format: "The upgraded index has no copy of the album %@: the study %@ is not added to it",
                                              DicomDatabaseObjC.arg(formerAlbum.value(forKey: "name")), DicomDatabaseObjC.arg(study.value(forKey: "name"))),
                                       "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
            continue
        }
        album.mutableSetValue(forKey: "studies").add(study)
    }
}

/// Puts Database3.sql in place of Database.sql, which becomes
/// Database-Old-PreviousVersion.sql. When either file cannot move, the former
/// index stays, or is put back, as Database.sql and the error is thrown: the
/// upgrade then stops on its error path, rather than leave no index at all.
private func moveUpgradedIndex(_ indexPath: String, upgraded upgradedPath: String, previous previousVersionPath: String) throws {
    let files = FileManager.default
    try? files.removeItem(atPath: previousVersionPath)
    try files.moveItem(atPath: indexPath, toPath: previousVersionPath)
    do {
        try files.moveItem(atPath: upgradedPath, toPath: indexPath)
    } catch {
        do {
            try files.moveItem(atPath: previousVersionPath, toPath: indexPath)
        } catch let restoreError {
            DicomDatabaseObjC.logError((restoreError as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
        }
        throw error
    }
}

/// The upgrade of the index of a database from a former model.
struct DatabaseModelUpgrade {
    let database: DicomDatabase
    let processGraph: ProcessGraph

    init(database: DicomDatabase) {
        self.init(database: database, processGraph: ProcessGraph.process)
    }

    init(database: DicomDatabase, processGraph: ProcessGraph) {
        self.database = database
        self.processGraph = processGraph
    }

    // MARK: The opening

    private var versionInFile: String? {
        return database.modelVersionFilePath().flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    private var versionInPreference: String? {
        return processGraph.preferences[DatabasePreferences.databaseVersion]
    }

    /// Whether the index in place waits for an upgrade that did not happen, so
    /// that opening it must not set it aside.
    var indexAwaitsUpgrade: Bool {
        return ModelUpgradeRules.indexAwaitsUpgrade(file: versionInFile, preference: versionInPreference, current: CurrentDatabaseVersion)
    }

    /// Upgrades the index at `indexPath` before the database opens it, when it is
    /// of another model. True when the index was copied, so that the patient
    /// identifiers need computing again; a rebuild makes them new.
    ///
    /// The version becomes the current one here only when the upgrade went well.
    /// A rebuild that took over writes it itself once the former index is
    /// retired, and one that stopped before that leaves it: the file still
    /// describes the index beside it, and the next opening tries again.
    func upgradeBeforeOpening(indexPath: String?) -> Bool {
        guard let version = ModelUpgradeRules.versionToUpgrade(file: versionInFile, preference: versionInPreference, current: CurrentDatabaseVersion,
                                                               indexExists: DicomDatabaseObjC.fileExists(indexPath)) else { return false }
        let upgraded = database.upgradeSqlFile(fromModelVersion: version)
        // A remote database rebuilds nothing and has no next attempt: its index
        // comes from its server, always in the current model.
        if upgraded || !database.rebuildAllowed(), let path = database.modelVersionFilePath() {
            try? (CurrentDatabaseVersion as NSString).write(toFile: path, atomically: true, encoding: String.Encoding.utf8.rawValue)
        }
        return upgraded
    }

    // MARK: The upgrade

    /// Copies Database.sql, of the model of `databaseModelVersion`, into a new
    /// index that takes its place. False when the index was rebuilt instead,
    /// or left as it was, so that nothing of it needs working on.
    func run(fromModelVersion databaseModelVersion: String!) -> Bool {
        NSLog("------ upgradeSqlFileFromModelVersion: %@", DicomDatabaseObjC.arg(databaseModelVersion))

        let thread = Thread.current
        let oldThreadName = thread.name

        var result = false

        // The contexts and coordinators the upgrade opens. An exception unwinds
        // the block below without releasing its locals, so they are closed
        // after it from here.
        var openedContexts: [NSManagedObjectContext] = []
        var openedCoordinators: [NSPersistentStoreCoordinator] = []

        thread.enterOperation()
        let exception = HorosObjCException.caught {
            thread.name = NSLocalizedString("Upgrading database...", comment: "")

            //   [NSThread sleepForTimeInterval:2];

            let oldModelFilename = ModelUpgradeRules.modelFileName(forVersion: databaseModelVersion, current: CurrentDatabaseVersion)

            let resourcePath = Bundle.main.resourcePath
            if !DicomDatabaseObjC.fileExists(DicomDatabaseObjC.appending(resourcePath, oldModelFilename)) {
                var r = HorosAlertPanel.defaultResponse

                if processGraph.preferences[NetworkPreferences.hidesListenerErrors] {
                    r = HorosAlertPanel.defaultResponse
                } else {
                    r = onMainRunLoopSync {
                        HorosAlertPanel.run(title: NSLocalizedString("IsiX DICOM Viewer Database", comment: ""),
                                            message: NSLocalizedString("IsiX DICOM Viewer cannot understand the model of current saved database... The database index will be deleted and reconstructed (no images are lost).", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Quit", comment: ""), otherButton: nil)
                    }
                }

                if r == HorosAlertPanel.alternateResponse {
                    if let path = database.loadingFilePath() { try? FileManager.default.removeItem(atPath: path) } // to avoid the crash message during next startup
                    onMainRunLoopSync { NSApp.terminate(nil) }
                    // Back here, the quit was refused: the person did not agree to
                    // a rebuild, so the index stays as it is for the next opening.
                    result = false
                    return
                }

                // The index is not deleted first: -rebuild: keeps a verified
                // copy of it, and reads its albums from there.
                database.rebuild(true)

                result = false
                return
            }

            guard let oldModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: DicomDatabaseObjC.appending(resourcePath, oldModelFilename)!)) else {
                // -initWithManagedObjectModel: raised for a nil model.
                NSException(name: .invalidArgumentException, reason: "Cannot create an NSPersistentStoreCoordinator with a nil model", userInfo: nil).raise()
                return
            }
            let oldPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
            let oldContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

            let newModel: NSManagedObjectModel = database.managedObjectModel
            let newPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
            let newContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

            openedContexts = [oldContext, newContext]
            openedCoordinators = [oldPersistentStoreCoordinator, newPersistentStoreCoordinator]

            let upgradeProblems = NSMutableArray()
            /// The studies that stayed without a series or an image, by the
            /// identifier of the former study, which a second copy of it replaces.
            var upgradeLosses: [NSManagedObjectID: UpgradeLoss] = [:]

            removeLeftoverUpgradeIndex(database.baseDirPath)

            // A former index that does not open would be copied as an empty one:
            // stop, and leave it as it is. It is opened without a write-ahead
            // log, as the database opens it: one would be left beside it as
            // Database.sql-wal and -shm once it is renamed, where SQLite reads
            // them as the log of the new Database.sql.
            do {
                try oldPersistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: database.sqlFilePath), options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

            do {
                // Without a write-ahead log, so that Database3.sql is the whole
                // index once it is closed, as the database opens it afterwards.
                try newPersistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: DicomDatabaseObjC.appending(database.baseDirPath, "Database3.sql")!), options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

            // Private-queue contexts, given their coordinators once the
            // stores are in, and used from here to the closing of the stores
            // inside their queues; an exception is raised again outside them.
            oldContext.persistentStoreCoordinator = oldPersistentStoreCoordinator
            oldContext.undoManager = nil
            newContext.persistentStoreCoordinator = newPersistentStoreCoordinator
            newContext.undoManager = nil
            N2ManagedObjectContextPerformAndWait(oldContext) {
            N2ManagedObjectContextPerformAndWait(newContext) {

            /// The former index read, or the upgrade stops: an empty result would
            /// leave studies out of the new index.
            func fetchOld(_ request: NSFetchRequest<NSFetchRequestResult>) -> [Any] {
                do {
                    return try oldContext.fetch(request)
                } catch {
                    DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                    upgradeFailure(error).raise()
                    return []
                }
            }

            var newStudyTable: NSManagedObject? = nil, newSeriesTable: NSManagedObject? = nil, newImageTable: NSManagedObject? = nil

            let req = NSFetchRequest<NSFetchRequestResult>()
            req.entity = entityNamed("Album", oldContext)
            req.predicate = NSPredicate(value: true)
            let albums = fetchOld(req)

            // The studies are added to these albums, each to the copies of its own
            // albums: they are saved first, or the upgrade stops.
            var albumCopies: [NSManagedObjectID: NSManagedObjectID] = [:]
            do {
                albumCopies = try copyUpgradeAlbums(albums, attributes: attributeNames(entityNamed("Album", oldContext)), into: newContext)
                try newContext.save()
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

            // STUDIES
            let dbRequest = NSFetchRequest<NSFetchRequestResult>()
            dbRequest.entity = oldModel.entitiesByName["Study"]
            dbRequest.predicate = NSPredicate(value: true)

            let studyIdentifiers = upgradeStudyIdentifiers(fetchOld(dbRequest))
            let studiesCount = studyIdentifiers.count
            thread.status = String(format: NSLocalizedString("Upgrading %d %@...", comment: ""), Int32(truncatingIfNeeded: studiesCount), (studiesCount != 1 ? NSLocalizedString("studies", comment: "") : NSLocalizedString("study", comment: "")))
            thread.progress = 0
            //   [NSThread sleepForTimeInterval:2];

            //[[splash progress] setMaxValue:[studies count]];

            let studyProperties = attributeNames(oldModel.entitiesByName["Study"])
            let seriesProperties = attributeNames(oldModel.entitiesByName["Series"])
            let imageProperties = attributeNames(oldModel.entitiesByName["Image"])

            var counter: Int32 = 0

            var newAlbums: [NSManagedObjectID: NSManagedObject]? = nil

            /// The albums of the new index, which the studies are added to, or
            /// the upgrade stops: without them the studies would lose their albums.
            func fetchNewAlbums() {
                // Find all current albums
                let r = NSFetchRequest<NSFetchRequestResult>()
                r.entity = newModel.entitiesByName["Album"]
                r.predicate = NSPredicate(value: true)

                do {
                    let fetched = try newContext.fetch(r).compactMap { $0 as? NSManagedObject }
                    newAlbums = Dictionary(fetched.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
                } catch {
                    DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                    upgradeFailure(error).raise()
                }
            }

            /// `[new willChangeValueForKey:key]; @try { [new setPrimitiveValue:value forKey:key]; } … [new didChangeValueForKey:key];`
            func setPrimitive(_ value: Any?, forKey key: String, of new: NSManagedObject?) {
                new?.willChangeValue(forKey: key)
                if let exception = HorosObjCException.caught({ new?.setPrimitiveValue(value, forKey: key) }) {
                    DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                }
                new?.didChangeValue(forKey: key)
            }

            /// Copies an attribute of the former model under the name and with
            /// the value the current model gives it. Past the setters for the
            /// keys that go that way; through them for the others, which is how
            /// an attribute that left the model, such as the path of an image,
            /// reaches the attributes that replace it.
            func copyAttribute(_ name: String, ofEntity entity: String, from old: NSManagedObject, to new: NSManagedObject?) {
                if ModelUpgradeRules.isRetired(name, ofEntity: entity) { return }

                let key = ModelUpgradeRules.currentKey(name, ofEntity: entity)
                let value = ModelUpgradeRules.upgradedValue(old.primitiveValue(forKey: name), ofKey: name, entity: entity)
                if ModelUpgradeRules.primitiveKeys.contains(name) {
                    setPrimitive(value, forKey: key, of: new)
                } else {
                    new?.setValue(value, forKey: key)
                }
            }

            /// Copies a study of the former index, with its series, images and
            /// album memberships, into the new one. When the copy raises, the study
            /// is listed, what was inserted for it is deleted, and false is returned.
            /// A series or an image whose copy raises goes alone, and the study stays
            /// without it, counted for the alert.
            func copyStudy(_ oldStudy: NSManagedObject) -> Bool {
                var studyName: Any? = nil
                var inserted: [NSManagedObject] = []
                var lostSeries = 0
                var lostImages = 0

                func insert(_ entityName: String) -> NSManagedObject {
                    let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: newContext)
                    inserted.append(object)
                    return object
                }

                /// Deletes what was inserted from `first` on: a series is inserted
                /// before it is linked to its study, and an image before it is linked
                /// to its series, so a copy that raises would leave a row of nothing.
                func discardInserted(from first: Int) {
                    if let e = HorosObjCException.caught({
                        for object in inserted[first...] { newContext.delete(object) }
                    }) {
                        DicomDatabaseObjC.log(e, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                    }
                    inserted.removeSubrange(first...)
                }

                // Outside the study's @try, whose handler would only list the study.
                if newAlbums == nil {
                    fetchNewAlbums()
                }

                if let e = HorosObjCException.caught({
                    newStudyTable = insert("Study")

                    for name in studyProperties {
                        copyAttribute(name, ofEntity: "Study", from: oldStudy, to: newStudyTable)

                        if name == "name" {
                            studyName = oldStudy.primitiveValue(forKey: name)
                        }
                    }

                    // SERIES
                    let series = DicomDatabaseObjC.set(oldStudy, "series")?.allObjects ?? []
                    for case let oldSeries as NSManagedObject in series {
                        autoreleasepool {
                            let firstOfSeries = inserted.count
                            var lostImagesOfSeries = 0
                            if let e = HorosObjCException.caught({
                                newSeriesTable = insert("Series")

                                for name in seriesProperties where !ModelUpgradeRules.seriesKeysLeftOut.contains(name) {
                                    copyAttribute(name, ofEntity: "Series", from: oldSeries, to: newSeriesTable)
                                }
                                newSeriesTable?.setValue(newStudyTable, forKey: "study")

                                // IMAGES
                                let images = DicomDatabaseObjC.set(oldSeries, "images")?.allObjects ?? []
                                for case let oldImage as NSManagedObject in images {
                                    let firstOfImage = inserted.count
                                    if let e = HorosObjCException.caught({
                                        newImageTable = insert("Image")

                                        for name in imageProperties where !ModelUpgradeRules.imageKeysLeftOut.contains(name) {
                                            copyAttribute(name, ofEntity: "Image", from: oldImage, to: newImageTable)
                                        }
                                        newImageTable?.setValue(newSeriesTable, forKey: "series")
                                    }) {
                                        NSLog("IMAGE LEVEL: Problems during updating: %@", e)
                                        e.printStackTrace()
                                        discardInserted(from: firstOfImage)
                                        lostImagesOfSeries += 1
                                    }
                                }
                            }) {
                                NSLog("SERIES LEVEL: Problems during updating: %@", e)
                                e.printStackTrace()
                                discardInserted(from: firstOfSeries)
                                lostSeries += 1
                                lostImagesOfSeries = 0 // they went with their series
                            }
                            lostImages += lostImagesOfSeries
                        }
                    }

                    let storedInAlbums = DicomDatabaseObjC.set(oldStudy, "albums")?.allObjects ?? []

                    if storedInAlbums.count != 0 {
                        if let e = HorosObjCException.caught({
                            if let newStudyTable, let newAlbums {
                                addUpgradedStudy(newStudyTable, toCopiesOf: storedInAlbums, copies: albumCopies, albums: newAlbums)
                            }
                        }) {
                            NSLog("ALBUM : %@", e)
                            e.printStackTrace()
                        }
                    }
                }) {
                    NSLog("STUDY LEVEL: Problems during updating: %@", e)
                    NSLog("Patient Name: %@", DicomDatabaseObjC.arg(studyName))
                    upgradeProblems.add(upgradeProblemName(studyName))

                    e.printStackTrace()

                    // Listed as removed: what was copied of it does not stay in the
                    // context, where it would make the save of its batch fail.
                    if let e = HorosObjCException.caught({
                        for object in inserted { newContext.delete(object) }
                    }) {
                        DicomDatabaseObjC.log(e, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                    }
                    upgradeLosses[oldStudy.objectID] = nil
                    return false
                }
                upgradeLosses[oldStudy.objectID] = lostSeries == 0 && lostImages == 0 ? nil
                    : UpgradeLoss(study: upgradeProblemName(studyName), series: lostSeries, images: lostImages)
                return true
            }

            /// The studies copied since the last save, saved one at a time if the
            /// save of all of them fails.
            var batch: [NSManagedObject] = []
            func saveBatch() {
                saveUpgradeBatch(newContext, batch, problems: upgradeProblems, copy: copyStudy, name: { study in
                    // Listed as removed, whole: nothing of it stayed.
                    upgradeLosses[study.objectID] = nil
                    return upgradeProblemName(studyProperties.contains("name") ? study.primitiveValue(forKey: "name") : nil)
                })
                batch = []
            }

            // Each study once, a hundred at a time: the contexts are saved and
            // reset between them, so that only a hundred studies are held at once.
            forEachUpgradeStudy(studyIdentifiers, in: oldContext, copy: { oldStudy in
                thread.progress = CGFloat(1.0 * Double(counter) / Double(studiesCount))

                if copyStudy(oldStudy) {
                    batch.append(oldStudy)
                }

                //		[splash incrementBy:1];
                counter &+= 1

                NSLog("%d", counter)
            }, betweenChunks: {
                saveBatch()

                newContext.reset()
                oldContext.reset()

                newAlbums = nil
            })

            thread.progress = -1

            saveBatch()

            copyUpgradeLogEntries(from: oldContext, to: newContext)

            // Both files are renamed below: no coordinator may still have them open.
            closeUpgradeStores(openedContexts, openedCoordinators)
            }
            }

            // An index that cannot take the place of the former one stops the
            // upgrade, with Database.sql as it was.
            do {
                try moveUpgradedIndex(database.sqlFilePath, upgraded: DicomDatabaseObjC.appending(database.baseDirPath, "Database3.sql")!,
                                      previous: DicomDatabaseObjC.appending(database.baseDirPath, "Database-Old-PreviousVersion.sql")!)
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

            if let message = upgradeProblemMessage(removed: upgradeProblems.compactMap { $0 as? String }, losses: Array(upgradeLosses.values)) {
                _ = onMainRunLoopSync {
                    HorosAlertPanel.run(title: NSLocalizedString("Database Upgrade", comment: ""), message: message,
                                        defaultButton: nil, alternateButton: nil, otherButton: nil)
                }
            }

            result = true
        }
        // Before a rebuild moves the index, and so that nothing opened above outlives the upgrade.
        closeUpgradeStores(openedContexts, openedCoordinators)
        openedContexts = []
        openedCoordinators = []
        if let e = exception {
            DicomDatabaseObjC.log(e, stack: true, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")

            _ = onMainRunLoopSync {
                HorosAlertPanel.run(title: NSLocalizedString("Database Update", comment: ""),
                                    message: NSLocalizedString("Database updating failed... The database SQL index file is probably corrupted... The database will be reconstructed.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            }

            database.rebuild(true)

            result = false
        }

        thread.exitOperation()
        thread.name = oldThreadName

        return result
    }
}
