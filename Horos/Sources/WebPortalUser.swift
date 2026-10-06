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

fileprivate let TIMEOUT: TimeInterval = 5 * 60

/// @synchronized(object) { body }: the same recursive lock (objc_sync_enter).
/// An NSException that body raises releases it and then goes on to the
/// caller, as it did through @synchronized. A nil object takes no lock, as
/// @synchronized(nil) did.
fileprivate func webPortalUserSynchronized(_ object: AnyObject?, _ body: () -> Void) {
    guard let object = object else {
        body()
        return
    }
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

/// +[NSEntityDescription entityForName:inManagedObjectContext:]. A nil context
/// is sent as nil, so it raises as it did.
fileprivate func webPortalUserEntity(_ name: String, _ context: NSManagedObjectContext?) -> NSEntityDescription? {
    if let context = context {
        return NSEntityDescription.entity(forEntityName: name, in: context)
    }
    return (NSEntityDescription.self as AnyObject).perform(#selector(NSEntityDescription.entity(forEntityName:in:)), with: name, with: nil)?.takeUnretainedValue() as? NSEntityDescription
}

/// -executeFetchRequest:error:NULL: nil for a nil context or a failed fetch. An
/// NSException it raises goes on to the caller.
fileprivate func webPortalUserFetch(_ context: NSManagedObjectContext?, _ request: NSFetchRequest<NSFetchRequestResult>) -> NSArray? {
    guard let context = context else { return nil }
    return (try? context.fetch(request)) as NSArray?
}

/// +predicateWithFormat: with %@ arguments that may be nil: a nil argument is
/// the constant nil, as in a C argument list (NSNull would not be).
fileprivate func webPortalUserPredicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
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

/// -replaceObjectAtIndex:withObject:, which raises for a nil object.
fileprivate func webPortalUserReplace(_ array: NSMutableArray, _ index: Int, _ object: Any?) {
    guard let object = object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM replaceObjectAtIndex:withObject:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.replaceObject(at: index, with: object)
}

/// -[NSMutableDictionary setObject:forKey:] of a dictionary that may be nil (a
/// message to nil did nothing), with a key that may be nil (which raises).
fileprivate func webPortalUserCacheSet(_ dictionary: NSMutableDictionary?, _ object: Any, _ key: String?) {
    guard let dictionary = dictionary else { return }
    guard let key = key else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil", userInfo: nil).raise()
        return
    }
    dictionary.setObject(object, forKey: key as NSString)
}

/// The cache entry of `key`, if it is younger than TIMEOUT (an entry without
/// a date counts as young, as a message to nil answered 0).
fileprivate func webPortalUserFreshEntry(_ cache: NSMutableDictionary?, _ key: String?) -> NSDictionary? {
    guard let key = key, let entry = cache?.object(forKey: key) as? NSDictionary else { return nil }
    return ((entry.object(forKey: "date") as? NSDate)?.timeIntervalSinceNow ?? 0) > -TIMEOUT ? entry : nil
}

/// The cached array of an entry, its object IDs turned back into objects of
/// the given database.
fileprivate func webPortalUserCachedObjects(_ entry: NSDictionary, _ database: DicomDatabase?) -> NSMutableArray {
    let cachedObjects = NSMutableArray(array: (entry.object(forKey: "array") as? [Any]) ?? [])

    var i = 0
    while i < cachedObjects.count {
        if cachedObjects.object(at: i) is NSManagedObjectID {
            webPortalUserReplace(cachedObjects, i, database?.object(withID: cachedObjects.object(at: i)))
        }
        i += 1
    }

    return cachedObjects
}

/// -subarrayWithRange: of the page fetchLimit/fetchOffset, with the unsigned
/// arithmetic of the former NSRange.
fileprivate func webPortalUserPage(_ array: NSArray?, _ fetchLimit: Int32, _ fetchOffset: Int32) -> NSArray? {
    guard let array = array else { return nil }
    let count = UInt(array.count)
    var location = UInt(bitPattern: Int(fetchOffset))
    var length = UInt(bitPattern: Int(fetchLimit))

    if location > count {
        location = count
    }

    if location &+ length > count {
        length = count &- location
    }

    return array.subarray(with: NSRange(location: Int(bitPattern: location), length: Int(bitPattern: length))) as NSArray
}

/// What a caught NSException (or another error) prints as with %@.
fileprivate func webPortalUserCaught(_ error: Error) -> NSObject {
    return ((error as NSError).userInfo[HorosObjCExceptionKey] as? NSObject) ?? (error as NSError)
}

/// -filteredArrayUsingPredicate: of an array that may be nil (a message to nil
/// answered nil). A nil predicate is sent as nil, so it raises as it did.
fileprivate func webPortalUserFiltered(_ array: NSArray?, _ predicate: NSPredicate?) -> NSArray? {
    guard let array = array else { return nil }
    guard let predicate = predicate else {
        return webPortalUserSendNil(array, #selector(NSArray.filtered(using:))) as? NSArray
    }
    return array.filtered(using: predicate) as NSArray
}

/// A message sent as Objective-C sends it: an object that does not answer it
/// raises.
fileprivate func webPortalUserSend(_ object: Any, _ selector: Selector) -> AnyObject? {
    return (object as AnyObject).perform(selector)?.takeUnretainedValue()
}

/// A one-argument message with a nil argument, sent as Objective-C sends it,
/// for the methods that raise on nil.
fileprivate func webPortalUserSendNil(_ object: Any, _ selector: Selector) -> AnyObject? {
    return (object as AnyObject).perform(selector, with: nil)?.takeUnretainedValue()
}

/// Core Data entity for a web user.
///
/// Implemented in Swift: the Objective-C name (which the WebPortalDB
/// model names as the User entity's class), the selectors and
/// <Horos/WebPortalUser.h> are those of the former class. Core Data provides
/// the accessors of the modelled properties (@NSManaged, the former @dynamic),
/// except the six the class writes itself, as before: the getters of address,
/// email and phone, and the setters of autoDelete, name and password. Their
/// other half is written here as Core Data's own does it (willAccess/didAccess
/// and willChange/didChange around the primitive value), since Swift cannot
/// leave one half of a property to Core Data.
///
/// The password is stored as before: -convertPasswordToHashIfNeeded replaces
/// it by HASHPASSWORD and keeps in passwordHash the hexadecimal SHA-1
/// (-[NSData sha1Digest], -[NSData hex]) of the UTF-8 bytes of password + name.
@objc(WebPortalUser)
public final class WebPortalUser: NSManagedObject {
    /// Guards `generator` and `storedStudiesForUserCache`: users are made and
    /// their studies listed on the portal's connection threads as well as the
    /// main thread.
    private static let staticsLock = NSLock()
    // nonisolated(unsafe): read and written only inside `staticsLock.withLock`.
    nonisolated(unsafe) private static var generator: PSGenerator? = nil
    /// Nil until the first listing registers the observer that empties it:
    /// without that observer, nothing may be cached.
    // nonisolated(unsafe): read and written only inside `staticsLock.withLock`;
    // the dictionary itself is used inside @synchronized on it.
    nonisolated(unsafe) private static var storedStudiesForUserCache: NSMutableDictionary? = nil
    private static var studiesForUserCache: NSMutableDictionary? {
        staticsLock.withLock { storedStudiesForUserCache }
    }

    // MARK: Properties

    @objc public var address: String! {
        get {
            if self.primitiveValue(forKey: "address") == nil {
                return ""
            }

            return self.primitiveValue(forKey: "address") as? String
        }
        set {
            self.willChangeValue(forKey: "address")
            self.setPrimitiveValue(newValue, forKey: "address")
            self.didChangeValue(forKey: "address")
        }
    }

    @objc public var autoDelete: NSNumber! {
        get {
            self.willAccessValue(forKey: "autoDelete")
            let v = self.primitiveValue(forKey: "autoDelete") as? NSNumber
            self.didAccessValue(forKey: "autoDelete")
            return v
        }
        set {
            if newValue?.boolValue ?? false {
                self.setValue(Date(timeIntervalSinceReferenceDate: Date.timeIntervalSinceReferenceDate + Double(UserDefaults.standard.integer(forKey: "temporaryUserDuration") * 60 * 60 * 24)), forKey: "deletionDate")
            }
            self.willChangeValue(forKey: "autoDelete")
            self.setPrimitiveValue(newValue, forKey: "autoDelete")
            self.didChangeValue(forKey: "autoDelete")
        }
    }

    @NSManaged public var canAccessPatientsOtherStudies: NSNumber!
    @NSManaged public var canSeeAlbums: NSNumber!
    @NSManaged public var creationDate: Date!
    @NSManaged public var deletionDate: Date!
    @NSManaged public var downloadZIP: NSNumber!

    @objc public var email: String! {
        get {
            if self.primitiveValue(forKey: "email") == nil {
                return ""
            }

            return self.primitiveValue(forKey: "email") as? String
        }
        set {
            self.willChangeValue(forKey: "email")
            self.setPrimitiveValue(newValue, forKey: "email")
            self.didChangeValue(forKey: "email")
        }
    }

    @NSManaged public var emailNotification: NSNumber!
    @NSManaged public var encryptedZIP: NSNumber!
    @NSManaged public var isAdmin: NSNumber!

    @objc public var name: String! {
        get {
            self.willAccessValue(forKey: "name")
            let v = self.primitiveValue(forKey: "name") as? String
            self.didAccessValue(forKey: "name")
            return v
        }
        set {
            let newName = newValue
            if !(self.name.map { (newName as NSString?)?.isEqual(to: $0) ?? false } ?? false) {
                if ((self.password as NSString?)?.length ?? 0) > 0 && !((self.password as NSString?)?.isEqual(to: HASHPASSWORD) ?? false) {

                } else {
                    NSLog("------- WebPortalUser : name changed -> password reset")
                    self.generatePassword()

                    NotificationCenter.default.post(name: NSNotification.Name("WebPortalUsernameChanged"), object: self)
                }

                self.willChangeValue(forKey: "name")
                self.setPrimitiveValue(newName, forKey: "name")
                self.didChangeValue(forKey: "name")
            }
        }
    }

    @objc public var password: String! {
        get {
            self.willAccessValue(forKey: "password")
            let v = self.primitiveValue(forKey: "password") as? String
            self.didAccessValue(forKey: "password")
            return v
        }
        set {
            let newPassword = newValue as NSString?
            if (newPassword?.length ?? 0) >= 4 && !(newPassword?.isEqual(to: HASHPASSWORD) ?? false) {
                self.setValue(Date(), forKey: "passwordCreationDate")

                self.willChangeValue(forKey: "password")
                self.setPrimitiveValue(newPassword, forKey: "password")
                self.didChangeValue(forKey: "password")

                self.willChangeValue(forKey: "passwordHash")
                self.setPrimitiveValue("", forKey: "passwordHash")
                self.didChangeValue(forKey: "passwordHash")

                self.willChangeValue(forKey: "passwordCreationDate")
                self.setPrimitiveValue(Date(), forKey: "passwordCreationDate")
                self.didChangeValue(forKey: "passwordCreationDate")
            }
        }
    }

    @NSManaged public var passwordHash: String!
    @NSManaged public var passwordCreationDate: Date!

    @objc public var phone: String! {
        get {
            if self.primitiveValue(forKey: "phone") == nil {
                return ""
            }

            return self.primitiveValue(forKey: "phone") as? String
        }
        set {
            self.willChangeValue(forKey: "phone")
            self.setPrimitiveValue(newValue, forKey: "phone")
            self.didChangeValue(forKey: "phone")
        }
    }

    @NSManaged public var sendDICOMtoAnyNodes: NSNumber!
    @NSManaged public var sendDICOMtoSelfIP: NSNumber!
    @NSManaged public var shareStudyWithUser: NSNumber!
    @NSManaged public var createTemporaryUser: NSNumber!
    @NSManaged public var studyPredicate: String!
    @NSManaged public var uploadDICOM: NSNumber!
    @NSManaged public var downloadReport: NSNumber!
    @NSManaged public var uploadDICOMAddToSpecificStudies: NSNumber!
    @NSManaged public var studies: Set<AnyHashable>!
    @NSManaged public var recentStudies: Set<AnyHashable>!
    @NSManaged public var showRecentPatients: NSNumber!

    // MARK: Password

    @objc(cachedArrayForArray:)
    public class func cachedArray(for studiesArray: NSArray!) -> NSArray! {
        let cachedObjects = NSMutableArray(array: (studiesArray as? [Any]) ?? [])
        let queryNodeClass: AnyClass? = NSClassFromString("DCMTKStudyQueryNode")

        var i = 0
        while i < cachedObjects.count {
            let object = cachedObjects.object(at: i)
            if !(queryNodeClass.map { (object as AnyObject).isKind(of: $0) } ?? false) {
                webPortalUserReplace(cachedObjects, i, webPortalUserSend(object, #selector(getter: NSManagedObject.objectID)))
            }
            i += 1
        }

        return cachedObjects
    }

    @objc(generatePassword)
    public func generatePassword() {
        let password = WebPortalUser.staticsLock.withLock { () -> Any? in
            if WebPortalUser.generator == nil {
                WebPortalUser.generator = PSGenerator(sourceString: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", minLength: 12, maxLength: 12)
            }
            return (WebPortalUser.generator?.generate(1) as NSArray?)?.lastObject
        }

        self.setValue(password, forKey: "password")
    }

    public override func awakeFromInsert() {
        super.awakeFromInsert()

        if self.primitiveValue(forKey: "passwordCreationDate") == nil {
            self.setPrimitiveValue(Date(), forKey: "passwordCreationDate")
        }

        if self.primitiveValue(forKey: "creationDate") == nil {
            self.setPrimitiveValue(Date(), forKey: "creationDate")
        }

        // The User entity has no dateAdded (its studies do): Core Data read
        // and would have written that key in the slot of another attribute.

        if self.primitiveValue(forKey: "studyPredicate") == nil {
            self.setPrimitiveValue("(YES == NO)", forKey: "studyPredicate")
        }

        self.generatePassword()

        // Create a unique name
        let uid = UInt64(100.0 * Date.timeIntervalSinceReferenceDate)

        self.willChangeValue(forKey: "name")
        self.setPrimitiveValue(String(format: "user %llu", uid), forKey: "name")
        self.didChangeValue(forKey: "name")
    }

    @objc(convertPasswordToHashIfNeeded)
    public func convertPasswordToHashIfNeeded() {
        let password = self.password as NSString?
        if (password?.length ?? 0) > 0 && !(password?.isEqual(to: HASHPASSWORD) ?? false) { // We dont want to store password, only sha1Digest version !
            let joined: NSString
            if let name = self.name {
                joined = password!.appending(name) as NSString
            } else {
                // -stringByAppendingString: nil raises, as it did.
                joined = webPortalUserSendNil(password!, #selector(NSString.appending(_:))) as! NSString
            }
            self.passwordHash = ((joined.data(using: String.Encoding.utf8.rawValue) as NSData?)?.sha1Digest() as NSData?)?.hex()

            self.willChangeValue(forKey: "password")
            self.setPrimitiveValue(HASHPASSWORD, forKey: "password")
            self.didChangeValue(forKey: "password")

            NSLog("---- Convert password to hash string. Delete original password for user: %@", (self.name as NSString?) ?? "(null)")
        }
    }

    // MARK: Validation

    @objc(validatePassword:error:)
    public func validatePassword(_ value: AutoreleasingUnsafeMutablePointer<NSString?>!) throws {
        let password2validate = value.pointee

        if !(password2validate?.isEqual(to: HASHPASSWORD) ?? false) {
            if ((password2validate?.replacingOccurrences(of: "*", with: "") as NSString?)?.length ?? 0) == 0 {
                throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Password cannot contain only '*' characters.", comment: ""))
            }

            if (password2validate?.length ?? 0) < 4 {
                throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Password needs to be at least 4 characters long.", comment: ""))
            }

            // Not nil past this point: a nil password ends at the first test.
            let password2validate = password2validate!

            if (password2validate.trimmingCharacters(in: CharacterSet.decimalDigits) as NSString).length == 0 {
                throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Password cannot contain only numbers: add letters.", comment: ""))
            }

            if (password2validate.replacingOccurrences(of: password2validate.substring(to: 1), with: "") as NSString).length == 0 {
                throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Password cannot contain only the same character.", comment: ""))
            }

            // -commonPrefixWithString:nil options: answers an empty prefix.
            if password2validate.length - (password2validate.commonPrefix(with: self.name ?? "", options: .caseInsensitive) as NSString).length < 4 {
                throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Password needs to be different from the user name.", comment: ""))
            }

            var invidualCharacters: UInt = 0
            let array = NSMutableArray()
            var i = 0
            while i < password2validate.length {
                let character = password2validate.substring(with: NSRange(location: i, length: 1)) as NSString
                if !array.contains(character) {
                    invidualCharacters += 1
                    array.add(character)
                }
                i += 1
            }

            if invidualCharacters < 3 {
                throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Password needs to have at least 3 different characters.", comment: ""))
            }
        }
    }

    @objc(validateDownloadZIP:error:)
    public func validateDownloadZIP(_ value: AutoreleasingUnsafeMutablePointer<NSNumber?>!) throws {
        if (value.pointee?.boolValue ?? false) && !AppController.hasMacOSXSnowLeopard() {
            throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("ZIP download requires MacOS 10.6 or higher.", comment: ""))
        }
    }

    @objc(validateName:error:)
    public func validateName(_ value: AutoreleasingUnsafeMutablePointer<NSString?>!) throws {
        if (value.pointee?.length ?? 0) < 2 {
            throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("Name needs to be at least 2 characters long.", comment: ""))
        }

        var duplicate = false
        var fetchError: Error? = nil
        do {
            try HorosObjCException.perform {
                let request = NSFetchRequest<NSFetchRequestResult>()
                request.entity = webPortalUserEntity("User", self.managedObjectContext)
                // Equality, not LIKE: a name carrying * or ? used to be compared as a
                // pattern, so it collided with names it does not equal.
                request.predicate = WebPortalUserLookup.predicate(forName: value.pointee! as String)
                var users: NSArray? = nil
                if let context = self.managedObjectContext {
                    // A failed fetch cannot tell whether the name is taken: it
                    // is an internal database error. The former code made an
                    // exception of it but never raised it, and took the name.
                    do {
                        users = try context.fetch(request) as NSArray
                    } catch {
                        fetchError = error
                        return
                    }
                }

                if ((users?.count ?? 0) == 1 && (users?.lastObject as AnyObject?) !== self) || (users?.count ?? 0) > 1 {
                    duplicate = true
                }
            }
            if let fetchError = fetchError {
                throw fetchError
            }
        } catch {
            NSLog("*** [WebPortalUser validateName:error:] exception: %@", webPortalUserCaught(error))
            let info = [NSLocalizedDescriptionKey: NSLocalizedString("Internal database error.", comment: "")]
            throw NSError(domain: "OsiriXDomain", code: -31, userInfo: info)
        }

        if duplicate {
            throw NSError.osirixError(withCode: -31, localizedDescription: NSLocalizedString("A user with that name already exists. Two users cannot have the same name.", comment: ""))
        }
    }

    @objc(validateStudyPredicate:error:)
    public func validateStudyPredicate(_ value: AutoreleasingUnsafeMutablePointer<NSString?>!) throws {
        let dicomDBContext: DicomDatabase? = WebPortal.default()?.threadDicomDatabase()

        var syntaxError: NSError? = nil
        do {
            try HorosObjCException.perform {
                if let context = dicomDBContext?.managedObjectContext {
                    // The DICOM database's Study, which the context fetches; the
                    // portal database's has the same name in another model, and
                    // Core Data refused the fetch.
                    let request = NSFetchRequest<NSFetchRequestResult>()
                    request.entity = webPortalUserEntity("Study", context)
                    request.predicate = DicomDatabase.predicate(forSmartAlbumFilter: value.pointee as String?)
                    do {
                        _ = try context.fetch(request)
                    } catch {
                        let e = error as NSError
                        syntaxError = NSError.osirixError(withCode: -31, localizedDescription: String(format: NSLocalizedString("Syntax error in study predicate filter: %@", comment: ""), e.localizedDescription as NSString)) as NSError?
                    }
                }
            }
        } catch {
            let e = webPortalUserCaught(error)
            NSLog("*** [WebPortalUser validateStudyPredicate:error:] exception: %@", e)
            throw NSError.osirixError(withCode: -31, localizedDescription: String(format: NSLocalizedString("Error: %@", comment: ""), e))
        }

        if let syntaxError = syntaxError {
            throw syntaxError
        }
    }

    // MARK: Studies

    @objc(arrayByAddingSpecificStudiesToArray:)
    public func arrayByAddingSpecificStudies(to array: [Any]!) -> [Any]! {
        return self.addingSpecificStudies(to: array.map { $0 as NSArray }) as? [Any]
    }

    private func addingSpecificStudies(to array: NSArray?) -> NSArray? {
        var specificArray: NSMutableArray? = nil
        let array: NSArray = array ?? NSArray()
        var early = false

        do {
            try HorosObjCException.perform {
                let userStudies = (self.value(forKey: "studies") as? NSSet)?.allObjects as NSArray? ?? NSArray()

                if userStudies.count == 0 {
                    early = true
                    return
                }

                let userID = (self.name as NSString?)?.appending(" specificStudies")

                webPortalUserSynchronized(WebPortalUser.studiesForUserCache) {
                    if userID != nil, let entry = webPortalUserFreshEntry(WebPortalUser.studiesForUserCache, userID) { // one hour
                        let dicomDBContext = WebPortal.default()?.threadDicomDatabase()

                        specificArray = webPortalUserCachedObjects(entry, dicomDBContext)
                    }
                }

                if specificArray == nil {
                    var studiesArray: NSArray? = nil

                    webPortalUserSynchronized(WebPortalUser.studiesForUserCache) {
                        if let entry = webPortalUserFreshEntry(WebPortalUser.studiesForUserCache, "all DB studies") {
                            let dicomDBContext = WebPortal.default()?.threadDicomDatabase()

                            studiesArray = webPortalUserCachedObjects(entry, dicomDBContext)
                        }
                    }

                    if studiesArray == nil {
                        let dicomDBContext = WebPortal.default()?.threadDicomDatabase()

                        N2ManagedObjectContextPerformAndWait(dicomDBContext?.managedObjectContext) {

                        // Find all studies
                        let req = NSFetchRequest<NSFetchRequestResult>()
                        req.entity = webPortalUserEntity("Study", dicomDBContext?.managedObjectContext)
                        req.predicate = NSPredicate(value: true)
                        studiesArray = webPortalUserFetch(dicomDBContext?.managedObjectContext, req)

                        webPortalUserSynchronized(WebPortalUser.studiesForUserCache) {
                            if let studiesArray = studiesArray {
                                webPortalUserCacheSet(WebPortalUser.studiesForUserCache, NSDictionary(objects: [WebPortalUser.cachedArray(for: studiesArray) as Any, Date()], forKeys: ["array" as NSString, "date" as NSString]), "all DB studies")
                            }
                        }

                        }
                    }

                    let newSpecificArray = NSMutableArray()
                    specificArray = newSpecificArray

                    for study in userStudies {
                        let study = study as! WebPortalStudy
                        var obj: NSArray? = nil

                        if self.canAccessPatientsOtherStudies?.boolValue ?? false {
                            obj = webPortalUserFiltered(studiesArray, webPortalUserPredicate("patientUID BEGINSWITH[cd] %@", study.patientUID))
                        } else {
                            obj = webPortalUserFiltered(studiesArray, webPortalUserPredicate("patientUID BEGINSWITH[cd] %@ AND studyInstanceUID == %@", study.patientUID, study.studyInstanceUID))
                        }

                        if (obj?.count ?? 0) >= 1 {
                            for o in obj! {
                                if !array.contains(o) && !newSpecificArray.contains(o) {
                                    newSpecificArray.add(o)
                                }
                            }
                        } else if (obj?.count ?? 0) == 0 {
                            // It means this study doesnt exist in the entire DB -> remove it from this user list
                            NSLog("This study is not longer available in the DB -> delete it : %@", (study.value(forKey: "patientUID") as? NSObject) ?? ("(null)" as NSString))
                            self.managedObjectContext?.delete(study)
                            _ = try? self.managedObjectContext?.save()
                        }
                    }

                    webPortalUserSynchronized(WebPortalUser.studiesForUserCache) {
                        if userID != nil {
                            webPortalUserCacheSet(WebPortalUser.studiesForUserCache, NSDictionary(objects: [WebPortalUser.cachedArray(for: newSpecificArray) as Any, Date()], forKeys: ["array" as NSString, "date" as NSString]), userID as String?)
                        }
                    }
                }
            }
        } catch {
            NSLog("********** addSpecificStudiesToArray : %@", webPortalUserCaught(error))
        }

        if early {
            return array
        }

        if let specificArray = specificArray {
            for study in array {
                if !specificArray.contains(study) {
                    specificArray.add(study)
                }
            }
        }

        return specificArray
    }

    @objc(studiesForPredicate:)
    public func studies(for predicate: NSPredicate!) -> [Any]! {
        return self.studies(for: predicate, sortBy: nil)
    }

    @objc(studiesForPredicate:sortBy:)
    public func studies(for predicate: NSPredicate!, sortBy sortValue: String!) -> [Any]! {
        return self.studies(for: predicate, sortBy: sortValue, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil)
    }

    @objc(studiesForPredicate:sortBy:fetchLimit:fetchOffset:numberOfStudies:)
    public func studies(for predicate: NSPredicate!, sortBy sortValue: String!, fetchLimit: Int32, fetchOffset: Int32, numberOfStudies: UnsafeMutablePointer<Int32>!) -> [Any]! {
        return WebPortalUser.studies(for: self, predicate: predicate, sortBy: sortValue, fetchLimit: fetchLimit, fetchOffset: fetchOffset, numberOfStudies: numberOfStudies)
    }

    @objc(studiesForUser:predicate:)
    public class func studies(for user: WebPortalUser!, predicate: NSPredicate!) -> [Any]! {
        return WebPortalUser.studies(for: user, predicate: predicate, sortBy: nil, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil)
    }

    @objc(studiesForUser:predicate:sortBy:)
    public class func studies(for user: WebPortalUser!, predicate: NSPredicate!, sortBy sortValue: String!) -> [Any]! {
        return WebPortalUser.studies(for: user, predicate: predicate, sortBy: sortValue, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil)
    }

    /// The observer of NSManagedObjectContextObjectsDidChangeNotification that
    /// empties the cache.
    private class func observeObjectChangesOnce() {
        let made = staticsLock.withLock { () -> Bool in
            guard storedStudiesForUserCache == nil else { return false }
            storedStudiesForUserCache = NSMutableDictionary()
            return true
        }
        if made {
            NotificationCenter.default.addObserver(self as AnyObject, selector: #selector(WebPortalUser.managedObjectChangedNotificationReceived(_:)), name: .NSManagedObjectContextObjectsDidChange, object: nil)
        }
    }

    @objc(studiesForUser:predicate:sortBy:fetchLimit:fetchOffset:numberOfStudies:)
    public class func studies(for user: WebPortalUser!, predicate: NSPredicate!, sortBy sortValue: String!, fetchLimit: Int32, fetchOffset: Int32, numberOfStudies: UnsafeMutablePointer<Int32>!) -> [Any]! {
        var studiesArray: NSArray? = nil
        var predicate: NSPredicate? = predicate

        let dicomDBContext = WebPortal.default()?.threadDicomDatabase()

        do {
            try HorosObjCException.perform {
                let req = NSFetchRequest<NSFetchRequestResult>()
                req.entity = webPortalUserEntity("Study", dicomDBContext?.managedObjectContext)

                var allStudies = false
                if ((user?.studyPredicate as NSString?)?.length ?? 0) == 0 {
                    allStudies = true
                }

                if !allStudies {
                    req.predicate = DicomDatabase.predicate(forSmartAlbumFilter: user.studyPredicate)

                    if studiesForUserCache == nil && user != nil {
                        observeObjectChangesOnce()
                    }

                    let userID = user.name

                    webPortalUserSynchronized(studiesForUserCache) {
                        if user != nil, let entry = webPortalUserFreshEntry(studiesForUserCache, userID) {
                            studiesArray = webPortalUserCachedObjects(entry, dicomDBContext)
                        }
                    }

                    if studiesArray == nil {
                        studiesArray = webPortalUserFetch(dicomDBContext?.managedObjectContext, req)

                        webPortalUserSynchronized(studiesForUserCache) {
                            if user != nil, let studiesArray = studiesArray {
                                webPortalUserCacheSet(studiesForUserCache, NSDictionary(objects: [WebPortalUser.cachedArray(for: studiesArray) as Any, Date()], forKeys: ["array" as NSString, "date" as NSString]), userID)
                            }
                        }
                    }

                    if user != nil && ((user.studyPredicate as NSString?)?.length ?? 0) > 0 {
                        studiesArray = user.addingSpecificStudies(to: studiesArray)
                    }

                    if let predicate = predicate {
                        studiesArray = webPortalUserFiltered(studiesArray, predicate)
                    }

                    if user.canAccessPatientsOtherStudies?.boolValue ?? false {
                        let req = NSFetchRequest<NSFetchRequestResult>()
                        req.entity = webPortalUserEntity("Study", dicomDBContext?.managedObjectContext)
                        req.predicate = webPortalUserPredicate("patientUID IN %@", studiesArray?.value(forKey: "patientUID"))

                        let previousStudiesArrayCount = Int32(truncatingIfNeeded: studiesArray?.count ?? 0)

                        studiesArray = webPortalUserFetch(dicomDBContext?.managedObjectContext, req)

                        if let predicate = predicate, UInt(studiesArray?.count ?? 0) != UInt(bitPattern: Int(previousStudiesArrayCount)) {
                            studiesArray = webPortalUserFiltered(studiesArray, predicate)
                        }
                    }
                } else {
                    if predicate == nil {
                        predicate = NSPredicate(value: true)
                    }

                    req.predicate = predicate

                    studiesArray = webPortalUserFetch(dicomDBContext?.managedObjectContext, req)
                }

                if ((sortValue as NSString?)?.length ?? 0) != 0 {
                    if (sortValue as NSString).range(of: "date").location == NSNotFound {
                        studiesArray = studiesArray?.sortedArray(using: [NSSortDescriptor(key: sortValue, ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]) as NSArray?
                    } else {
                        studiesArray = studiesArray?.sortedArray(using: [NSSortDescriptor(key: sortValue, ascending: false)]) as NSArray?
                    }
                }

                if let numberOfStudies = numberOfStudies {
                    numberOfStudies.pointee = Int32(truncatingIfNeeded: studiesArray?.count ?? 0)
                }

                if fetchLimit != 0 {
                    studiesArray = webPortalUserPage(studiesArray, fetchLimit, fetchOffset)
                }
            }
        } catch {
            NSLog("Error: [WebPortal studiesForUser:predicate:sortBy:] %@", webPortalUserCaught(error))
        }

        if studiesArray == nil {
            studiesArray = NSArray()
        }

        return studiesArray as? [Any]
    }

    @objc(studiesForAlbum:)
    public func studies(forAlbum albumName: String!) -> [Any]! {
        return self.studies(forAlbum: albumName, sortBy: nil)
    }

    @objc(studiesForAlbum:sortBy:)
    public func studies(forAlbum albumName: String!, sortBy sortValue: String!) -> [Any]! {
        return self.studies(forAlbum: albumName, sortBy: sortValue, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil)
    }

    @objc(studiesForAlbum:sortBy:fetchLimit:fetchOffset:numberOfStudies:)
    public func studies(forAlbum albumName: String!, sortBy sortValue: String!, fetchLimit: Int32, fetchOffset: Int32, numberOfStudies: UnsafeMutablePointer<Int32>!) -> [Any]! {
        return WebPortalUser.studies(for: self, album: albumName, sortBy: sortValue, fetchLimit: fetchLimit, fetchOffset: fetchOffset, numberOfStudies: numberOfStudies)
    }

    @objc(studiesForUser:album:)
    public class func studies(for user: WebPortalUser!, album albumName: String!) -> [Any]! {
        return WebPortalUser.studies(for: user, album: albumName, sortBy: nil, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil)
    }

    @objc(studiesForUser:album:sortBy:)
    public class func studies(for user: WebPortalUser!, album albumName: String!, sortBy sortValue: String!) -> [Any]! {
        return WebPortalUser.studies(for: user, album: albumName, sortBy: sortValue, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil)
    }

    @objc(managedObjectChangedNotificationReceived:)
    public class func managedObjectChangedNotificationReceived(_ n: Notification) {
        webPortalUserSynchronized(studiesForUserCache) {
            var set = NSMutableSet()

            if let inserted = n.userInfo?[NSInsertedObjectsKey] as? NSSet {
                set.union(inserted as! Set<AnyHashable>)
            }

            if let deleted = n.userInfo?[NSDeletedObjectsKey] as? NSSet {
                set.union(deleted as! Set<AnyHashable>)
            }

            for object in set {
                let object = object as AnyObject
                if object.isKind(of: DicomStudy.self) || object.isKind(of: WebPortalUser.self) || object.isKind(of: WebPortalStudy.self) {
                    studiesForUserCache?.removeAllObjects()
                    DicomStudyTransformer.clearOtherStudiesForThisPatientCache()
                    return
                }
            }

            // WebPortal User updated ?

            set = NSMutableSet()

            if let updated = n.userInfo?[NSUpdatedObjectsKey] as? NSSet {
                set.union(updated as! Set<AnyHashable>)
            }

            for object in set {
                if (object as AnyObject).isKind(of: WebPortalUser.self) {
                    studiesForUserCache?.removeAllObjects()
                    DicomStudyTransformer.clearOtherStudiesForThisPatientCache()
                    return
                }
            }
        }
    }

    /// The albums' studies, sorted by sortValue (by date, the most recent
    /// first, when it is empty or "date").
    private class func sortedAlbumStudies(_ studiesArray: NSArray?, _ sortValue: String?) -> NSArray? {
        if ((sortValue as NSString?)?.length ?? 0) != 0 && !((sortValue as NSString?)?.isEqual(to: "date") ?? false) {
            return studiesArray?.sortedArray(using: [NSSortDescriptor(key: sortValue, ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]) as NSArray?
        } else {
            return studiesArray?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: false)]) as NSArray?
        }
    }

    @objc(studiesForUser:album:sortBy:fetchLimit:fetchOffset:numberOfStudies:)
    public class func studies(for user: WebPortalUser!, album albumName: String!, sortBy sortValue: String!, fetchLimit: Int32, fetchOffset: Int32, numberOfStudies: UnsafeMutablePointer<Int32>!) -> [Any]! {
        var studiesArray: NSArray? = nil
        var albumArray: NSArray? = nil

        if studiesForUserCache == nil && user != nil {
            observeObjectChangesOnce()
        }

        // -stringByAppendingFormat: @" %@", as before: a nil album reads "(null)".
        let userID = (user?.name as NSString?)?.appending(" " + (albumName ?? "(null)"))

        webPortalUserSynchronized(studiesForUserCache) {
            if user != nil, let entry = webPortalUserFreshEntry(studiesForUserCache, userID) {
                let dicomDBContext = WebPortal.default()?.threadDicomDatabase()

                studiesArray = webPortalUserCachedObjects(entry, dicomDBContext)

                studiesArray = sortedAlbumStudies(studiesArray, sortValue)
            }
        }

        if studiesArray == nil {
            let dicomDBContext = WebPortal.default()?.threadDicomDatabase()

            N2ManagedObjectContextPerformAndWait(dicomDBContext?.managedObjectContext) {

            do {
                try HorosObjCException.perform {
                    let req = NSFetchRequest<NSFetchRequestResult>()
                    req.entity = webPortalUserEntity("Album", dicomDBContext?.managedObjectContext)
                    req.predicate = webPortalUserPredicate("name == %@", albumName)
                    albumArray = webPortalUserFetch(dicomDBContext?.managedObjectContext, req)
                }
            } catch {
                NSLog("******** studiesForAlbum exception: %@", webPortalUserCaught(error).description as NSString)
            }


            let album = albumArray?.lastObject as? NSObject

            if ((album?.value(forKey: "smartAlbum") as? NSNumber)?.int32Value ?? 0) == 1 {
                studiesArray = WebPortalUser.studies(for: user, predicate: DicomDatabase.predicate(forSmartAlbumFilter: album?.value(forKey: "predicateString") as? String), sortBy: sortValue).map { $0 as NSArray }

                // PACS On Demand
                var pred = (user?.studyPredicate as NSString?)?.uppercased as NSString?
                pred = pred?.replacingOccurrences(of: " ", with: "") as NSString?
                pred = pred?.replacingOccurrences(of: "(", with: "") as NSString?
                pred = pred?.replacingOccurrences(of: ")", with: "") as NSString?
                if user == nil || (pred?.length ?? 0) == 0 || (pred?.isEqual(to: "YES==YES") ?? false) {
                    if UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") && UserDefaults.standard.bool(forKey: "ActivatePACSOnDemandForWebPortalAlbums") {
//                    BOOL usePatientID = [[NSUserDefaults standardUserDefaults] boolForKey: @"UsePatientIDForUID"];
//                    BOOL usePatientBirthDate = [[NSUserDefaults standardUserDefaults] boolForKey: @"UsePatientBirthDateForUID"];
//                    BOOL usePatientName = [[NSUserDefaults standardUserDefaults] boolForKey: @"UsePatientNameForUID"];

                        // Servers
                        let servers = BrowserController.comparativeServers() as NSArray?

                        if (servers?.count ?? 0) != 0 {
                            // Distant studies
                            // In current versions, two filters exist: modality & date
                            var distantStudies: NSArray? = nil
                            for d in (UserDefaults.standard.object(forKey: "smartAlbumStudiesDICOMNodes") as? NSArray) ?? NSArray() {
                                let d = d as! NSObject
                                let dName = d.value(forKey: "name") as? String
                                if ((d.value(forKey: "activated") as? NSNumber)?.boolValue ?? false) && (dName.map { (albumName as NSString?)?.isEqual(to: $0) ?? false } ?? false) {
                                    distantStudies = QueryController.queryStudies(forFilters: d as? [AnyHashable: Any], servers: servers as? [Any], showErrors: false) as NSArray?
                                }
                            }

                            if (distantStudies?.count ?? 0) != 0 {
                                let mutableStudiesArray = NSMutableArray(array: (studiesArray as? [Any]) ?? [])

                                // Merge local and distant studies
                                for distantStudy in distantStudies! {
                                    let distantStudy = distantStudy as AnyObject
                                    let distantUID = webPortalUserSend(distantStudy, NSSelectorFromString("studyInstanceUID"))
                                    if !((mutableStudiesArray.value(forKey: "studyInstanceUID") as? NSArray)?.contains(distantUID as Any) ?? false) {
                                        mutableStudiesArray.add(distantStudy)
                                    } else if UserDefaults.standard.bool(forKey: "preferStudyWithMoreImages") {
                                        let index = (mutableStudiesArray.value(forKey: "studyInstanceUID") as? NSArray)?.index(of: distantUID as Any) ?? NSNotFound

                                        if index != NSNotFound && ((webPortalUserSend(mutableStudiesArray.object(at: index), NSSelectorFromString("rawNoFiles")) as? NSNumber)?.int32Value ?? 0) < ((webPortalUserSend(distantStudy, NSSelectorFromString("noFiles")) as? NSNumber)?.int32Value ?? 0) {
                                            mutableStudiesArray.replaceObject(at: index, with: distantStudy)
                                        }
                                    }
                                }

                                studiesArray = mutableStudiesArray
                            }
                        }
                    }
                }
            } else {
                let originalAlbum = (album?.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?

                if ((user?.studyPredicate as NSString?)?.length ?? 0) != 0 {
                    do {
                        try HorosObjCException.perform {
                            studiesArray = webPortalUserFiltered(originalAlbum, DicomDatabase.predicate(forSmartAlbumFilter: user.studyPredicate))

                            let specificArray = user.addingSpecificStudies(to: nil)

                            for specificStudy in specificArray ?? NSArray() {
                                if (originalAlbum?.contains(specificStudy) ?? false) && !(studiesArray?.contains(specificStudy) ?? false) {
                                    studiesArray = studiesArray?.adding(specificStudy) as NSArray?
                                }
                            }
                        }
                    } catch {
                        NSLog("****** User Filter Error : %@", webPortalUserCaught(error))
                        NSLog("****** NO studies will be displayed.")

                        studiesArray = nil
                    }
                } else {
                    studiesArray = originalAlbum
                }
            }

            studiesArray = sortedAlbumStudies(studiesArray, sortValue)

            webPortalUserSynchronized(studiesForUserCache) {
                if user != nil, let studiesArray = studiesArray {
                    webPortalUserCacheSet(studiesForUserCache, NSDictionary(objects: [WebPortalUser.cachedArray(for: studiesArray) as Any, Date()], forKeys: ["array" as NSString, "date" as NSString]), userID as String?)
                }
            }
        }

        }

        if let numberOfStudies = numberOfStudies {
            numberOfStudies.pointee = Int32(truncatingIfNeeded: studiesArray?.count ?? 0)
        }

        if fetchLimit != 0 {
            studiesArray = webPortalUserPage(studiesArray, fetchLimit, fetchOffset)
        }

        return studiesArray as? [Any]
    }

    /// Not in the header; read by the portal's pages (User.recentPatients).
    @objc(recentPatients)
    public func recentPatients() -> NSArray {
        let recentPatients = NSMutableArray()

        let oldestDate = Date().addingTimeInterval(-UserDefaults.standard.double(forKey: "WebPortalMaximumNumberOfDaysForRecentStudies") * 86400.0)

        let recentStudies = ((self.value(forKey: "recentStudies") as? NSSet)?.filtered(using: NSPredicate(format: "dateAdded > CAST(%lf, \"NSDate\")", oldestDate.timeIntervalSinceReferenceDate)) as NSSet?) ?? NSSet()

        for patientUID in NSSet(array: ((recentStudies.allObjects as NSArray).value(forKey: "patientUID") as? [Any]) ?? []).allObjects {
            let ddb = WebPortal.default()?.threadDicomDatabase()

            let studies = ddb?.objects(forEntity: "Study", predicate: NSPredicate(format: "patientUID == %@", argumentArray: [patientUID])) as NSArray?

            if (studies?.count ?? 0) != 0 {
                //take the most recent study
                recentPatients.add((studies!.sortedArray(using: [NSSortDescriptor(key: "date", ascending: true)]) as NSArray).lastObject as Any)
            }
        }

        recentPatients.sort(using: [NSSortDescriptor(key: "name", ascending: true)])

        return recentPatients
    }
}

/// The accessors Core Data generates for the relationships, as the former
/// CoreDataGeneratedAccessors category declared them.
extension WebPortalUser {
    @objc(addStudiesObject:)
    @NSManaged public func addStudiesObject(_ value: WebPortalStudy!)

    @objc(removeStudiesObject:)
    @NSManaged public func removeStudiesObject(_ value: WebPortalStudy!)

    @objc(addStudies:)
    @NSManaged public func addStudies(_ value: Set<AnyHashable>!)

    @objc(removeStudies:)
    @NSManaged public func removeStudies(_ value: Set<AnyHashable>!)

    @objc(addRecentStudies:)
    @NSManaged public func addRecentStudies(_ value: Set<AnyHashable>!)

    @objc(removeRecentStudies:)
    @NSManaged public func removeRecentStudies(_ value: Set<AnyHashable>!)
}
