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

/// Where the database the browser shows is read by the objects the process
/// graph does not reach: the Core Data objects of the database, the images a
/// viewer loads, the reports, the plugin adapters and the class methods that
/// run without an instance. A type that receives the graph reads
/// `processGraph.browserDatabase` instead.
///
/// It keeps the graph it was made with, which is Sendable, and hands out the
/// databases the graph answers from any thread, so it is read from any thread
/// too. The browser itself is a main-actor object: it is reached through
/// `processGraph` on the main actor.
///
/// A model object has a database of its own, the one its context belongs to.
/// When the two can differ, the object's own database is the one that counts:
/// `database(of:)` answers it, and the browser's only for an object without
/// one. While the object is a row of the database the browser shows, both are
/// the same database, or two of the same store.
struct BrowserDatabaseSource: Sendable {
    let processGraph: ProcessGraph

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    /// The database the browser shows; nil before the browser exists and
    /// while a rebuild has none.
    var browserDatabase: DicomDatabase? {
        processGraph.browserDatabase
    }

    /// The local database a retrieve or an import fills: the one the browser
    /// shows when it is local, the default one otherwise.
    var activeLocalDatabase: DicomDatabase? {
        processGraph.activeLocalDatabase
    }

    /// The database `object` belongs to: the one its context was made for;
    /// the browser's for an object without a context or whose context belongs
    /// to no database.
    func database(of object: NSManagedObject?) -> DicomDatabase? {
        ((object?.managedObjectContext as? N2ManagedObjectContext)?.database as? DicomDatabase) ?? browserDatabase
    }

    /// Whether `object` is a row of the database the browser shows: its
    /// context and the browser's share their store. An object without a
    /// context is, while the browser shows no database.
    func isInBrowserDatabase(_ object: NSManagedObject) -> Bool {
        object.managedObjectContext?.persistentStoreCoordinator === browserDatabase?.managedObjectContext?.persistentStoreCoordinator
    }

    /// The source of the objects made without a graph.
    static let process = BrowserDatabaseSource(processGraph: ProcessGraph.process)
}
