//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation
import IsiXContracts

/// The attribute values and the files of the local records a query matches,
/// for the modules that declare `LocalMetadataQuerying`.
///
/// Each query reads on a private-queue context of the database made for it
/// alone (`performIndependentRead`), so a long C-FIND neither waits for nor
/// holds up the other reads. The records are fetched in batches; what the
/// query names is read from them there, and only values leave the read.
extension LocalDatabaseStudyReader: LocalMetadataQuerying {

    /// How many records a fetch reads at a time.
    static let metadataFetchBatch = 100

    func records(matching query: LocalMetadataQuery,
                 progress: @Sendable (LocalMetadataProgress) -> Bool) throws -> LocalMetadataResult {
        try metadataRead { context in try Self.read(query, in: context, progress: progress) }
    }

    func representativeFile(of record: LocalRecordIdentifier) throws -> String? {
        try metadataRead { context -> String? in
            guard let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: record.uri),
                  let object = try? context.existingObject(with: id) else { return nil }
            // The image itself, one of the series' images, or one of an image of one of the study's series.
            var image: NSObject? = object
            switch object.entity.name {
            case "Study": image = Self.anyMember(of: object, "series").flatMap { Self.anyMember(of: $0, "images") }
            case "Series": image = Self.anyMember(of: object, "images")
            default: break
            }
            return image.flatMap { Self.value(of: $0, at: "completePathResolved") } as? String
        }
    }

    // MARK: - The read

    /// `body` on a private-queue context of the database made for it alone; its
    /// failures as `LocalMetadataQueryError`.
    private func metadataRead<T>(_ body: @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        guard let database = database() else { throw LocalMetadataQueryError.noDatabase }
        do {
            return try database.performIndependentRead(body)
        } catch let error as LocalMetadataQueryError {
            throw error
        } catch let error as NSError where error.domain == HorosPrivateQueueReadErrorDomain {
            throw LocalMetadataQueryError.noDatabase
        } catch {
            // An Objective-C exception, which the read turned into an error.
            throw LocalMetadataQueryError.raised(error.localizedDescription)
        }
    }

    /// The records of `query`, inside the context's queue.
    private static func read(_ query: LocalMetadataQuery, in context: NSManagedObjectContext,
                             progress: @Sendable (LocalMetadataProgress) -> Bool) throws -> LocalMetadataResult {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel,
              let entity = model.entitiesByName[entityName(of: query.level)] else {
            throw LocalMetadataQueryError.readFailed("The database has no \(entityName(of: query.level)) records.")
        }
        var failure: Error?
        var stopped = false

        // The records of `request`, `metadataFetchBatch` at a time, until a
        // batch comes back empty or the caller stops the read. A failed count
        // or fetch is kept and ends the read.
        func batches(_ request: NSFetchRequest<NSManagedObject>, stage: LocalMetadataProgress.Stage) -> [NSManagedObject] {
            var total = 0
            do { total = try context.count(for: request) } catch { failure = error }
            var found: [NSManagedObject] = []
            request.fetchLimit = metadataFetchBatch
            var batch: [NSManagedObject]
            repeat {
                do { batch = try context.fetch(request) } catch { failure = error; batch = [] }
                found += batch
                request.fetchOffset += metadataFetchBatch
                guard progress(LocalMetadataProgress(stage: stage, read: found.count, total: total)) else {
                    stopped = true
                    break
                }
            } while !batch.isEmpty
            return found
        }

        var objects: [NSManagedObject]
        if let seriesPredicate = query.seriesPredicate, let seriesEntity = model.entitiesByName["Series"] {
            // The series first, then their images.
            let request = NSFetchRequest<NSManagedObject>()
            request.entity = seriesEntity
            request.predicate = seriesPredicate
            var images: [NSManagedObject] = []
            for series in batches(request, stage: .series) {
                images += members(of: series, "images").compactMap { $0 as? NSManagedObject }
            }
            let condition = query.predicate ?? NSPredicate(value: true)
            objects = images.filter { condition.evaluate(with: $0) }
        } else {
            let request = NSFetchRequest<NSManagedObject>()
            request.entity = entity
            request.predicate = query.predicate
            objects = batches(request, stage: .records)
        }
        if let failure {
            throw LocalMetadataQueryError.readFailed((failure as NSError).localizedDescription)
        }

        if let filter = query.filter { objects = objects.filter { filter.evaluate(with: $0) } }
        if let key = query.sortKeyPath { objects = sorted(objects, on: key) }
        let matchCount = objects.count
        if let limit = query.limit, objects.count > limit { objects = Array(objects.prefix(limit)) }
        if let key = query.distinctKeyPath { objects = distinct(objects, on: key) }

        let records = objects.map { object -> LocalMetadataRecord in
            var values: [String: LocalMetadataValue] = [:]
            for keyPath in query.keyPaths {
                if let found = value(of: object, at: keyPath) { values[keyPath] = metadataValue(found) }
            }
            // After the key paths, which have fired the object's fault.
            var primitive: [String: LocalMetadataValue] = [:]
            for key in query.primitiveKeys {
                if let found = object.primitiveValue(forKey: key) { primitive[key] = metadataValue(found) }
            }
            let files = query.includesFiles ? members(of: object, "pathsForForkedProcess").compactMap { $0 as? String } : []
            return LocalMetadataRecord(identifier: LocalRecordIdentifier(uri: object.objectID.uriRepresentation()),
                                       level: query.level, values: values, primitiveValues: primitive, files: files)
        }
        return LocalMetadataResult(records: records, matchCount: matchCount, stopped: stopped)
    }

    private static func entityName(of level: LocalMetadataLevel) -> String {
        switch level {
        case .study: return "Study"
        case .series: return "Series"
        case .image: return "Image"
        }
    }

    /// `objects` in the ascending order of their values at `key`, as
    /// NSSortDescriptor sorts them with `compare:`: those without a value
    /// first, those with equal values in the order they came.
    private static func sorted(_ objects: [NSManagedObject], on key: String) -> [NSManagedObject] {
        let keyed = objects.enumerated().map { (offset: $0.offset, object: $0.element, value: value(of: $0.element, at: key)) }
        return keyed.sorted { a, b in
            let order = compare(a.value, b.value)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.object)
    }

    private static func compare(_ a: Any?, _ b: Any?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x as NSNumber, y as NSNumber): return x.compare(y)
        case let (x as Date, y as Date): return x.compare(y)
        case let (x as String, y as String): return (x as NSString).compare(y)
        default: return .orderedSame
        }
    }

    /// `objects` without those whose string at `key` an earlier one has
    /// (compared as NSString does, character by character); an object without
    /// a string there is always kept.
    private static func distinct(_ objects: [NSManagedObject], on key: String) -> [NSManagedObject] {
        var seen = Set<NSString>()
        return objects.filter { object in
            guard let string = value(of: object, at: key) as? String else { return true }
            return seen.insert(string as NSString).inserted
        }
    }

    // MARK: - Reading the model

    /// The value of an object of the database at `keyPath`, through its
    /// accessors and relationships as the model defines them: the one place
    /// this adapter reads the model by name.
    private static func value(of object: NSObject, at keyPath: String) -> Any? {
        object.value(forKeyPath: keyPath)
    }

    /// The members of the to-many relationship or set at `key`.
    private static func members(of object: NSObject, _ key: String) -> [Any] {
        switch value(of: object, at: key) {
        case let set as NSSet: return set.allObjects
        case let set as NSOrderedSet: return set.array
        default: return []
        }
    }

    /// Any one member of the to-many relationship at `key`.
    private static func anyMember(of object: NSObject, _ key: String) -> NSObject? {
        (value(of: object, at: key) as? NSSet)?.anyObject() as? NSObject
    }

    /// A value read from the model as a value of the contract.
    private static func metadataValue(_ value: Any) -> LocalMetadataValue {
        switch value {
        case let number as NSNumber: return .number(number)
        case let text as String: return .text(text)
        case let date as Date: return .date(date)
        case is NSNull: return .null
        case let set as NSSet: return .collection(set.allObjects.map(metadataValue))
        case let set as NSOrderedSet: return .collection(set.array.map(metadataValue))
        case let array as [Any]: return .collection(array.map(metadataValue))
        default: return .record
        }
    }
}
