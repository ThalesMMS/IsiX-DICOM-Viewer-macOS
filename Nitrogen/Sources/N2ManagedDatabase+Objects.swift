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

import CoreData
import Foundation

// The objects of N2ManagedDatabase (the Objects category of N2ManagedDatabase.h):
// entities, object IDs, fetches, counts and saves, each on the queue of the
// database's context. A failure that raised is reported as an NSError, as the
// former @catch did. -newObjectForEntity: and -objectsForEntity:predicate:error:
// are N2ManagedDatabase+CAPI.m's.

@objc(Objects) @implementation extension N2ManagedDatabase {

    func entity(forName name: String!) -> NSEntityDescription! {
        guard let name, let context = self.managedObjectContext else {
            return nil
        }
        var entity: NSEntityDescription? = nil
        N2ManagedObjectContextPerformAndWait(context) {
            entity = NSEntityDescription.entity(forEntityName: name, in: context)
        }
        return entity
    }

    func object(withID oid: Any!) -> Any! {
        let context = self.managedObjectContext
        var result: Any? = nil
        // Resolve an input managed object's ID on its own context, before entering
        // the destination queue (the object may belong to another database).
        _ = N2ManagedDatabaseObjC.attempt {
            var identifier: Any? = oid
            if let object = oid as? NSManagedObject {
                var objectID: NSManagedObjectID? = nil
                N2ManagedObjectContextPerformAndWait(object.managedObjectContext) { objectID = object.objectID }
                identifier = objectID
            }
            N2ManagedObjectContextPerformAndWait(context) {
                result = N2ManagedDatabase.existingObject(identifier, in: context)
            }
        }
        // Invalid or missing IDs historically return nil.
        return result
    }

    func objects(withIDs objectIDs: [Any]!) -> [Any]! {
        // Resolve source object IDs before entering the destination queue, so that
        // no destination-queue block synchronously enters an unrelated context.
        var identifiers: [Any] = []
        identifiers.reserveCapacity(objectIDs?.count ?? 0)
        for oid in objectIDs ?? [] {
            _ = N2ManagedDatabaseObjC.attempt {
                var identifier: Any? = oid
                if let object = oid as? NSManagedObject {
                    var objectID: NSManagedObjectID? = nil
                    N2ManagedObjectContextPerformAndWait(object.managedObjectContext) { objectID = object.objectID }
                    identifier = objectID
                }
                if let identifier {
                    identifiers.append(identifier)
                }
            }
            // Continue resolving the remaining IDs.
        }
        let result = NSMutableArray(capacity: identifiers.count)
        N2ManagedObjectContextPerformAndWait(self.managedObjectContext) {
            for oid in identifiers {
                if let object = self.object(withID: oid) {
                    result.add(object)
                }
            }
        }
        return result as? [Any]
    }

    /// What -objectWithID: finds for an ID on the context's queue: the query
    /// node itself, or the object of a managed object ID, of its URI or of the
    /// URI's string.
    private static func existingObject(_ identifier: Any?, in context: NSManagedObjectContext?) -> Any? {
        #if !OSIRIX_LIGHT
        if let node = identifier as? DCMTKQueryNode {
            return node
        }
        #endif
        guard let context else {
            return nil
        }
        var objectID = identifier as? NSManagedObjectID
        if let url = identifier as? URL {
            objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
        } else if let string = identifier as? String {
            objectID = URL(string: string).flatMap { context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: $0) }
        }
        guard let objectID else {
            return nil
        }
        return try? context.existingObject(with: objectID)
    }

    // in these methods, e can be an NSEntityDescription* or an NSString*

    func objects(forEntity e: Any!) -> [Any]! {
        return self.objects(forEntity: e, predicate: nil, error: nil, fetchLimit: 0, sortDescriptors: nil)
    }

    func objects(forEntity e: Any!, predicate p: NSPredicate!) -> [Any]! {
        return self.objects(forEntity: e, predicate: p, error: nil, fetchLimit: 0, sortDescriptors: nil)
    }

    // -objectsForEntity:predicate:error: is N2ManagedDatabase+CAPI.m's.

    func objects(forEntity e: Any!, predicate p: NSPredicate!, error: NSErrorPointer, fetchLimit: UInt, sortDescriptors: [Any]!) -> [Any]! {
        let context = self.managedObjectContext
        var result: [Any]? = nil
        var queueError: NSError? = nil
        if let exception = N2ManagedDatabaseObjC.attempt({
            N2ManagedObjectContextPerformAndWait(context) {
                let request = self.fetchRequest(e, predicate: p)
                request.sortDescriptors = sortDescriptors as? [NSSortDescriptor]
                request.fetchLimit = Int(truncatingIfNeeded: fetchLimit)
                do {
                    result = try context?.__execute(request)
                } catch {
                    queueError = error as NSError
                }
            }
        }) {
            if error != nil && queueError == nil {
                queueError = NSError(domain: N2ErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? "Core Data fetch failed."])
            } else {
                N2ManagedDatabaseObjC.log(exception, stack: false, "-[N2ManagedDatabase objectsForEntity:predicate:error:fetchLimit:sortDescriptors:]")
            }
        }
        error?.pointee = queueError
        return result
    }

    func countObjects(forEntity e: Any!) -> UInt {
        return self.countObjects(forEntity: e, predicate: nil, error: nil)
    }

    func countObjects(forEntity e: Any!, predicate p: NSPredicate!) -> UInt {
        return self.countObjects(forEntity: e, predicate: p, error: nil)
    }

    func countObjects(forEntity e: Any!, predicate p: NSPredicate!, error: NSErrorPointer) -> UInt {
        let context = self.managedObjectContext
        var count = 0
        var queueError: NSError? = nil
        if let exception = N2ManagedDatabaseObjC.attempt({
            N2ManagedObjectContextPerformAndWait(context) {
                let request = self.fetchRequest(e, predicate: p)
                guard let context else { return }
                do {
                    count = try context.count(for: request)
                } catch {
                    // -countForFetchRequest:error: answered NSNotFound with its error.
                    count = NSNotFound
                    queueError = error as NSError
                }
            }
        }) {
            if error != nil && queueError == nil {
                queueError = NSError(domain: N2ErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? "Core Data count failed."])
            } else {
                N2ManagedDatabaseObjC.log(exception, stack: false, "-[N2ManagedDatabase countObjectsForEntity:predicate:error:]")
            }
        }
        error?.pointee = queueError
        return UInt(bitPattern: count)
    }

    /// The request of -objectsForEntity: and -countObjectsForEntity:, made on
    /// the context's queue: the entity, or the entity of that name, and the
    /// predicate, or one that is always true.
    private final func fetchRequest(_ e: Any?, predicate p: NSPredicate?) -> NSFetchRequest<any NSFetchRequestResult> {
        let request = NSFetchRequest<any NSFetchRequestResult>()
        if let name = e as? String {
            request.entity = self.entity(forName: name)
        } else {
            request.entity = e as? NSEntityDescription
        }
        request.predicate = p ?? NSPredicate(value: true)
        return request
    }

    func save() -> Bool {
        return self.save(nil)
    }

    func save(_ error: NSErrorPointer) -> Bool {
        var saved = false
        var queueError: NSError? = nil
        let context = self.managedObjectContext
        // dealloc also calls save:; do not capture/retain the deallocating database.
        if let exception = N2ManagedDatabaseObjC.attempt({
            N2ManagedObjectContextPerformAndWait(context) {
                guard let context else { return }
                do {
                    try context.save()
                    saved = true
                } catch {
                    queueError = error as NSError
                }
            }
        }) {
            if queueError == nil {
                queueError = NSError(domain: N2ErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? "Core Data save failed."])
            } else {
                N2ManagedDatabaseObjC.log(exception, stack: false, "-[N2ManagedDatabase save:]")
            }
        }
        error?.pointee = queueError
        return saved
    }
}
