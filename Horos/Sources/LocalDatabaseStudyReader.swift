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

/// Which studies are here, read from a local database for the modules that
/// declare `LocalStudyReading`.
///
/// Each call asks `database` which database to read, at that moment, and reads
/// it on its private-queue context through `HorosLocalQueryReader`: nothing
/// waits on the main thread, and only values leave the read. A database that is
/// not there, or that has no store, is an error the caller decides about.
final class LocalDatabaseStudyReader: LocalStudyReading {
    /// The database to read; nil while there is none.
    let database: @Sendable () -> N2ManagedDatabase?

    init(database: @escaping @Sendable () -> N2ManagedDatabase?) {
        self.database = database
    }

    func studies(withInstanceUIDs studyInstanceUIDs: Set<String>) async throws -> [LocalStudySnapshot] {
        guard let database = database() else {
            throw NSError(domain: HorosPrivateQueueReadErrorDomain, code: 2, userInfo: [
                NSLocalizedDescriptionKey: "There is no local database to read."])
        }
        return try HorosLocalQueryReader.studySnapshots(ofStudyInstanceUIDs: studyInstanceUIDs, in: database)
    }
}
