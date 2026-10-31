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

/// A record of the local database, as a module may hold it: opaque.
///
/// The app makes it from the URI of the record's Core Data object ID, which
/// stays valid across contexts and threads; a module only compares and keeps
/// it, and hands it back to the app, which resolves it in its own context.
public struct LocalRecordIdentifier: Hashable, Sendable, Codable {
    /// The URI the app made the identifier from.
    public let uri: URL

    public init(uri: URL) {
        self.uri = uri
    }
}

/// One study of the local database, read once: what a module may know of it
/// without reaching the database.
public struct LocalStudySnapshot: Hashable, Sendable {
    /// The study's record, for the app to find it again.
    public let identifier: LocalRecordIdentifier
    /// Its Study Instance UID.
    public let studyInstanceUID: String
    /// How many of its files are here, summed over its series.
    public let fileCount: Int
    /// Its State, the reading status the database column shows; nil when unset.
    public let state: Int?
    /// Its Comment; nil when unset.
    public let comment: String?

    public init(identifier: LocalRecordIdentifier, studyInstanceUID: String, fileCount: Int, state: Int?, comment: String?) {
        self.identifier = identifier
        self.studyInstanceUID = studyInstanceUID
        self.fileCount = fileCount
        self.state = state
        self.comment = comment
    }
}

/// Which studies are here, by Study Instance UID.
///
/// A port over the local database: the module that needs to know what is here
/// declares what it reads through it, and the app implements it with a read on
/// the database's private-queue context. Each call reads what is committed at
/// that moment; nothing is kept between calls.
public protocol LocalStudyReading: Sendable {
    /// The local studies whose Study Instance UID is one of `studyInstanceUIDs`.
    /// A UID that is not here has no snapshot; two local studies with the same
    /// UID have one each. Throws when the database cannot be read.
    func studies(withInstanceUIDs studyInstanceUIDs: Set<String>) async throws -> [LocalStudySnapshot]
}

public extension LocalStudyReading {
    /// How many files of each of these studies are here, by Study Instance
    /// UID: local studies that share a UID add up, and a UID with nothing here
    /// has no entry.
    func fileCounts(ofStudyInstanceUIDs studyInstanceUIDs: Set<String>) async throws -> [String: Int] {
        let wanted = studyInstanceUIDs.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for study in try await studies(withInstanceUIDs: wanted) {
            counts[study.studyInstanceUID, default: 0] += study.fileCount
        }
        return counts
    }
}
