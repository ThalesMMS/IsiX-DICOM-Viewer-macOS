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
import IsiXPreferences
import IsiXStorage

// The "Instance" methods of DicomDatabase are implemented in Swift:
// a Swift extension of DicomDatabase, with the selectors of the former
// methods. DicomDatabase.h imports DicomDatabase+Instance.h, so that plugins
// still see them. The state they use is stored by DicomDatabase.swift.
//
// The initializer, deinit, the properties with the -name getter, and the three
// C paths the DICOM listener reads are in DicomDatabase.swift; -release, which
// takes the registry lock of the databases by path, in DicomDatabase+CAPI.m.
//
// An @try is HorosObjCException.caught, and the
// code of its @finally runs after it. An @synchronized is
// HorosObjCException.synchronized, the same recursive lock on the same object.
// A message to nil answered nil, NO or 0: the optionals give that value.

/// What the Objective-C did implicitly, for the DicomDatabase blocks that are
/// Swift.
enum DicomDatabaseObjC {

    /// N2LogException (stack: false) or N2LogExceptionWithStackTrace (stack:
    /// true), with the __PRETTY_FUNCTION__ of the former method.
    static func log(_ exception: NSException, stack: Bool, _ function: String) {
        _N2LogExceptionImpl(exception, stack, function)
    }

    /// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
    static func arg(_ object: Any?) -> CVarArg {
        if let object = object as? NSObject { return object }
        if let object { return String(describing: object) as NSString }
        return "(null)" as NSString
    }

    /// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug
    /// is active.
    static func DLog(_ format: StaticString, _ arguments: CVarArg...) {
        #if DEBUG
        unifiedLogv(format, arguments)
        #else
        if N2Debug.isActive() { unifiedLogv(format, arguments) }
        #endif
    }

    /// N2LogStackTrace(@"%@", message).
    static func logStackTrace(_ message: String) {
        DicomDatabaseLogStackTrace(message)
    }

    /// N2LogError(message), with the function of the former method.
    static func logError(_ message: String?, _ function: String, file: String = #file, line: Int = #line) {
        DicomDatabaseLogError(function, file, Int32(line), message ?? "(null)")
    }

    /// `[object key]` of a to-many relationship: the NSSet itself, without
    /// bridging it to a Swift Set, which would enumerate in another order.
    static func set(_ object: AnyObject?, _ key: String) -> NSSet? {
        return object?.value(forKey: key) as? NSSet
    }

    /// `[dictionary setObject:object forKey:key]`, which raised on nil.
    static func setObject(_ dictionary: NSMutableDictionary, _ object: Any?, _ key: Any) {
        if let object {
            dictionary.setObject(object, forKey: (key as AnyObject) as! NSCopying)
        } else {
            _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: nil, with: key)
        }
    }

    /// `[object objectForKey:key]`: nil for nil, and the unrecognized selector
    /// exception of before for an object that is not a dictionary.
    static func objectForKey(_ object: Any?, _ key: String) -> Any? {
        guard let object = object as AnyObject? else { return nil }
        if let dictionary = object as? NSDictionary { return dictionary.object(forKey: key) }
        return object.perform(#selector(NSDictionary.object(forKey:)), with: key)?.takeUnretainedValue()
    }

    /// `[NSArray arrayWithObjects: a, b, …, nil]`: the list ends at the first nil.
    static func array(_ items: Any?...) -> NSArray {
        let array = NSMutableArray()
        for item in items {
            guard let item else { break }
            array.add(item)
        }
        return array
    }

    /// `[NSDictionary dictionaryWithObjectsAndKeys: o1, k1, o2, k2, …, nil]`:
    /// the list ends at the first nil object.
    static func dictionary(_ pairs: [(Any?, String)]) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        for (object, key) in pairs {
            guard let object else { break }
            dictionary.setObject(object, forKey: key as NSString)
        }
        return NSDictionary(dictionary: dictionary)
    }

    /// `[string isEqualToString:other]` sent as the Objective-C sent it: NO to
    /// nil and against nil, and a literal comparison of the UTF-16 units.
    static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }

    /// `[path stringByAppendingPathComponent:component]`: nil for a nil path.
    static func appending(_ path: String?, _ component: String) -> String? {
        return (path as NSString?)?.appendingPathComponent(component)
    }

    /// `-[NSFileManager fileExistsAtPath:]`, NO for nil.
    static func fileExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// `-[NSFileManager fileExistsAtPath:isDirectory:]`, NO for nil.
    static func fileExists(_ path: String?, isDirectory: inout Bool) -> Bool {
        guard let path else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        isDirectory = isDir.boolValue
        return exists
    }

    /// `[NSFileManager.defaultManager enumeratorAtPath:path filesOnly:NO recursive:NO]`:
    /// nil, which enumerates nothing, for a nil path.
    static func enumerator(_ path: String?) -> N2DirectoryEnumerator? {
        guard let path else { return nil }
        let enumerator: N2DirectoryEnumerator? = FileManager.default.enumerator(atPath: path, filesOnly: false, recursive: false)
        return enumerator
    }

    /// `[string integerValue]`, 0 for nil.
    static func integerValue(_ string: String?) -> Int {
        return (string as NSString?)?.integerValue ?? 0
    }

    /// `[[string stringByDeletingPathExtension] integerValue]`, 0 for nil.
    static func integerValueWithoutExtension(_ string: String?) -> Int {
        return integerValue((string as NSString?)?.deletingPathExtension)
    }
}

/// -[DicomDatabase managedObjectModel]'s `static NSManagedObjectModel*`,
/// created once and never released. Databases are opened on several threads:
/// a global is made once, on first use, whichever thread asks first.
private let sharedManagedObjectModel = SharedManagedObjectModel(
    model: NSManagedObjectModel(contentsOf: URL(fileURLWithPath: (Bundle.main.resourcePath! as NSString).appendingPathComponent(DicomDatabase.modelName()))))

/// @unchecked Sendable: the model no longer changes once a coordinator uses
/// it, and Core Data shares such a model between threads.
private struct SharedManagedObjectModel: @unchecked Sendable {
    let model: NSManagedObjectModel?
}

/// `static NSString* const SqlFileName`.
private let SqlFileName = "Database.sql"

/// `#define PATIENTUIDVERSION` of -contextAtPath:.
private let PATIENTUIDVERSION = "2.0"

public extension DicomDatabase {

    // MARK: - Instance

    @objc(dataNodeIdentifier)
    dynamic func dataNodeIdentifier() -> DataNodeIdentifier! {
        return LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: self.baseDirPath) as? DataNodeIdentifier
    }

    @objc(description)
    override var description: String {
        return String(format: "<%@ 0x%08lx> \"%@\"", self.className, unsafeBitCast(self, to: Int.self), DicomDatabaseObjC.arg(self.name))
    }

    @objc(modelName)
    override class func modelName() -> String! {
        return "OsiriXDB_DataModel.momd"
    }

    @objc(deleteSQLFileIfOpeningFailed)
    override func deleteSQLFileIfOpeningFailed() -> Bool {
        // An index waiting for its upgrade is not damaged: set aside, the database
        // would open empty and the upgrade would never be tried again.
        return !DatabaseModelUpgrade(database: self).indexAwaitsUpgrade
    }

    @objc(migratePersistentStoresAutomatically)
    override func migratePersistentStoresAutomatically() -> Bool {
        // Nor for Core Data to migrate in place, which it can, as the store holds
        // its model: the next opening would find an index the record no longer
        // describes, and rebuild it instead of keeping what only the index holds.
        return !DatabaseModelUpgrade(database: self).indexAwaitsUpgrade
    }

    @objc(managedObjectModel)
    override var managedObjectModel: NSManagedObjectModel! {
        return sharedManagedObjectModel.model
    }

    @objc(observeIndependentDatabaseNotification:)
    dynamic func observeIndependentDatabaseNotification(_ notification: Notification!) {
        if !Thread.isMainThread {
            // The independent database posts on the thread that owns its
            // context, and may hold that context's queue while it waits for
            // the main thread: a disc scan does so to ask whether to copy the
            // disc or browse it. Reading the objects' IDs on the main thread
            // entered that queue, and the scan and the main thread waited for
            // each other. The IDs are read here, where the queue is ours.
            self.performSelector(onMainThread: #selector(DicomDatabase.observeIndependentDatabaseNotification(_:)), with: DicomDatabase.replacingObjectsWithIDs(notification), waitUntilDone: false)
        } else {
            let userInfo = NSMutableDictionary()

            let idatabase = (self.isMainDatabase() ? self : self.mainDatabase) as? DicomDatabase
            N2ManagedObjectContextPerformAndWait(idatabase?.managedObjectContext) {
            if let exception = HorosObjCException.caught({

                let independentObjects = DicomDatabaseObjC.objectForKey(notification.userInfo as NSDictionary?, OsirixAddToDBNotificationImagesArray) as? NSArray
                if let independentObjects {
                    let selfObjects = idatabase?.objects(withIDs: independentObjects as? [Any]) as NSArray?
                    if (selfObjects?.count ?? 0) != independentObjects.count {
                        NSLog("Warning: independent database is notifying about %d new images, but the main database can only find %d.", Int32(truncatingIfNeeded: independentObjects.count), Int32(truncatingIfNeeded: selfObjects?.count ?? 0))
                    }
                    DicomDatabaseObjC.setObject(userInfo, selfObjects, OsirixAddToDBNotificationImagesArray) // We should NOT send a notification with objects, but objectsID instead...
                }

                let independentDictionary = DicomDatabaseObjC.objectForKey(notification.userInfo as NSDictionary?, OsirixAddToDBNotificationImagesPerAETDictionary) as? NSDictionary
                if let independentDictionary {
                    let selfDictionary = NSMutableDictionary()
                    for key in independentDictionary.keyEnumerator() {
                        DicomDatabaseObjC.setObject(selfDictionary, idatabase?.objects(withIDs: independentDictionary.object(forKey: key) as? [Any]) as NSArray?, key)
                    }
                    DicomDatabaseObjC.setObject(userInfo, selfDictionary, OsirixAddToDBNotificationImagesPerAETDictionary)
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase observeIndependentDatabaseNotification:]")
            }
            }

            NotificationCenter.default.post(name: notification.name, object: self, userInfo: userInfo as? [AnyHashable: Any])
        }
    }

    /// The notification with the managed objects of its image array and of
    /// its per-AET dictionary replaced by their object IDs, read on the
    /// posting database's context.
    private static func replacingObjectsWithIDs(_ notification: Notification!) -> Notification! {
        guard let notification, let userInfo = notification.userInfo,
              let context = (notification.object as? N2ManagedDatabase)?.managedObjectContext else { return notification }
        func identifiers(_ value: Any?) -> NSArray? {
            guard let objects = value as? NSArray else { return nil }
            return objects.map { ($0 as? NSManagedObject)?.objectID ?? $0 } as NSArray
        }
        var converted = userInfo
        N2ManagedObjectContextPerformAndWait(context) {
            if let images = identifiers(userInfo[OsirixAddToDBNotificationImagesArray]) {
                converted[OsirixAddToDBNotificationImagesArray] = images
            }
            if let perAET = userInfo[OsirixAddToDBNotificationImagesPerAETDictionary] as? NSDictionary {
                let dictionary = NSMutableDictionary()
                for case let (key, value) in perAET { dictionary[key] = identifiers(value) ?? value }
                converted[OsirixAddToDBNotificationImagesPerAETDictionary] = dictionary
            }
        }
        return Notification(name: notification.name, object: notification.object, userInfo: converted)
    }

    @objc(isLocal)
    dynamic func isLocal() -> Bool {
        return true
    }

    @objc(contextAtPath:)
    override func context(atPath sqlFilePath: String!) -> NSManagedObjectContext! {
        // custom migration

        var rebuildPatientUIDs = false
        var independentContext = true

        if self.managedObjectContext == nil || !DicomDatabaseObjC.isEqual(sqlFilePath, self.managedObjectContext.persistentStoreCoordinator?.persistentStores.first?.url?.path) {
            independentContext = false
        }

        if independentContext == false { // avoid doing this for independent contexts: we know it's already ok, and this leads to very bad crashes
            rebuildPatientUIDs = DatabaseModelUpgrade(database: self).upgradeBeforeOpening(indexPath: sqlFilePath)
        }

        // super + spec

        let context = super.context(atPath: sqlFilePath)
        // On the context's own queue, whichever it is.
        N2ManagedObjectContextPerformAndWait(context) {
            context?.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
            context?.undoManager = nil
        }

        if independentContext == false {
            // Meta Data
            if let coordinator = context?.persistentStoreCoordinator, coordinator.persistentStores.count == 1 {
                let metaData = coordinator.metadata(for: coordinator.persistentStores.last!) as NSDictionary

                let defaults = PreferencesSource.process.preferences
                let PatientUIDVersion = String(format: "%@ - %d - %d - %d", PATIENTUIDVERSION,
                                               Int32(defaults[DatabasePreferences.usePatientBirthDateForUID] ? 1 : 0),
                                               Int32(defaults[DatabasePreferences.usePatientIDForUID] ? 1 : 0),
                                               Int32(defaults[DatabasePreferences.usePatientNameForUID] ? 1 : 0))

                if metaData.object(forKey: "patientUIDVersion") == nil || !DicomDatabaseObjC.isEqual(metaData.object(forKey: "patientUIDVersion") as? String, PatientUIDVersion) {
                    rebuildPatientUIDs = true //recompute patient UIDs
                    let newMetaData = NSMutableDictionary(dictionary: metaData)
                    newMetaData.setObject(PatientUIDVersion, forKey: "patientUIDVersion" as NSString)
                    coordinator.setMetadata(newMetaData as? [String: Any], for: coordinator.persistentStores.last!)
                }
            } else {
                DicomDatabaseObjC.logStackTrace(String(format: "********* persistentStoreCoordinator.persistentStores.count != 1, %d", Int32(truncatingIfNeeded: context?.persistentStoreCoordinator?.persistentStores.count ?? 0)))
            }
        }

        if rebuildPatientUIDs {
            N2ManagedObjectContextPerformAndWait(context) {
                DatabaseStartupRepairs.recomputePatientUIDs(in: context) // if upgradeSqlFileFromModelVersion returns NO, the database was rebuilt so no need to recompute IDs
            }
        }

        return context
    }

    @objc(save:)
    override func save(_ err: NSErrorPointer) -> Bool {

        var b = false
        // Held here and handed over after the queue: the caller's pointer is
        // autoreleasing, and the pool of the block would free what it was given.
        var saveError: NSError? = nil

        let context = self.managedObjectContext
        N2ManagedObjectContextPerformAndWait(context) {
        if let exception = HorosObjCException.caught({
            b = super.save(&saveError)

            if let saveError {
                NSLog("DicomDatabase save error: %@", saveError)
            } else if let context {
                DatabaseVersionRecord.record(in: context, versionFile: self.modelVersionFilePath())
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase save:]")
        }
        }

        err?.pointee = saveError
        return b
    }

    @objc(imageEntity)
    dynamic func imageEntity() -> NSEntityDescription! {
        return self.entity(forName: "Image")
    }

    @objc(seriesEntity)
    dynamic func seriesEntity() -> NSEntityDescription! {
        return self.entity(forName: "Series")
    }

    @objc(studyEntity)
    dynamic func studyEntity() -> NSEntityDescription! {
        return self.entity(forName: "Study")
    }

    @objc(albumEntity)
    dynamic func albumEntity() -> NSEntityDescription! {
        return self.entity(forName: "Album")
    }

    @objc(logEntryEntity)
    dynamic func logEntryEntity() -> NSEntityDescription! {
        return self.entity(forName: "LogEntry")
    }

    @objc(sqlFilePathForBasePath:)
    dynamic class func sqlFilePath(forBasePath basePath: String!) -> String! {
        return DicomDatabaseObjC.appending(basePath, SqlFileName)
    }

    /// `folder` of the data folder, through its links and aliases.
    private func resolvedDataBasePath(_ folder: DocumentsLocation.DataFolder) -> String? {
        DocumentsLocation(documentsDirectory: self.baseDirPath, dataDirectory: self.dataBaseDirPath).path(of: folder)
    }

    @objc(dataDirPath)
    dynamic func dataDirPath() -> String! {
        return resolvedDataBasePath(.images)
    }

    @objc(incomingDirPath)
    dynamic func incomingDirPath() -> String! {
        return resolvedDataBasePath(.incoming)
    }

    @objc(decompressionDirPath)
    dynamic func decompressionDirPath() -> String! {
        return resolvedDataBasePath(.decompression)
    }

    @objc(toBeIndexedDirPath)
    dynamic func toBeIndexedDirPath() -> String! {
        return resolvedDataBasePath(.toBeIndexed)
    }

    @objc(tempDirPath)
    dynamic func tempDirPath() -> String! {
        return resolvedDataBasePath(.temporary)
    }

    @objc(dumpDirPath)
    dynamic func dumpDirPath() -> String! {
        return resolvedDataBasePath(.dump)
    }

    @objc(errorsDirPath)
    dynamic func errorsDirPath() -> String! {
        let path = resolvedDataBasePath(.unreadable)
        // Nothing created this directory, so every -moveItemAtPath: into it failed
        // and the fallback removed the file instead: the preference that is meant to
        // keep unreadable files for inspection kept nothing.
        FileManager.default.confirmDirectory(atPath: path)
        return path
    }

    @objc(reportsDirPath)
    dynamic func reportsDirPath() -> String! {
        return resolvedDataBasePath(.reports)
    }

    @objc(pagesDirPath)
    dynamic func pagesDirPath() -> String! {
        return resolvedDataBasePath(.pages)
    }

    @objc(roisDirPath)
    dynamic func roisDirPath() -> String! {
        return resolvedDataBasePath(.rois)
    }

    @objc(htmlTemplatesDirPath)
    dynamic func htmlTemplatesDirPath() -> String! {
        return resolvedDataBasePath(.htmlTemplates)
    }

    @objc(statesDirPath)
    dynamic func statesDirPath() -> String! {
        return resolvedDataBasePath(.states3D)
    }

    @objc(clutsDirPath)
    dynamic func clutsDirPath() -> String! {
        return resolvedDataBasePath(.colourTables)
    }

    @objc(presetsDirPath)
    dynamic func presetsDirPath() -> String! {
        return resolvedDataBasePath(.presets3D)
    }

    @objc(modelVersionFilePath)
    dynamic func modelVersionFilePath() -> String! {
        return DicomDatabaseObjC.appending(self.baseDirPath, "DB_VERSION")
    }

    @objc(loadingFilePath)
    dynamic func loadingFilePath() -> String! {
        return DicomDatabaseObjC.appending(self.baseDirPath, "Loading")
    }

    /// Reads the data folder and goes on from what it and the index hold;
    /// answers the number of the data file given last. DataFileAllocator.
    @objc(computeDataFileIndex)
    dynamic func computeDataFileIndex() -> UInt {
        guard let dataDirPath = self.dataDirPath() else { return UInt(dataFileAllocator.lastNumber) }
        return UInt(dataFileAllocator.resume(fromDataFolder: dataDirPath, folderSize: DicomDatabase.dataFolderSize, highestRecorded: { RecordedDataFileNumbers.highest(in: self) }))
    }

    /// A path in the data folder for a new file, which no other caller gets,
    /// on any thread. DataFileAllocator.
    @objc(uniquePathForNewDataFileWithExtension:)
    dynamic func uniquePathForNewDataFile(withExtension ext: String!) -> String! {
        let fileExtension = DataFileNumbering.fileExtension(ext)
        if fileExtension.replaced {
            NSLog("Warning: strange extension \"%@\", it will be replaced with \"dcm\"", DicomDatabaseObjC.arg(ext))
        }
        guard let dataDirPath = self.dataDirPath() else { return nil }
        let files = FileManager.default
        files.confirmNoIndexDirectory(atPath: dataDirPath)
        return dataFileAllocator.uniquePath(inDataFolder: dataDirPath, extension: fileExtension.value, folderSize: DicomDatabase.dataFolderSize,
                                            highestRecorded: { RecordedDataFileNumbers.highest(in: self) }) { files.confirmDirectory(atPath: $0) }
    }

    /// The number of files a folder of the data folder holds, from the
    /// preferences, as a value for the allocator.
    private static var dataFolderSize: UInt64 {
        UInt64(max(BrowserController.defaultFolderSizeForDB(), 1))
    }
}

/// The numbers the records of an index give its data files.
enum RecordedDataFileNumbers {
    /// The highest number a record of the index of `database` gives a data
    /// file, 0 when it gives none or the index is not open. A record names its
    /// file by that number whether or not the file is still in the data
    /// folder, so a new file must never be given it: the record would read
    /// the new file as its own image.
    ///
    /// One request to the store, on a context of its own: any thread may ask,
    /// whichever context it is working on, and waits only for the store. The
    /// allocator asks when it reads the data folder, not for each file.
    static func highest(in database: DicomDatabase) -> UInt64 {
        guard let coordinator = database.managedObjectContext?.persistentStoreCoordinator, !coordinator.persistentStores.isEmpty,
              coordinator.managedObjectModel.entitiesByName["Image"]?.attributesByName["pathNumber"] != nil else { return 0 }
        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        reader.undoManager = nil
        var highest: UInt64 = 0
        reader.performAndWait {
            let highestNumber = NSExpressionDescription()
            highestNumber.name = "highest"
            highestNumber.expression = NSExpression(forFunction: "max:", arguments: [NSExpression(forKeyPath: "pathNumber")])
            highestNumber.expressionResultType = .integer64AttributeType
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Image")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [highestNumber]
            let found = ((try? reader.fetch(request)) as? [[String: Any]])?.first?["highest"] as? Int64
            highest = UInt64(max(found ?? 0, 0))
        }
        return highest
    }
}

/// What -[DicomDatabase save:] does once the context saved: the index is of the
/// current model, said in the preferences and in the version file beside it.
enum DatabaseVersionRecord {
    /// On the context's queue. Only over an index that is open: with none, what
    /// stays on disk may be an index waiting for its upgrade.
    static func record(in context: NSManagedObjectContext, versionFile: String?) {
        guard context.persistentStoreCoordinator?.persistentStores.isEmpty == false else { return }
        PreferencesSource.process.preferences.set(CurrentDatabaseVersion, for: DatabasePreferences.databaseVersion)
        if let versionFile {
            try? (CurrentDatabaseVersion as NSString).write(toFile: versionFile, atomically: true, encoding: String.Encoding.utf8.rawValue)
        }
    }
}

// The save at dealloc that N2ManagedDatabase hands to the main queue records the
// version as -save: does, with the database gone.
extension DicomDatabase: N2ManagedDatabaseSaveFollowUp {}

extension N2ManagedDatabaseSaveFollowUp where Self: DicomDatabase {
    func saveFollowUpWithoutDatabase() -> @Sendable (NSManagedObjectContext) -> Void {
        let versionFile: String? = self.modelVersionFilePath()
        return { context in DatabaseVersionRecord.record(in: context, versionFile: versionFile) }
    }
}
