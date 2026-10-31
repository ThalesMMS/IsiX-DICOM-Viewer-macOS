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
import Synchronization

/// Reconciles a remote identity inventory with transport events and local import.
/// The WADO download manifest describes HTTP attempts; this record describes the
/// study/series that the query window can actually prove is present locally.
///
/// The transfer, import and window threads share one inventory; its state is a
/// `RetrieveInventoryState` behind a mutex, and each call reads or changes it
/// whole. `RetrieveInventoryStore` makes, finds and forgets inventories. The
/// properties stay visible to Objective-C for the key-value reads of the
/// diagnostic probes.
@objc(IsiXRetrieveInventory)
public final class RetrieveInventory: NSObject, Sendable {
    private let state: Mutex<RetrieveInventoryState>
    private let store: RetrieveInventoryStore
    /// The manifest's file.
    @objc public let path: String

    init(record: RetrieveInventoryRecord, path: String, store: RetrieveInventoryStore) {
        state = Mutex(RetrieveInventoryState(record: record))
        self.path = path
        self.store = store
        super.init()
    }

    private func read<T>(_ body: (borrowing RetrieveInventoryState) -> T) -> T {
        state.withLock { body($0) }
    }

    /// Changes the state and writes the manifest, in one hold of the lock.
    private func change<T>(saving: Bool = true, _ body: (inout RetrieveInventoryState) -> T) -> T {
        state.withLock { state in
            let result = body(&state)
            if saving { Self.save(&state, to: path) }
            return result
        }
    }

    // MARK: Made and ended by the store

    /// Inside the store's lock: a new listing for this inventory.
    func begin(_ listing: RetrieveInventoryRecord) {
        change { $0.begin(listing) }
    }

    var isReceiving: Bool { read { $0.receiving } }

    /// The retrieve that began it has ended: it no longer receives, and the
    /// store forgets it once no retrieve does.
    @objc public func finish() {
        change { $0.receivers = max($0.receivers - 1, 0) }
        store.release(self)
    }

    /// A store the listener completed, given to every inventory that receives.
    func storeCompleted(uid: String, status: Int, study: String, series: String) {
        change(saving: false) { state in
            if state.receiving && state.concerns(uid: uid, status: status, study: study, series: series) {
                state.record(uid: uid, status: status)
            }
        }
    }

    private static func save(_ state: inout RetrieveInventoryState, to path: String) {
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The persistent record includes the exact reconciliation, not only counters.
            try state.manifest().write(to: url, options: .atomic)
        } catch {
            NSLog("Retrieve manifest could not be saved; in-memory reconciliation remains available")
        }
    }

    // MARK: What is here

    /// A repaint reuses the reconciled UID set until Core Data changes or saves state.
    @objc public func beginImportRefresh() -> Bool {
        let revision = store.importRevision.load(ordering: .relaxed)
        return change(saving: false) { state in
            guard state.lastImportRevision != revision else { return false }
            state.lastImportRevision = revision
            return true
        }
    }

    @objc public func invalidateImportRefresh() {
        change(saving: false) { $0.lastImportRevision = nil }
    }

    /// Returns whether the imported identities changed.
    @objc(updateImportedUIDs:) @discardableResult
    public func updateImportedUIDs(_ uids: [String]) -> Bool {
        state.withLock { state in
            let changed = state.updateImportedUIDs(uids)
            if changed { Self.save(&state, to: path) }
            return changed
        }
    }

    /// Reconciles the inventory with what the local database holds now, read
    /// through `reader`: the instances of its study, or of its series. Returns
    /// whether the imported identities changed; throws what the read threw,
    /// leaving them as they were.
    @discardableResult
    public func refreshImported(from reader: any LocalSeriesReading) throws -> Bool {
        let (study, series) = read { ($0.record.study, $0.record.series) }
        return updateImportedUIDs(try reader.sopInstanceUIDs(ofStudyInstanceUID: study, seriesInstanceUID: series))
    }

    // MARK: The listing

    /// Gives the inventory what the peer listed, once the listing that ran
    /// beside the transfer has ended: the same reading of `instances` as
    /// `begin`, keeping what this attempt has received, refused or imported.
    /// `confirmed` false (a failed or cancelled listing) leaves completeness
    /// unknown, whatever arrived.
    public func confirm(instances: [RetrieveListedInstance], confirmed: Bool, reported: Int,
                        seriesReported: [String: Int], discovery: String) {
        change { $0.confirm(instances: instances, confirmed: confirmed, reported: reported,
                            seriesReported: seriesReported, discovery: discovery) }
    }

    /// Marks the listing as running beside the transfer.
    public func markDiscovery(_ state: String) {
        change(saving: false) { $0.record.discovery = state }
    }

    /// "in progress", "confirmed", "failed", "cancelled" or "not supported"
    /// when the listing ran beside the transfer; empty when it ran before it.
    public var discoveryState: String { read { $0.record.discovery ?? "" } }

    /// What the peer listed: each SOP Instance UID with its series.
    public var expectedInstances: [String: String] { read { $0.record.expected } }

    /// Listed instances neither received in this attempt nor in the index,
    /// leaving out those the peer cannot send, by series: what a second pass
    /// still has to ask for.
    public var unreceivedSeries: [String: [String]] { read { $0.unreceivedSeries } }

    /// Records the series the node's rules left out of this attempt: the
    /// study is then retrieved but for them, not complete.
    public func exclude(series: [String: [String]]) {
        change { $0.record.excluded = series.isEmpty ? nil : series }
    }

    /// The series left out of the last attempt: `[description, rule]` by UID.
    public var excludedSeries: [String: [String]] { read { $0.record.excluded ?? [:] } }

    /// What this attempt asked for: the listed instances but those of the
    /// series left out, and how many of them are in the index.
    public var scopeExpectedCount: Int { read { $0.scopeExpectedCount } }
    public var scopeImportedCount: Int { read { $0.scopeImportedCount } }

    // MARK: What arrives

    public func record(uid: String, status: Int) {
        change(saving: false) { $0.record(uid: uid, status: status) }
    }

    /// Records an object whose Source Image Sequence names `sources`. One
    /// the listing does not name stands for the listed instance among them:
    /// it counts as that instance, which is then not asked for again.
    public func record(uid: String, status: Int, sources: [String]) {
        change(saving: false) { $0.record(uid: uid, status: status, sources: sources) }
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
    public func record(uid: String, status: Int, series: String, sopClass: String, instanceNumber: String) {
        change(saving: false) { $0.record(uid: uid, status: status, series: series, sopClass: sopClass, instanceNumber: instanceNumber) }
    }

    /// The instances that the local objects among `uids`, received under a
    /// new SOP Instance UID, came from, by their Source Image Sequence: a
    /// retrieve that finds such an object here does not ask for its source.
    public func sourceUIDs(ofDerived uids: [String]) -> [String] {
        read { $0.sourceUIDs(ofDerived: uids) }
    }

    public func recordPeerFailedUID(_ uid: String) {
        change(saving: false) { $0.recordPeerFailedUID(uid) }
    }

    /// After a C-GET, the instances it asked for that neither arrived nor were refused here are
    /// what the peer could not send, when they are as many as its failed sub-operations less
    /// those refused here. A peer that omits the Failed SOP Instance UID List (OsiriX, for a
    /// file it cannot convert) names them this way. `requested` empty means every instance of
    /// `series`, or of the study when that is empty. Only a final status that speaks of
    /// failed sub-operations (0xB000, 0xA702, or success) counts: a refusal of the whole
    /// request (0xC000, an IMAGE level the peer does not support) says nothing of any
    /// instance. A count that does not match, or sub-operations still remaining, records
    /// nothing.
    ///
    /// Returns whether what was not sent is all instances of classes this retrieve does not
    /// offer to receive: expected absences, nothing to report.
    @discardableResult
    public func recordUnsent(requested: [String], series: String, status: UInt, failed: UInt, remaining: UInt) -> Bool {
        change(saving: false) { $0.recordUnsent(requested: requested, series: series, status: status, failed: failed, remaining: remaining) }
    }

    /// Asks the peer again for what it declared it cannot send: a forced retrieve.
    public func forgetPeerFailures() {
        change(saving: false) { $0.forgetPeerFailures() }
    }

    public func recordHTTPRejectedUID(_ uid: String) {
        change(saving: false) { $0.recordHTTPRejectedUID(uid) }
    }

    /// A WADO instance not fetched because the server's certificate was not trusted.
    public func recordTLSUntrustedUID(_ uid: String, reason: String) {
        change(saving: false) { $0.recordTLSUntrustedUID(uid, reason: reason) }
    }

    public func record(operation: String, status: UInt, completed: UInt, failed: UInt, warnings: UInt, remaining: UInt) {
        change(saving: false) { $0.record(operation: operation, status: status, completed: completed, failed: failed,
                                          warnings: warnings, remaining: remaining) }
    }

    /// Of what one operation asks the peer for, how much this attempt has
    /// received: [received, asked]. It is the operation's progress when the
    /// peer counts no sub-operations. `requested` names instances; without
    /// it `series` names a series, and with neither the operation asks for
    /// all that is listed.
    public func arrivals(requested: [String], series: String) -> [Int] {
        read { $0.arrivals(requested: requested, series: series) }
    }

    /// Expected instances this attempt received that the index does not hold yet.
    @objc public var receivedAwaitingImportCount: Int { read { $0.receivedAwaitingImportCount } }

    /// Waits for what this attempt received to be in the index, refreshing the imported identities
    /// with `refresh`. Received files are indexed by the importer's timer, after the transfer has
    /// returned: judged at once, a retrieve that brought every instance was recorded as incomplete.
    /// An import or conversion can take longer than `patience` without committing
    /// any images. Count inactivity only while those workers are idle; cancellation still
    /// interrupts the wait immediately. Returns whether nothing is left waiting.
    ///
    /// Whether they are idle is asked before `refresh`, which may ask for the import
    /// again: asked after it, the short pass that request starts would count as a
    /// worker at every look, and an instance the import refused would never end the wait.
    @discardableResult
    public func waitForReceivedImports(refreshing refresh: () -> Void,
                                       importInProgress: () -> Bool = { false }, patience: TimeInterval,
                                       cancelled: () -> Bool) -> Bool {
        var awaiting = Int.max
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while true {
            let working = importInProgress()
            refresh()
            let count = receivedAwaitingImportCount
            if count == 0 { return true }
            if cancelled() { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if count < awaiting || working {
                awaiting = count
                lastProgress = now
            } else if now - lastProgress >= patience {
                return false
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: How the retrieve is judged

    @objc public var inventoryConfirmed: Bool { read { $0.inventoryConfirmed } }
    @objc public var expectedCount: Int { read { $0.expectedCount } }
    @objc public var localUniqueCount: Int { read { $0.localUniqueCount } }

    /// Whether the retrieve is to be reported incomplete. An inventory left
    /// unconfirmed only because the node does not implement the listing,
    /// after a retrieve of the whole study or series that ended without
    /// error, is not: there is nothing else to ask that node for.
    @objc public var needsAttention: Bool { read { $0.needsAttention } }

    /// Missing instances the peer declared it cannot send; a smart retrieve does not ask for them.
    @objc public var unsendableUIDs: [String] { read { $0.unsendableUIDs } }

    /// The missing instances the peer will not send, counted by SOP class.
    public var unsendableClasses: [String: Int] { read { $0.unsendableClasses } }

    /// Two additional IMAGE-level rounds repair omissions without repeating a whole study.
    /// Received objects still awaiting import and previously unavailable objects are not requested again.
    /// A failed sub-operation in this attempt may be transient, so it keeps its two recovery rounds.
    public func retrySeries(afterRound round: Int, cancelled: Bool) -> [String: [String]] {
        read { $0.retrySeries(afterRound: round, cancelled: cancelled) }
    }

    /// Every missing instance arrived in this attempt or is one the peer cannot send.
    @objc public var nothingLeftToAsk: Bool { read { $0.nothingLeftToAsk } }
    @objc public var importedCount: Int { read { $0.importedCount } }
    @objc public var missingUIDs: [String] { read { $0.missingUIDs } }
    /// Received more than once, an object and its converted copy included.
    @objc public var duplicateUIDs: [String] { read { $0.duplicateUIDs } }
    @objc public var rejectedUIDs: [String] { read { $0.rejectedUIDs } }
    @objc public var unexpectedUIDs: [String] { read { $0.unexpectedUIDs } }

    /// Whether the inventory still describes what the peer reports now: the count it gave when
    /// the inventory was queried has not changed. An older manifest kept no count, and
    /// stands only when what it listed matches.
    public func matchesReportedCount(_ count: Int) -> Bool {
        read { $0.matchesReportedCount(count) }
    }

    /// What the peer said it holds when the inventory was queried; 0 when it did not say.
    @objc public var reportedCount: Int { read { $0.reportedCount } }
    /// Instances the peer counts but does not list at the IMAGE level.
    @objc public var unlistedCount: Int { read { $0.unlistedCount } }
    /// Series the peer counts instances in but lists none of.
    @objc public var emptySeries: [String] { read { $0.emptySeries } }
    /// Everything the peer lists and can send is here: what it counts without listing, and
    /// what it declared it cannot send, are expected absences, not missing. A
    /// retrieve that is not forced has nothing more to ask for.
    @objc public var isSatisfied: Bool { read { $0.isSatisfied } }
    /// The absences a satisfied inventory allows: counted without being listed, or not sendable.
    @objc public var expectedAbsenceCount: Int { read { $0.expectedAbsenceCount } }
    @objc public var queriedAt: Date { read { $0.queriedAt } }
    @objc public var isComplete: Bool { read { $0.isComplete } }
    public var missingSeries: [String: [String]] { read { $0.missingSeries } }
    @objc public var summary: String { read { $0.summary } }
}
