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

/// What the query window shows of one local study or series: how many of its
/// files are here, and the values of its own State and Comment columns.
@objc(HorosLocalRowState)
public final class HorosLocalRowState: NSObject {
    @objc public let fileCount: Int
    @objc public let stateText: Any?
    @objc public let comment: String?

    init(fileCount: Int, stateText: Any?, comment: String?) {
        self.fileCount = fileCount
        self.stateText = stateText
        self.comment = comment
    }

    /// Two local studies or series with the same UID count together; the
    /// first one read keeps its columns.
    func adding(_ fileCount: Int) -> HorosLocalRowState {
        HorosLocalRowState(fileCount: self.fileCount + fileCount, stateText: stateText, comment: comment)
    }
}

/// The local side of a list of query results, read once off the main thread.
///
/// Painting the query window used to look each row up in the database on the
/// main thread, several times per row and per repaint, and to count its files
/// by loading every image of the study. A repaint now only looks the row up in
/// here; the window reads a new one after a query and after the database changes.
@objc(HorosLocalQuerySnapshot)
public final class HorosLocalQuerySnapshot: NSObject {
    let studies: [String: HorosLocalRowState]
    let series: [String: HorosLocalRowState]

    init(studies: [String: HorosLocalRowState], series: [String: HorosLocalRowState]) {
        self.studies = studies
        self.series = series
    }

    static func key(_ study: String, _ series: String) -> String { study + "\u{1}" + series }

    /// The local study with this Study Instance UID, nil when it is not here.
    @objc(stateOfStudy:)
    public func state(ofStudy studyInstanceUID: String?) -> HorosLocalRowState? {
        guard let studyInstanceUID else { return nil }
        return studies[studyInstanceUID]
    }

    /// The local series with this Series Instance UID in that study.
    @objc(stateOfStudy:series:)
    public func state(ofStudy studyInstanceUID: String?, series seriesInstanceUID: String?) -> HorosLocalRowState? {
        guard let studyInstanceUID, let seriesInstanceUID else { return nil }
        return series[HorosLocalQuerySnapshot.key(studyInstanceUID, seriesInstanceUID)]
    }

    /// How many of these studies have at least one file here.
    @objc(countOfStudiesHereAmong:)
    public func countOfStudiesHere(among studyInstanceUIDs: [String]) -> Int {
        studyInstanceUIDs.reduce(0) { $0 + ((studies[$1]?.fileCount ?? 0) > 0 ? 1 : 0) }
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

    /// The local studies among these Study Instance UIDs, with their series:
    /// files as `rawNoFiles` counts them, State and Comment. Only those studies
    /// are read, by UID, in batches.
    @objc(snapshotOfStudyInstanceUIDs:inDatabase:error:)
    public static func snapshot(ofStudyInstanceUIDs studyInstanceUIDs: [String],
                                in database: N2ManagedDatabase) throws -> HorosLocalQuerySnapshot {
        let wanted = Array(Set(studyInstanceUIDs.filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return HorosLocalQuerySnapshot(studies: [:], series: [:]) }
        return try database.performPrivateRead { context -> HorosLocalQuerySnapshot in
            var studies: [String: HorosLocalRowState] = [:]
            var series: [String: HorosLocalRowState] = [:]
            for start in stride(from: 0, to: wanted.count, by: 500) {
                let request = NSFetchRequest<DicomStudy>(entityName: "Study")
                request.predicate = NSPredicate(format: "studyInstanceUID IN %@", Array(wanted[start..<min(start + 500, wanted.count)]))
                request.relationshipKeyPathsForPrefetching = ["series"]
                for study in try context.fetch(request) {
                    guard let uid = study.value(forKey: "studyInstanceUID") as? String else { continue }
                    var files = 0
                    for case let one as DicomSeries in study.series ?? [] {
                        let count = one.rawNoFiles()?.intValue ?? 0
                        files += count
                        guard let seriesUID = one.value(forKey: "seriesDICOMUID") as? String else { continue }
                        let key = HorosLocalQuerySnapshot.key(uid, seriesUID)
                        series[key] = series[key]?.adding(count) ?? HorosLocalRowState(fileCount: count,
                            stateText: one.value(forKey: "stateText"), comment: one.value(forKey: "comment") as? String)
                    }
                    studies[uid] = studies[uid]?.adding(files) ?? HorosLocalRowState(fileCount: files,
                        stateText: study.value(forKey: "stateText"), comment: study.value(forKey: "comment") as? String)
                }
            }
            return HorosLocalQuerySnapshot(studies: studies, series: series)
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
