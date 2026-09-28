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

import Cocoa
import CoreData

// MARK: - Objective-C semantics the class keeps

/// `@try { body } @catch (NSException *e) { N2LogExceptionWithStackTrace(e); }`
/// (or N2LogException when `stack` is false), logged under the name the
/// Objective-C method gave __PRETTY_FUNCTION__. True when body raised.
@discardableResult
fileprivate func dicomStudyTry(_ function: String, stack: Bool = true, _ body: () -> Void) -> Bool {
    do {
        try HorosObjCException.perform(body)
        return false
    } catch {
        if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            _N2LogExceptionImpl(e, stack, function)
        }
        return true
    }
}

/// `@synchronized (object) { body }`: the same recursive lock (objc_sync_enter).
/// An NSException that body raises releases it and then goes on to the caller,
/// as it did through @synchronized.
fileprivate func dicomStudySynchronized(_ object: AnyObject, _ body: () -> Void) {
    objc_sync_enter(object)
    var raised: NSException? = nil
    do {
        try HorosObjCException.perform(body)
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    raised?.raise()
}

/// `[context lock]` and `[context unlock]` (NSManagedObjectContext, or the
/// N2ManagedObjectContext subclass that overrides them), nothing for nil.
fileprivate func dicomStudyLock(_ context: NSManagedObjectContext?) {
    context?.lock()
}

fileprivate func dicomStudyUnlock(_ context: NSManagedObjectContext?) {
    context?.unlock()
}

/// `[string isEqualToString: other]`: NO for a nil receiver or a nil argument.
fileprivate func dicomStudyEqual(_ string: Any?, _ other: Any?) -> Bool {
    guard let string = string as? NSString, let other = other as? String else { return false }
    return string.isEqual(to: other)
}

/// `[object isEqualToString: literal]` for an element of a collection, which may
/// be an NSNull: sent as Objective-C sends it, so an object that does not answer
/// raises as it did.
fileprivate func dicomStudyElementEqual(_ object: Any, _ literal: String) -> Bool {
    if let string = object as? NSString {
        return string.isEqual(to: literal)
    }
    return (object as AnyObject).perform(NSSelectorFromString("isEqualToString:"), with: literal) != nil
}

/// `[string length]`, 0 for nil.
fileprivate func dicomStudyLength(_ string: Any?) -> Int {
    return (string as? NSString)?.length ?? 0
}

/// `[string hasPrefix: prefix]`, NO for a nil receiver.
fileprivate func dicomStudyHasPrefix(_ string: String?, _ prefix: String) -> Bool {
    return (string as NSString?)?.hasPrefix(prefix) ?? false
}

/// `[[NSFileManager defaultManager] fileExistsAtPath: path]`, NO for nil.
fileprivate func dicomStudyFileExists(_ path: String?) -> Bool {
    guard let path = path else { return false }
    return FileManager.default.fileExists(atPath: path)
}

/// `[[NSFileManager defaultManager] removeItemAtPath: path error: nil]`.
fileprivate func dicomStudyRemoveItem(_ path: String?) {
    guard let path = path else { return }
    try? FileManager.default.removeItem(atPath: path)
}

/// `[object valueForKey: key]`, nil for a nil receiver.
fileprivate func dicomStudyValue(_ object: Any?, _ key: String) -> Any? {
    guard let object = object else { return nil }
    return (object as AnyObject).value(forKey: key)
}

/// A message without arguments sent as Objective-C sends it (nil for a nil
/// receiver), for the objects DicomSeries and DicomImage hand back, which are
/// kept as the objects they are. Only for methods that answer an object.
fileprivate func dicomStudyGet(_ object: Any?, _ selector: String) -> AnyObject? {
    guard let object = object else { return nil }
    return (object as AnyObject).perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// A one-argument message that answers an object, sent as Objective-C sends
/// it, nil argument included.
fileprivate func dicomStudyGet(_ object: Any, _ selector: String, _ argument: Any?) -> AnyObject? {
    return (object as AnyObject).perform(NSSelectorFromString(selector), with: argument)?.takeUnretainedValue()
}

/// A message whose answer is not an object (or nothing), sent as Objective-C
/// sends it, nil argument included, for the methods whose answer to nil is
/// their own (a raise, or nothing). What it answers is dropped.
fileprivate func dicomStudyPerform(_ object: Any, _ selector: String, _ argument: Any?) {
    _ = (object as AnyObject).perform(NSSelectorFromString(selector), with: argument)
}

fileprivate func dicomStudyPerform(_ object: Any, _ selector: String) {
    _ = (object as AnyObject).perform(NSSelectorFromString(selector))
}

/// `for (id x in object)`: nothing for nil; an object that does not enumerate
/// raises as fast enumeration did.
fileprivate func dicomStudyEnumerate(_ object: Any?) -> [Any] {
    guard let object = object else { return [] }
    guard let enumerable = object as? NSFastEnumeration else {
        dicomStudyPerform(object, "countByEnumeratingWithState:objects:count:", nil)
        return []
    }
    var elements = [Any]()
    var iterator = NSFastEnumerationIterator(enumerable)
    while let element = iterator.next() {
        elements.append(element)
    }
    return elements
}

/// `[NSArray arrayWithObject: object]`, which raises for nil.
fileprivate func dicomStudyArray(_ object: Any?) -> NSArray {
    guard let object = object else {
        return (dicomStudyGet(NSArray.self, "arrayWithObject:", nil) as? NSArray) ?? NSArray()
    }
    return NSArray(object: object)
}

/// `[array addObject: object]`, which raises for nil.
fileprivate func dicomStudyAdd(_ array: NSMutableArray, _ object: Any?) {
    guard let object = object else {
        dicomStudyPerform(array, "addObject:", nil)
        return
    }
    array.add(object)
}

/// `[dictionary setObject: object forKey: key]`, which raises for nil.
fileprivate func dicomStudySet(_ dictionary: NSMutableDictionary, _ object: Any?, _ key: String) {
    guard let object = object else {
        _ = (dictionary as AnyObject).perform(NSSelectorFromString("setObject:forKey:"), with: nil, with: key)
        return
    }
    dictionary.setObject(object, forKey: key as NSString)
}

/// `[set unionSet: other]`, sent as is: the sets are those Core Data hands back.
fileprivate func dicomStudyUnion(_ set: NSMutableSet, _ other: Any?) {
    dicomStudyPerform(set, "unionSet:", other)
}

/// The ROIs of an SR. An SR that cannot be read hands back nil, which
/// NSUnarchiver did not survive (a segmentation fault, not an exception): nil
/// is answered with nil (#778), as is an archive that names a class a ROI
/// archive does not hold.
fileprivate func dicomStudyUnarchive(_ data: Any?) -> Any? {
    return RestrictedUnarchiver.unarchiveROIs(with: data as? Data)
}

/// +predicateWithFormat: with one %@ argument that may be nil: a nil argument
/// is the constant nil, as in a C argument list.
fileprivate func dicomStudyPredicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
    let parts = format.components(separatedBy: "%@")
    var composed = parts[0]
    var values = [Any]()
    for (index, part) in parts.dropFirst().enumerated() {
        if let value = arguments[index] {
            composed += "%@"
            values.append(value)
        } else {
            composed += "nil"
        }
        composed += part
    }
    return NSPredicate(format: composed, argumentArray: values)
}

/// `%@` of an object that may be nil.
fileprivate func dicomStudyArg(_ object: Any?) -> CVarArg {
    return (object as AnyObject?) as? NSObject ?? ("(null)" as NSString)
}

/// N2LocalizedSingularPluralCount(c, s, p) of N2Stuff.h.
fileprivate func dicomStudySingularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), count == 1 ? singular : plural)
}

/// `[NSDictionary dictionaryWithObjectsAndKeys: files, @"files", @"field"…, value, @"value", nil]`:
/// the list ends at its first nil object.
fileprivate func dicomStudyModifyDictionary(_ files: Any?, _ field: String, _ value: Any?) -> NSDictionary {
    let dict = NSMutableDictionary()
    guard let files = files else { return NSDictionary(dictionary: dict) }
    dict.setObject(files, forKey: "files" as NSString)
    dict.setObject(field, forKey: "field" as NSString)
    guard let value = value else { return NSDictionary(dictionary: dict) }
    dict.setObject(value, forKey: "value" as NSString)
    return NSDictionary(dictionary: dict)
}

/// The database list asks for an age on every visible row at every redraw, and
/// each answer is a calendar computation. The answer depends only on its inputs
/// and the time zone - and, for the age today, on the time - so it is kept.
fileprivate let dicomStudyAgeCache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 4096
    return cache
}()

/// `[cache setObject: age forKey: key]`, which raises for a nil age.
fileprivate func dicomStudyCacheAge(_ age: String?, _ key: NSString) {
    guard let age = age else {
        _ = (dicomStudyAgeCache as AnyObject).perform(NSSelectorFromString("setObject:forKey:"), with: nil, with: key)
        return
    }
    dicomStudyAgeCache.setObject(age as NSString, forKey: key)
}

/// The age the list shows for the years, months and days between two dates.
fileprivate func dicomStudyAge(_ later: Date?, since earlier: Date) -> String {
    var years = 0, months = 0, days = 0

    HorosDicomStudyYearsMonthsDays(later, earlier, &years, &months, &days)

    if years < 2 {
        if years < 1 {
            if months < 1 {
                if days < 0 { return "" }
                else { return String(format: NSLocalizedString("%d d", comment: "d = day"), Int32(truncatingIfNeeded: days)) }
            }
            else { return String(format: "%d%@", Int32(truncatingIfNeeded: months), NSLocalizedString(" m", comment: "m = month")) }
        }
        else { return String(format: "%d%@ %d%@", Int32(truncatingIfNeeded: years), NSLocalizedString(" y", comment: "y = year"), Int32(truncatingIfNeeded: months), NSLocalizedString(" m", comment: "m = month")) }
    }
    else { return String(format: "%d%@", Int32(truncatingIfNeeded: years), NSLocalizedString(" y", comment: "y = year")) }
}

/// Core Data entity for a study.
///
/// Implemented in Swift since #721: the Objective-C name (which the
/// OsiriXDB_DataModel names as the Study entity's class), the selectors, the
/// KVC keys and <Horos/DicomStudy.h> are those of the former class. Core Data
/// provides the accessors of the modelled properties (@NSManaged, the former
/// @dynamic), except those the class writes itself, as before: the getters of
/// series, studyName, performingPhysician, referringPhysician, institutionName
/// and name, the setters of comment…comment4, stateText, date, modality and
/// numberOfImages, and both halves of reportURL. The other half of those is
/// written here as Core Data's own does it (willAccess/didAccess and
/// willChange/didChange around the primitive value), since Swift cannot leave
/// one half of a property to Core Data.
///
/// Every member is `dynamic`, so that it is sent as the Objective-C class sent
/// it, also from inside the class.
@objc(DicomStudy)
public final class DicomStudy: NSManagedObject {

    // The former instance variables.
    private var hiddenFlag: Bool = false
    private var dicomTimeCache: NSNumber? = nil
    private var numberOfImagesWhenCachedModalities: Int = 0
    private var cachedModalites: NSString? = nil

    // The former function-local statics.
    // Created once, whatever the thread that asks first (#778).
    private static let dbModifyLockStorage = NSRecursiveLock()
    private static var scrambleLetters: NSMutableArray? = nil
    private static var avoidReentry = 0
    private static var avoidReentry2 = 0
    private static var avoidReentry3 = 0

    // MARK: Properties

    @NSManaged public var accessionNumber: String!

    @objc public dynamic var comment: String! {
        get {
            self.willAccessValue(forKey: "comment")
            let v = self.primitiveValue(forKey: "comment") as? String
            self.didAccessValue(forKey: "comment")
            return v
        }
        set {
            var c = newValue

            if self.hasDICOM?.boolValue == true && UserDefaults.standard.bool(forKey: "savedCommentsAndStatusInDICOMFiles") && (DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false) {
                if c == nil {
                    c = ""
                }

                if dicomStudyLength(self.primitiveValue(forKey: "comment")) != 0 || dicomStudyLength(c) != 0 {
                    if dicomStudyEqual(c, self.primitiveValue(forKey: "comment")) == false {
                        let dict = dicomStudyModifyDictionary(self.paths()?.allObjects, "(0032,4000)", c)

                        let t = Thread(target: self, selector: #selector(DicomStudy.dcmodifyThread(_:)), object: dict)
                        t.name = NSLocalizedString("Updating DICOM files...", comment: "")
                        t.status = dicomStudySingularPluralCount((dict.object(forKey: "files") as? NSArray)?.count ?? 0, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))

                        ThreadsManager.default().addThreadAndStart(t)
                    }
                }
            }

            self.setComment(c, forKey: "comment")
        }
    }

    @objc public dynamic var comment2: String! {
        get {
            self.willAccessValue(forKey: "comment2")
            let v = self.primitiveValue(forKey: "comment2") as? String
            self.didAccessValue(forKey: "comment2")
            return v
        }
        set {
            self.setComment(newValue, forKey: "comment2")
        }
    }

    @objc public dynamic var comment3: String! {
        get {
            self.willAccessValue(forKey: "comment3")
            let v = self.primitiveValue(forKey: "comment3") as? String
            self.didAccessValue(forKey: "comment3")
            return v
        }
        set {
            self.setComment(newValue, forKey: "comment3")
        }
    }

    @objc public dynamic var comment4: String! {
        get {
            self.willAccessValue(forKey: "comment4")
            let v = self.primitiveValue(forKey: "comment4") as? String
            self.didAccessValue(forKey: "comment4")
            return v
        }
        set {
            self.setComment(newValue, forKey: "comment4")
        }
    }

    /// The end every comment setter shares: the value is stored, and the
    /// annotations SR written again when it changed.
    private func setComment(_ c: String?, forKey key: String) {
        let previousValue = self.primitiveValue(forKey: key) as? String

        self.willChangeValue(forKey: key)
        self.setPrimitiveValue(c, forKey: key)
        self.didChangeValue(forKey: key)

        if dicomStudyLength(previousValue) != 0 || dicomStudyLength(c) != 0 {
            if dicomStudyEqual(c, previousValue) == false {
                self.archiveAnnotationsAsDICOMSR()
            }
        }
    }

    @objc public dynamic var date: Date! {
        get {
            self.willAccessValue(forKey: "date")
            let v = self.primitiveValue(forKey: "date") as? Date
            self.didAccessValue(forKey: "date")
            return v
        }
        set {
            dicomStudySynchronized(self) {
                self.dicomTimeCache = nil

                self.willChangeValue(forKey: "date")
                self.setPrimitiveValue(newValue, forKey: "date")
                self.didChangeValue(forKey: "date")
            }
        }
    }

    @NSManaged public var dateAdded: Date!
    @NSManaged public var dateOfBirth: Date!
    @NSManaged public var dateOpened: Date!
    @NSManaged public var dictateURL: String!
    @NSManaged public var expanded: NSNumber!
    @NSManaged public var hasDICOM: NSNumber!
    @NSManaged public var id: String!

    @objc public dynamic var institutionName: String! {
        get {
            if UserDefaults.standard.bool(forKey: "CapitalizedString") {
                return (self.primitiveValue(forKey: "institutionName") as? NSString)?.capitalized
            }

            return self.primitiveValue(forKey: "institutionName") as? String
        }
        set {
            self.willChangeValue(forKey: "institutionName")
            self.setPrimitiveValue(newValue, forKey: "institutionName")
            self.didChangeValue(forKey: "institutionName")
        }
    }

    @NSManaged public var lockedStudy: NSNumber!

    @objc public dynamic var modality: String! {
        get {
            self.willAccessValue(forKey: "modality")
            let v = self.primitiveValue(forKey: "modality") as? String
            self.didAccessValue(forKey: "modality")
            return v
        }
        set {
            let s = newValue as NSString?

            if let s = s, s.isEqual(to: "SC") ||
                s.isEqual(to: "PR") ||
                s.isEqual(to: "SR") ||
                s.isEqual(to: "RTSTRUCT") ||
                s.isEqual(to: "RT") ||
                s.isEqual(to: "KO") {
                if dicomStudyLength(self.modality) > 0 {
                    return //We are not insterested in these 'technical' modalities, we prefer true modalities like CT, MR, ...
                }
            }

            self.willChangeValue(forKey: "modality")
            self.setPrimitiveValue(s, forKey: "modality")
            self.didChangeValue(forKey: "modality")
        }
    }

    @objc public dynamic var name: String! {
        get {
            var s = (self.primitiveValue(forKey: "name") as? NSString)?.replacingOccurrences(of: "^", with: " ") as NSString?

            s = s?.trimmingCharacters(in: .whitespaces) as NSString?

            if UserDefaults.standard.bool(forKey: "CapitalizedString") {
                return s?.capitalized
            }

            return s as String?
        }
        set {
            self.willChangeValue(forKey: "name")
            self.setPrimitiveValue(newValue, forKey: "name")
            self.didChangeValue(forKey: "name")
        }
    }

    @objc public dynamic var numberOfImages: NSNumber! {
        get {
            self.willAccessValue(forKey: "numberOfImages")
            let v = self.primitiveValue(forKey: "numberOfImages") as? NSNumber
            self.didAccessValue(forKey: "numberOfImages")
            return v
        }
        set {
            dicomStudySynchronized(self) {
                self.cachedModalites = nil

                self.willChangeValue(forKey: "numberOfImages")
                self.setPrimitiveValue(newValue, forKey: "numberOfImages")
                self.didChangeValue(forKey: "numberOfImages")
            }
        }
    }

    @NSManaged public var patientID: String!
    @NSManaged public var patientSex: String!
    @NSManaged public var patientUID: String!

    @objc public dynamic var performingPhysician: String! {
        get {
            if UserDefaults.standard.bool(forKey: "CapitalizedString") {
                return (self.primitiveValue(forKey: "performingPhysician") as? NSString)?.capitalized
            }

            return self.primitiveValue(forKey: "performingPhysician") as? String
        }
        set {
            self.willChangeValue(forKey: "performingPhysician")
            self.setPrimitiveValue(newValue, forKey: "performingPhysician")
            self.didChangeValue(forKey: "performingPhysician")
        }
    }

    @objc public dynamic var referringPhysician: String! {
        get {
            if UserDefaults.standard.bool(forKey: "CapitalizedString") {
                return (self.primitiveValue(forKey: "referringPhysician") as? NSString)?.capitalized
            }

            return self.primitiveValue(forKey: "referringPhysician") as? String
        }
        set {
            self.willChangeValue(forKey: "referringPhysician")
            self.setPrimitiveValue(newValue, forKey: "referringPhysician")
            self.didChangeValue(forKey: "referringPhysician")
        }
    }

    @objc public dynamic var reportURL: String! {
        get {
            var url = self.primitiveValue(forKey: "reportURL") as? NSString

            if let u = url, u.length != 0 {
                if u.hasPrefix("http://") == false && u.hasPrefix("https://") == false {
                    let db = BrowserController.currentBrowser()?.database

                    if !(db?.isLocal() ?? false) {
                        // We will give a path with TEMP.noindex, instead of REPORTS
                        if u.character(at: 0) != 0x2F /* '/' */ {
                            var relative = u
                            if relative.hasPrefix("REPORTS/") {
                                relative = relative.replacingOccurrences(of: "REPORTS/", with: "TEMP.noindex/") as NSString
                            }
                            url = (db?.baseDirPath as NSString?)?.appendingPathComponent(relative as String) as NSString?
                        }
                    } else {
                        if u.character(at: 0) != 0x2F /* '/' */ {
                            url = (db?.baseDirPath as NSString?)?.appendingPathComponent(u as String) as NSString?
                        } else {	// Should we convert it to a local path?
                            let commonPath = (db?.baseDirPath as NSString?)?.commonPrefix(with: u as String, options: .literal)
                            if dicomStudyEqual(commonPath, db?.baseDirPath) {
                                self.willChangeValue(forKey: "reportURL")
                                self.setPrimitiveValue(u, forKey: "reportURL")
                                self.didChangeValue(forKey: "reportURL")
                            }
                        }
                    }
                }
            }

            return url as String?
        }
        set {
            var url = newValue as NSString?
            let db = BrowserController.currentBrowser()?.database

            if let u = url {
                if u.hasPrefix("http://") == false && u.hasPrefix("https://") == false {
                    let commonPath = (db?.baseDirPath as NSString?)?.commonPrefix(with: u as String, options: .literal)

                    if dicomStudyEqual(commonPath, db?.baseDirPath) {
                        var relative = u.substring(from: (db?.baseDirPath as NSString?)?.length ?? 0) as NSString

                        if relative.hasPrefix("TEMP.noindex/") {
                            relative = relative.replacingOccurrences(of: "TEMP.noindex/", with: "REPORTS/") as NSString
                        }

                        if relative.character(at: 0) == 0x2F /* '/' */ { relative = relative.substring(from: 1) as NSString }

                        url = relative
                    }
                }
            }

            self.willChangeValue(forKey: "reportURL")
            self.setPrimitiveValue(url, forKey: "reportURL")
            self.didChangeValue(forKey: "reportURL")

            self.archiveReportAsDICOMSR()
        }
    }

    @objc public dynamic var stateText: NSNumber! {
        get {
            self.willAccessValue(forKey: "stateText")
            let v = self.primitiveValue(forKey: "stateText") as? NSNumber
            self.didAccessValue(forKey: "stateText")
            return v
        }
        set {
            var c = newValue

            dicomStudyTry("-[DicomStudy setStateText:]") {
                if self.hasDICOM?.boolValue == true && UserDefaults.standard.bool(forKey: "savedCommentsAndStatusInDICOMFiles") && (DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false) {
                    if c == nil {
                        c = NSNumber(value: 0 as Int32)
                    }

                    if (c?.int32Value ?? 0) != ((self.primitiveValue(forKey: "stateText") as? NSNumber)?.int32Value ?? 0) {
                        let dict = dicomStudyModifyDictionary(self.paths()?.allObjects, "(4008,0212)", c?.stringValue)

                        let t = Thread(target: self, selector: #selector(DicomStudy.dcmodifyThread(_:)), object: dict)
                        t.name = NSLocalizedString("Updating DICOM files...", comment: "")
                        t.status = dicomStudySingularPluralCount((dict.object(forKey: "files") as? NSArray)?.count ?? 0, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))

                        ThreadsManager.default().addThreadAndStart(t)
                    }
                }

                if self.hasDICOM?.boolValue == true {
                    // Save as DICOM PDF
                    if UserDefaults.standard.bool(forKey: "generateDICOMPDFWhenValidated") && (c?.int32Value ?? 0) == 4 && dicomStudyLength(self.reportURL) != 0 {
                        let isMainDB = self.managedObjectContext?.persistentStoreCoordinator === BrowserController.currentBrowser()?.database?.managedObjectContext?.persistentStoreCoordinator

                        let filePath: String? = isMainDB ? BrowserController.currentBrowser()?.database?.uniquePathForNewDataFile(withExtension: "dcm") : FileManager.default.tmpFilePathInTmp()

                        var caught: NSException? = nil
                        do {
                            try HorosObjCException.perform {
                                self.saveReportAsDicom(atPath: filePath)

                                // Conversion failure must not import an empty path or
                                // replace the Pages report (#129). reportURL is untouched.
                                if dicomStudyFileExists(filePath) == false {
                                    NSException(name: .genericException, reason: "The DICOM PDF could not be written. The original report has been left unchanged.", userInfo: nil).raise()
                                }

                                var idb: DicomDatabase? = nil
                                if Thread.current.isMainThread {
                                    idb = BrowserController.currentBrowser()?.database
                                } else {
                                    idb = BrowserController.currentBrowser()?.database?.independentDatabase() as? DicomDatabase
                                }

                                if isMainDB {
                                    _ = idb?.addFiles(atPaths: dicomStudyArray(filePath) as? [Any],
                                                      postNotifications: true,
                                                      dicomOnly: true,
                                                      rereadExistingItems: true,
                                                      generatedByOsiriX: true)
                                } else {
                                    _ = DicomDatabase(atPath: FileManager.default.tmpDirPath())?.addFiles(atPaths: dicomStudyArray(filePath) as? [Any],
                                                                                postNotifications: true,
                                                                                dicomOnly: true,
                                                                                rereadExistingItems: true,
                                                                                generatedByOsiriX: true)
                                }
                            }
                        } catch {
                            caught = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                        }
                        if let e = caught {
                            _N2LogExceptionImpl(e, true, "-[DicomStudy setStateText:]")
                            // Validation goes on; the missing DICOM PDF is said, not only logged (#649).
                            let reason = String(format: "%@: %@", dicomStudyArg(self.name ?? ""), dicomStudyArg(e.reason ?? e.name.rawValue))
                            DispatchQueue.main.async {
                                AppController.shared()?.notificationTitle(NSLocalizedString("Report Error", comment: ""), description: reason, name: "reportConversion")
                            }
                        }
                    }
                }
            }

            let previousState = self.primitiveValue(forKey: "stateText") as? NSNumber

            self.willChangeValue(forKey: "stateText")
            self.setPrimitiveValue(c, forKey: "stateText")
            self.didChangeValue(forKey: "stateText")

            if (c?.int32Value ?? 0) != (previousState?.int32Value ?? 0) {
                self.archiveAnnotationsAsDICOMSR()
            }
        }
    }

    @NSManaged public var studyInstanceUID: String!

    @objc public dynamic var studyName: String! {
        get {
            if UserDefaults.standard.bool(forKey: "CapitalizedString") {
                return (self.primitiveValue(forKey: "studyName") as? NSString)?.capitalized
            }

            return self.primitiveValue(forKey: "studyName") as? String
        }
        set {
            self.willChangeValue(forKey: "studyName")
            self.setPrimitiveValue(newValue, forKey: "studyName")
            self.didChangeValue(forKey: "studyName")
        }
    }

    @NSManaged public var windowsState: Data!
    @NSManaged public var albums: NSSet!

    @objc public dynamic var series: NSSet! {
        get {
            if (self.managedObjectContext?.deletedObjects.count ?? 0) == 0 {
                return self.primitiveValue(forKey: "series") as? NSSet
            } else {
                return ((self.primitiveValue(forKey: "series") as? NSSet)?.objects(passingTest: { obj, _ in
                    if (obj as? NSManagedObject)?.isDeleted ?? false {
                        return false
                    }

                    return true
                }) as NSSet?)
            }
        }
        set {
            self.willChangeValue(forKey: "series")
            self.setPrimitiveValue(newValue, forKey: "series")
            self.didChangeValue(forKey: "series")
        }
    }

    // MARK: Class methods

    @objc public dynamic class func dbModifyLock() -> NSRecursiveLock! {
        return dbModifyLockStorage
    }

    @objc(soundex:)
    public dynamic class func soundex(_ s: String!) -> String! {
        let a = (s as NSString?)?.components(separatedBy: " ")
        let r = NSMutableString()

        for w in a ?? [] {
            r.append(" ")
            r.append((soundex4(w) as String?) ?? "(null)")
        }

        return r as String
    }

    @objc(yearOldFromDateOfBirth:)
    public dynamic class func yearOld(fromDateOfBirth dateOfBirth: Date!) -> String! {
        if let dateOfBirth = dateOfBirth {
            // Measured against now, so the age can change at any second of the day
            // a birth date falls on; kept for the minute, which is the most a
            // redraw of the list could be behind.
            let key = String(format: "today|%.6f|%.0f|%@", dateOfBirth.timeIntervalSinceReferenceDate, floor(Date.timeIntervalSinceReferenceDate / 60.0), (NSTimeZone.default as NSTimeZone).name) as NSString
            var age = dicomStudyAgeCache.object(forKey: key) as String?
            if age == nil {
                age = self.computeYearOld(fromDateOfBirth: dateOfBirth)
                dicomStudyCacheAge(age, key)
            }
            return age
        }
        else { return "" }
    }

    @objc(yearOldAcquisition:FromDateOfBirth:)
    public dynamic class func yearOldAcquisition(_ acquisitionDate: Date!, fromDateOfBirth dateOfBirth: Date!) -> String! {
        if let dateOfBirth = dateOfBirth, let acquisitionDate = acquisitionDate {
            let key = String(format: "acquisition|%.6f|%.6f|%@", dateOfBirth.timeIntervalSinceReferenceDate, acquisitionDate.timeIntervalSinceReferenceDate, (NSTimeZone.default as NSTimeZone).name) as NSString
            var age = dicomStudyAgeCache.object(forKey: key) as String?
            if age == nil {
                age = self.computeYearOldAcquisition(acquisitionDate, fromDateOfBirth: dateOfBirth)
                dicomStudyCacheAge(age, key)
            }
            return age
        }
        else { return "" }
    }

    @objc(computeYearOldAcquisition:FromDateOfBirth:)
    public dynamic class func computeYearOldAcquisition(_ acquisitionDate: Date!, fromDateOfBirth dateOfBirth: Date!) -> String! {
        if let dateOfBirth = dateOfBirth, let acquisitionDate = acquisitionDate {
            return dicomStudyAge(acquisitionDate, since: dateOfBirth)
        }
        else { return "" }
    }

    @objc(computeYearOldFromDateOfBirth:)
    public dynamic class func computeYearOld(fromDateOfBirth dateOfBirth: Date!) -> String! {
        if let dateOfBirth = dateOfBirth {
            return dicomStudyAge(nil, since: dateOfBirth)
        }
        else { return "" }
    }

    @objc(displaySeriesWithSOPClassUID:andSeriesDescription:containingOnlyPixels:)
    public dynamic class func displaySeries(withSOPClassUID uid: String!, andSeriesDescription description: String!, containingOnlyPixels pixels: Bool) -> Bool {
        if dicomStudyEqual(description, "OsiriX No Autodeletion") {
            return false
        }

        if pixels {
            if uid == nil || DCMAbstractSyntaxUID.isImageStorage(uid) {
                if dicomStudyEqual(uid, DCMAbstractSyntaxUID.pdfStorageClassUID()) {
                    return false
                }

                return true
            }
        } else {
            if uid == nil || DCMAbstractSyntaxUID.isImageStorage(uid) || DCMAbstractSyntaxUID.isRadiotherapy(uid) || DCMAbstractSyntaxUID.isWaveform(uid) {
                return true
            }

            if DCMAbstractSyntaxUID.isStructuredReport(uid) && dicomStudyHasPrefix(description, "OsiriX ROI SR") == false && dicomStudyHasPrefix(description, "OsiriX Annotations SR") == false && dicomStudyHasPrefix(description, "OsiriX Report SR") == false && dicomStudyHasPrefix(description, "OsiriX WindowsState SR") == false {
                return true
            }
        }

        return false
    }

    @objc(displaySeriesWithSOPClassUID:andSeriesDescription:)
    public dynamic class func displaySeries(withSOPClassUID uid: String!, andSeriesDescription description: String!) -> Bool {
        return self.displaySeries(withSOPClassUID: uid, andSeriesDescription: description, containingOnlyPixels: false)
    }

    @objc(displayedModalitiesForSeries:)
    public dynamic class func displayedModalities(forSeries seriesModalities: NSArray!) -> String! {
        let r = NSMutableArray()

        var SC = false, SR = false, PR = false, OT = false

        for mod in dicomStudyEnumerate(seriesModalities) {
            if dicomStudyElementEqual(mod, "SR") {
                SR = true
            } else if dicomStudyElementEqual(mod, "SC") {
                SC = true
            } else if dicomStudyElementEqual(mod, "PR") {
                PR = true
            } else if dicomStudyElementEqual(mod, "RTSTRUCT") {
                // Listed once, as RT: this looked for "RTSTRUCT" in the list,
                // so a second RTSTRUCT series added RT again (#778).
                if !r.contains("RT") {
                    r.add("RT")
                }
            } else if dicomStudyElementEqual(mod, "OT") {
                OT = true
            } else if dicomStudyElementEqual(mod, "KO") {
            } else if !r.contains(mod) {
                r.add(mod)
            }
        }

        if r.count == 0 {
            if SC { r.add("SC") }
            else if OT { r.add("OT") }
            else {
                if SR { r.add("SR") }
                if PR { r.add("PR") }
            }
        }

        let m = r.componentsJoined(by: "\\")

        return m
    }

    @objc public dynamic class func seriesSortDescriptors() -> NSArray! {
        let sortid = NSSortDescriptor(key: "seriesInstanceUID", ascending: true, selector: NSSelectorFromString("numericCompare:"))
        let sortdate = NSSortDescriptor(key: "date", ascending: true)
        var sortDescriptors: NSArray? = nil

        if UserDefaults.standard.integer(forKey: "SERIESORDER") == 0 { sortDescriptors = [sortid, sortdate] }
        else if UserDefaults.standard.integer(forKey: "SERIESORDER") == 1 { sortDescriptors = [sortdate, sortid] }
        else { sortDescriptors = [sortid, sortdate] }

        return sortDescriptors
    }

    // MARK: Accessors the class adds

    @objc public dynamic func isDistant() -> Bool {
        return false
    }

    @objc(isHidden)
    public dynamic func isHidden() -> Bool {
        return hiddenFlag
    }

    @objc(setHidden:)
    public dynamic func setHidden(_ h: Bool) {
        hiddenFlag = h
    }

    // -type, under another Swift name: a method named type would hide
    // type(of:) from the extensions of the class.
    @objc(type)
    public dynamic func objectType() -> String! {
        return "Study"
    }

    @objc public dynamic func soundex() -> String! {
        return DicomStudy.soundex(self.name)
    }

    @objc public dynamic func dicomTime() -> NSNumber! {
        var time: NSNumber? = nil
        dicomStudySynchronized(self) {
            if let cached = self.dicomTimeCache {
                time = cached
                return
            }

            self.dicomTimeCache = (DCMCalendarDate.dicomTime(with: self.date) as? DCMCalendarDate)?.timeAsNumber()

            time = self.dicomTimeCache
        }
        return time
    }

    @objc public dynamic func intervalSinceBirth() -> NSNumber! {
        // -[NSDate timeIntervalSinceDate: nil] is NaN; a nil receiver answers 0.
        let dateOfBirth = self.dateOfBirth
        if UserDefaults.standard.integer(forKey: "yearOldDatabaseDisplay") == 0 {
            return NSNumber(value: dateOfBirth.map { Date().timeIntervalSince($0) } ?? Double.nan)
        } else {
            guard let date = self.date else { return NSNumber(value: 0.0) }
            return NSNumber(value: dateOfBirth.map { date.timeIntervalSince($0) } ?? Double.nan)
        }
    }

    @objc public dynamic func yearOldAcquisition() -> String! {
        return DicomStudy.yearOldAcquisition(self.date, fromDateOfBirth: self.dateOfBirth)
    }

    @objc public dynamic func yearOld() -> String! {
        return DicomStudy.yearOld(fromDateOfBirth: self.dateOfBirth)
    }

    @objc public dynamic func localstring() -> String! {
        var local = true

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy localstring]") {
            let obj = (dicomStudyValue(self.series?.anyObject(), "images") as? NSSet)?.anyObject()
            local = (dicomStudyValue(obj, "inDatabaseFolder") as? NSNumber)?.boolValue ?? false
        }
        dicomStudyUnlock(self.managedObjectContext)

        if local {
            return "L"
        }
        else { return "" }
    }

    @objc public dynamic func albumsNames() -> String! {
        var names: String? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy albumsNames]") {
            names = ((self.albums?.allObjects as NSArray?)?.value(forKey: "name") as? NSArray)?.componentsJoined(by: "/")
        }
        dicomStudyUnlock(self.managedObjectContext)

        return names
    }

    // MARK: Counts

    @objc public dynamic func rawNoFiles() -> NSNumber! {
        var sum: Int32 = 0

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy rawNoFiles]") {
            for s in (self.series?.allObjects ?? []) {
                sum &+= (dicomStudyValue(s, "rawNoFiles") as? NSNumber)?.int32Value ?? 0
            }
        }
        dicomStudyUnlock(self.managedObjectContext)

        return NSNumber(value: sum)
    }

    @objc public dynamic func noFilesExcludingMultiFrames() -> NSNumber! {
        if ((self.primitiveValue(forKey: "numberOfImages") as? NSNumber)?.int32Value ?? 0) <= 0 { // There are frames !
            var result: NSNumber? = nil

            dicomStudyLock(self.managedObjectContext)
            dicomStudyTry("-[DicomStudy noFilesExcludingMultiFrames]") {
                var sum: Int32 = 0
                for s in (self.series?.allObjects ?? []) {
                    sum &+= (dicomStudyValue(s, "noFilesExcludingMultiFrames") as? NSNumber)?.int32Value ?? 0
                }
                result = NSNumber(value: sum)
            }
            dicomStudyUnlock(self.managedObjectContext)

            if let result = result {
                return result
            }
        }
        return self.noFiles()
    }

    @objc public dynamic func noSeries() -> NSNumber! {
        return NSNumber(value: Int32(truncatingIfNeeded: self.imageSeries()?.count ?? 0))
    }

    @objc public dynamic func noFiles() -> NSNumber! {
        let n = (self.primitiveValue(forKey: "numberOfImages") as? NSNumber)?.int32Value ?? 0
        if n == 0 {
            var sum: Int32 = 0
            var no: NSNumber? = nil

            dicomStudyLock(self.managedObjectContext)
            dicomStudyTry("-[DicomStudy noFiles]") {
                var framesInSeries = false

                for s in (self.series?.allObjects ?? []) {
                    if DCMAbstractSyntaxUID.isStructuredReport(dicomStudyValue(s, "seriesSOPClassUID") as? String) == false &&
                        DCMAbstractSyntaxUID.isSupportedPrivateClasses(dicomStudyValue(s, "seriesSOPClassUID") as? String) == false &&
                        DCMAbstractSyntaxUID.isPresentationState(dicomStudyValue(s, "seriesSOPClassUID") as? String) == false {
                        sum &+= (dicomStudyValue(s, "noFiles") as? NSNumber)?.int32Value ?? 0

                        if (((s as? NSManagedObject)?.primitiveValue(forKey: "numberOfImages") as? NSNumber)?.int32Value ?? 0) < 0 { // There are frames !
                            framesInSeries = true
                        }
                    }
                }

                if framesInSeries {
                    sum = 0 &- sum
                }

                no = NSNumber(value: sum)

                self.willChangeValue(forKey: "numberOfImages")
                self.setPrimitiveValue(no, forKey: "numberOfImages")
                self.didChangeValue(forKey: "numberOfImages")
            }
            dicomStudyUnlock(self.managedObjectContext)

            if sum < 0 {
                return NSNumber(value: 0 &- sum)
            }
            else { return no }
        } else {
            if n < 0 {
                return NSNumber(value: 0 &- n)
            }
            else { return self.primitiveValue(forKey: "numberOfImages") as? NSNumber }
        }
    }

    // MARK: Files and images

    /// The union of the sets of a key path of the series' images.
    private func unionOfImages(keyPath: String, function: String) -> NSSet? {
        var result: NSSet? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry(function) {
            let set = NSMutableSet()
            for subset in dicomStudyEnumerate(self.value(forKeyPath: keyPath)) {
                dicomStudyUnion(set, subset)
            }
            result = set
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func paths() -> NSSet! {
        return self.unionOfImages(keyPath: "series.images.completePath", function: "-[DicomStudy paths]")
    }

    @objc public dynamic func pathsForForkedProcess() -> NSSet! {
        return self.unionOfImages(keyPath: "series.images.completePathWithNoDownloadAndLocalOnly", function: "-[DicomStudy pathsForForkedProcess]")
    }

    @objc public dynamic func keyImages() -> NSSet! {
        var result: NSSet? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy keyImages]") {
            let set = NSMutableSet()
            for object in dicomStudyEnumerate(self.series) {
                dicomStudyUnion(set, dicomStudyGet(object, "keyImages"))
            }
            result = set
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func images() -> NSSet! {
        return self.unionOfImages(keyPath: "series.images", function: "-[DicomStudy images]")
    }

    // MARK: Series subselections

    @objc public dynamic func allSeries() -> NSArray! {
        return self.series?.sortedArray(using: (DicomStudy.seriesSortDescriptors() as? [NSSortDescriptor]) ?? []) as NSArray?
    }

    @objc(imageSeriesContainingPixels:)
    public dynamic func imageSeriesContainingPixels(_ pixels: Bool) -> NSArray! {
        var result: NSArray? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy imageSeriesContainingPixels:]") {
            let newArray = NSMutableArray()
            for series in (self.series?.sortedArray(using: (DicomStudy.seriesSortDescriptors() as? [NSSortDescriptor]) ?? []) ?? []) {
                do {
                    try HorosObjCException.perform {
                        if let series = series as? DicomSeries, DicomStudy.displaySeries(withSOPClassUID: series.seriesSOPClassUID, andSeriesDescription: series.name, containingOnlyPixels: pixels) {
                            newArray.add(series)
                        }
                    }
                } catch {
                }
            }
            result = newArray
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func imageSeries() -> NSArray! {
        return self.imageSeriesContainingPixels(false)
    }

    // What [[self imageSeries] count] says, without sorting the series first: the
    // database list shows it on every row.
    @objc public dynamic func numberOfImageSeries() -> UInt {
        var count: UInt = 0

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy numberOfImageSeries]") {
            for series in dicomStudyEnumerate(self.series) {
                do {
                    try HorosObjCException.perform {
                        if let series = series as? DicomSeries, DicomStudy.displaySeries(withSOPClassUID: series.seriesSOPClassUID, andSeriesDescription: series.name) {
                            count += 1
                        }
                    }
                } catch {
                }
            }
        }
        dicomStudyUnlock(self.managedObjectContext)

        return count
    }

    /// The series of the study whose SOP class passes `test`.
    private func seriesWithSOPClass(_ function: String, _ test: (String?) -> Bool) -> NSArray? {
        var result: NSArray? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry(function) {
            let newArray = NSMutableArray()
            for series in dicomStudyEnumerate(self.series) {
                if test(dicomStudyValue(series, "seriesSOPClassUID") as? String) {
                    newArray.add(series)
                }
            }
            result = newArray
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func keyObjectSeries() -> NSArray! {
        return self.seriesWithSOPClass("-[DicomStudy keyObjectSeries]") { dicomStudyEqual(DCMAbstractSyntaxUID.keyObjectSelectionDocumentStorage(), $0) }
    }

    @objc public dynamic func keyObjects() -> NSArray! {
        var result: NSArray? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy keyObjects]") {
            let set = NSMutableSet()
            for series in dicomStudyEnumerate(self.keyObjectSeries()) {
                dicomStudyUnion(set, dicomStudyGet(series, "images"))
            }
            result = set.allObjects as NSArray
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func presentationStateSeries() -> NSArray! {
        return self.seriesWithSOPClass("-[DicomStudy presentationStateSeries]") { DCMAbstractSyntaxUID.isPresentationState($0) }
    }

    @objc public dynamic func waveFormSeries() -> NSArray! {
        return self.seriesWithSOPClass("-[DicomStudy waveFormSeries]") { DCMAbstractSyntaxUID.isWaveform($0) }
    }

    // MARK: The app's own SR series

    /// The series of `array` (the study's) with the id and name the app gives
    /// an SR series of its own. When there are several, as a crash or a second
    /// machine leaves them, the others' images are merged into the last one and
    /// the others deleted, under the method's own exception log;
    /// `numberOfImagesFirst` says whether numberOfImages is reset before the
    /// save (the report, windows state and ROI series) or after the merge (the
    /// annotations series), as each method did.
    private func ownSRSeries(in array: NSSet?, _ number: Int32, _ name: String, logFormat: String, function: String, numberOfImagesFirst: Bool) -> NSArray {
        let newArray = NSMutableArray()

        for series in dicomStudyEnumerate(array) {
            if (dicomStudyValue(series, "id") as? NSNumber)?.int32Value ?? 0 == number &&
                dicomStudyEqual(dicomStudyValue(series, "name"), name) &&
                DCMAbstractSyntaxUID.isStructuredReport(dicomStudyValue(series, "seriesSOPClassUID") as? String) == true {
                newArray.add(series)
            }
        }

        if newArray.count > 1 {
            NSLog(logFormat, Int32(truncatingIfNeeded: newArray.count))

            dicomStudyTry(function) {
                let r = (newArray.lastObject as AnyObject).mutableSetValue(forKey: "images")

                for i in dicomStudyEnumerate(newArray) {
                    if (i as AnyObject) !== (newArray.lastObject as AnyObject?) {
                        dicomStudyPerform(r, "addObjectsFromArray:", (dicomStudyValue(i, "images") as? NSSet)?.allObjects)

                        let o = (i as AnyObject).mutableSetValue(forKey: "images")
                        o.setValue(NSNumber(value: false), forKeyPath: "inDatabaseFolder")
                        o.removeAllObjects()
                        if let i = i as? NSManagedObject {
                            self.managedObjectContext?.delete(i)
                        }
                    }
                }

                if numberOfImagesFirst {
                    self.numberOfImages = nil
                }

                try? self.managedObjectContext?.save()

                r.setValue(NSNumber(value: true), forKeyPath: "inDatabaseFolder")
            }

            if !numberOfImagesFirst {
                self.numberOfImages = nil
            }
        }

        return newArray
    }

    @objc public dynamic func annotationsSRImage() -> DicomImage! { // Comments, Status, Key Images, ...
        let array = self.series
        if (array?.count ?? 0) < 1 { return nil }

        var image: DicomImage? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy annotationsSRImage]") {
            let newArray = self.ownSRSeries(in: array, 5004, "OsiriX Annotations SR", logFormat: "****** multiple (%d) annotationsSRImage 5004 series: Delete the extra series and merge the images...", function: "-[DicomStudy annotationsSRImage]", numberOfImagesFirst: false)

            if ((dicomStudyValue(newArray.lastObject, "images") as? NSSet)?.count ?? 0) > 1 {
                var images = (dicomStudyValue(newArray.lastObject, "images") as? NSSet)?.allObjects

                // Take the most recent image: dates tie within a second, and the SR stored later is the newer (#645)
                images = ArchivedSRImages.sortedOldestFirst(images)
                image = images?.last as? DicomImage
            }
            else {
                image = (dicomStudyValue(newArray.lastObject, "images") as? NSSet)?.anyObject() as? DicomImage
            }
        }
        dicomStudyUnlock(self.managedObjectContext)

        return image
    }

    @objc public dynamic func reportImage() -> DicomImage! {
        var images: [Any]? = nil

        dicomStudyTry("-[DicomStudy reportImage]") {
            images = (dicomStudyValue(self.reportSRSeries(), "images") as? NSSet)?.allObjects

            if (images?.count ?? 0) > 1 {
                // Take the most recent image: dates tie within a second, and the SR stored later is the newer (#645)
                images = ArchivedSRImages.sortedOldestFirst(images)
            }
        }

        return images?.last as? DicomImage
    }

    @objc public dynamic func reportSRSeries() -> DicomSeries! {
        let array = self.series
        if (array?.count ?? 0) < 1 { return nil }

        var result: DicomSeries? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy reportSRSeries]") {
            result = self.ownSRSeries(in: array, 5003, "OsiriX Report SR", logFormat: "****** multiple (%d) reportSRSeries: Delete the extra series and merge the images...", function: "-[DicomStudy reportSRSeries]", numberOfImagesFirst: true).lastObject as? DicomSeries
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func allWindowsStateSRSeries() -> NSArray! {
        var images: [Any]? = nil

        dicomStudyTry("-[DicomStudy allWindowsStateSRSeries]") {
            images = (dicomStudyValue(self.windowsStateSRSeries(), "images") as? NSSet)?.allObjects

            if (images?.count ?? 0) > 1 {
                // Take the most recent image: dates tie within a second, and the SR stored later is the newer (#645)
                images = ArchivedSRImages.sortedOldestFirst(images)
            }
        }

        return images as NSArray?
    }

    @objc public dynamic func windowsStateImage() -> DicomImage! { // most recent state
        return self.allWindowsStateSRSeries()?.lastObject as? DicomImage
    }

    @objc public dynamic func windowsStateSRSeries() -> DicomSeries! {
        let array = self.series
        if (array?.count ?? 0) < 1 { return nil }

        var result: DicomSeries? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy windowsStateSRSeries]") {
            result = self.ownSRSeries(in: array, 5006, "OsiriX WindowsState SR", logFormat: "****** multiple (%d) reportSRSeries: Delete the extra series and merge the images...", function: "-[DicomStudy windowsStateSRSeries]", numberOfImagesFirst: true).lastObject as? DicomSeries
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    @objc public dynamic func roiSRSeries() -> DicomSeries! {
        let array = self.series
        if (array?.count ?? 0) < 1 { return nil }

        var result: DicomSeries? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy roiSRSeries]") {
            result = self.ownSRSeries(in: array, 5002, "OsiriX ROI SR", logFormat: "****** multiple (%d) roiSRSeries: Delete the extra series and merge the images...", function: "-[DicomStudy roiSRSeries]", numberOfImagesFirst: true).lastObject as? DicomSeries
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }

    // MARK: ROIs

    @objc(roiForImage:inArray:)
    public dynamic func roiForImage(_ image: DicomImage!, inArray roisArray: NSArray!) -> DicomImage! {
        var roi: DicomImage? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy roiForImage:inArray:]") {
            var searchedUID = dicomStudyValue(image, "sopInstanceUID") as? NSString

            searchedUID = searchedUID?.appending(String(format: "-%d", (dicomStudyValue(image, "frameID") as? NSNumber)?.int32Value ?? 0)) as NSString?

            var rois = roisArray
            if rois == nil {
                rois = (dicomStudyValue(self.roiSRSeries(), "images") as? NSSet)?.allObjects as NSArray?
            }

            var found = rois?.filtered(using: dicomStudyPredicate("comment == %@", searchedUID)) as NSArray?

            // Take the most recent roi
            if (found?.count ?? 0) > 1 {
                found = (found?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: true)]) as NSArray?)?.mutableCopy() as? NSArray
                NSLog("--- multiple rois array for same sopInstanceUID (roiForImage) : %d", Int32(truncatingIfNeeded: found?.count ?? 0))

                // Merge the other ROIs with this ROI, and empty the old ones
                let r = NSMutableArray()
                for i in dicomStudyEnumerate(found) {
                    if (i as AnyObject) !== (found?.lastObject as AnyObject?) {
                        dicomStudyTry("-[DicomStudy roiForImage:inArray:]") {
                            if !(DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false) {
                                // Not modified on the 'bonjour client side'?
                                if (dicomStudyValue(i, "inDatabaseFolder") as? NSNumber)?.boolValue ?? false {
                                    // The ROI file was maybe changed on the server -> delete it
                                    dicomStudyRemoveItem(dicomStudyValue(i, "completePath") as? String)
                                }
                            }

                            let d = SRAnnotation.roi(fromDICOM: dicomStudyValue(i, "completePathResolved") as? String)

                            if let d = d {
                                let o = dicomStudyUnarchive(d) as? NSArray

                                if (o?.count ?? 0) != 0 {
                                    dicomStudyPerform(r, "addObjectsFromArray:", o)
                                    _ = SRAnnotation.archiveROIs(asDICOM: [], toPath: dicomStudyValue(i, "completePathResolved") as? String, forImage: image)
                                }
                            }
                        }
                    }
                }

                if r.count != 0 {
                    let o = dicomStudyUnarchive(SRAnnotation.roi(fromDICOM: dicomStudyValue(found?.lastObject, "completePathResolved") as? String)) as? NSArray
                    dicomStudyPerform(r, "addObjectsFromArray:", o)

                    _ = SRAnnotation.archiveROIs(asDICOM: r as? [Any], toPath: dicomStudyValue(found?.lastObject, "completePathResolved") as? String, forImage: image)
                }
            }

            if !(DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false) {
                // Not modified on the 'bonjour client side'?
                if (dicomStudyValue(found?.lastObject, "inDatabaseFolder") as? NSNumber)?.boolValue ?? false {
                    // The ROI file was maybe changed on the server -> delete it
                    if dicomStudyValue(found?.lastObject, "completePath") != nil {
                        dicomStudyRemoveItem(dicomStudyValue(found?.lastObject, "completePath") as? String)
                    }
                }
            }

            roi = found?.lastObject as? DicomImage
        }
        dicomStudyUnlock(self.managedObjectContext)

        return roi
    }

    @objc(roiPathForImage:)
    public dynamic func roiPath(forImage image: DicomImage!) -> String! {
        return self.roiPath(forImage: image, inArray: nil)
    }

    @objc(roiPathForImage:inArray:)
    public dynamic func roiPath(forImage image: DicomImage!, inArray roisArray: NSArray!) -> String! {
        var path: String? = nil

        dicomStudyTry("-[DicomStudy roiPathForImage:inArray:]") {
            let roi = self.roiForImage(image, inArray: roisArray)

            path = dicomStudyValue(roi, "completePathResolved") as? String

            if path == nil { // Try the 'old' ROIs folder
                path = dicomStudyGet(image, "SRPath") as? String
            }
        }

        return path
    }

    @objc public dynamic func roiImages() -> NSArray! {
        let roiImages = NSMutableArray()

        let allImages = self.images()?.allObjects as NSArray?

        for roi in dicomStudyEnumerate(dicomStudyGet(self.roiSRSeries(), "images")) {
            let robjs = dicomStudyUnarchive(SRAnnotation.roi(fromDICOM: dicomStudyGet(roi, "completePath") as? String))
            if dicomStudyCount(robjs) == 0 { continue }

            let comment = dicomStudyValue(roi, "comment") as? NSString
            let it = comment?.range(of: "-", options: [.literal, .backwards]).location ?? 0
            let uid = comment?.substring(to: it)
            let fid = (comment?.substring(from: it + 1) as NSString?)?.intValue ?? 0
            // find the image that uses these ROIs
            var p: NSPredicate
            if fid != 0 {
                p = dicomStudyPredicate("sopInstanceUID = %@ and frameID = %@", uid, NSNumber(value: fid))
            }
            else {
                p = dicomStudyPredicate("sopInstanceUID = %@", uid)
            }

            let found = allImages?.filtered(using: p) as NSArray?
            if (found?.count ?? 0) != 0 {
                roiImages.add(found!.object(at: 0))
            }
        }

        let sortid = NSSortDescriptor(key: "series.seriesInstanceUID", ascending: true) { o1, o2 in
            return dicomStudyCompareNumeric(o1, o2)
        }

        roiImages.sort(using: [sortid, NSSortDescriptor(key: "date", ascending: false), NSSortDescriptor(key: "instanceNumber", ascending: true)])

        return roiImages
    }

    @objc public dynamic func roiAndKeyImages() -> NSArray! {
        let images = NSMutableArray(array: (self.roiImages() ?? NSArray()).addingObjects(from: (self.keyImages()?.allObjects) ?? []))

        // remove double entries: first sort, then remove subsequent doubles
        images.sort(comparator: { obj1, obj2 in
            let a = UInt(bitPattern: ObjectIdentifier(obj1 as AnyObject))
            let b = UInt(bitPattern: ObjectIdentifier(obj2 as AnyObject))
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        })

        var i = images.count - 2
        while i >= 0 {
            if (images.object(at: i) as AnyObject) === (images.object(at: i + 1) as AnyObject) {
                images.removeObject(at: i + 1)
            }
            i -= 1
        }

        let sortid = NSSortDescriptor(key: "series.seriesInstanceUID", ascending: true) { o1, o2 in
            return dicomStudyCompareNumeric(o1, o2)
        }

        images.sort(using: [sortid, NSSortDescriptor(key: "date", ascending: false), NSSortDescriptor(key: "instanceNumber", ascending: true)])

        return images
    }

    @objc(generateDICOMSCImagesForKeyImages:andROIImages:)
    public dynamic func generateDICOMSCImages(forKeyImages keyImages: Bool, andROIImages ROIImages: Bool) -> NSArray! {
        let images = self.images(forKeyImages: keyImages, andForROIs: ROIImages)

        let producedFiles = NSMutableArray()
        let exporter = DICOMExport()

        for image in dicomStudyEnumerate(images) {
            let d = dicomStudyGet(image, "imageAsDICOMScreenCapture:", exporter)

            dicomStudyAdd(producedFiles, d)
        }

        if producedFiles.count != 0 {
            var objects = BrowserController.currentBrowser()?.database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                                                                 postNotifications: true,
                                                                                 dicomOnly: true,
                                                                                 rereadExistingItems: true,
                                                                                 generatedByOsiriX: true)

            objects = BrowserController.currentBrowser()?.database?.objects(withIDs: objects)

            return objects as NSArray?
        }
        return nil
    }

    // MARK: Comparisons and relations

    @objc(compareName:)
    public dynamic func compareName(_ study: DicomStudy!) -> ComparisonResult {
        guard let name = self.name as NSString? else { return .orderedSame }
        guard let other = dicomStudyValue(study, "name") as? String else { return .orderedDescending }
        return name.caseInsensitiveCompare(other)
    }

    @objc public dynamic func studiesForThisPatient() -> NSArray! {
        var comparatives: NSArray? = nil
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
        req.predicate = dicomStudyPredicate("(patientUID == %@)", self.patientUID)

        dicomStudyTry("-[DicomStudy studiesForThisPatient]", stack: false) {
            comparatives = (try? self.managedObjectContext?.fetch(req)) as NSArray?
        }

        return comparatives
    }

    @objc public dynamic func authorizedUsers() -> NSArray! {
        let webContext = WebPortal.default()?.database?.independentContext()

        var result: NSArray? = nil
        dicomStudyTry("-[DicomStudy authorizedUsers]") {
            let dbRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "User")
            dbRequest.predicate = NSPredicate(value: true)
            dbRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            // Find all users
            let users = (try? webContext?.fetch(dbRequest)) as NSArray?

            // Find all comparatives for this patient
            let allStudies = self.studiesForThisPatient()

            let authorizedUsers = NSMutableArray()
            for case let user as WebPortalUser in dicomStudyEnumerate(users) {
                if dicomStudyLength(user.studyPredicate) > 0 {
                    var studies: NSArray? = nil

                    // First check the studyPredicate of the user

                    // The flag is read, not tested for nil: a user who may not see the
                    // patient's other studies had the access of one who may (#778).
                    if user.canAccessPatientsOtherStudies?.boolValue ?? false {
                        studies = dicomStudyFiltered(allStudies, DicomDatabase.predicate(forSmartAlbumFilter: user.studyPredicate))
                    }
                    else {
                        studies = dicomStudyFiltered(NSArray(object: self), DicomDatabase.predicate(forSmartAlbumFilter: user.studyPredicate))
                    }

                    if (studies?.count ?? 0) != 0 {
                        authorizedUsers.add(user)
                    }

                    // And now check his list of specific studies
                    else {
                        if (user.canAccessPatientsOtherStudies?.boolValue ?? false) && dicomStudyContains(((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: "patientUID"), self.patientUID) {
                            authorizedUsers.add(user)
                        }

                        else if dicomStudyContains(((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: "studyInstanceUID"), self.studyInstanceUID) {
                            authorizedUsers.add(user)
                        }
                    }
                }
                else {
                    authorizedUsers.add(user)
                }
            }

            result = authorizedUsers
        }

        return result
    }

    // MARK: Annotations and the SRs the app archives

    @objc public dynamic func reapplyAnnotationsFromDICOMSR() {
        if DicomStudy.avoidReentry3 != 0 {
            NSLog("****** reapplyAnnotationsFromDICOMSR avoidReentry")
            return
        }

        DicomStudy.avoidReentry3 += 1

        if self.hasDICOM?.boolValue == true {
            dicomStudyTry("-[DicomStudy reapplyAnnotationsFromDICOMSR]") {
                let archivedAnnotations = self.annotationsSRImage()
                let dstPath = dicomStudyValue(archivedAnnotations, "completePath") as? String

                if let dstPath = dstPath {
                    let r = SRAnnotation(contentsOfFile: dstPath)

                    let annotations = r?.annotations()
                    if let annotations = annotations {
                        self.applyAnnotations(fromDictionary: annotations as NSDictionary)
                    }
                }
            }
        }

        DicomStudy.avoidReentry3 -= 1
    }

    @objc(applyAnnotationsFromDictionary:)
    public dynamic func applyAnnotations(fromDictionary rootDict: NSDictionary!) {
        guard let rootDict = rootDict else {
            NSLog("******** applyAnnotationsFromDictionary : rootDict == nil")
            return
        }

        if dicomStudyEqual(self.studyInstanceUID, rootDict.value(forKey: "studyInstanceUID")) == false { // || [self.patientUID compare: [rootDict valueForKey: @"patientUID"] options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch] != NSOrderedSame)
            NSLog("******** WARNING applyAnnotationsFromDictionary will not be applied - studyInstanceUID are NOT corresponding: %@ / %@", dicomStudyArg(rootDict.value(forKey: "studyInstanceUID")), dicomStudyArg(self.studyInstanceUID))
        }
        else {
            dicomStudyTry("-[DicomStudy applyAnnotationsFromDictionary:]") {
                // We are at root level
                for key in ["comment", "comment2", "comment3", "comment4", "stateText"] {
                    if rootDict.value(forKey: key) != nil {
                        self.willChangeValue(forKey: key)
                        self.setPrimitiveValue(rootDict.value(forKey: key), forKey: key)
                        self.didChangeValue(forKey: key)
                    }
                }

                let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Album")
                req.predicate = NSPredicate(value: true)
                let albums = (try? self.managedObjectContext?.fetch(req)) as NSArray?

                for name in dicomStudyEnumerate(rootDict.value(forKey: "albums")) {
                    // [nil indexOfObject:] is 0, and the album a message to nil.
                    guard let albums = albums else { continue }

                    let index = (albums.value(forKey: "name") as! NSArray).index(of: name)

                    if index != NSNotFound {
                        if ((albums.object(at: index) as AnyObject).value(forKey: "smartAlbum") as? NSNumber)?.boolValue ?? false == false {
                            let studies = (albums.object(at: index) as AnyObject).mutableSetValue(forKey: "studies")

                            studies.add(self)
                        }
                    }
                }

                let seriesArray = self.series?.allObjects as NSArray?

                var allImages: NSArray? = nil, compressedSopInstanceUIDArray: NSArray? = nil

                for series in dicomStudyEnumerate(rootDict.value(forKey: "series")) {
                    // -------------------------
                    // Find corresponding series
                    if dicomStudyValue(series, "seriesInstanceUID") != nil && dicomStudyValue(series, "seriesDICOMUID") != nil {
                        var index = (seriesArray?.value(forKey: "seriesInstanceUID") as? NSArray)?.index(of: dicomStudyValue(series, "seriesInstanceUID")!) ?? 0

                        if index == NSNotFound {
                            index = (seriesArray?.value(forKey: "seriesDICOMUID") as? NSArray)?.index(of: dicomStudyValue(series, "seriesDICOMUID")!) ?? 0
                        }

                        if index != NSNotFound {
                            // A nil seriesArray answered index 0 and a nil series.
                            let s = seriesArray?.object(at: index) as? NSManagedObject

                            for key in ["comment", "comment2", "comment3", "comment4", "stateText"] {
                                if dicomStudyValue(series, key) != nil {
                                    s?.willChangeValue(forKey: key)
                                    s?.setPrimitiveValue(dicomStudyValue(series, key), forKey: key)
                                    s?.didChangeValue(forKey: key)
                                }
                            }

                            for image in dicomStudyEnumerate(dicomStudyValue(series, "images")) {
                                if allImages == nil {
                                    var all = NSArray()
                                    for w in dicomStudyEnumerate(seriesArray) {
                                        all = all.addingObjects(from: (dicomStudyValue(w, "images") as? NSSet)?.allObjects ?? []) as NSArray
                                    }
                                    allImages = all

                                    compressedSopInstanceUIDArray = all.filtered(using: NSPredicate(format: "compressedSopInstanceUID != NIL")) as NSArray
                                }

                                let predicate = NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: "compressedSopInstanceUID"), rightExpression: NSExpression(forConstantValue: DicomImage.sopInstanceUIDEncode(dicomStudyValue(image, "sopInstanceUID") as? String)), customSelector: NSSelectorFromString("isEqualToSopInstanceUID:"))
                                let found = compressedSopInstanceUIDArray?.filtered(using: predicate) as NSArray?

                                // -------------------------
                                // Find corresponding image
                                if (found?.count ?? 0) > 0 {
                                    let i = found?.lastObject as? NSManagedObject

                                    if dicomStudyValue(image, "isKeyImage") != nil {
                                        i?.willChangeValue(forKey: "storedIsKeyImage")
                                        i?.setPrimitiveValue(dicomStudyValue(image, "isKeyImage"), forKey: "storedIsKeyImage")
                                        i?.didChangeValue(forKey: "storedIsKeyImage")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @objc public dynamic func annotationsAsDictionary() -> NSDictionary! {
        // Comments - Study / Series

        // State - Study / Series

        // Albums - Study

        // Key Images - Image

        // ***************************************************************************************************

        // Study Level

        let rootDict = NSMutableDictionary()

        if self.studyInstanceUID != nil {
            dicomStudySet(rootDict, self.studyInstanceUID, "studyInstanceUID")
        }

        if self.name != nil {
            dicomStudySet(rootDict, self.name, "patientsName")
        }

        if self.patientID != nil {
            dicomStudySet(rootDict, self.patientID, "patientID")
        }

        if self.patientUID != nil {
            dicomStudySet(rootDict, self.patientUID, "patientUID")
        }

        if self.comment != nil { dicomStudySet(rootDict, self.comment, "comment") }
        if self.comment2 != nil { dicomStudySet(rootDict, self.comment2, "comment2") }
        if self.comment3 != nil { dicomStudySet(rootDict, self.comment3, "comment3") }
        if self.comment4 != nil { dicomStudySet(rootDict, self.comment4, "comment4") }

        if self.stateText != nil {
            dicomStudySet(rootDict, self.stateText, "stateText")
        }

        let albumsArray = NSMutableArray()

        for a in dicomStudyEnumerate((self.albums?.allObjects as NSArray?)?.sortedArray(using: [NSSortDescriptor(key: "name", ascending: true)])) {
            if (dicomStudyValue(a, "smartAlbum") as? NSNumber)?.boolValue ?? false == false {
                let name = dicomStudyValue(a, "name")
                dicomStudyAdd(albumsArray, name)
            }
        }

        rootDict.setObject(albumsArray, forKey: "albums" as NSString)

        // ***************************************************************************************************

        // Series Level

        let seriesArray = NSMutableArray()

        for series in dicomStudyEnumerate((self.series?.allObjects as NSArray?)?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: true)])) {
            let seriesDict = NSMutableDictionary()

            if dicomStudyValue(series, "seriesInstanceUID") != nil && dicomStudyValue(series, "seriesDICOMUID") != nil {
                for key in ["comment", "comment2", "comment3", "comment4", "stateText"] {
                    if dicomStudyValue(series, key) != nil { dicomStudySet(seriesDict, dicomStudyValue(series, key), key) }
                }

                // ***************************************************************************************************

                // Images Level

                let imagesArray = NSMutableArray()
                for image in dicomStudyEnumerate(((dicomStudyValue(series, "images") as? NSSet)?.allObjects as NSArray?)?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: true)])) {
                    let imageDict = NSMutableDictionary()

                    if dicomStudyValue(image, "sopInstanceUID") != nil {
                        if dicomStudyValue(image, "storedIsKeyImage") != nil {
                            dicomStudySet(imageDict, dicomStudyValue(image, "isKeyImage"), "isKeyImage")
                            dicomStudySet(imageDict, dicomStudyValue(image, "sopInstanceUID"), "sopInstanceUID")
                            imagesArray.add(imageDict)
                        }
                    }
                }

                if imagesArray.count > 0 {
                    seriesDict.setObject(imagesArray, forKey: "images" as NSString)
                }

                if seriesDict.count > 0 {
                    dicomStudySet(seriesDict, dicomStudyValue(series, "seriesInstanceUID"), "seriesInstanceUID")
                    dicomStudySet(seriesDict, dicomStudyValue(series, "seriesDICOMUID"), "seriesDICOMUID")

                    seriesArray.add(seriesDict)
                }
            }
        }

        if seriesArray.count > 0 {
            rootDict.setObject(seriesArray, forKey: "series" as NSString)
        }

        return rootDict
    }

    // The image an archived SR refers to and takes its patient data from: an image of an image series, not one of
    // the app's own SRs, which made the SR unreadable or left it without a patient (#651). Any image when the study
    // holds nothing else.
    @objc public dynamic func archivedSRReferenceImage() -> DicomImage! {
        return (ArchivedSRReference.image(inSeries: self.series?.allObjects) ?? (dicomStudyValue(self.series?.anyObject(), "images") as? NSSet)?.anyObject()) as? DicomImage
    }

    @objc public dynamic func archiveAnnotationsAsDICOMSR() {
        if DicomStudy.avoidReentry2 != 0 {
            NSLog("****** archiveAnnotationsAsDICOMSR avoidReentry")
            return
        }

        DicomStudy.avoidReentry2 += 1

        if self.hasDICOM?.boolValue == true {
            dicomStudyTry("-[DicomStudy archiveAnnotationsAsDICOMSR]") {
                let isMainDB = self.managedObjectContext?.persistentStoreCoordinator === BrowserController.currentBrowser()?.database?.managedObjectContext?.persistentStoreCoordinator

                let archivedAnnotations = self.annotationsSRImage()
                var dstPath = dicomStudyValue(archivedAnnotations, "completePath") as? String

                if dstPath == nil {
                    dstPath = isMainDB ? DicomDatabase(for: self.managedObjectContext)?.uniquePathForNewDataFile(withExtension: "dcm") : FileManager.default.tmpFilePathInTmp()
                }

                let annotationsDict = self.annotationsAsDictionary()

                let w = SRAnnotation(contentsOfFile: dstPath)
                if ((w?.annotations() as NSDictionary?)?.isEqual(to: annotationsDict as? [AnyHashable: Any] ?? [:]) ?? false) == false {
                    if w != nil {
                        dstPath = isMainDB ? DicomDatabase(for: self.managedObjectContext)?.uniquePathForNewDataFile(withExtension: "dcm") : FileManager.default.tmpFilePathInTmp()
                    }

                    // Save or Re-Save it as DICOM SR
                    let r = SRAnnotation(dictionary: annotationsDict as? [AnyHashable: Any], path: dstPath, for: self.archivedSRReferenceImage())
                    _ = r?.writeToFile(atPath: dstPath)

                    var idb: DicomDatabase? = nil
                    if Thread.current.isMainThread {
                        idb = BrowserController.currentBrowser()?.database
                    } else {
                        idb = BrowserController.currentBrowser()?.database?.independentDatabase() as? DicomDatabase
                    }

                    if isMainDB {
                        _ = idb?.addFiles(atPaths: dicomStudyArray(dstPath) as? [Any],
                                          postNotifications: false,
                                          dicomOnly: true,
                                          rereadExistingItems: true,
                                          generatedByOsiriX: true)
                    } else {
                        _ = DicomDatabase(atPath: FileManager.default.tmpDirPath())?.addFiles(atPaths: dicomStudyArray(dstPath) as? [Any],
                                                                    postNotifications: false,
                                                                    dicomOnly: true,
                                                                    rereadExistingItems: true,
                                                                    generatedByOsiriX: true)
                    }
                }
            }
        }
        DicomStudy.avoidReentry2 -= 1
    }

    @objc public dynamic func archiveWindowsStateAsDICOMSR() {
        NSLog("--- Windows State -> DICOM SR : %@", dicomStudyArg(self.name))

        let windowsState = self.windowsState

        let dstPath = BrowserController.currentBrowser()?.database?.uniquePathForNewDataFile(withExtension: "dcm")

        let r = SRAnnotation(windowsState: windowsState, path: dstPath, for: self.archivedSRReferenceImage())

        _ = r?.writeToFile(atPath: dstPath)

        try? self.managedObjectContext?.save()

        var idb: DicomDatabase? = nil
        if Thread.current.isMainThread {
            idb = BrowserController.currentBrowser()?.database
        } else {
            idb = BrowserController.currentBrowser()?.database?.independentDatabase() as? DicomDatabase
        }

        _ = idb?.addFiles(atPaths: dicomStudyArray(dstPath) as? [Any],
                          postNotifications: true,
                          dicomOnly: true,
                          rereadExistingItems: true,
                          generatedByOsiriX: true)
    }

    @objc public dynamic func archiveReportAsDICOMSR() {
        if UserDefaults.standard.bool(forKey: "archiveReportsAndAnnotationsAsDICOMSR") == false {
            return
        }

        if DicomStudy.avoidReentry != 0 {
            NSLog("****** archiveReportAsDICOMSR avoidReentry")
            return
        }

        DicomStudy.avoidReentry += 1

        if self.hasDICOM?.boolValue == true {
            dicomStudyLock(self.managedObjectContext)
            var archiveDirectory: String? = nil
            dicomStudyTry("-[DicomStudy archiveReportAsDICOMSR]") {
                let isMainDB = self.managedObjectContext?.persistentStoreCoordinator === BrowserController.currentBrowser()?.database?.managedObjectContext?.persistentStoreCoordinator

                // Report
                archiveDirectory = FileManager.default.tmpDirectoryPathInTmp()
                var zippedFile = (archiveDirectory as NSString?)?.appendingPathComponent("report.zip")
                var needToArchive = false
                var dstPath: String? = nil
                let reportImage = self.reportImage()

                dstPath = dicomStudyValue(reportImage, "completePathResolved") as? String

                if dstPath == nil {
                    dstPath = isMainDB ? DicomDatabase(for: self.managedObjectContext)?.uniquePathForNewDataFile(withExtension: "dcm") : FileManager.default.tmpFilePathInTmp()
                }

                if dicomStudyHasPrefix(self.reportURL, "http://") || dicomStudyHasPrefix(self.reportURL, "https://") {
                    let r = SRAnnotation(contentsOfFile: dstPath)
                    if dicomStudyEqual(self.reportURL, r?.reportURL()) == false {
                        needToArchive = true
                    }
                }
                else if dicomStudyFileExists(self.reportURL) {
                    // Dates lose subsecond precision in SR. Compare archive contents
                    // even when both timestamps describe the same second.
                    do {
                        BrowserController.encryptFileOrFolder(self.reportURL, inZIPFile: zippedFile, password: nil, deleteSource: false, showGUI: false)

                        if dicomStudyFileExists(zippedFile) {
                            let r = SRAnnotation(contentsOfFile: dstPath)
                            let zipped = zippedFile.flatMap { NSData(contentsOfFile: $0) }
                            if dicomStudyDataEqual(zipped, r?.dataEncapsulated()) == false {
                                needToArchive = true
                            }
                        }
                    }
                }
                else //empty or deleted report?
                {
                    if dicomStudyValue(reportImage, "completePath") != nil && dicomStudyFileExists(dicomStudyValue(reportImage, "completePath") as? String) {
                        needToArchive = true
                        zippedFile = nil	//We will archive an empty NSData
                    }

                    if self.reportURL != nil && dicomStudyFileExists(self.reportURL) {
                        dicomStudyRemoveItem(self.reportURL)
                    }

                    self.willChangeValue(forKey: "reportURL")
                    self.setPrimitiveValue(nil, forKey: "reportURL")
                    self.didChangeValue(forKey: "reportURL")
                }

                if needToArchive {
                    var r: SRAnnotation? = nil

                    NSLog("--- Report -> DICOM SR : %@", dicomStudyArg(self.name))

                    if dicomStudyHasPrefix(self.reportURL, "http://") || dicomStudyHasPrefix(self.reportURL, "https://") {
                        r = SRAnnotation(urlReport: self.reportURL, path: dstPath, for: self.archivedSRReferenceImage())
                    }
                    else {
                        let modifDate = (self.reportURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) })?[.modificationDate] as? Date
                        r = SRAnnotation(fileReport: zippedFile, path: dstPath, for: self.archivedSRReferenceImage(), contentDate: modifDate)
                    }

                    if !(r?.writeToFile(atPath: dstPath) ?? false) {
                        NSException(name: NSExceptionName("ReportArchive"), reason: "Could not write the DICOM report archive.", userInfo: nil).raise()
                    }

                    try? self.managedObjectContext?.save()

                    var idb: DicomDatabase? = nil
                    if Thread.current.isMainThread {
                        idb = BrowserController.currentBrowser()?.database
                    } else {
                        idb = BrowserController.currentBrowser()?.database?.independentDatabase() as? DicomDatabase
                    }

                    if isMainDB {
                        _ = idb?.addFiles(atPaths: dicomStudyArray(dstPath) as? [Any],
                                          postNotifications: true,
                                          dicomOnly: true,
                                          rereadExistingItems: true,
                                          generatedByOsiriX: true)
                    } else {
                        _ = DicomDatabase(atPath: FileManager.default.tmpDirPath())?.addFiles(atPaths: dicomStudyArray(dstPath) as? [Any],
                                                                    postNotifications: true,
                                                                    dicomOnly: true,
                                                                    rereadExistingItems: true,
                                                                    generatedByOsiriX: true)
                    }
                }

                if zippedFile != nil {
                    dicomStudyRemoveItem(zippedFile)
                }
            }
            if archiveDirectory != nil { dicomStudyRemoveItem(archiveDirectory) }
            dicomStudyUnlock(self.managedObjectContext)
        }

        DicomStudy.avoidReentry -= 1
    }

    // MARK: DICOM files

    @objc(dcmodifyThread:)
    public dynamic func dcmodifyThread(_ dict: NSDictionary!) {
        autoreleasepool {
            DicomStudy.dbModifyLock()?.lock()
            dicomStudyTry("-[DicomStudy dcmodifyThread:]") {
                let tagAndValues = NSMutableArray()

                let field = DCMAttributeTag(tagString: dict?.object(forKey: "field") as? String)
                if dict?.object(forKey: "value") == nil || dicomStudyLength(dict?.object(forKey: "value")) == 0 {
                    tagAndValues.add(field.map { NSArray(object: $0) } ?? NSArray())
                }
                else {
                    tagAndValues.add(field.map { NSArray(objects: $0, dict!.object(forKey: "value")!) } ?? NSArray())
                }

                let files = NSMutableArray(array: (dict?.object(forKey: "files") as? [Any]) ?? [])

                _ = XMLController.modifyDicom(tagAndValues as? [Any], dicomFiles: files as? [Any])

                for loopItem in dicomStudyEnumerate(files) {
                    dicomStudyRemoveItem((loopItem as? NSString)?.appending(".bak"))
                }
            }
            DicomStudy.dbModifyLock()?.unlock()
        }
    }

    // MARK: NSManagedObject

    public override func validateForDelete() throws {
        try super.validateForDelete()

        let reportPath = self.reportURL
        if let reportPath = reportPath, let context = self.managedObjectContext, context.responds(to: NSSelectorFromString("performAfterSuccessfulSave:")) {
            (context as AnyObject).perform?(afterSuccessfulSave: {
                try? FileManager.default.removeItem(atPath: reportPath)
            })
        }
    }

    public override func didTurnIntoFault() {
        dicomTimeCache = nil
        cachedModalites = nil

        super.didTurnIntoFault()
    }

    public override func setValue(_ value: Any?, forUndefinedKey key: String) {
    }

    public override func value(forUndefinedKey key: String) -> Any? {
        // The file of one image answers (#778). This gathered -paths, every file
        // of the study, for each key asked - a viewer asks for each of its
        // images - and then sent -completePath to one of those paths, a string,
        // which raised.
        var path: String? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy valueForUndefinedKey:]") {
            for series in dicomStudyEnumerate(self.series) {
                if let image = (dicomStudyValue(series, "images") as? NSSet)?.anyObject() as? DicomImage {
                    path = image.completePath()
                    break
                }
            }
        }
        dicomStudyUnlock(self.managedObjectContext)

        if let path = path, let value = DicomFile.getDicomField(key, forFile: path) {
            return value
        }

        return super.value(forUndefinedKey: key)
    }

    @objc public dynamic func modalities() -> String! {
        var result: String? = nil

        dicomStudyLock(self.managedObjectContext)
        dicomStudyTry("-[DicomStudy modalities]") {
            if let cached = self.cachedModalites, self.numberOfImagesWhenCachedModalities == (self.numberOfImages?.intValue ?? 0) {
                result = cached as String
                return
            }

            // skip the "OsiriX No Autodeletion" series
            let series = NSMutableArray(array: self.series?.allObjects ?? [])
            for serie in dicomStudyEnumerate(series) {
                if let s = serie as? DicomSeries, (s.id?.int32Value ?? 0) == 5005 && dicomStudyEqual(s.name, "OsiriX No Autodeletion") {
                    series.remove(serie)
                    break
                }
            }

            let m = DicomStudy.displayedModalities(forSeries: (series.sortedArray(using: [NSSortDescriptor(key: "date", ascending: true)]) as NSArray).value(forKey: "modality") as? NSArray)

            self.cachedModalites = m as NSString?
            self.numberOfImagesWhenCachedModalities = self.numberOfImages?.intValue ?? 0

            result = m
        }
        dicomStudyUnlock(self.managedObjectContext)

        return result
    }
}

/// `[array filteredArrayUsingPredicate: predicate]`: nil for a nil array; a nil
/// predicate raises as it did.
fileprivate func dicomStudyFiltered(_ array: NSArray?, _ predicate: NSPredicate?) -> NSArray? {
    guard let array = array else { return nil }
    guard let predicate = predicate else {
        return dicomStudyGet(array, "filteredArrayUsingPredicate:", nil) as? NSArray
    }
    return array.filtered(using: predicate) as NSArray
}

/// `[array containsObject: object]`: NO for a nil array or a nil object.
fileprivate func dicomStudyContains(_ array: Any?, _ object: Any?) -> Bool {
    guard let array = array as? NSArray, let object = object else { return false }
    return array.contains(object)
}

/// `[object count]` of an unarchived object: 0 for nil; an object that does not
/// answer raises as it did.
fileprivate func dicomStudyCount(_ object: Any?) -> Int {
    guard let object = object else { return 0 }
    if let array = object as? NSArray { return array.count }
    if let set = object as? NSSet { return set.count }
    if let dictionary = object as? NSDictionary { return dictionary.count }
    dicomStudyPerform(object, "count")
    return 0
}

/// `[data isEqualToData: other]`: NO for a nil receiver or a nil argument.
fileprivate func dicomStudyDataEqual(_ data: NSData?, _ other: Data?) -> Bool {
    guard let data = data, let other = other else { return false }
    return data.isEqual(to: other)
}

/// `[o1 compare: o2 options: NSNumericSearch | NSCaseInsensitiveSearch]` of the
/// ROI and key images' sort, whose key (series.seriesInstanceUID) is a string
/// or nil: 0 for a nil receiver, as a message to nil answered; a nil argument
/// sorts after (NSOrderedDescending), as NSString answers.
fileprivate func dicomStudyCompareNumeric(_ o1: Any?, _ o2: Any?) -> ComparisonResult {
    guard let s1 = o1 as? NSString else { return .orderedSame }
    guard let s2 = o2 as? String else { return .orderedDescending }
    return s1.compare(s2, options: [.numeric, .caseInsensitive])
}

// MARK: - Core Data generated accessors

/// The to-many accessors Core Data provides at run time (@NSManaged, as the
/// former CoreDataGeneratedAccessors category declared them), and the other
/// member that category declared.
extension DicomStudy {
    @objc(addAlbumsObject:)
    @NSManaged public func addAlbumsObject(_ value: NSManagedObject!)

    @objc(removeAlbumsObject:)
    @NSManaged public func removeAlbumsObject(_ value: NSManagedObject!)

    @objc(addAlbums:)
    @NSManaged public func addAlbums(_ value: NSSet!)

    @objc(removeAlbums:)
    @NSManaged public func removeAlbums(_ value: NSSet!)

    @objc(addSeriesObject:)
    @NSManaged public func addSeriesObject(_ value: DicomSeries!)

    @objc(removeSeriesObject:)
    @NSManaged public func removeSeriesObject(_ value: DicomSeries!)

    @objc(addSeries:)
    @NSManaged public func addSeries(_ value: NSSet!)

    @objc(removeSeries:)
    @NSManaged public func removeSeries(_ value: NSSet!)

    @objc(scrambleString:)
    public dynamic class func scrambleString(_ t: String!) -> String! {
        if DicomStudy.scrambleLetters == nil {
            let v = NSMutableArray(array: ["A", "E", "I", "O", "U", "Y", "R", "F", "N", "M", "P", "L", "S", "D", "B", "C"])

            var i = v.count
            while i > 1 {
                v.exchangeObject(at: i - 1, withObjectAt: HorosDicomStudyRandom() % i)
                i -= 1
            }

            DicomStudy.scrambleLetters = v
        }

        let v = DicomStudy.scrambleLetters!
        var t = t as NSString?

        for (index, letter) in ["A", "E", "I", "O", "U", "Y", "R", "F", "N", "M", "P", "L", "S", "D", "B", "C"].enumerated() {
            t = t?.replacingOccurrences(of: letter, with: v.object(at: index) as! String) as NSString?
        }

        for (index, letter) in ["a", "e", "i", "o", "u", "y", "r", "f", "n", "m", "p", "l", "s", "d", "b", "c"].enumerated() {
            t = t?.replacingOccurrences(of: letter, with: v.object(at: index) as! String) as NSString?
        }
        return t as String?
    }
}

// Declared by the former CoreDataGeneratedAccessors category, so an extension
// keeps it where plugins built against that header expect it.
extension DicomStudy {
    /// The key images, the images with ROIs, or both, as the screen captures
    /// below choose them. The former header declared it and nothing implemented
    /// it (#778).
    @objc(imagesForKeyImages:andForROIs:)
    public dynamic func images(forKeyImages keyImages: Bool, andForROIs alsoImagesWithROIs: Bool) -> NSArray! {
        if keyImages && alsoImagesWithROIs {
            return self.roiAndKeyImages()
        }
        else if keyImages {
            return (self.keyImages()?.allObjects as NSArray?) ?? NSArray()
        }
        else if alsoImagesWithROIs {
            return self.roiImages()
        }
        return NSArray()
    }
}
