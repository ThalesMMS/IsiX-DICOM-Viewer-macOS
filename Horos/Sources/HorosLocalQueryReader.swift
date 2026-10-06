//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation

/// The domain of the errors a private-queue read reports before it reads.
let HorosPrivateQueueReadErrorDomain = "HorosPrivateQueueRead"

/// The read context each database keeps, under this key, and the lock that
/// guards creating it.
nonisolated(unsafe) private var privateReadContextKey: UInt8 = 0
private let privateReadContextLock = NSLock()

/// A database's read context and the coordinator it was made for: a database
/// that is rebuilt gets a new coordinator, and then a new read context.
private final class PrivateReadContext: NSObject {
    let context: N2ManagedObjectContext
    let coordinator: NSPersistentStoreCoordinator

    init(context: N2ManagedObjectContext, coordinator: NSPersistentStoreCoordinator) {
        self.context = context
        self.coordinator = coordinator
    }
}

public extension N2ManagedDatabase {

    /// Runs `body` on this database's private-queue read context and waits for
    /// it, returning what it returns.
    ///
    /// Nothing in here goes to the main thread, so any thread may call it, the
    /// main one included, without waiting on the UI. Reads are serialized on the
    /// context's queue. Only values and permanent object IDs may leave `body`:
    /// the context is reset when `body` returns, so each read starts from what
    /// is committed then and nothing stays registered between reads. A Core Data
    /// exception becomes the thrown error, as does a database with no store.
    func performPrivateRead<T>(_ body: @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        guard let context = self.privateReadContext() else {
            throw NSError(domain: HorosPrivateQueueReadErrorDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The database has no store to read from."])
        }
        return try context.performAndWait {
            defer { context.reset() }
            var value: T?
            var thrown: Error?
            try HorosObjCException.perform {
                do { value = try body(context) } catch { thrown = error }
            }
            if let thrown { throw thrown }
            return value!
        }
    }

    /// `performPrivateRead` for Objective-C: `body` runs on the read context's
    /// queue with that context; only values and object IDs may leave it.
    @objc(performPrivateRead:error:)
    func performPrivateReadObjC(_ body: @Sendable (NSManagedObjectContext) -> Void) throws {
        try performPrivateRead { context in body(context) }
    }

    /// The private-queue context this database reads on, made the first time
    /// and again when its coordinator changes; it goes away with the database.
    private func privateReadContext() -> N2ManagedObjectContext? {
        guard let coordinator = self.managedObjectContext?.persistentStoreCoordinator else { return nil }
        privateReadContextLock.lock()
        defer { privateReadContextLock.unlock() }
        if let cached = objc_getAssociatedObject(self, &privateReadContextKey) as? PrivateReadContext,
           cached.coordinator === coordinator {
            return cached.context
        }
        guard let context = self.privateQueueContext() else { return nil }
        objc_setAssociatedObject(self, &privateReadContextKey, PrivateReadContext(context: context, coordinator: coordinator),
                                 .OBJC_ASSOCIATION_RETAIN)
        return context
    }
}

/// Which studies of the local database are here, as their Study Instance UIDs
/// and object IDs, in the same order. A study without a UID has `NSNull`, as
/// `-[NSArray valueForKey:]` gave the query window before.
@objc(HorosLocalStudyIndex)
public final class HorosLocalStudyIndex: NSObject {
    @objc public let studyInstanceUIDs: [Any]
    @objc public let objectIDs: [NSManagedObjectID]

    init(studyInstanceUIDs: [Any], objectIDs: [NSManagedObjectID]) {
        self.studyInstanceUIDs = studyInstanceUIDs
        self.objectIDs = objectIDs
    }
}

/// What the query window and the retrieve paths need to know about the local
/// database, read on a private queue. The answers are values and object
/// IDs; a caller that needs an object resolves the ID in its own context.
@objc(HorosLocalQueryReader)
public final class HorosLocalQueryReader: NSObject {

    /// Every committed study: its UID and its object ID, without faulting the
    /// studies themselves.
    @objc(studyIndexOfDatabase:error:)
    public static func studyIndex(of database: N2ManagedDatabase) throws -> HorosLocalStudyIndex {
        return try database.performPrivateRead { context -> HorosLocalStudyIndex in
            let objectID = NSExpressionDescription()
            objectID.name = "objectID"
            objectID.expression = NSExpression.expressionForEvaluatedObject()
            objectID.expressionResultType = .objectIDAttributeType

            let request = NSFetchRequest<NSDictionary>(entityName: "Study")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["studyInstanceUID", objectID]

            var uids: [Any] = []
            var ids: [NSManagedObjectID] = []
            for row in try context.fetch(request) {
                guard let id = row["objectID"] as? NSManagedObjectID else { continue }
                ids.append(id)
                uids.append(row["studyInstanceUID"] ?? NSNull())
            }
            return HorosLocalStudyIndex(studyInstanceUIDs: uids, objectIDs: ids)
        }
    }

    /// The files of a local study, or of its series `seriesInstanceUID` when
    /// one is given: the study's or the series' `rawNoFiles`, 0 when the study
    /// or the series is no longer there.
    @objc(fileCountOfStudy:seriesInstanceUID:inDatabase:error:)
    public static func fileCount(ofStudy studyID: NSManagedObjectID, seriesInstanceUID: String?,
                                 in database: N2ManagedDatabase) throws -> NSNumber {
        return try database.performPrivateRead { context -> NSNumber in
            guard let study = try? context.existingObject(with: studyID) as? DicomStudy else { return 0 }
            guard let seriesInstanceUID else { return study.rawNoFiles() ?? 0 }
            for case let series as DicomSeries in study.series ?? []
            where (series.value(forKey: "seriesDICOMUID") as? String) == seriesInstanceUID {
                return series.rawNoFiles() ?? 0
            }
            return 0
        }
    }

    /// The SOP Instance UIDs already here for the studies with this UID, only
    /// those of the series `seriesInstanceUID` when one is given.
    @objc(SOPInstanceUIDsOfStudyInstanceUID:seriesInstanceUID:inDatabase:error:)
    public static func sopInstanceUIDs(ofStudyInstanceUID studyInstanceUID: String, seriesInstanceUID: String?,
                                       in database: N2ManagedDatabase) throws -> [String] {
        return try database.performPrivateRead { context -> [String] in
            let request = NSFetchRequest<DicomStudy>(entityName: "Study")
            request.predicate = NSPredicate(format: "studyInstanceUID == %@", studyInstanceUID)
            var uids: [String] = []
            for study in try context.fetch(request) {
                for case let series as NSObject in (study.value(forKey: "series") as? NSSet) ?? [] {
                    if let seriesInstanceUID, !seriesInstanceUID.isEmpty,
                       (series.value(forKey: "seriesDICOMUID") as? String) != seriesInstanceUID { continue }
                    let images = (series.value(forKey: "images") as? NSSet)?.value(forKey: "sopInstanceUID") as? NSSet
                    for case let uid as String in images ?? [] where !uid.isEmpty { uids.append(uid) }
                }
            }
            return uids
        }
    }
}
