//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// Rebuilding the index of a database, from its files or from its SQL file.
///
/// A port over the database: the app implements it. A remote database, whose
/// index is on its server, answers false to `rebuildAllowed`, and the two
/// rebuilds do nothing on it.
///
/// The two rebuilds block until the work has ended, which can take long, so they
/// belong on a thread of their own, where they show their status and progress.
/// While one runs the import of the INCOMING folder waits. What is added to the
/// database by other paths waits while the rebuild of the SQL file replaces the
/// index, and goes into the new one. Quitting waits for both rebuilds.
public protocol DatabaseRebuilding: Sendable {
    /// Whether this database can be rebuilt at all.
    var rebuildAllowed: Bool { get }

    /// Reads the database's folders again, on a private-queue database. When
    /// `complete`, the index is replaced by a new one, after a verified copy of
    /// it is kept; a copy that cannot be made leaves the index as it was.
    /// Otherwise the index stays, what is new is added to it and what is gone
    /// is taken out.
    func rebuildIndex(complete: Bool)

    /// Replaces the SQL file by what `sqlite3` can dump of it.
    func rebuildSQLFile()

    /// Archives the report of every study that has one as a DICOM structured
    /// report, so that the two agree.
    func checkReportsConsistency()
}
