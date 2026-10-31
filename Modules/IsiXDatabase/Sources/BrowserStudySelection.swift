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

/// What the database window does with a study it is asked to select.
///
/// The window lists the studies of one database. A study of another database
/// is selected by showing that database, and changing the database shown
/// closes every viewer. A selection somebody asked for - a click in the
/// window's history, a study named by XML-RPC, a `horos://` link, a plugin's
/// `-selectThisStudy:` - may do that. A selection the application makes on its
/// own may not: a viewer's series list selects the viewer's study each time it
/// is built, and the viewer of a study the window does not show (opened by a
/// plugin, by XML-RPC, from a shared database the window does not show) closed
/// itself and every other viewer when a viewer closed, images arrived or a
/// series changed.
public enum BrowserStudySelection {

    public enum Decision: Equatable, Sendable {
        /// The study is in the database shown: select its row.
        case select
        /// Show the study's database, then select its row.
        case switchDatabase
        /// The study belongs to no store any more.
        case refuseOutsideAnyDatabase
        /// The study is in another store and no database is known for it.
        case refuseUnknownDatabase
        /// The study is in another database, and the selection was not asked
        /// for: the window keeps the database it shows.
        case refuseNotShown
    }

    /// - Parameters:
    ///   - requested: somebody asked for the selection, which may then show
    ///     the study's database.
    ///   - studyStore: the persistent store coordinator of the study's context.
    ///   - shownStore: the coordinator of the context of the database shown.
    ///   - studyDatabase: the database of the study's context; asked only when
    ///     the stores differ.
    ///   - shownDatabase: the database the window shows.
    public static func decision(requested: Bool, studyStore: AnyObject?, shownStore: AnyObject?,
                                studyDatabase: () -> AnyObject?, shownDatabase: AnyObject?) -> Decision {
        guard let studyStore else { return .refuseOutsideAnyDatabase }
        var known: AnyObject?
        if showsDatabase(store: studyStore, database: { known = studyDatabase(); return known },
                         shownStore: shownStore, shownDatabase: shownDatabase) {
            return .select
        }
        guard known != nil else { return .refuseUnknownDatabase }
        return requested ? .switchDatabase : .refuseNotShown
    }

    /// Whether the window shows the database whose context reads `store`;
    /// what decides if a study is selected without a switch, and if an image
    /// written for a database goes to the one shown.
    /// - Parameters:
    ///   - store: the persistent store coordinator of the context.
    ///   - database: the database of the context; asked only when the stores
    ///     differ.
    ///   - shownStore: the coordinator of the context of the database shown.
    ///   - shownDatabase: the database the window shows.
    public static func showsDatabase(store: AnyObject?, database: () -> AnyObject?,
                                     shownStore: AnyObject?, shownDatabase: AnyObject?) -> Bool {
        // A private-queue copy of the database shown reads the same store.
        if let store, store === shownStore { return true }
        // A shared database replaces its store at each update and stays the
        // database shown.
        guard let database = database() else { return false }
        return database === shownDatabase
    }
}
