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

// The "Other" methods of DicomDatabase are implemented in Swift since #833: a
// Swift extension of DicomDatabase, which stays Objective-C, with the
// selectors of the former methods. DicomDatabase.h imports
// DicomDatabase+Other.h, so that plugins still see them. The instance
// variables they use are read through DicomDatabase (SwiftIvars).
//
// An @try is HorosObjCException.perform (DicomDatabaseObjC.attempt): an
// @throw inside it is an NSException raised and caught by the same block, and
// the code of an @finally runs after it, raising again what it caught. The
// NSAutoreleasePools are autoreleasepool blocks.
//
// -upgradeSqlFileFromModelVersion: closes the stores it opened before it
// renames their files, and again after the upgrade whether or not it finished,
// so that no coordinator keeps Database3.sql open once it is Database.sql.

/// The attributes that the former upgrade copied without KVO or skipped.
private let upgradeCommentKeys: Set<String> = ["isKeyImage", "comment", "comment2", "comment3", "comment4", "reportURL", "stateText"]
private let upgradeSeriesSkippedKeys: Set<String> = ["xOffset", "yOffset", "scale", "rotationAngle", "displayStyle", "windowLevel", "windowWidth", "yFlipped", "xFlipped"]
private let upgradeImageSkippedKeys: Set<String> = ["xOffset", "yOffset", "scale", "rotationAngle", "windowLevel", "windowWidth", "yFlipped", "xFlipped"]

/// `[NSEntityDescription entityForName:name inManagedObjectContext:context]`,
/// which raised for a nil context.
private func entityNamed(_ name: String, _ context: NSManagedObjectContext?) -> NSEntityDescription? {
    if let context { return NSEntityDescription.entity(forEntityName: name, in: context) }
    return (NSEntityDescription.self as AnyObject).perform(#selector(NSEntityDescription.entity(forEntityName:in:)), with: name, with: nil)?.takeUnretainedValue() as? NSEntityDescription
}

/// `[[entity attributesByName] allKeys]`, in the order of the NSDictionary.
private func attributeNames(_ entity: NSEntityDescription?) -> [String] {
    return ((entity?.value(forKey: "attributesByName") as? NSDictionary)?.allKeys as? [String]) ?? []
}

/// `[array addObject:object]`, which raised on nil.
private func add(_ object: Any?, to array: NSMutableArray) {
    if let object { array.add(object) } else { _ = array.perform(#selector(NSMutableArray.add(_:)), with: nil) }
}

/// `[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL]`.
private func contentsOfDirectory(_ path: String?) -> [String]? {
    guard let path else { return nil }
    return try? FileManager.default.contentsOfDirectory(atPath: path)
}

/// `[name characterAtIndex:0] != '.'`, which raised on an empty name.
private func isNotHidden(_ name: String) -> Bool {
    return (name as NSString).character(at: 0) != UInt16(UInt8(ascii: "."))
}

/// N2LocalizedSingularPluralCount(c, s, p) of N2Stuff.h.
private func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), count == 1 ? singular : plural)
}

/// Forgets what the contexts hold and removes every store of the coordinators,
/// which closes their SQLite files. Removing a store that is already gone is a
/// no-op, so this can run more than once.
private func closeUpgradeStores(_ contexts: [NSManagedObjectContext], _ coordinators: [NSPersistentStoreCoordinator]) {
    if let exception = DicomDatabaseObjC.attempt({
        for context in contexts { context.reset() }
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

/// The exception -rebuild: stops with. A save can fail without an error, and
/// then there is no underlying error to name, rather than a nil one.
private func rebuildFailure(_ error: NSError?) -> NSException {
    return NSException(name: NSExceptionName("DatabaseRebuildFailure"),
                       reason: error?.localizedDescription ?? NSLocalizedString("unknown error", comment: ""),
                       userInfo: error.map { [NSUnderlyingErrorKey: $0] })
}

/// What -upgradeSqlFileFromModelVersion: lists for a study it could not copy.
private func upgradeProblemName(_ studyName: Any?) -> String {
    if let name = studyName as? String, !name.isEmpty { return name }
    return NSLocalizedString("Unnamed", comment: "")
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

public extension DicomDatabase {

    // MARK: - Other

    @objc(rebuildAllowed)
    dynamic func rebuildAllowed() -> Bool {
        return true
    }

    @objc(upgradeSqlFileFromModelVersion:)
    dynamic func upgradeSqlFile(fromModelVersion databaseModelVersion: String!) -> Bool {
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
        let exception = DicomDatabaseObjC.attempt {
            thread.name = NSLocalizedString("Upgrading database...", comment: "")

            //   [NSThread sleepForTimeInterval:2];

            var oldModelFilename = String(format: "OsiriXDB_Previous_DataModel%@.mom", DicomDatabaseObjC.arg(databaseModelVersion))
            if DicomDatabaseObjC.isEqual(databaseModelVersion, CurrentDatabaseVersion) { oldModelFilename = String(format: "OsiriXDB_DataModel.mom") } // same version

            let resourcePath = Bundle.main.resourcePath
            if !DicomDatabaseObjC.fileExists(DicomDatabaseObjC.appending(resourcePath, oldModelFilename)) {
                var r = NSAlertDefaultReturn

                if UserDefaults.standard.bool(forKey: "hideListenerError") {
                    r = NSAlertDefaultReturn
                } else {
                    r = HorosAlertPanel.run(title: NSLocalizedString("Horos Database", comment: ""),
                                            message: NSLocalizedString("Horos cannot understand the model of current saved database... The database index will be deleted and reconstructed (no images are lost).", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Quit", comment: ""), otherButton: nil)
                }

                if r == NSAlertAlternateReturn {
                    if let path = self.loadingFilePath() { try? FileManager.default.removeItem(atPath: path) } // to avoid the crash message during next startup
                    NSApp.terminate(self)
                }

                // The index is not deleted first: -rebuild: keeps a verified
                // copy of it, and reads its albums from there (#913).
                self.rebuild(true)

                result = false
                return
            }

            guard let oldModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: DicomDatabaseObjC.appending(resourcePath, oldModelFilename)!)) else {
                // -initWithManagedObjectModel: raised for a nil model.
                NSException(name: .invalidArgumentException, reason: "Cannot create an NSPersistentStoreCoordinator with a nil model", userInfo: nil).raise()
                return
            }
            let oldPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
            let oldContext = NSManagedObjectContext()

            let newModel: NSManagedObjectModel = self.managedObjectModel
            let newPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
            let newContext = NSManagedObjectContext()

            openedContexts = [oldContext, newContext]
            openedCoordinators = [oldPersistentStoreCoordinator, newPersistentStoreCoordinator]

            let upgradeProblems = NSMutableArray()

            oldContext.persistentStoreCoordinator = oldPersistentStoreCoordinator
            oldContext.undoManager = nil
            newContext.persistentStoreCoordinator = newPersistentStoreCoordinator
            newContext.undoManager = nil

            removeLeftoverUpgradeIndex(self.baseDirPath)

            // A former index that does not open would be copied as an empty one:
            // stop, and leave it as it is. It is opened without a write-ahead
            // log, as the database opens it: one would be left beside it as
            // Database.sql-wal and -shm once it is renamed, where SQLite reads
            // them as the log of the new Database.sql.
            do {
                try oldPersistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: self.sqlFilePath), options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

            do {
                // Without a write-ahead log, so that Database3.sql is the whole
                // index once it is closed, as the database opens it afterwards.
                try newPersistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: DicomDatabaseObjC.appending(self.baseDirPath, "Database3.sql")!), options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

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

            /// `[new willChangeValueForKey:name]; @try { [new setPrimitiveValue:[old primitiveValueForKey:name] forKey:name]; } … [new didChangeValueForKey:name];`
            func copyPrimitive(_ name: String, from old: NSManagedObject, to new: NSManagedObject?) {
                new?.willChangeValue(forKey: name)
                if let exception = DicomDatabaseObjC.attempt({ new?.setPrimitiveValue(old.primitiveValue(forKey: name), forKey: name) }) {
                    DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                }
                new?.didChangeValue(forKey: name)
            }

            /// Copies a study of the former index, with its series, images and
            /// album memberships, into the new one. When the copy raises, the study
            /// is listed, what was inserted for it is deleted, and false is returned.
            func copyStudy(_ oldStudy: NSManagedObject) -> Bool {
                var studyName: Any? = nil
                var inserted: [NSManagedObject] = []

                func insert(_ entityName: String) -> NSManagedObject {
                    let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: newContext)
                    inserted.append(object)
                    return object
                }

                // Outside the study's @try, whose handler would only list the study.
                if newAlbums == nil {
                    fetchNewAlbums()
                }

                if let e = DicomDatabaseObjC.attempt({
                    newStudyTable = insert("Study")

                    for name in studyProperties {
                        if upgradeCommentKeys.contains(name) {
                            copyPrimitive(name, from: oldStudy, to: newStudyTable)
                        } else {
                            newStudyTable?.setValue(oldStudy.primitiveValue(forKey: name), forKey: name)
                        }

                        if name == "name" {
                            studyName = oldStudy.primitiveValue(forKey: name)
                        }
                    }

                    // SERIES
                    let series = DicomDatabaseObjC.set(oldStudy, "series")?.allObjects ?? []
                    for case let oldSeries as NSManagedObject in series {
                        autoreleasepool {
                            if let e = DicomDatabaseObjC.attempt({
                                newSeriesTable = insert("Series")

                                for name in seriesProperties {
                                    if upgradeSeriesSkippedKeys.contains(name) {

                                    } else if upgradeCommentKeys.contains(name) {
                                        copyPrimitive(name, from: oldSeries, to: newSeriesTable)
                                    } else {
                                        newSeriesTable?.setValue(oldSeries.primitiveValue(forKey: name), forKey: name)
                                    }
                                }
                                newSeriesTable?.setValue(newStudyTable, forKey: "study")

                                // IMAGES
                                let images = DicomDatabaseObjC.set(oldSeries, "images")?.allObjects ?? []
                                for case let oldImage as NSManagedObject in images {
                                    if let e = DicomDatabaseObjC.attempt({
                                        newImageTable = insert("Image")

                                        for name in imageProperties {
                                            if upgradeImageSkippedKeys.contains(name) {

                                            } else if upgradeCommentKeys.contains(name) {
                                                copyPrimitive(name, from: oldImage, to: newImageTable)
                                            } else {
                                                newImageTable?.setValue(oldImage.primitiveValue(forKey: name), forKey: name)
                                            }
                                        }
                                        newImageTable?.setValue(newSeriesTable, forKey: "series")
                                    }) {
                                        NSLog("IMAGE LEVEL: Problems during updating: %@", e)
                                        e.printStackTrace()
                                    }
                                }
                            }) {
                                NSLog("SERIES LEVEL: Problems during updating: %@", e)
                                e.printStackTrace()
                            }
                        }
                    }

                    let storedInAlbums = DicomDatabaseObjC.set(oldStudy, "albums")?.allObjects ?? []

                    if storedInAlbums.count != 0 {
                        if let e = DicomDatabaseObjC.attempt({
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
                    if let e = DicomDatabaseObjC.attempt({
                        for object in inserted { newContext.delete(object) }
                    }) {
                        DicomDatabaseObjC.log(e, stack: false, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                    }
                    return false
                }
                return true
            }

            /// The studies copied since the last save, saved one at a time if the
            /// save of all of them fails.
            var batch: [NSManagedObject] = []
            func saveBatch() {
                saveUpgradeBatch(newContext, batch, problems: upgradeProblems, copy: copyStudy,
                                 name: { upgradeProblemName(studyProperties.contains("name") ? $0.primitiveValue(forKey: "name") : nil) })
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

            // Both files are renamed below: no coordinator may still have them open.
            closeUpgradeStores(openedContexts, openedCoordinators)

            // An index that cannot take the place of the former one stops the
            // upgrade, with Database.sql as it was.
            do {
                try moveUpgradedIndex(self.sqlFilePath, upgraded: DicomDatabaseObjC.appending(self.baseDirPath, "Database3.sql")!,
                                      previous: DicomDatabaseObjC.appending(self.baseDirPath, "Database-Old-PreviousVersion.sql")!)
            } catch {
                DicomDatabaseObjC.logError((error as NSError).description, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")
                upgradeFailure(error).raise()
            }

            if upgradeProblems.count != 0 {
                HorosAlertPanel.run(title: NSLocalizedString("Database Upgrade", comment: ""),
                                    message: String(format: NSLocalizedString("The upgrade encountered %d errors. These corrupted studies have been removed: %@", comment: ""), Int32(truncatingIfNeeded: upgradeProblems.count), upgradeProblems.componentsJoined(by: ", ")),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            }

            result = true
        }
        // Before a rebuild moves the index, and so that nothing opened above outlives the upgrade.
        closeUpgradeStores(openedContexts, openedCoordinators)
        openedContexts = []
        openedCoordinators = []
        if let e = exception {
            DicomDatabaseObjC.log(e, stack: true, "-[DicomDatabase upgradeSqlFileFromModelVersion:]")

            HorosAlertPanel.run(title: NSLocalizedString("Database Update", comment: ""),
                                message: NSLocalizedString("Database updating failed... The database SQL index file is probably corrupted... The database will be reconstructed.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)

            self.rebuild(true)

            result = false
        }

        thread.exitOperation()
        thread.name = oldThreadName

        return result
    }

    // Series indexed before the importer derived an identifier for a file that
    // carried none have an empty seriesDICOMUID, and the C-FIND SCP answers with it:
    // an empty UI, in every response about that series. The value is derived from
    // what the row is already grouped on, so it is the same identifier a re-import
    // would produce.
    @objc(repairEmptySeriesIdentifiersInContext:)
    dynamic class func repairEmptySeriesIdentifiers(in context: NSManagedObjectContext!) {
        let request = NSFetchRequest<NSFetchRequestResult>()
        request.entity = entityNamed("Series", context)
        request.predicate = NSPredicate(format: "seriesDICOMUID == nil OR seriesDICOMUID == %@", "")

        context.lock()
        if let exception = DicomDatabaseObjC.attempt({
            let series = ((try? context.fetch(request)) ?? []) as NSArray
            if series.count == 0 {
                return
            }

            NSLog("-------------- %d series have no DICOM identifier; deriving one for each", Int32(truncatingIfNeeded: series.count))

            for case let one as NSManagedObject in series {
                if let exception = DicomDatabaseObjC.attempt({
                    let grouping = one.value(forKey: "seriesInstanceUID") as? String
                    let study = one.value(forKeyPath: "study.studyInstanceUID") as? String
                    let derived = HorosDerivedUID.seriesUID(forKey: String(format: "%@|%@", study ?? "", grouping ?? ""))
                    one.setValue(derived, forKey: "seriesDICOMUID")
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairEmptySeriesIdentifiersInContext:]")
                }
            }

            // The context is what holds the changes; this is a class method, so
            // there is no database instance to ask.
            do {
                try context.save()
            } catch {
                NSLog("**** could not save the derived series identifiers: %@", (error as NSError).localizedDescription)
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairEmptySeriesIdentifiersInContext:]")
        }
        context.unlock()
    }

    @objc(repairFabricatedPatientIdentifiersInContext:)
    dynamic class func repairFabricatedPatientIdentifiers(in context: NSManagedObjectContext!) {
        // A patient with no date of birth used to be given one, so the identifier
        // stored for those studies carries a date that was never in any file. Left
        // there, every instance of that patient arriving from now on computes an
        // identifier without it and lands in a third study instead of the one it
        // belongs to - the same split again, by the other route.
        let request = NSFetchRequest<NSFetchRequestResult>()
        request.entity = entityNamed("Study", context)
        request.predicate = NSPredicate(format: "dateOfBirth == nil AND patientUID != nil")

        context.lock()
        if let exception = DicomDatabaseObjC.attempt({
            let studies = ((try? context.fetch(request)) ?? []) as NSArray
            var repaired: Int32 = 0

            for case let study as NSManagedObject in studies {
                if let exception = DicomDatabaseObjC.attempt({
                    let stored = study.value(forKey: "patientUID") as? String
                    if PatientIdentity.uidCarriesABirthDate(stored ?? "") == false {
                        return
                    }

                    let corrected = PatientIdentity.uidWithoutBirthDate(stored ?? "")
                    if DicomDatabaseObjC.isEqual(corrected, stored) {
                        return
                    }

                    NSLog("---- patient identity: %@ has no date of birth; %@ becomes %@", DicomDatabaseObjC.arg(study.value(forKey: "name")), DicomDatabaseObjC.arg(stored), corrected)
                    study.setValue(corrected, forKey: "patientUID")
                    repaired &+= 1
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairFabricatedPatientIdentifiersInContext:]")
                }
            }

            if repaired != 0 {
                do {
                    try context.save()
                } catch {
                    NSLog("**** could not save the repaired patient identifiers: %@", (error as NSError).localizedDescription)
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairFabricatedPatientIdentifiersInContext:]")
        }
        context.unlock()
    }

    @objc(recomputePatientUIDsInContext:)
    dynamic class func recomputePatientUIDs(in context: NSManagedObjectContext!) {

        // Find all studies
        let dbRequest = NSFetchRequest<NSFetchRequestResult>()
        dbRequest.entity = entityNamed("Study", context)
        dbRequest.predicate = NSPredicate(value: true)

        context.lock()
        if let exception = DicomDatabaseObjC.attempt({
            let studiesArray = ((try? context.fetch(dbRequest)) ?? []) as NSArray

            if studiesArray.count != 0 {
                NSLog("-------------- Recompute Patient UIDs -- START")

                var wait: Wait? = nil
                if Thread.isMainThread && studiesArray.count > 200 {
                    wait = Wait(string: NSLocalizedString("Recomputing Patient UIDs...", comment: ""))
                }

                wait?.showWindow(self)

                wait?.progress()?.maxValue = Double(studiesArray.count)

                var i: Int32 = 0

                for case let study as NSManagedObject in studiesArray {
                    autoreleasepool {
                        wait?.increment(by: 1)

                        if let exception = DicomDatabaseObjC.attempt({

                            let uid = DicomFile.patientUID(DicomDatabaseObjC.dictionary([(study.value(forKey: "name"), "patientName"),
                                                                                           (study.value(forKey: "patientID"), "patientID"),
                                                                                           (study.value(forKey: "dateOfBirth"), "patientBirthDate")]))

                            if let uid {
                                study.setValue(uid, forKey: "patientUID")
                            }

                        }) {
                            DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase recomputePatientUIDsInContext:]")
                        }
                    }

                    i &+= 1

                    if i % 1000 == 0 {
                        try? context.save()
                    }
                }

                try? context.save()

                wait?.close()

                NSLog("-------------- Recompute Patient UIDs -- END")
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase recomputePatientUIDsInContext:]")
        }
        context.unlock()
    }

    /// The models an index of this database can be of: the current one, then
    /// the former ones the application carries, newest first.
    private func indexModels() -> [NSManagedObjectModel] {
        var models: [NSManagedObjectModel] = []
        if let current = self.managedObjectModel { models.append(current) }
        let former = Bundle.main.paths(forResourcesOfType: "mom", inDirectory: nil)
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("OsiriXDB_Previous_DataModel") }
            .sorted { ($0 as NSString).lastPathComponent.compare(($1 as NSString).lastPathComponent, options: .numeric) == .orderedDescending }
        for path in former {
            if let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) { models.append(model) }
        }
        return models
    }

    @objc(rebuild)
    dynamic func rebuild() {
        self.rebuild(false)
    }

    @objc(rebuild:)
    dynamic func rebuild(_ complete: Bool) {
        let thread = Thread.current

        NotificationCenter.default.post(name: .OsirixDatabaseObjectsMayBecomeUnavailable, object: self, userInfo: nil)

        self.horos_importFilesFromIncomingDirLock?.lock()

        var recoveryFolder: String? = nil
        var savedAlbumsPath: String? = nil
        var albumsLost = false
        var contextLocked = false
        if let e = DicomDatabaseObjC.attempt({
            if complete {
                var error: NSError? = nil
                if self.managedObjectContext != nil && !self.save(&error) {
                    rebuildFailure(error).raise()
                }

                // Finish a verified recovery snapshot before retiring any active file.
                if DicomDatabaseObjC.fileExists(self.sqlFilePath) {
                    let metadata = DicomDatabaseObjC.fileExists(self.modelVersionFilePath()) ? self.modelVersionFilePath() : nil
                    do {
                        recoveryFolder = try DatabaseIndexBackup.snapshot(atPath: self.sqlFilePath, metadataPath: metadata)
                    } catch let snapshotError {
                        error = snapshotError as NSError
                    }
                    if recoveryFolder == nil {
                        rebuildFailure(error).raise()
                    }
                } else {
                    recoveryFolder = (((self.sqlFilePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Index Backups") as NSString).appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.createDirectory(atPath: recoveryFolder!, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
                    } catch let createError {
                        error = createError as NSError
                        rebuildFailure(error).raise()
                    }
                }
                savedAlbumsPath = DicomDatabaseObjC.appending(recoveryFolder, "Albums.plist")
                self.saveAlbums(toPath: savedAlbumsPath)

                // A rebuild started while the database opens its index (an
                // upgrade that failed) has no context to save the albums
                // from: they are read from the verified copy instead, and when
                // they cannot be, the default ones are created again and the
                // person is told where the copy is (#913).
                if self.managedObjectContext == nil,
                   let copy = DicomDatabaseObjC.appending(recoveryFolder, (self.sqlFilePath as NSString).lastPathComponent),
                   DicomDatabaseObjC.fileExists(copy) {
                    if let albums = albumsFileEntries(ofIndexAtPath: copy, models: self.indexModels()) {
                        if albums.count != 0, let savedAlbumsPath, !albums.write(toFile: savedAlbumsPath, atomically: true) {
                            NSLog("--- albums could not be saved to %@", savedAlbumsPath as NSString)
                            albumsLost = true
                        }
                    } else {
                        NSLog("--- the albums of %@ could not be read", copy as NSString)
                        albumsLost = true
                    }
                }

                thread.status = NSLocalizedString("Locking database...", comment: "")
                let oldContext = self.managedObjectContext
                oldContext?.lock()
                let raised = DicomDatabaseObjC.attempt {
                    self.managedObjectContext = nil
                    if DicomDatabaseObjC.fileExists(self.sqlFilePath) {
                        let retiredPath = DicomDatabaseObjC.appending(recoveryFolder, "RetiredDatabase.sql")!
                        do {
                            try FileManager.default.moveItem(atPath: self.sqlFilePath, toPath: retiredPath)
                        } catch let moveError {
                            error = moveError as NSError
                            self.managedObjectContext = oldContext
                            rebuildFailure(error).raise()
                        }
                    }
                }
                oldContext?.unlock()
                if let raised { raised.raise() }
                if let path = self.modelVersionFilePath() { try? FileManager.default.removeItem(atPath: path) }
                self.managedObjectContext = self.context(atPath: self.sqlFilePath)
                if self.managedObjectContext == nil {
                    NSException(name: NSExceptionName("DatabaseRebuildFailure"), reason: NSLocalizedString("The reconstructed database index could not be opened.", comment: ""), userInfo: nil).raise()
                }
            } else {
                _ = self.save(nil)
            }

            self.lock()
            contextLocked = true
            thread.status = NSLocalizedString("Scanning database directory...", comment: "")

            let filesArray = NSMutableArray(capacity: 10000)

            // SCAN THE DATABASE FOLDER, TO BE SURE WE HAVE EVERYTHING!

            let aPath = self.dataDirPath()
            let incomingPath = self.incomingDirPath()

            NSLog("Scan the Database folder")

            // In the DATABASE FOLDER, we have only folders! Move all files that are wrongly there to the INCOMING folder.... and then scan these folders containing the DICOM files

            var dirContent = contentsOfDirectory(aPath)
            autoreleasepool {
                for dir in dirContent ?? [] {
                    let itemPath = DicomDatabaseObjC.appending(aPath, dir)!
                    let attributes = try? FileManager.default.attributesOfItem(atPath: itemPath)
                    if (attributes?[.type] as? FileAttributeType) == .typeRegular {
                        if let destination = DicomDatabaseObjC.appending(incomingPath, (itemPath as NSString).lastPathComponent) {
                            try? FileManager.default.moveItem(atPath: itemPath, toPath: destination)
                        }
                    }
                }
            }

            dirContent = contentsOfDirectory(aPath)

            NSLog("Start Rebuild")

            for name in dirContent ?? [] {
                autoreleasepool {
                    let curDir = DicomDatabaseObjC.appending(aPath, name)!
                    let subDir = contentsOfDirectory(DicomDatabaseObjC.appending(aPath, name))

                    for subName in subDir ?? [] {
                        if isNotHidden(subName) {
                            filesArray.add((curDir as NSString).appendingPathComponent(subName))
                        }
                    }
                }
            }

            // ** DICOM ROI SR FOLDER
            autoreleasepool {
                dirContent = contentsOfDirectory(self.roisDirPath())
                for name in dirContent ?? [] {
                    if isNotHidden(name) {
                        add(DicomDatabaseObjC.appending(self.roisDirPath(), name), to: filesArray)
                    }
                }
            }

            // ** Finish the rebuild

            thread.status = String(format: NSLocalizedString("Adding %@...", comment: "rebuild database thread status: Adding %@ (%@ = '120 files')"), singularPluralCount(filesArray.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: "")))

            autoreleasepool {
                _ = self.addFiles(atPaths: filesArray as? [Any], postNotifications: false, dicomOnly: UserDefaults.standard.bool(forKey: "onlyDICOM"), rereadExistingItems: false, generatedByOsiriX: false, returnArray: false)
            }

            NSLog("End Rebuild")

            if !complete {
                thread.status = NSLocalizedString("Checking for missing files...", comment: "")

                // remove non-available images
                for case let aFile as DicomImage in (self.objects(forEntity: self.imageEntity()) as NSArray?) ?? [] {
                    var fp: UnsafeMutablePointer<FILE>? = nil
                    if let path = aFile.completePath() { fp = fopen(path, "r") }
                    if let fp {
                        fclose(fp)
                    } else {
                        self.managedObjectContext?.delete(aFile)
                    }
                }

                // remove empty studies
                thread.status = NSLocalizedString("Checking for empty studies...", comment: "")
                for case let study as DicomStudy in (self.objects(forEntity: self.studyEntity()) as NSArray?) ?? [] {
                    self.checkForExistingReport(forStudy: study)
                    if (study.series?.count ?? 0) == 0 || (study.noFiles()?.int32Value ?? 0) == 0 {
                        self.managedObjectContext?.delete(study)
                    }
                }
            } else {
                //Restore albums
                if DicomDatabaseObjC.fileExists(savedAlbumsPath) {
                    self.loadAlbums(fromPath: savedAlbumsPath)
                    if let savedAlbumsPath { try? FileManager.default.removeItem(atPath: savedAlbumsPath) }
                }
                if albumsLost {
                    self.addDefaultAlbums()
                }
            }

            var saveError: NSError? = nil
            if !self.save(&saveError) {
                rebuildFailure(saveError).raise()
            }

            thread.status = NSLocalizedString("Checking reports consistency...", comment: "")
            self.checkReportsConsistencyWithDICOMSR()

            if albumsLost, let recoveryFolder {
                let description = String(format: NSLocalizedString("The albums of the former database index could not be read, and the default albums were created again. The former index is kept in: %@", comment: ""), recoveryFolder)
                let error = NSError(domain: "HorosDatabaseRebuild", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
                DispatchQueue.main.async { _ = NSApp.presentError(error) }
            }
        }) {
            DicomDatabaseObjC.log(e, stack: true, "-[DicomDatabase rebuild:]")
            let description: String
            if let recoveryFolder {
                description = String(format: NSLocalizedString("Database reconstruction stopped: %@\nRecovery files: %@", comment: ""), DicomDatabaseObjC.arg(e.reason), recoveryFolder)
            } else if complete {
                description = String(format: NSLocalizedString("Database reconstruction stopped before the index could be backed up: %@", comment: ""), DicomDatabaseObjC.arg(e.reason))
            } else {
                description = String(format: NSLocalizedString("Database maintenance stopped: %@", comment: ""), DicomDatabaseObjC.arg(e.reason))
            }
            let error = NSError(domain: "HorosDatabaseRebuild", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
            DispatchQueue.main.async { _ = NSApp.presentError(error) }
        }
        if contextLocked { self.unlock() }
        self.horos_importFilesFromIncomingDirLock?.unlock()
    }

    @objc(checkReportsConsistencyWithDICOMSR)
    dynamic func checkReportsConsistencyWithDICOMSR() {
        // Find all studies with reportURL
        self.managedObjectContext?.lock()

        if let exception = DicomDatabaseObjC.attempt({
            let predicate = NSPredicate(format: "reportURL != NIL")
            let dbRequest = NSFetchRequest<NSFetchRequestResult>()
            dbRequest.entity = self.managedObjectModel.entitiesByName["Study"]
            dbRequest.predicate = predicate

            let studiesArray = ((try? self.managedObjectContext?.fetch(dbRequest)) ?? nil) ?? []

            for case let s as DicomStudy in studiesArray {
                s.archiveReportAsDICOMSR()
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase checkReportsConsistencyWithDICOMSR]")
        }
        self.managedObjectContext?.unlock()
    }

    @objc(checkForExistingReportForStudy:)
    dynamic func checkForExistingReport(forStudy study: NSManagedObject!) {
        // #ifndef OSIRIX_LIGHT (compiled)
        let attached = study?.value(forKey: "reportURL") as? String
        if let attached, (attached as NSString).length != 0, attached.hasPrefix("http://") || attached.hasPrefix("https://") || FileManager.default.fileExists(atPath: attached) {
            return
        }
        if let exception = DicomDatabaseObjC.attempt({ // is there a report?
            let filenames = DicomDatabaseObjC.array(Reports.getUniqueFilename(study), Reports.getOldUniqueFilename(study))
            let extensions = ["pages", "odt", "doc", "docx", "rtf"]
            for case let filename as String in filenames {
                for `extension` in extensions {
                    let reportPath = DicomDatabaseObjC.appending(self.reportsDirPath(), String(format: "%@.%@", filename, `extension`))
                    if DicomDatabaseObjC.fileExists(reportPath) {
                        study?.setValue(reportPath, forKey: "reportURL")
                        return
                    }
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase checkForExistingReportForStudy:]")
        }
    }

    @objc(allowAutoroutingWithPostNotifications:rereadExistingItems:)
    dynamic func allowAutorouting(withPostNotifications postNotifications: Bool, rereadExistingItems: Bool) -> Bool {
        return true
    }

    @objc(alertToApplyRoutingRules:toImages:)
    dynamic func alertToApplyRoutingRules(_ routingRules: [Any]!, toImages images: [Any]!) {
        self.applyRoutingRules(nil, toImages: images as NSArray?)
    }

    @objc(dumpSqlFile)
    dynamic func dumpSqlFile() {

        if let exception = DicomDatabaseObjC.attempt({
            let repairedDBFile = (self.sqlFilePath as NSString).appendingPathExtension("dump")!

            try? FileManager.default.removeItem(atPath: repairedDBFile)
            FileManager.default.createFile(atPath: repairedDBFile, contents: Data(), attributes: nil)

            var theTask = Process()
            theTask.launchPath = "/usr/bin/sqlite3"
            theTask.standardOutput = FileHandle(forWritingAtPath: repairedDBFile)
            theTask.arguments = [self.sqlFilePath, ".dump"]

            theTask.launch()

            while theTask.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }

            //[theTask waitUntilExit];		// <- This is VERY DANGEROUS : the main runloop is continuing...

            let dumpStatus = theTask.terminationStatus

            if dumpStatus == 0 {
                let repairedDBFinalFile = (repairedDBFile as NSString).appendingPathExtension("sql")!
                try? FileManager.default.removeItem(atPath: repairedDBFinalFile)

                theTask = Process()
                theTask.launchPath = "/usr/bin/sqlite3"
                theTask.standardInput = FileHandle(forReadingAtPath: repairedDBFile)
                theTask.arguments = [repairedDBFinalFile]

                theTask.launch()
                while theTask.isRunning {
                    Thread.sleep(forTimeInterval: 0.1)
                }

                //[theTask waitUntilExit];		// <- This is VERY DANGEROUS : the main runloop is continuing...

                if theTask.terminationStatus == 0 {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: self.sqlFilePath), resultingItemURL: nil)
                    try? FileManager.default.moveItem(atPath: repairedDBFinalFile, toPath: self.sqlFilePath)
                }
            }

            try? FileManager.default.removeItem(atPath: repairedDBFile)
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase dumpSqlFile]")
        }

    }

    @objc(rebuildSqlFile)
    dynamic func rebuildSqlFile() {
        self.horos_importFilesFromIncomingDirLock?.lock()

        _ = self.save(nil)
        self.managedObjectContext = nil

        self.dumpSqlFile()
        //	[self upgradeSqlFileFromModelVersion:CurrentDatabaseVersion]; // removing this line reflects antoine's commit 9758

        self.managedObjectContext = self.context(atPath: self.sqlFilePath)

        self.checkReportsConsistencyWithDICOMSR()

        self.horos_importFilesFromIncomingDirLock?.unlock()
    }

    @objc(checkForHtmlTemplates)
    dynamic func checkForHtmlTemplates() {
        let fileManager = FileManager.default
        let resourcePath = Bundle.main.resourcePath

        /// `[NSFileManager copyItemAtPath:[resourcePath stringByAppendingPathComponent:resource] toPath:path error:NULL]`
        func copyResource(_ resource: String, to path: String?) {
            guard let source = DicomDatabaseObjC.appending(resourcePath, resource), let path else { return }
            try? fileManager.copyItem(atPath: source, toPath: path)
        }

        // directory
        let htmlTemplatesDirectory = self.htmlTemplatesDirPath()
        if DicomDatabaseObjC.fileExists(htmlTemplatesDirectory) == false, let htmlTemplatesDirectory {
            try? fileManager.createDirectory(atPath: htmlTemplatesDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // HTML templates
        var templateFile: String?

        templateFile = DicomDatabaseObjC.appending(htmlTemplatesDirectory, "QTExportPatientsTemplate.html")
        if DicomDatabaseObjC.fileExists(templateFile) == false {
            copyResource("QTExportPatientsTemplate.html", to: templateFile)
        }

        templateFile = DicomDatabaseObjC.appending(htmlTemplatesDirectory, "QTExportStudiesTemplate.html")
        if DicomDatabaseObjC.fileExists(templateFile) == false {
            copyResource("QTExportStudiesTemplate.html", to: templateFile)
        }

        templateFile = DicomDatabaseObjC.appending(htmlTemplatesDirectory, "QTExportSeriesTemplate.html")
        if DicomDatabaseObjC.fileExists(templateFile) == false {
            copyResource("QTExportSeriesTemplate.html", to: templateFile)
        }

        // HTML-extra directory
        let htmlExtraDirectory = DicomDatabaseObjC.appending(htmlTemplatesDirectory, "html-extra/")
        if DicomDatabaseObjC.fileExists(htmlExtraDirectory) == false, let htmlExtraDirectory {
            try? fileManager.createDirectory(atPath: htmlExtraDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // CSS file
        let cssFile = DicomDatabaseObjC.appending(htmlExtraDirectory, "style.css")
        if DicomDatabaseObjC.fileExists(cssFile) == false {
            copyResource("QTExportStyle.css", to: cssFile)
        }

    }
}
