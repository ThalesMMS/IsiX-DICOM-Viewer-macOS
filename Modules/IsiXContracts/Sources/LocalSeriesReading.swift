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

/// One series of a local study, read once: which of its instances are here.
public struct LocalSeriesSnapshot: Hashable, Sendable {
    /// The Study Instance UID of the study it belongs to.
    public let studyInstanceUID: String
    /// Its Series Instance UID; nil when the series has none.
    public let seriesInstanceUID: String?
    /// The SOP Instance UIDs of its images here, each once; an image without
    /// one has none here.
    public let sopInstanceUIDs: Set<String>

    public init(studyInstanceUID: String, seriesInstanceUID: String?, sopInstanceUIDs: Set<String>) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUIDs = sopInstanceUIDs
    }
}

/// The series of a local study and the instances already here, and the files
/// of a study or one of its series.
///
/// A port over the local database, as `LocalStudyReading` is: the app
/// implements it with a read on the database's private-queue context, and each
/// call reads what is committed at that moment. The calls block the calling
/// thread for the read, as the retrieve threads that ask them expect; nothing
/// waits on the main thread's context.
public protocol LocalSeriesReading: Sendable {
    /// The series of every local study whose Study Instance UID is
    /// `studyInstanceUID`: two local studies with that UID give the series of
    /// both. Nothing when it is not here. Throws when the database cannot be read.
    func series(ofStudyInstanceUID studyInstanceUID: String) throws -> [LocalSeriesSnapshot]

    /// How many files of the local study `study` are here: the whole study's,
    /// or, with `seriesInstanceUID`, those of its first series with that UID.
    /// 0 when the study, or that series, is no longer here. Throws when the
    /// database cannot be read.
    func fileCount(ofStudy study: LocalRecordIdentifier, seriesInstanceUID: String?) throws -> Int
}

public extension LocalSeriesReading {
    /// The SOP Instance UIDs already here of the studies with this UID: of
    /// every series, or only of the series `seriesInstanceUID` when one is
    /// given (an empty one names none). An instance in two series is listed
    /// for each; the order is none in particular.
    func sopInstanceUIDs(ofStudyInstanceUID studyInstanceUID: String, seriesInstanceUID: String?) throws -> [String] {
        let wanted = seriesInstanceUID.flatMap { $0.isEmpty ? nil : $0 }
        var uids: [String] = []
        for series in try series(ofStudyInstanceUID: studyInstanceUID) where wanted == nil || series.seriesInstanceUID == wanted {
            uids.append(contentsOf: series.sopInstanceUIDs)
        }
        return uids
    }
}
