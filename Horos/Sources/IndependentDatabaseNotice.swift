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

/// The notice an independent database posts about the images it added, on its
/// way to the main database, which answers it on the main thread.
///
/// The notice names managed objects of the independent database's context.
/// The main thread must not enter that context's queue to read their IDs:
/// whoever indexes holds it, for as long as a batch lasts, and may itself be
/// waiting for the main thread. So the main thread is handed the notice with
/// IDs in place of the objects, read on the posting database's context:
///
/// - posted off the main thread, by the thread that owns that context, they
///   are read there and then, where the queue is the poster's own (a disc scan
///   holds it while it asks whether to copy the disc or browse it);
/// - posted on the main thread, as the indexer posts what an import added,
///   they are read from that context's queue once whoever holds it lets go,
///   and the main thread waits for nothing meanwhile. Notices of one database
///   keep their order, the queue being serial.
enum IndependentDatabaseNotice {
    /// Hands `notification` to `database` on the main thread with IDs in place
    /// of managed objects. False when there is nothing to hand over: it is
    /// already on the main thread and names no managed object, and `database`
    /// answers it now.
    static func handsOver(_ notification: Notification!, to database: DicomDatabase) -> Bool {
        guard let notification else { return false }
        if !Thread.isMainThread {
            deliver(withObjectIDs(notification), to: database)
            return true
        }
        guard namesObjects(notification),
              let context = (notification.object as? N2ManagedDatabase)?.managedObjectContext else { return false }
        let handed = Handed(notification: notification, database: database)
        context.perform {
            deliver(withObjectIDs(handed.notification), to: handed.database)
        }
        return true
    }

    /// The notification with the managed objects of its image array and of
    /// its per-AET dictionary replaced by their object IDs, read on the
    /// posting database's context.
    static func withObjectIDs(_ notification: Notification) -> Notification {
        guard let userInfo = notification.userInfo,
              let context = (notification.object as? N2ManagedDatabase)?.managedObjectContext else { return notification }
        var converted = userInfo
        N2ManagedObjectContextPerformAndWait(context) {
            if let images = userInfo[OsirixAddToDBNotificationImagesArray] as? [Any] {
                converted[OsirixAddToDBNotificationImagesArray] = identifiers(images)
            }
            if let perAET = userInfo[OsirixAddToDBNotificationImagesPerAETDictionary] as? [AnyHashable: Any] {
                converted[OsirixAddToDBNotificationImagesPerAETDictionary] = perAET.mapValues { ($0 as? [Any]).map(identifiers) ?? $0 }
            }
        }
        return Notification(name: notification.name, object: notification.object, userInfo: converted)
    }

    /// Whether the image array or the per-AET dictionary still names a managed
    /// object. Asking an object its class enters no queue.
    private static func namesObjects(_ notification: Notification) -> Bool {
        func named(_ value: Any?) -> Bool {
            return (value as? [Any])?.contains { $0 is NSManagedObject } ?? false
        }
        if named(notification.userInfo?[OsirixAddToDBNotificationImagesArray]) { return true }
        let perAET = notification.userInfo?[OsirixAddToDBNotificationImagesPerAETDictionary] as? [AnyHashable: Any]
        return perAET?.values.contains { named($0) } ?? false
    }

    private static func identifiers(_ objects: [Any]) -> [Any] {
        return objects.map { ($0 as? NSManagedObject)?.objectID ?? $0 }
    }

    /// From any thread, without waiting: the main run loop sends it in its
    /// common modes, a modal panel's included.
    private static func deliver(_ notification: Notification, to database: DicomDatabase) {
        database.performSelector(onMainThread: #selector(DicomDatabase.observeIndependentDatabaseNotification(_:)),
                                 with: notification, waitUntilDone: false)
    }

    /// What the context's queue is given to hand over. The notification is
    /// read there and the database only receives it: neither is changed.
    private struct Handed: @unchecked Sendable {
        let notification: Notification
        let database: DicomDatabase
    }
}
