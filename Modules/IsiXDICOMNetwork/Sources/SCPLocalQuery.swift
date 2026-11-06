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
import IsiXContracts

public extension SCPQueryLevel {
    /// The level of the local records a request at this level reads.
    var metadataLevel: LocalMetadataLevel {
        switch self {
        case .study: return .study
        case .series: return .series
        case .image: return .image
        }
    }
}

/// What the listener reads of the local database for a C-FIND, a C-MOVE or a
/// C-GET, through `LocalMetadataQuerying`: the query each request makes of its
/// conditions (`SCPQueryMatching`), and what the listener keeps of the records.
public enum SCPLocalQuery {

    /// The query of a C-FIND at `level` with `predicates`, whose responses
    /// answer `keys` (`SCPResponseIdentifier`).
    ///
    /// Images come in Instance Number order and one per file: a multi-frame
    /// file is several images of the database, and only the first answers.
    /// Series come in date order. Studies and series stop at `maximumCount`,
    /// when it is above 0, after sorting; images never do.
    public static func find(level: SCPQueryLevel, predicates: SCPFetchPredicates, keys: [DICOMTag],
                            maximumCount: Int) -> LocalMetadataQuery {
        let read = SCPResponseIdentifier.keyPaths(level: level, keys: keys)
        var query = base(level: level, predicates: predicates)
        query.keyPaths = read.keyPaths
        query.primitiveKeys = read.primitiveKeys
        switch level {
        case .image:
            query.sortKeyPath = "instanceNumber"
            query.distinctKeyPath = "completePath"
        case .series:
            query.sortKeyPath = "date"
        case .study:
            break
        }
        if level != .image, maximumCount > 0 { query.limit = maximumCount }
        return query
    }

    /// The query of a C-MOVE or C-GET at `level` with `predicates`: the
    /// matching records with their files, and when the network log is on
    /// (`logged`), the values its entry names.
    public static func retrieve(level: SCPQueryLevel, predicates: SCPFetchPredicates, logged: Bool) -> LocalMetadataQuery {
        var query = base(level: level, predicates: predicates)
        query.includesFiles = true
        if logged {
            let names = logKeyPaths(level: level)
            query.keyPaths = Set([names.patientName, names.studyDescription] + (names.fileCount.map { [$0] } ?? []))
        }
        return query
    }

    /// The key paths of the first record that the network log entry of a
    /// retrieve names: its patient, its study and how many files it has. An
    /// image has no file count: the entry counts the images.
    public static func logKeyPaths(level: SCPQueryLevel) -> (patientName: String, studyDescription: String, fileCount: String?) {
        switch level {
        case .study: return ("name", "studyName", "rawNoFiles")
        case .series: return ("study.name", "study.studyName", "rawNoFiles")
        case .image: return ("series.study.name", "series.study.studyName", nil)
        }
    }

    /// The files a retrieve sends of `records`: each once, in path order
    /// (-[NSString compare:]).
    public static func files(of records: [LocalMetadataRecord]) -> [String] {
        // The paths are compared as NSString compares them: character by
        // character, without canonical equivalence.
        var seen = Set<NSString>()
        var files: [String] = []
        for record in records {
            for file in record.files where seen.insert(file as NSString).inserted {
                files.append(file)
            }
        }
        return files.enumerated().sorted { a, b in
            let order = (a.element as NSString).compare(b.element)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }

    /// What a C-FIND, C-MOVE and C-GET read alike: the conditions on the level,
    /// on the series of an IMAGE request, and its SOP Instance UIDs, applied
    /// after the read.
    private static func base(level: SCPQueryLevel, predicates: SCPFetchPredicates) -> LocalMetadataQuery {
        LocalMetadataQuery(level: level.metadataLevel, predicate: predicates.predicate, seriesPredicate: predicates.seriesLevel,
                           filter: level == .image ? predicates.compressedSOPInstance : nil)
    }
}

public extension LocalMetadataValue {
    /// The value as the database's objects gave it: a string, a number, a
    /// date, NSNull, an array for a to-many key path, and this value itself
    /// for an object of the database.
    var object: Any {
        switch self {
        case .text(let text): return text
        case .number(let number): return number
        case .date(let date): return date
        case .null: return NSNull()
        case .record: return self
        case .collection(let values): return values.map(\.object)
        }
    }
}

public extension LocalMetadataRecord {
    /// The value at `keyPath` as the database's objects gave it; nil when it has none.
    func object(at keyPath: String) -> Any? {
        values[keyPath]?.object
    }

    /// The stored value of `key` as the database's objects gave it; nil when it has none.
    func primitiveObject(of key: String) -> Any? {
        primitiveValues[key]?.object
    }
}
