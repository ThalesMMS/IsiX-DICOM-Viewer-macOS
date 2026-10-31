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

/// The series of a local study and the instances and files already here, for
/// the retrieve and the Query window, which declare `LocalSeriesReading`.
///
/// Read on the database's private-queue context through `HorosLocalQueryReader`,
/// as the studies are; a read that fails throws the error of that read as it
/// came, an Objective-C exception included, for the caller that raises it again.
extension LocalDatabaseStudyReader: LocalSeriesReading {

    func series(ofStudyInstanceUID studyInstanceUID: String) throws -> [LocalSeriesSnapshot] {
        try HorosLocalQueryReader.seriesSnapshots(ofStudyInstanceUID: studyInstanceUID, in: try seriesDatabase())
    }

    func fileCount(ofStudy study: LocalRecordIdentifier, seriesInstanceUID: String?) throws -> Int {
        try HorosLocalQueryReader.fileCount(ofStudyAt: study.uri, seriesInstanceUID: seriesInstanceUID, in: try seriesDatabase())
    }

    private func seriesDatabase() throws -> N2ManagedDatabase {
        guard let database = database() else {
            throw NSError(domain: HorosPrivateQueueReadErrorDomain, code: 2, userInfo: [
                NSLocalizedDescriptionKey: "There is no local database to read."])
        }
        return database
    }
}
