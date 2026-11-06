//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CryptoKit
import Foundation
import Synchronization

/// The retrieve inventories of a process: one per node, study and series,
/// kept on disk as a manifest in RetrieveManifests of the database folder.
///
/// Every query window and every retrieve of the same study and series from the
/// same node share one inventory while any of them holds it; an inventory no
/// one holds is forgotten, and read again from its manifest when asked for.
/// The inventories that receive now take the stores the listener completes,
/// and every inventory learns when the local database changes.
///
/// The registry is behind a mutex. Its lock is taken before an inventory's,
/// never after: an inventory never calls back into the store while it holds its own.
public final class RetrieveInventoryStore: Sendable {
    /// Each change of the local database counts once; an inventory refreshes
    /// what is here only when this changed since its last refresh.
    let importRevision = Atomic<UInt>(0)

    private struct Registry {
        /// Every inventory someone holds, by manifest path, without holding it.
        var cache: [String: Weak] = [:]
        /// The inventories a retrieve receives into, held until it ends.
        var active: [String: RetrieveInventory] = [:]
    }

    private struct Weak {
        weak var inventory: RetrieveInventory?
    }

    private let registry = Mutex(Registry())

    public init() {}

    // MARK: What the store learns

    /// Has `center` tell the store when the listener completes a store, by the
    /// notification `storesCompleted` (with the instance's "uid", "status",
    /// "study" and "series"), and when the local database changes, by
    /// `databaseChanges`. Called once, by whoever makes the store, which then
    /// lives as long as the process: the observers are never removed.
    public func observe(_ center: NotificationCenter, storesCompleted: Notification.Name, databaseChanges: [Notification.Name]) {
        for name in databaseChanges {
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [self] _ in databaseChanged() }
        }
        _ = center.addObserver(forName: storesCompleted, object: nil, queue: nil) { [self] note in
            guard let info = note.userInfo, let uid = info["uid"] as? String,
                  let status = info["status"] as? NSNumber else { return }
            storeCompleted(uid: uid, status: status.intValue, study: info["study"] as? String ?? "",
                           series: info["series"] as? String ?? "")
        }
    }

    /// The local database changed or saved: what is here is read again on the next refresh.
    public func databaseChanged() {
        importRevision.wrappingAdd(1, ordering: .relaxed)
    }

    /// The listener completed a store of `uid` with `status`: every inventory
    /// that receives now and lists it, or that is of its study (and series),
    /// records it.
    public func storeCompleted(uid: String, status: Int, study: String, series: String) {
        let receiving = registry.withLock { Array($0.active.values) }
        for inventory in receiving {
            inventory.storeCompleted(uid: uid, status: status, study: study, series: series)
        }
    }

    // MARK: Inventories

    /// The manifest of a node's study, or series, in a database folder.
    static func path(study: String, series: String, endpoint: String, database: String) -> String {
        let key = (try? JSONEncoder().encode([endpoint, study, series])) ?? Data()
        let hash = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: database, isDirectory: true)
            .appendingPathComponent("RetrieveManifests", isDirectory: true)
            .appendingPathComponent(hash + ".json").path
    }

    /// Begins the inventory a retrieve receives into, from what the node
    /// listed. `reported` is the peer's count for the study or series, and
    /// `seriesReported` its count for each series: the inventory is what it
    /// listed, and a count it gives but does not list is recorded beside it,
    /// not held against it. What earlier attempts received, were refused or
    /// learned of the peer is kept. The inventory receives until `finish`.
    public func begin(study: String, series: String, endpoint: String, database: String,
                      instances: [RetrieveListedInstance], confirmed: Bool,
                      reported: Int = 0, seriesReported: [String: Int] = [:]) -> RetrieveInventory {
        let path = Self.path(study: study, series: series, endpoint: endpoint, database: database)
        let listing = RetrieveInventoryState.listing(study: study, series: series, instances: instances, confirmed: confirmed,
                                                     reported: reported, seriesReported: seriesReported)
        return registry.withLock { registry in
            let inventory = Self.find(path, in: &registry, store: self)
                ?? RetrieveInventory(record: listing, path: path, store: self)
            inventory.begin(listing)
            registry.cache[path] = Weak(inventory: inventory)
            registry.active[path] = inventory
            return inventory
        }
    }

    /// The inventory of a node's study, or series: the one someone holds, or
    /// the one its manifest records; nil when there is none.
    public func load(study: String, series: String, endpoint: String, database: String) -> RetrieveInventory? {
        let path = Self.path(study: study, series: series, endpoint: endpoint, database: database)
        return registry.withLock { Self.find(path, in: &$0, store: self) }
    }

    private static func find(_ path: String, in registry: inout Registry, store: RetrieveInventoryStore) -> RetrieveInventory? {
        if let cached = registry.cache[path]?.inventory { return cached }
        registry.cache = registry.cache.filter { $0.value.inventory != nil }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(RetrieveInventoryRecord.self, from: bytes), record.version == 1 else { return nil }
        let inventory = RetrieveInventory(record: record, path: path, store: store)
        registry.cache[path] = Weak(inventory: inventory)
        return inventory
    }

    /// An inventory's retrieve ended: once none receives into it, the store
    /// no longer holds it.
    func release(_ inventory: RetrieveInventory) {
        registry.withLock { registry in
            if registry.active[inventory.path] === inventory && !inventory.isReceiving {
                registry.active[inventory.path] = nil
            }
        }
    }
}
