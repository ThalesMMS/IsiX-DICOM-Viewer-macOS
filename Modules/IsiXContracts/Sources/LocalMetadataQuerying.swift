//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The level of the records a metadata query reads. The local database keeps
/// the patient's attributes on its studies, so a query at the patient level
/// reads studies.
public enum LocalMetadataLevel: String, Hashable, Sendable, CaseIterable {
    case study, series, image
}

/// One attribute value of a record of the local database, as it was read.
public indirect enum LocalMetadataValue: Hashable, Sendable {
    case text(String)
    case number(NSNumber)
    case date(Date)
    /// An object of the database, such as a related series, of which no
    /// value is read.
    case record
    /// The placeholder a to-many key path gives for a member without a value.
    case null
    /// The values of a to-many key path, in the order the database gave them.
    case collection([LocalMetadataValue])
}

/// One record a metadata query matched, read once: the values a module may
/// know of it without reaching the database.
public struct LocalMetadataRecord: Hashable, Sendable {
    /// The record, for the app to find it again.
    public let identifier: LocalRecordIdentifier
    /// Its level, that of the query.
    public let level: LocalMetadataLevel
    /// The values of the query's key paths; a key path without a value has no entry.
    public let values: [String: LocalMetadataValue]
    /// The stored values of the query's primitive keys, read without their
    /// accessors; a key without a value has no entry.
    public let primitiveValues: [String: LocalMetadataValue]
    /// Its files here, when the query asks for them: those of its images that
    /// are on this Mac, each once.
    public let files: [String]

    public init(identifier: LocalRecordIdentifier, level: LocalMetadataLevel, values: [String: LocalMetadataValue],
                primitiveValues: [String: LocalMetadataValue] = [:], files: [String] = []) {
        self.identifier = identifier
        self.level = level
        self.values = values
        self.primitiveValues = primitiveValues
        self.files = files
    }
}

/// What a metadata query asks of the local database.
///
/// The conditions are Foundation predicates over the database's attribute
/// names. NSPredicate is not marked `Sendable`, but a predicate is immutable
/// once made, and a query never changes the ones it holds: it is a value that
/// may be handed to the queue that reads the database.
public struct LocalMetadataQuery: @unchecked Sendable {
    /// The level of the records it reads.
    public var level: LocalMetadataLevel
    /// The condition on the records of the level; nil: all of them.
    public var predicate: NSPredicate?
    /// For an image query: the condition on the series whose images it reads,
    /// first, in the database; `predicate` then applies to those images. nil:
    /// `predicate` is read in the database.
    public var seriesPredicate: NSPredicate?
    /// A condition applied to each record after it is read, in memory, for
    /// conditions the database cannot evaluate; nil: none.
    public var filter: NSPredicate?
    /// The records are sorted on the value of this key path, ascending, the
    /// records without a value first, those with equal values in the order
    /// they were read; nil: in the order they were read.
    public var sortKeyPath: String?
    /// At most this many records, after sorting; nil: all of them.
    public var limit: Int?
    /// Of the records whose text value at this key path is the same, only the
    /// first is kept; records without a text value are always kept. nil: all.
    public var distinctKeyPath: String?
    /// The key paths whose values each record carries.
    public var keyPaths: Set<String>
    /// The keys whose stored values each record carries.
    public var primitiveKeys: Set<String>
    /// Whether each record carries its files.
    public var includesFiles: Bool

    public init(level: LocalMetadataLevel, predicate: NSPredicate? = nil, seriesPredicate: NSPredicate? = nil,
                filter: NSPredicate? = nil, sortKeyPath: String? = nil, limit: Int? = nil, distinctKeyPath: String? = nil,
                keyPaths: Set<String> = [], primitiveKeys: Set<String> = [], includesFiles: Bool = false) {
        self.level = level
        self.predicate = predicate
        self.seriesPredicate = seriesPredicate
        self.filter = filter
        self.sortKeyPath = sortKeyPath
        self.limit = limit
        self.distinctKeyPath = distinctKeyPath
        self.keyPaths = keyPaths
        self.primitiveKeys = primitiveKeys
        self.includesFiles = includesFiles
    }
}

/// How far a metadata query has read, while it reads.
public struct LocalMetadataProgress: Hashable, Sendable {
    /// What is being read: the series of an image query that names them, or
    /// the records of its level.
    public enum Stage: Hashable, Sendable { case series, records }

    public let stage: Stage
    /// How many have been read so far, and how many there are.
    public let read: Int
    public let total: Int

    public init(stage: Stage, read: Int, total: Int) {
        self.stage = stage
        self.read = read
        self.total = total
    }
}

/// The records a metadata query matched.
public struct LocalMetadataResult: Hashable, Sendable {
    /// The records, sorted, limited and made distinct as the query asks.
    public let records: [LocalMetadataRecord]
    /// How many records matched before the limit.
    public let matchCount: Int
    /// Whether the reading stopped early because the caller asked it to: the
    /// records are then those read until then.
    public let stopped: Bool

    public init(records: [LocalMetadataRecord], matchCount: Int, stopped: Bool = false) {
        self.records = records
        self.matchCount = matchCount
        self.stopped = stopped
    }
}

/// Why a metadata query read nothing.
public enum LocalMetadataQueryError: Error, Hashable, Sendable {
    /// There is no database to read, or it has no store.
    case noDatabase
    /// The database could not be read; the description of its error.
    case readFailed(String)
    /// Reading raised an exception, such as a condition on an attribute the
    /// database does not have; its description.
    case raised(String)
}

/// The attribute values and the files of the local records a query matches.
///
/// A port over the local database: the listener's C-FIND, C-MOVE and C-GET
/// declare through it what they read, and the app implements it with a read on
/// a private-queue context of the database, in batches. The call waits for the
/// read, on the caller's thread: only values leave it, and nothing is kept
/// between calls.
public protocol LocalMetadataQuerying: Sendable {
    /// The records `query` matches. `progress` is called as the read advances,
    /// on the caller's thread; returning false stops it, and the records read
    /// until then are returned.
    /// Throws `LocalMetadataQueryError` when the database cannot be read.
    func records(matching query: LocalMetadataQuery,
                 progress: @Sendable (LocalMetadataProgress) -> Bool) throws -> LocalMetadataResult

    /// A file of one of the images of `record`, which holds its character
    /// sets; nil when the record is no longer there or has no image.
    func representativeFile(of record: LocalRecordIdentifier) throws -> String?
}
