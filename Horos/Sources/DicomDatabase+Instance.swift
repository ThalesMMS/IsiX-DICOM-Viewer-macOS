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

// The "Instance" methods of DicomDatabase are implemented in Swift since #833:
// a Swift extension of DicomDatabase, which stays Objective-C, with the
// selectors of the former methods. DicomDatabase.h imports
// DicomDatabase+Instance.h, so that plugins still see them. The instance
// variables they use are read through DicomDatabase (SwiftIvars).
//
// The initializer, -release and -dealloc (which take the registry lock of the
// databases by path, in that order), the synthesized properties with the -name
// getter, and the three C paths the DICOM listener reads stay in
// DicomDatabase.mm.
//
// An @try is HorosObjCException.perform (DicomDatabaseObjC.attempt), and the
// code of its @finally runs after it. An @synchronized is
// DicomDatabaseObjC.synchronized, the same recursive lock on the same object.
// A message to nil answered nil, NO or 0: the optionals give that value.

/// What the Objective-C did implicitly, for the DicomDatabase blocks that are
/// Swift since #833.
enum DicomDatabaseObjC {

    /// Runs `body` as an @try block: the NSException it raised is returned.
    static func attempt(_ body: () -> Void) -> NSException? {
        do {
            try HorosObjCException.perform(body)
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }

    /// `@synchronized (object) { … }`: the same recursive lock, taken on
    /// nothing when the object is nil, and left before an exception raised
    /// inside goes on.
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
        guard let object else { return body() }
        objc_sync_enter(object)
        var result: T?
        let raised = attempt { result = body() }
        objc_sync_exit(object)
        if let raised { raised.raise() }
        return result!
    }

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
    static func DLog(_ format: String, _ arguments: CVarArg...) {
        #if DEBUG
        withVaList(arguments) { NSLogv(format, $0) }
        #else
        if N2Debug.isActive() { withVaList(arguments) { NSLogv(format, $0) } }
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
/// created once and never released.
private var sharedManagedObjectModel: NSManagedObjectModel? = nil

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
        return true
    }

    @objc(managedObjectModel)
    override var managedObjectModel: NSManagedObjectModel! {
        if sharedManagedObjectModel == nil {
            sharedManagedObjectModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: (Bundle.main.resourcePath! as NSString).appendingPathComponent(DicomDatabase.modelName())))
        }
        return sharedManagedObjectModel
    }

    @objc(observeIndependentDatabaseNotification:)
    dynamic func observeIndependentDatabaseNotification(_ notification: Notification!) {
        if !Thread.isMainThread {
            self.performSelector(onMainThread: #selector(DicomDatabase.observeIndependentDatabaseNotification(_:)), with: notification, waitUntilDone: false)
        } else {
            let userInfo = NSMutableDictionary()

            self.lock()
            if let exception = DicomDatabaseObjC.attempt({
                let idatabase = (self.isMainDatabase() ? self : self.mainDatabase) as? DicomDatabase //We are on the mainthread : we can'safely' use the maindatabase

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
            self.unlock()

            NotificationCenter.default.post(name: notification.name, object: self, userInfo: userInfo as? [AnyHashable: Any])
        }
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
            var modelVersion: String? = nil
            if let path = self.modelVersionFilePath() {
                modelVersion = try? String(contentsOfFile: path, encoding: .utf8)
            }
            if modelVersion == nil { modelVersion = UserDefaults.standard.string(forKey: "DATABASEVERSION") }

            if let modelVersion, (modelVersion as NSString).length != 0, !DicomDatabaseObjC.isEqual(modelVersion, CurrentDatabaseVersion) {
                rebuildPatientUIDs = self.upgradeSqlFile(fromModelVersion: modelVersion)
                if let path = self.modelVersionFilePath() {
                    try? (CurrentDatabaseVersion as NSString).write(toFile: path, atomically: true, encoding: String.Encoding.utf8.rawValue)
                }
            }
        }

        // super + spec

        let context = super.context(atPath: sqlFilePath)
        context?.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context?.undoManager = nil

        if independentContext == false {
            // Meta Data
            if let coordinator = context?.persistentStoreCoordinator, coordinator.persistentStores.count == 1 {
                let metaData = coordinator.metadata(for: coordinator.persistentStores.last!) as NSDictionary

                let defaults = UserDefaults.standard
                let PatientUIDVersion = String(format: "%@ - %d - %d - %d", PATIENTUIDVERSION,
                                               Int32(defaults.bool(forKey: "UsePatientBirthDateForUID") ? 1 : 0),
                                               Int32(defaults.bool(forKey: "UsePatientIDForUID") ? 1 : 0),
                                               Int32(defaults.bool(forKey: "UsePatientNameForUID") ? 1 : 0))

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
            DicomDatabase.recomputePatientUIDs(in: context) // if upgradeSqlFileFromModelVersion returns NO, the database was rebuilt so no need to recompute IDs
        }

        return context
    }

    @objc(save:)
    override func save(_ err: NSErrorPointer) -> Bool {

        var b = false

        let context = self.managedObjectContext
        context?.lock()
        if let exception = DicomDatabaseObjC.attempt({
            // err, or a local NSError when the caller passed NULL.
            func save(_ err: AutoreleasingUnsafeMutablePointer<NSError?>) {
                b = super.save(err)

                if let saveError = err.pointee {
                    NSLog("DicomDatabase save error: %@", saveError)
                } else {
                    UserDefaults.standard.set(CurrentDatabaseVersion, forKey: "DATABASEVERSION")
                    if let path = self.modelVersionFilePath() {
                        try? (CurrentDatabaseVersion as NSString).write(toFile: path, atomically: true, encoding: String.Encoding.utf8.rawValue)
                    }
                }
            }

            if let err {
                save(err)
            } else {
                var error: NSError? = nil
                save(&error)
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase save:]")
        }
        self.managedObjectContext?.unlock()

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

    /// `[[self.dataBaseDirPath stringByAppendingPathComponent:component] stringByResolvingSymlinksAndAliases]`.
    private func resolvedDataBasePath(_ component: String) -> String? {
        return (DicomDatabaseObjC.appending(self.dataBaseDirPath, component) as NSString?)?.resolvingSymlinksAndAliases()
    }

    @objc(dataDirPath)
    dynamic func dataDirPath() -> String! {
        return resolvedDataBasePath("DATABASE.noindex")
    }

    @objc(incomingDirPath)
    dynamic func incomingDirPath() -> String! {
        return resolvedDataBasePath("INCOMING.noindex")
    }

    @objc(decompressionDirPath)
    dynamic func decompressionDirPath() -> String! {
        return resolvedDataBasePath("DECOMPRESSION.noindex")
    }

    @objc(toBeIndexedDirPath)
    dynamic func toBeIndexedDirPath() -> String! {
        return resolvedDataBasePath("TOBEINDEXED.noindex")
    }

    @objc(tempDirPath)
    dynamic func tempDirPath() -> String! {
        return resolvedDataBasePath("TEMP.noindex")
    }

    @objc(dumpDirPath)
    dynamic func dumpDirPath() -> String! {
        return resolvedDataBasePath("DUMP")
    }

    @objc(errorsDirPath)
    dynamic func errorsDirPath() -> String! {
        let path = resolvedDataBasePath("NOT READABLE")
        // Nothing created this directory, so every -moveItemAtPath: into it failed
        // and the fallback removed the file instead: the preference that is meant to
        // keep unreadable files for inspection kept nothing.
        FileManager.default.confirmDirectory(atPath: path)
        return path
    }

    @objc(reportsDirPath)
    dynamic func reportsDirPath() -> String! {
        return resolvedDataBasePath("REPORTS")
    }

    @objc(pagesDirPath)
    dynamic func pagesDirPath() -> String! {
        return resolvedDataBasePath("PAGES")
    }

    @objc(roisDirPath)
    dynamic func roisDirPath() -> String! {
        return resolvedDataBasePath("ROIs")
    }

    @objc(htmlTemplatesDirPath)
    dynamic func htmlTemplatesDirPath() -> String! {
        return resolvedDataBasePath("HTML_TEMPLATES")
    }

    @objc(statesDirPath)
    dynamic func statesDirPath() -> String! {
        return resolvedDataBasePath("3DSTATE")
    }

    @objc(clutsDirPath)
    dynamic func clutsDirPath() -> String! {
        return resolvedDataBasePath("CLUTs")
    }

    @objc(presetsDirPath)
    dynamic func presetsDirPath() -> String! {
        return resolvedDataBasePath("3DPRESETS")
    }

    @objc(modelVersionFilePath)
    dynamic func modelVersionFilePath() -> String! {
        return DicomDatabaseObjC.appending(self.baseDirPath, "DB_VERSION")
    }

    @objc(loadingFilePath)
    dynamic func loadingFilePath() -> String! {
        return DicomDatabaseObjC.appending(self.baseDirPath, "Loading")
    }

    @objc(computeDataFileIndex)
    dynamic func computeDataFileIndex() -> UInt {
        let dataFileIndex = self.horos_dataFileIndex
        var value: UInt { return dataFileIndex?.unsignedIntegerValue ?? 0 }

        return DicomDatabaseObjC.synchronized(dataFileIndex) { () -> UInt in
            DicomDatabaseObjC.DLog("In -[DicomDatabase computeDataFileIndex] for %@ initially %d", DicomDatabaseObjC.arg(self.sqlFilePath), Int32(truncatingIfNeeded: value))

            let hereBecauseZero = (value == 0)
            let early = DicomDatabaseObjC.synchronized(dataFileIndex) { () -> UInt? in
                if hereBecauseZero && value != 0 {
                    let incremented = value &+ 1
                    dataFileIndex?.unsignedIntegerValue = incremented
                    return incremented
                }
                if let exception = DicomDatabaseObjC.attempt({
                    let path = self.dataDirPath()
                    //			NSLog(@"Path is %@", path);

                    // delete empty dirs and scan for files with number names
                    //			NSLog(@"Scanning %d dirs", fs.count);
                    let enumerator = DicomDatabaseObjC.enumerator(path)
                    while let object = enumerator?.nextObject() {
                        guard let f = object as? String else { continue }
                        //				NSLog(@"Scanning dir %@", f);
                        let fpath = DicomDatabaseObjC.appending(path, f)
                        //NSDictionary* fattr = [NSFileManager.defaultManager fileAttributesAtPath:fpath traverseLink:YES];
                        //NSLog(@"Has %d attrs", fattr.count);

                        // check if this folder is empty, and delete it if necessary
                        var isDir = false
                        if DicomDatabaseObjC.fileExists(fpath, isDirectory: &isDir) && isDir {
                            autoreleasepool {
                                if let exception = DicomDatabaseObjC.attempt({
                                    var hasValidFiles = false

                                    //						NSLog(@"Content of %@", f);
                                    let n2de = DicomDatabaseObjC.enumerator(fpath)
                                    while let s = n2de?.nextObject() as? String { // [NSFileManager.defaultManager contentsOfDirectoryAtPath:fpath error:nil])
                                        if DicomDatabaseObjC.integerValueWithoutExtension(s) > 0 {
                                            hasValidFiles = true
                                            break
                                        }
                                    }

                                    if !hasValidFiles {
                                        if let fpath { try? FileManager.default.removeItem(atPath: fpath) }
                                    } else {
                                        let fi = UInt(bitPattern: DicomDatabaseObjC.integerValue(f))
                                        if fi > value {
                                            dataFileIndex?.unsignedIntegerValue = fi
                                        }
                                    }
                                }) {
                                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase computeDataFileIndex]")
                                }
                            }
                        }
                    }

                    // scan directories

                    if value > 0 {
                        //				NSLog(@"datafileindex is %d", _dataFileIndex.unsignedIntegerValue);

                        var t = Int(bitPattern: value)
                        t = t &- Int(BrowserController.defaultFolderSizeForDB())
                        if t < 0 { t = 0 }

                        let paths = DicomDatabaseObjC.enumerator(DicomDatabaseObjC.appending(path, String(format: "%d", Int32(truncatingIfNeeded: value))))?.allObjects ?? [] // [NSFileManager.defaultManager contentsOfDirectoryAtPath:[path stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", _dataFileIndex.unsignedIntegerValue]] error:nil];
                        //				NSLog(@"contains %d files", paths.count);
                        for case let s as String in paths {
                            let si = DicomDatabaseObjC.integerValueWithoutExtension(s)
                            if si > t {
                                t = si
                            }
                        }

                        dataFileIndex?.unsignedIntegerValue = UInt(bitPattern: t)
                    }

                    if value == 0 {
                        dataFileIndex?.unsignedIntegerValue = 1
                    }

                    DicomDatabaseObjC.DLog("   -[DicomDatabase computeDataFileIndex] for %@ computed %d", DicomDatabaseObjC.arg(self.sqlFilePath), Int32(truncatingIfNeeded: value))
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase computeDataFileIndex]")
                }
                return nil
            }
            if let early { return early }

            return value
        }
    }

    @objc(uniquePathForNewDataFileWithExtension:)
    dynamic func uniquePathForNewDataFile(withExtension ext: String!) -> String! {
        var path: String? = nil
        var ext = ext

        let length = (ext as NSString?)?.length ?? 0
        if length > 4 || length < 3 {
            if length != 0 {
                NSLog("Warning: strange extension \"%@\", it will be replaced with \"dcm\"", DicomDatabaseObjC.arg(ext))
            }
            ext = "dcm"
        }

        let dataFileIndex = self.horos_dataFileIndex
        if let exception = DicomDatabaseObjC.attempt({
            DicomDatabaseObjC.synchronized(dataFileIndex) {
                let dataDirPath = self.dataDirPath()
                FileManager.default.confirmNoIndexDirectory(atPath: dataDirPath) // old impl only did this every 3 secs..

                var index: UInt = 0
                DicomDatabaseObjC.synchronized(dataFileIndex) {
                    if (dataFileIndex?.unsignedIntegerValue ?? 0) == 0 {
                        _ = self.computeDataFileIndex()
                    }
                    dataFileIndex?.increment()
                    index = dataFileIndex?.unsignedIntegerValue ?? 0
                }

                let defaultFolderSizeForDB = UInt64(bitPattern: Int64(BrowserController.defaultFolderSizeForDB()))

                var fileExists = false, firstExists = true
                repeat {
                    let subFolderInt = defaultFolderSizeForDB &* (UInt64(index) / defaultFolderSizeForDB &+ 1)
                    let subFolderPath = DicomDatabaseObjC.appending(dataDirPath, String(format: "%llu", subFolderInt))
                    FileManager.default.confirmDirectory(atPath: subFolderPath)

                    path = DicomDatabaseObjC.appending(subFolderPath, String(format: "%llu.%@", UInt64(dataFileIndex?.unsignedIntegerValue ?? 0), DicomDatabaseObjC.arg(ext)))
                    fileExists = DicomDatabaseObjC.fileExists(path)

                    if fileExists {
                        if firstExists {
                            firstExists = false
                            DicomDatabaseObjC.synchronized(dataFileIndex) {
                                _ = self.computeDataFileIndex()
                                index = dataFileIndex?.unsignedIntegerValue ?? 0
                            }
                        } else {
                            DicomDatabaseObjC.synchronized(dataFileIndex) {
                                dataFileIndex?.increment()
                                index = dataFileIndex?.unsignedIntegerValue ?? 0
                            }
                        }
                    }
                } while fileExists
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase uniquePathForNewDataFileWithExtension:]")
        }

        return path
    }
}
