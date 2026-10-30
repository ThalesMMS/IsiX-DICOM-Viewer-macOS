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

// The decisions the application's Core Data database (N2ManagedDatabase and its
// context) takes before it touches a store: the options a store is added with,
// where the copy of the model beside the index lives, which queue a context
// gets, when a context shares the database's coordinator, and when a batch of
// atomic changes may start. The application applies them to its coordinators
// and contexts.

public enum ManagedStoreRules {

    /// The queue a context of the database works on.
    public enum ContextQueue: Equatable, Sendable {
        /// The main queue: the UI's context.
        case main
        /// A private queue of its own.
        case privateQueue
    }

    /// The options a SQLite store is added with: an inferred mapping model,
    /// automatic migration when the database asks for it, and the rollback
    /// journal, so that the index stays one file (no write-ahead log beside it).
    public static func storeOptions(migratingAutomatically: Bool) -> [String: Any] {
        return [NSInferMappingModelAutomaticallyOption: true,
                NSMigratePersistentStoresAutomaticallyOption: migratingAutomatically,
                NSSQLitePragmasOption: ["journal_mode": "delete"]]
    }

    /// The copy of the model kept beside the index, which a later version that
    /// knows more of the model merges in: the index's path with the extension
    /// `momd` in place of its own.
    public static func localModelsPath(forStoreAtPath path: String) -> String {
        let stem = (path as NSString).deletingPathExtension as NSString
        return stem.appendingPathExtension("momd") ?? stem as String
    }

    /// The queue of a database's own context: the UI's main queue when it is
    /// made on the main thread, a private queue otherwise.
    public static func ownContextQueue(onMainThread: Bool) -> ContextQueue {
        return onMainThread ? .main : .privateQueue
    }

    /// Whether a context asked for at `path` is an independent context over the
    /// database's own coordinator, on a private queue: the database has a
    /// coordinator, the path is the database's own, and its index exists.
    /// Otherwise the context opens the store itself, as the database's own.
    public static func isIndependentContext(hasCoordinator: Bool, isDatabasePath: Bool, indexExists: Bool) -> Bool {
        return hasCoordinator && isDatabasePath && indexExists
    }

    /// The queue of a context asked for at a path.
    public static func contextQueue(independent: Bool, onMainThread: Bool) -> ContextQueue {
        return independent ? .privateQueue : ownContextQueue(onMainThread: onMainThread)
    }

    /// The state of a context when a batch of atomic changes is asked of it.
    public struct AtomicChangesState: Equatable, Sendable {
        public var hasChangesBlock: Bool
        public var defersSaves: Bool
        public var hasChanges: Bool
        public var hasParentContext: Bool
        public var persistentStoreCount: Int
        public var pendingNextSaveActions: Int
        public var pendingDiscardActions: Int

        public init(hasChangesBlock: Bool, defersSaves: Bool, hasChanges: Bool, hasParentContext: Bool,
                    persistentStoreCount: Int, pendingNextSaveActions: Int, pendingDiscardActions: Int) {
            self.hasChangesBlock = hasChangesBlock
            self.defersSaves = defersSaves
            self.hasChanges = hasChanges
            self.hasParentContext = hasParentContext
            self.persistentStoreCount = persistentStoreCount
            self.pendingNextSaveActions = pendingNextSaveActions
            self.pendingDiscardActions = pendingDiscardActions
        }
    }

    /// A batch of atomic changes needs a clean, independent, store-backed
    /// context: changes to make, no batch already open, nothing unsaved, no
    /// parent context, at least one store, and no action left from earlier work.
    public static func atomicChangesMayStart(_ state: AtomicChangesState) -> Bool {
        return state.hasChangesBlock && !state.defersSaves && !state.hasChanges && !state.hasParentContext
            && state.persistentStoreCount > 0 && state.pendingNextSaveActions == 0 && state.pendingDiscardActions == 0
    }

    /// The error a batch that may not start reports.
    public static let atomicChangesRefusal = "Atomic changes require a clean, independent store context."
    /// The error a batch that was prepared but not committed reports.
    public static let atomicChangesNotCommitted = "The prepared changes were not committed."
    /// The domain of both.
    public static let atomicChangesErrorDomain = "N2AtomicChanges"
}
