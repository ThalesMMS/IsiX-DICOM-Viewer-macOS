//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import CryptoKit
import CoreData

/// Reconciles a remote identity inventory with transport events and local import.
/// The WADO download manifest describes HTTP attempts; this record describes the
/// study/series that the query window can actually prove is present locally.
@objc(HorosRetrieveInventory)
public final class RetrieveInventory: NSObject {
    private static let lock = NSRecursiveLock()
    // nonisolated(unsafe): the transfer, import and window threads share these,
    // and read and write them only between `lock.lock()` and `lock.unlock()`,
    // as every use below shows (watchImports runs inside begin's lock). Remove
    // when the lock becomes a Mutex that holds them.
    nonisolated(unsafe) private static let cache = NSMapTable<NSString, RetrieveInventory>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    nonisolated(unsafe) private static var active: [String: RetrieveInventory] = [:]
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    nonisolated(unsafe) private static var saveObserver: NSObjectProtocol?
    nonisolated(unsafe) private static var changeObserver: NSObjectProtocol?
    nonisolated(unsafe) private static var importRevision: UInt = 0
    private var lastImportRevision: UInt?
    private var receivers = 0
    private var receiving: Bool { receivers > 0 }
    private var attemptReceived: Set<String> = []
    private var attemptRefused: Set<String> = []
    private var baselineImported: Set<String>?
    /// Instances the peer had already declared it cannot send when this attempt began:
    /// their absence was reported by the attempt that found it (#692).
    private var knownUnsendable: Set<String> = []
    private var data: Snapshot
    @objc public let path: String

    private struct Snapshot: Codable {
        var version = 1
        var study: String
        var series: String
        var expected: [String: String]
        var inventoryConfirmed: Bool
        var received: [String: Int] = [:]
        var rejected: [String: [Int]] = [:]
        var storageWarnings: [String: [Int]]? = [:]
        var httpRejected: Set<String>? = []
        /// Instances not fetched because the WADO server's certificate was not
        /// trusted, with the reason given. Cleared for an instance once it arrives.
        var tlsUntrusted: [String: String]? = [:]
        var peerResponses: [[String: String]]? = []
        var peerFailed: Set<String>? = []
        var imported: Set<String> = []
        var duplicateInventory: Set<String> = []
        var queried: Date? = Date()
        var updated = Date()
        /// What the peer said it holds when the inventory was queried: its
        /// NumberOf{Study,Series}RelatedInstances, 0 when it did not say (#790).
        var reported: Int? = 0
        /// Per series, what the peer said it holds and how many instances it listed.
        var seriesReported: [String: Int]? = [:]
        var seriesListed: [String: Int]? = [:]
        /// Each listed instance's SOP class, when the IMAGE level gave it.
        var sopClasses: [String: String]? = [:]
        /// Listed instances of classes this retrieve does not offer to receive: they cannot
        /// arrive, and a retrieve that is not forced does not ask for them (#789).
        var unoffered: Set<String>? = []
        /// Where the listing of the peer's instances stands when the transfer
        /// starts before it ends: in progress, confirmed, failed or cancelled.
        var discovery: String? = nil
        /// Series the node's rules left out of the last attempt, by UID: their
        /// description and the rule. An intentional exclusion, not a failure.
        var excluded: [String: [String]]? = nil
        /// Objects received under a SOP Instance UID the listing does not
        /// name, by UID: the SOP Instance UIDs their Source Image Sequence
        /// names. A server that converts an object to a lossy syntax may give
        /// the copy a new UID, as Orthanc does, and name the original there.
        var derived: [String: [String]]? = nil
        /// Each listed instance's Instance Number, when the IMAGE level gave one.
        var numbers: [String: Int]? = nil
        /// Objects received under a SOP Instance UID the listing does not
        /// name, in a lossy syntax that was asked for, with no Source Image
        /// Sequence, by UID: their series, SOP class and Instance Number. Not
        /// yet matched to a listed instance; once matched, they move to
        /// `derived`.
        var unreferenced: [String: [String]]? = nil
    }

    private init(data: Snapshot, path: String) {
        self.data = data
        self.path = path
        super.init()
    }

    private static func watchImports() {
        if saveObserver == nil {
            saveObserver = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { _ in
                lock.lock(); importRevision &+= 1; lock.unlock()
            }
            changeObserver = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextObjectsDidChange, object: nil, queue: nil) { _ in
                lock.lock(); importRevision &+= 1; lock.unlock()
            }
        }
    }

    /// A repaint reuses the reconciled UID set until Core Data changes or saves state.
    @objc public func beginImportRefresh() -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard lastImportRevision != Self.importRevision else { return false }
        lastImportRevision = Self.importRevision
        return true
    }

    @objc public func invalidateImportRefresh() {
        Self.lock.lock(); defer { Self.lock.unlock() }; lastImportRevision = nil
    }

    private static func file(study: String, series: String, endpoint: String, database: String) -> String {
        let key = (try? JSONEncoder().encode([endpoint, study, series])) ?? Data()
        let hash = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: database, isDirectory: true)
            .appendingPathComponent("RetrieveManifests", isDirectory: true)
            .appendingPathComponent(hash + ".json").path
    }

    @objc(beginStudy:series:endpoint:database:instances:confirmed:)
    public static func begin(study: String, series: String, endpoint: String, database: String,
                             instances: [[String: String]], confirmed: Bool) -> RetrieveInventory {
        begin(study: study, series: series, endpoint: endpoint, database: database, instances: instances, confirmed: confirmed,
              reported: 0, seriesReported: [:])
    }

    /// `reported` is the peer's count for the study or series, and `seriesReported` its count
    /// for each series: the inventory is what it listed, and a count it gives but does not list
    /// is recorded beside it, not held against it (#790).
    @objc(beginStudy:series:endpoint:database:instances:confirmed:reported:seriesReported:)
    public static func begin(study: String, series: String, endpoint: String, database: String,
                             instances: [[String: String]], confirmed: Bool,
                             reported: Int, seriesReported: [String: NSNumber]) -> RetrieveInventory {
        lock.lock(); defer { lock.unlock() }
        watchImports()
        let path = file(study: study, series: series, endpoint: endpoint, database: database)
        var snapshot = Snapshot(study: study, series: series, expected: [:], inventoryConfirmed: confirmed)
        for item in instances {
            guard let uid = item["uid"], !uid.isEmpty, let seriesUID = item["series"], !seriesUID.isEmpty else {
                snapshot.inventoryConfirmed = false
                continue
            }
            if snapshot.expected[uid] != nil { snapshot.duplicateInventory.insert(uid) }
            snapshot.expected[uid] = seriesUID
            if let sopClass = item["sopClass"], !sopClass.isEmpty { snapshot.sopClasses?[uid] = sopClass }
            if let number = Self.instanceNumber(item["number"]) {
                if snapshot.numbers == nil { snapshot.numbers = [:] }
                snapshot.numbers?[uid] = number
            }
            if item["offered"] == "NO" { snapshot.unoffered?.insert(uid) }
        }
        if snapshot.expected.isEmpty { snapshot.inventoryConfirmed = false }
        snapshot.reported = max(reported, 0)
        snapshot.seriesReported = seriesReported.mapValues { $0.intValue }
        snapshot.seriesListed = Dictionary(grouping: snapshot.expected.values, by: { $0 }).mapValues { $0.count }
        let inventory = load(study: study, series: series, endpoint: endpoint, database: database)
            ?? RetrieveInventory(data: snapshot, path: path)
        snapshot.received = inventory.data.received
        snapshot.rejected = inventory.data.rejected
        snapshot.storageWarnings = inventory.data.storageWarnings
        snapshot.httpRejected = inventory.data.httpRejected
        snapshot.tlsUntrusted = inventory.data.tlsUntrusted
        snapshot.peerResponses = inventory.data.peerResponses
        snapshot.peerFailed = inventory.data.peerFailed
        snapshot.derived = inventory.data.derived
        snapshot.unreferenced = inventory.data.unreferenced
        inventory.data = snapshot
        if !inventory.receiving {
            inventory.attemptReceived = []
            inventory.attemptRefused = []
            inventory.baselineImported = nil
            inventory.knownUnsendable = inventory.expectedAbsent
        }
        inventory.lastImportRevision = nil
        inventory.receivers += 1
        cache.setObject(inventory, forKey: path as NSString)
        active[path] = inventory
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: Notification.Name("HorosDICOMStoreCompleted"), object: nil, queue: nil) { note in
                guard let info = note.userInfo, let uid = info["uid"] as? String,
                      let status = info["status"] as? NSNumber else { return }
                lock.lock(); defer { lock.unlock() }
                for entry in active.values where entry.receiving {
                    let study = info["study"] as? String ?? ""
                    let series = info["series"] as? String ?? ""
                    if ((study.isEmpty || status.intValue != 0) && entry.data.expected[uid] != nil) || (study == entry.data.study && (entry.data.series.isEmpty || entry.data.series == series)) {
                        entry.record(uid: uid, status: status.intValue)
                    }
                }
            }
        }
        inventory.save()
        return inventory
    }

    /// Gives the inventory what the peer listed, once the listing that ran
    /// beside the transfer has ended: the same reading of `instances` as
    /// `begin`, keeping what this attempt has received, refused or imported.
    /// `confirmed` NO (a failed or cancelled listing) leaves completeness
    /// unknown, whatever arrived.
    @objc(confirmInstances:confirmed:reported:seriesReported:discovery:)
    public func confirm(instances: [[String: String]], confirmed: Bool, reported: Int,
                        seriesReported: [String: NSNumber], discovery: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var expected: [String: String] = [:]
        var duplicates = Set<String>()
        var classes: [String: String] = [:]
        var numbers: [String: Int] = [:]
        var unoffered = Set<String>()
        var valid = confirmed
        for item in instances {
            guard let uid = item["uid"], !uid.isEmpty, let seriesUID = item["series"], !seriesUID.isEmpty else { valid = false; continue }
            if expected[uid] != nil { duplicates.insert(uid) }
            expected[uid] = seriesUID
            if let sopClass = item["sopClass"], !sopClass.isEmpty { classes[uid] = sopClass }
            if let number = Self.instanceNumber(item["number"]) { numbers[uid] = number }
            if item["offered"] == "NO" { unoffered.insert(uid) }
        }
        data.expected = expected
        data.duplicateInventory = duplicates
        data.sopClasses = classes
        data.numbers = numbers
        data.unoffered = unoffered
        data.inventoryConfirmed = valid && !expected.isEmpty
        data.reported = max(reported, 0)
        data.seriesReported = seriesReported.mapValues { $0.intValue }
        data.seriesListed = Dictionary(grouping: expected.values, by: { $0 }).mapValues { $0.count }
        data.discovery = discovery
        data.derived = data.derived?.filter { expected[$0.key] == nil }
        data.unreferenced = data.unreferenced?.filter { expected[$0.key] == nil }
        matchUnreferenced()
        data.queried = Date()
        lastImportRevision = nil
        save()
    }

    /// Marks the listing as running beside the transfer.
    @objc(markDiscovery:)
    public func markDiscovery(_ state: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        data.discovery = state
    }

    /// "in progress", "confirmed", "failed" or "cancelled" when the listing
    /// ran beside the transfer; empty when it ran before it.
    @objc public var discoveryState: String { Self.lock.lock(); defer { Self.lock.unlock() }; return data.discovery ?? "" }

    /// What the peer listed: each SOP Instance UID with its series.
    @objc public var expectedInstances: [String: String] { Self.lock.lock(); defer { Self.lock.unlock() }; return data.expected }

    /// Listed instances neither received in this attempt nor in the index,
    /// leaving out those the peer cannot send, by series: what a second pass
    /// still has to ask for.
    @objc public var unreceivedSeries: [String: [String]] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard data.inventoryConfirmed else { return [:] }
        let left = Set(data.expected.keys).subtracting(listed(data.imported))
            .subtracting(listed(attemptReceived)).subtracting(expectedAbsent).subtracting(excludedUIDs)
        return Dictionary(grouping: left.sorted(), by: { data.expected[$0] ?? "" })
    }

    /// Records the series the node's rules left out of this attempt: the
    /// study is then retrieved but for them, not complete.
    @objc(excludeSeries:)
    public func exclude(series: [String: [String]]) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        data.excluded = series.isEmpty ? nil : series
        save()
    }

    /// The series left out of the last attempt: `[description, rule]` by UID.
    @objc public var excludedSeries: [String: [String]] { Self.lock.lock(); defer { Self.lock.unlock() }; return data.excluded ?? [:] }

    /// Listed instances of the series left out.
    private var excludedUIDs: Set<String> {
        guard let excluded = data.excluded, !excluded.isEmpty else { return [] }
        return Set(data.expected.filter { excluded[$0.value] != nil }.keys)
    }

    /// What this attempt asked for: the listed instances but those of the
    /// series left out, and how many of them are in the index.
    @objc public var scopeExpectedCount: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return data.expected.count - excludedUIDs.count }
    @objc public var scopeImportedCount: Int {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Set(data.expected.keys).subtracting(excludedUIDs).intersection(listed(data.imported)).count
    }

    @objc(loadStudy:series:endpoint:database:)
    public static func load(study: String, series: String, endpoint: String, database: String) -> RetrieveInventory? {
        lock.lock(); defer { lock.unlock() }
        watchImports()
        let path = file(study: study, series: series, endpoint: endpoint, database: database)
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes), snapshot.version == 1 else { return nil }
        let result = RetrieveInventory(data: snapshot, path: path)
        cache.setObject(result, forKey: path as NSString)
        return result
    }

    @objc(recordUID:status:)
    public func record(uid: String, status: Int) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if status == 0 || (status & 0xf000) == 0xb000 { data.received[uid, default: 0] += 1; attemptReceived.insert(uid); data.tlsUntrusted?[uid] = nil }
        if (status & 0xf000) == 0xb000 {
            var warnings = data.storageWarnings ?? [:]; warnings[uid, default: []].append(status); data.storageWarnings = warnings
        } else if status != 0 { data.rejected[uid, default: []].append(status); attemptRefused.insert(uid) }
    }

    /// Records an object whose Source Image Sequence names `sources`. One
    /// the listing does not name stands for the listed instance among them:
    /// it counts as that instance, which is then not asked for again.
    @objc(recordUID:status:sources:)
    public func record(uid: String, status: Int, sources: [String]) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let named = sources.filter { !$0.isEmpty && $0 != uid }
        if !named.isEmpty && !(data.inventoryConfirmed && data.expected[uid] != nil) {
            if data.derived == nil { data.derived = [:] }
            data.derived?[uid] = named
        }
        record(uid: uid, status: status)
    }

    /// Records an object with no Source Image Sequence that arrived in a
    /// lossy syntax that was asked for, with its series, SOP class and
    /// Instance Number. A server that converts an object to such a syntax may
    /// give the copy a new SOP Instance UID and name nothing it came from, as
    /// Orthanc 1.13.0 does for an object it converts through GDCM; the series,
    /// the class and the Instance Number stay those of the original. One the
    /// listing does not name stands for the listed instance with the same
    /// three, when exactly one has them and it has not arrived: that instance
    /// is then not asked for again. A tie, or a missing Instance Number on
    /// either side, matches nothing.
    @objc(recordUID:status:series:sopClass:instanceNumber:)
    public func record(uid: String, status: Int, series: String, sopClass: String, instanceNumber: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let unlisted = !(data.inventoryConfirmed && data.expected[uid] != nil)
        if let number = Self.instanceNumber(instanceNumber), !series.isEmpty, !sopClass.isEmpty, unlisted {
            if data.unreferenced == nil { data.unreferenced = [:] }
            data.unreferenced?[uid] = [series, sopClass, String(number)]
        }
        record(uid: uid, status: status)
        if data.inventoryConfirmed && data.unreferenced?[uid] != nil { matchUnreferenced() }
    }

    /// An Instance Number as an integer; nil when there is none.
    private static func instanceNumber(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Matches each unreferenced object the listing does not name to the one
    /// listed instance with its series, SOP class and Instance Number that
    /// has not arrived in this attempt or in the index, neither by its own
    /// UID nor through another copy. A
    /// matched object moves to `derived`, as if its Source Image Sequence
    /// named that instance; one with no such instance, or more than one,
    /// stays where it is and stands for itself.
    private func matchUnreferenced() {
        guard data.inventoryConfirmed, let unreferenced = data.unreferenced, !unreferenced.isEmpty else { return }
        var keys: [[String]: [String]] = [:]
        for (uid, series) in data.expected {
            guard let sopClass = data.sopClasses?[uid], let number = data.numbers?[uid] else { continue }
            keys[[series, sopClass, String(number)], default: []].append(uid)
        }
        for uid in unreferenced.keys.sorted() where data.expected[uid] == nil {
            guard let key = unreferenced[uid], let candidates = keys[key], candidates.count == 1 else { continue }
            let arrived = data.imported.union(attemptReceived).subtracting([uid])
            guard !listed(arrived).contains(candidates[0]) else { continue }
            if data.derived == nil { data.derived = [:] }
            data.derived?[uid] = candidates
            data.unreferenced?[uid] = nil
        }
    }

    /// The instances the objects `uids` stand for: each one the listing
    /// names stands for itself, and one it does not name, received with a
    /// Source Image Sequence that names a listed instance, for that instance.
    private func listed(_ uids: Set<String>) -> Set<String> {
        guard let derived = data.derived, !derived.isEmpty else { return uids }
        return Set(uids.map { uid in
            data.expected[uid] != nil ? uid : derived[uid]?.first { data.expected[$0] != nil } ?? uid
        })
    }

    /// The instances that the local objects among `uids`, received under a
    /// new SOP Instance UID, came from, by their Source Image Sequence: a
    /// retrieve that finds such an object here does not ask for its source.
    @objc(sourceUIDsOfDerivedUIDs:)
    public func sourceUIDs(ofDerived uids: [String]) -> [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let derived = data.derived, !derived.isEmpty else { return [] }
        return Array(Set(uids.flatMap { derived[$0] ?? [] })).sorted()
    }

    @objc(recordPeerFailedUID:)
    public func recordPeerFailedUID(_ uid: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if data.peerFailed == nil { data.peerFailed = [] }
        data.peerFailed?.insert(uid)
    }

    /// After a C-GET, the instances it asked for that neither arrived nor were refused here are
    /// what the peer could not send, when they are as many as its failed sub-operations less
    /// those refused here. A peer that omits the Failed SOP Instance UID List (OsiriX, for a
    /// file it cannot convert) names them this way. `requested` empty means every instance of
    /// `series`, or of the study when that is empty. Only a final status that speaks of
    /// failed sub-operations (0xB000, 0xA702, or success) counts: a refusal of the whole
    /// request (0xC000, an IMAGE level the peer does not support) says nothing of any
    /// instance. A count that does not match, or sub-operations still remaining, records
    /// nothing (#692).
    ///
    /// Returns whether what was not sent is all instances of classes this retrieve does not
    /// offer to receive: expected absences, nothing to report (#789).
    @objc(recordUnsentOfRequested:series:status:failed:remaining:) @discardableResult
    public func recordUnsent(requested: [String], series: String, status: UInt, failed: UInt, remaining: UInt) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard [0x0000, 0xB000, 0xA702].contains(status), failed > 0, remaining == 0 else { return false }
        let asked = requested.isEmpty
            ? Set(data.expected.filter { series.isEmpty || $0.value == series }.keys)
            : Set(requested.filter { !$0.isEmpty })
        let refusedHere = asked.intersection(attemptRefused).count
        let unsent = asked.subtracting(attemptReceived).subtracting(attemptRefused)
        guard !unsent.isEmpty, unsent.count == Int(failed) - refusedHere else { return false }
        data.peerFailed = (data.peerFailed ?? []).union(unsent)
        return refusedHere == 0 && unsent.isSubset(of: data.unoffered ?? [])
    }

    /// Asks the peer again for what it declared it cannot send: a forced retrieve (#692).
    @objc public func forgetPeerFailures() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        data.peerFailed = []
        data.unoffered = []
        knownUnsendable = []
    }

    /// What will not arrive by asking: what the peer declared it cannot send, and instances of
    /// classes this retrieve does not offer to receive.
    private var expectedAbsent: Set<String> { (data.peerFailed ?? []).union(data.unoffered ?? []) }

    @objc(recordHTTPRejectedUID:)
    public func recordHTTPRejectedUID(_ uid: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if data.httpRejected == nil { data.httpRejected = [] }
        data.httpRejected?.insert(uid)
    }

    /// A WADO instance not fetched because the server's certificate was not trusted.
    @objc(recordTLSUntrustedUID:reason:)
    public func recordTLSUntrustedUID(_ uid: String, reason: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if data.tlsUntrusted == nil { data.tlsUntrusted = [:] }
        data.tlsUntrusted?[uid] = reason
    }

    @objc(recordOperation:status:completed:failed:warnings:remaining:)
    public func record(operation: String, status: UInt, completed: UInt, failed: UInt, warnings: UInt, remaining: UInt) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if data.peerResponses == nil { data.peerResponses = [] }
        data.peerResponses?.append(["operation":operation,"status":String(status),"completed":String(completed),
                                    "failed":String(failed),"warnings":String(warnings),"remaining":String(remaining)])
    }

    /// Returns whether the imported identities changed.
    @objc(updateImportedUIDs:) @discardableResult
    public func updateImportedUIDs(_ uids: [String]) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let imported = Set(uids.filter { !$0.isEmpty })
        if receiving && baselineImported == nil { baselineImported = imported }
        guard imported != data.imported else { return false }
        data.imported = imported; save()
        return true
    }

    /// Expected instances this attempt received that the index does not hold yet.
    @objc public var receivedAwaitingImportCount: Int {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return listed(attemptReceived).intersection(data.expected.keys).subtracting(listed(data.imported)).count
    }

    /// Waits for what this attempt received to be in the index, refreshing the imported identities
    /// with `refresh`. Received files are indexed by the importer's timer, after the transfer has
    /// returned: judged at once, a retrieve that brought every instance was recorded as incomplete
    /// (#646). An import or conversion can take longer than `patience` without committing
    /// any images. Count inactivity only while those workers are idle; cancellation still
    /// interrupts the wait immediately. Returns whether nothing is left waiting.
    @objc(waitForReceivedImportsRefreshing:importInProgress:patience:cancelled:)
    public func waitForReceivedImports(refreshing refresh: () -> Void,
                                       importInProgress: () -> Bool = { false }, patience: TimeInterval,
                                       cancelled: () -> Bool) -> Bool {
        var awaiting = Int.max
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while true {
            refresh()
            let count = receivedAwaitingImportCount
            if count == 0 { return true }
            if cancelled() { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if count < awaiting || importInProgress() {
                awaiting = count
                lastProgress = now
            } else if now - lastProgress >= patience {
                return false
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    @objc public func finish() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        receivers = max(receivers - 1, 0)
        if !receiving { Self.active[path] = nil }
        save()
    }

    private func save() {
        data.updated = Date()
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The persistent record includes the exact reconciliation, not only counters.
            let encoded = try JSONEncoder().encode(data)
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["missingUIDs"] = missingUIDs
            object["duplicateUIDs"] = duplicateUIDs
            object["rejectedUIDs"] = rejectedUIDs
            object["unexpectedUIDs"] = unexpectedUIDs
            object["emptySeries"] = emptySeries
            object["unlistedCount"] = unlistedCount
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch {
            NSLog("Retrieve manifest could not be saved; in-memory reconciliation remains available")
        }
    }

    @objc public var inventoryConfirmed: Bool { Self.lock.lock(); defer { Self.lock.unlock() }; return data.inventoryConfirmed }
    @objc public var expectedCount: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return data.expected.count }
    @objc public var localUniqueCount: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return data.imported.count }
    @objc public var needsAttention: Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return !inventoryConfirmed || !Set(missingUIDs).subtracting(listed(attemptReceived)).subtracting(listed(baselineImported ?? []))
            .subtracting(knownUnsendable).subtracting(excludedUIDs).isEmpty
    }
    /// Missing instances the peer declared it cannot send; a smart retrieve does not ask for them (#692).
    @objc public var unsendableUIDs: [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Set(missingUIDs).intersection(expectedAbsent).sorted()
    }
    /// The missing instances the peer will not send, counted by SOP class (#789).
    @objc public var unsendableClasses: [String: Int] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Dictionary(grouping: unsendableUIDs, by: { data.sopClasses?[$0] ?? "" }).mapValues { $0.count }
    }
    /// Every missing instance arrived in this attempt or is one the peer cannot send.
    @objc public var nothingLeftToAsk: Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return inventoryConfirmed && expectedCount > 0 &&
            Set(missingUIDs).subtracting(listed(attemptReceived)).subtracting(expectedAbsent).isEmpty
    }
    @objc public var importedCount: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return Set(data.expected.keys).intersection(listed(data.imported)).count }
    @objc public var missingUIDs: [String] { Self.lock.lock(); defer { Self.lock.unlock() }; return Set(data.expected.keys).subtracting(listed(data.imported)).sorted() }
    /// Received more than once, an object and its converted copy included.
    @objc public var duplicateUIDs: [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let counts = (data.derived ?? [:]).isEmpty ? data.received
            : Dictionary(data.received.map { (listed([$0.key]).first ?? $0.key, $0.value) }, uniquingKeysWith: +)
        return Set(counts.filter { $0.value > 1 }.keys).union(data.duplicateInventory).sorted()
    }
    @objc public var rejectedUIDs: [String] { Self.lock.lock(); defer { Self.lock.unlock() }; return Set(data.rejected.keys).union(data.httpRejected ?? []).union(data.peerFailed ?? []).sorted() }
    @objc public var unexpectedUIDs: [String] { Self.lock.lock(); defer { Self.lock.unlock() }; return inventoryConfirmed ? listed(data.imported.union(data.received.keys)).subtracting(data.expected.keys).sorted() : [] }
    /// Whether the inventory still describes what the peer reports now: the count it gave when
    /// the inventory was queried has not changed. A manifest from before #790 kept no count, and
    /// stands only when what it listed matches.
    @objc(matchesReportedCount:)
    public func matchesReportedCount(_ count: Int) -> Bool {
        inventoryConfirmed && (count <= 0 || count == (reportedCount > 0 ? reportedCount : expectedCount))
    }
    /// What the peer said it holds when the inventory was queried; 0 when it did not say.
    @objc public var reportedCount: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return data.reported ?? 0 }
    /// Instances the peer counts but does not list at the IMAGE level (#790).
    @objc public var unlistedCount: Int { max(reportedCount - expectedCount, 0) }
    /// Series the peer counts instances in but lists none of.
    @objc public var emptySeries: [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let listed = data.seriesListed ?? [:]
        return (data.seriesReported ?? [:]).filter { $0.value > 0 && (listed[$0.key] ?? 0) == 0 }.keys.sorted()
    }
    /// Everything the peer lists and can send is here: what it counts without listing, and
    /// what it declared it cannot send, are expected absences, not missing (#790, #692). A
    /// retrieve that is not forced has nothing more to ask for.
    @objc public var isSatisfied: Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return inventoryConfirmed && expectedCount > 0 && Set(missingUIDs).subtracting(expectedAbsent).isEmpty
    }
    /// The absences a satisfied inventory allows: counted without being listed, or not sendable.
    @objc public var expectedAbsenceCount: Int { unlistedCount + unsendableUIDs.count }
    @objc public var queriedAt: Date { Self.lock.lock(); defer { Self.lock.unlock() }; return data.queried ?? data.updated }
    @objc public var isComplete: Bool { inventoryConfirmed && expectedCount > 0 && missingUIDs.isEmpty }
    @objc public var missingSeries: [String: [String]] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Dictionary(grouping: missingUIDs, by: { data.expected[$0] ?? "" })
    }
    @objc public var summary: String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if !inventoryConfirmed {
            let listing = ["failed": " The listing of the server's instances failed.", "cancelled": " The listing of the server's instances was cancelled.",
                           "in progress": " The listing of the server's instances is still in progress."][data.discovery ?? ""] ?? ""
            return "Inventory unconfirmed: \(localUniqueCount) local unique instances; \(expectedCount) UIDs announced." + listing + " Completeness cannot be established."
        }
        let total = String(expectedCount)
        let leftOut = excludedUIDs
        let state = isComplete ? "Complete" : isSatisfied ? "Complete but for expected absences" :
            !leftOut.isEmpty && leftOut.count == expectedCount ? "Not retrieved: the node's rules leave out every series" :
            !leftOut.isEmpty && Set(missingUIDs).subtracting(leftOut).subtracting(expectedAbsent).isEmpty
            ? "Retrieved but for the series the node's rules leave out; the study is not complete" : "Incomplete"
        var text = "\(state): \(importedCount) of \(total) unique instances imported; \(missingUIDs.count) missing (\(unsendableUIDs.count) the server cannot send), \(duplicateUIDs.count) duplicated, \(rejectedUIDs.count) with recorded rejections, \(data.storageWarnings?.count ?? 0) with storage warnings, \(unexpectedUIDs.count) unexpected."
        let untrusted = Set((data.tlsUntrusted ?? [:]).keys).intersection(missingUIDs)
        if !untrusted.isEmpty {
            text += " \(untrusted.count) not retrieved because the server's certificate is not trusted."
        }
        let byClass = unsendableClasses
        if !byClass.isEmpty {
            let offeredNot = data.unoffered ?? []
            text += " Not sent by the server: " + byClass.sorted { $0.key < $1.key }.map { sopClass, count in
                let notOffered = sopClass.isEmpty ? false : unsendableUIDs.contains { data.sopClasses?[$0] == sopClass && offeredNot.contains($0) }
                return "\(count) of \(sopClass.isEmpty ? "an unknown class" : sopClass)" + (notOffered ? ", a class this retrieve does not offer to receive" : "")
            }.joined(separator: "; ") + "."
        }
        if let excluded = data.excluded, !excluded.isEmpty {
            text += " \(excluded.count) series left out by the node's rules, intentionally: " +
                excluded.sorted { $0.key < $1.key }.map { "\"\($0.value.first ?? "")\" (rule \"\($0.value.last ?? "")\")" }.joined(separator: ", ") +
                ". Retrieve a series by itself, or hold Option while retrieving, to include it."
        }
        if unlistedCount > 0 {
            let empty = emptySeries.count
            text += " The server reports \(reportedCount): \(unlistedCount) it counts but does not list" +
                (empty > 0 ? " (\(empty) series with no instances listed)" : "") + "."
        }
        return text
    }
}
