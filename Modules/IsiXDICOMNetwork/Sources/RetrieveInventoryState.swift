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

/// The decisions of a retrieve inventory, as a value: what the node listed,
/// what this attempt received or was refused, what is here, and from them
/// what is missing, what a second pass asks for and how the retrieve is judged.
///
/// `RetrieveInventory` holds one behind its lock; nothing here waits, reads the
/// disk or the database.
struct RetrieveInventoryState: Sendable {
    var record: RetrieveInventoryRecord
    /// The Core Data revision the imported identities were last refreshed at.
    var lastImportRevision: UInt?
    /// The retrieves that receive into this inventory now.
    var receivers = 0
    var attemptReceived: Set<String> = []
    var attemptRefused: Set<String> = []
    var baselineImported: Set<String>?
    /// Instances the peer had already declared it cannot send when this attempt began:
    /// their absence was reported by the attempt that found it.
    var knownUnsendable: Set<String> = []

    init(record: RetrieveInventoryRecord) {
        self.record = record
    }

    var receiving: Bool { receivers > 0 }

    // MARK: The listing

    /// What the node listed, read as `begin` reads it: a new record of
    /// `study` and `series`, unconfirmed when an instance lacks its UID or
    /// series, or when nothing was listed.
    static func listing(study: String, series: String, instances: [RetrieveListedInstance], confirmed: Bool,
                        reported: Int, seriesReported: [String: Int]) -> RetrieveInventoryRecord {
        var record = RetrieveInventoryRecord(study: study, series: series, expected: [:], inventoryConfirmed: confirmed)
        for item in instances {
            guard !item.sopInstanceUID.isEmpty, !item.seriesInstanceUID.isEmpty else {
                record.inventoryConfirmed = false
                continue
            }
            let uid = item.sopInstanceUID
            if record.expected[uid] != nil { record.duplicateInventory.insert(uid) }
            record.expected[uid] = item.seriesInstanceUID
            if let sopClass = item.sopClassUID, !sopClass.isEmpty { record.sopClasses?[uid] = sopClass }
            if let number = instanceNumber(item.instanceNumber) {
                if record.numbers == nil { record.numbers = [:] }
                record.numbers?[uid] = number
            }
            if !item.offered { record.unoffered?.insert(uid) }
        }
        if record.expected.isEmpty { record.inventoryConfirmed = false }
        record.reported = max(reported, 0)
        record.seriesReported = seriesReported
        record.seriesListed = Dictionary(grouping: record.expected.values, by: { $0 }).mapValues { $0.count }
        return record
    }

    /// A new listing for this inventory: what earlier attempts received,
    /// were refused or learned of the peer is kept; a retrieve that is not
    /// already receiving into it starts a new attempt.
    mutating func begin(_ listing: RetrieveInventoryRecord) {
        var next = listing
        next.received = record.received
        next.rejected = record.rejected
        next.storageWarnings = record.storageWarnings
        next.httpRejected = record.httpRejected
        next.tlsUntrusted = record.tlsUntrusted
        next.peerResponses = record.peerResponses
        next.peerFailed = record.peerFailed
        next.derived = record.derived
        next.unreferenced = record.unreferenced
        record = next
        if !receiving {
            attemptReceived = []
            attemptRefused = []
            baselineImported = nil
            knownUnsendable = expectedAbsent
        }
        lastImportRevision = nil
        receivers += 1
    }

    /// What the peer listed, once the listing that ran beside the transfer
    /// has ended: the same reading as `begin`, keeping what this attempt has
    /// received, refused or imported.
    mutating func confirm(instances: [RetrieveListedInstance], confirmed: Bool, reported: Int,
                          seriesReported: [String: Int], discovery: String) {
        var expected: [String: String] = [:]
        var duplicates = Set<String>()
        var classes: [String: String] = [:]
        var numbers: [String: Int] = [:]
        var unoffered = Set<String>()
        var valid = confirmed
        for item in instances {
            guard !item.sopInstanceUID.isEmpty, !item.seriesInstanceUID.isEmpty else { valid = false; continue }
            let uid = item.sopInstanceUID
            if expected[uid] != nil { duplicates.insert(uid) }
            expected[uid] = item.seriesInstanceUID
            if let sopClass = item.sopClassUID, !sopClass.isEmpty { classes[uid] = sopClass }
            if let number = Self.instanceNumber(item.instanceNumber) { numbers[uid] = number }
            if !item.offered { unoffered.insert(uid) }
        }
        record.expected = expected
        record.duplicateInventory = duplicates
        record.sopClasses = classes
        record.numbers = numbers
        record.unoffered = unoffered
        record.inventoryConfirmed = valid && !expected.isEmpty
        record.reported = max(reported, 0)
        record.seriesReported = seriesReported
        record.seriesListed = Dictionary(grouping: expected.values, by: { $0 }).mapValues { $0.count }
        record.discovery = discovery
        record.derived = record.derived?.filter { expected[$0.key] == nil }
        record.unreferenced = record.unreferenced?.filter { expected[$0.key] == nil }
        matchUnreferenced()
        record.queried = Date()
        lastImportRevision = nil
    }

    /// An Instance Number as an integer; nil when there is none.
    static func instanceNumber(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Listed instances neither received in this attempt nor in the index,
    /// leaving out those the peer cannot send, by series: what a second pass
    /// still has to ask for.
    var unreceivedSeries: [String: [String]] {
        guard record.inventoryConfirmed else { return [:] }
        let left = Set(record.expected.keys).subtracting(listed(record.imported))
            .subtracting(listed(attemptReceived)).subtracting(expectedAbsent).subtracting(excludedUIDs)
        return Dictionary(grouping: left.sorted(), by: { record.expected[$0] ?? "" })
    }

    /// Listed instances of the series left out.
    var excludedUIDs: Set<String> {
        guard let excluded = record.excluded, !excluded.isEmpty else { return [] }
        return Set(record.expected.filter { excluded[$0.value] != nil }.keys)
    }

    var scopeExpectedCount: Int { record.expected.count - excludedUIDs.count }
    var scopeImportedCount: Int {
        Set(record.expected.keys).subtracting(excludedUIDs).intersection(listed(record.imported)).count
    }

    // MARK: What arrives

    mutating func record(uid: String, status: Int) {
        if status == 0 || (status & 0xf000) == 0xb000 {
            record.received[uid, default: 0] += 1
            attemptReceived.insert(uid)
            record.tlsUntrusted?[uid] = nil
        }
        if (status & 0xf000) == 0xb000 {
            var warnings = record.storageWarnings ?? [:]
            warnings[uid, default: []].append(status)
            record.storageWarnings = warnings
        } else if status != 0 {
            record.rejected[uid, default: []].append(status)
            attemptRefused.insert(uid)
        }
    }

    /// Whether a store the listener completed is one of this inventory's: an
    /// instance it lists that failed or came without its study, or an
    /// instance of its study (and series).
    func concerns(uid: String, status: Int, study: String, series: String) -> Bool {
        ((study.isEmpty || status != 0) && record.expected[uid] != nil)
            || (study == record.study && (record.series.isEmpty || record.series == series))
    }

    mutating func record(uid: String, status: Int, sources: [String]) {
        let named = sources.filter { !$0.isEmpty && $0 != uid }
        if !named.isEmpty && !(record.inventoryConfirmed && record.expected[uid] != nil) {
            if record.derived == nil { record.derived = [:] }
            record.derived?[uid] = named
        }
        self.record(uid: uid, status: status)
    }

    mutating func record(uid: String, status: Int, series: String, sopClass: String, instanceNumber: String) {
        let unlisted = !(record.inventoryConfirmed && record.expected[uid] != nil)
        if let number = Self.instanceNumber(instanceNumber), !series.isEmpty, !sopClass.isEmpty, unlisted {
            if record.unreferenced == nil { record.unreferenced = [:] }
            record.unreferenced?[uid] = [series, sopClass, String(number)]
        }
        self.record(uid: uid, status: status)
        if record.inventoryConfirmed && record.unreferenced?[uid] != nil { matchUnreferenced() }
    }

    /// Matches each unreferenced object the listing does not name to the one
    /// listed instance with its series, SOP class and Instance Number that
    /// has not arrived in this attempt or in the index, neither by its own
    /// UID nor through another copy. A matched object moves to `derived`, as
    /// if its Source Image Sequence named that instance; one with no such
    /// instance, or more than one, stays where it is and stands for itself.
    mutating func matchUnreferenced() {
        guard record.inventoryConfirmed, let unreferenced = record.unreferenced, !unreferenced.isEmpty else { return }
        var keys: [[String]: [String]] = [:]
        for (uid, series) in record.expected {
            guard let sopClass = record.sopClasses?[uid], let number = record.numbers?[uid] else { continue }
            keys[[series, sopClass, String(number)], default: []].append(uid)
        }
        for uid in unreferenced.keys.sorted() where record.expected[uid] == nil {
            guard let key = unreferenced[uid], let candidates = keys[key], candidates.count == 1 else { continue }
            let arrived = record.imported.union(attemptReceived).subtracting([uid])
            guard !listed(arrived).contains(candidates[0]) else { continue }
            if record.derived == nil { record.derived = [:] }
            record.derived?[uid] = candidates
            record.unreferenced?[uid] = nil
        }
    }

    /// The instances the objects `uids` stand for: each one the listing
    /// names stands for itself, and one it does not name, received with a
    /// Source Image Sequence that names a listed instance, for that instance.
    func listed(_ uids: Set<String>) -> Set<String> {
        guard let derived = record.derived, !derived.isEmpty else { return uids }
        return Set(uids.map { uid in
            record.expected[uid] != nil ? uid : derived[uid]?.first { record.expected[$0] != nil } ?? uid
        })
    }

    func sourceUIDs(ofDerived uids: [String]) -> [String] {
        guard let derived = record.derived, !derived.isEmpty else { return [] }
        return Array(Set(uids.flatMap { derived[$0] ?? [] })).sorted()
    }

    mutating func recordPeerFailedUID(_ uid: String) {
        if record.peerFailed == nil { record.peerFailed = [] }
        record.peerFailed?.insert(uid)
    }

    /// See `RetrieveInventory.recordUnsent`.
    mutating func recordUnsent(requested: [String], series: String, status: UInt, failed: UInt, remaining: UInt) -> Bool {
        guard [0x0000, 0xB000, 0xA702].contains(status), failed > 0, remaining == 0 else { return false }
        let asked = requested.isEmpty
            ? Set(record.expected.filter { series.isEmpty || $0.value == series }.keys)
            : Set(requested.filter { !$0.isEmpty })
        let refusedHere = asked.intersection(attemptRefused).count
        let unsent = asked.subtracting(attemptReceived).subtracting(attemptRefused)
        guard !unsent.isEmpty, unsent.count == Int(failed) - refusedHere else { return false }
        record.peerFailed = (record.peerFailed ?? []).union(unsent)
        return refusedHere == 0 && unsent.isSubset(of: record.unoffered ?? [])
    }

    mutating func forgetPeerFailures() {
        record.peerFailed = []
        record.unoffered = []
        knownUnsendable = []
    }

    /// What will not arrive by asking: what the peer declared it cannot send, and instances of
    /// classes this retrieve does not offer to receive.
    var expectedAbsent: Set<String> { (record.peerFailed ?? []).union(record.unoffered ?? []) }

    mutating func recordHTTPRejectedUID(_ uid: String) {
        if record.httpRejected == nil { record.httpRejected = [] }
        record.httpRejected?.insert(uid)
    }

    mutating func recordTLSUntrustedUID(_ uid: String, reason: String) {
        if record.tlsUntrusted == nil { record.tlsUntrusted = [:] }
        record.tlsUntrusted?[uid] = reason
    }

    mutating func record(operation: String, status: UInt, completed: UInt, failed: UInt, warnings: UInt, remaining: UInt) {
        if record.peerResponses == nil { record.peerResponses = [] }
        record.peerResponses?.append(["operation": operation, "status": String(status), "completed": String(completed),
                                      "failed": String(failed), "warnings": String(warnings), "remaining": String(remaining)])
    }

    /// Returns whether the imported identities changed.
    mutating func updateImportedUIDs(_ uids: [String]) -> Bool {
        let imported = Set(uids.filter { !$0.isEmpty })
        if receiving && baselineImported == nil { baselineImported = imported }
        guard imported != record.imported else { return false }
        record.imported = imported
        return true
    }

    func arrivals(requested: [String], series: String) -> [Int] {
        let asked: Set<String>
        if !requested.isEmpty {
            asked = Set(requested)
        } else {
            asked = Set(record.expected.filter { series.isEmpty || $0.value == series }.keys).subtracting(excludedUIDs)
        }
        return [listed(attemptReceived).intersection(asked).count, asked.count]
    }

    var receivedAwaitingImportCount: Int {
        listed(attemptReceived).intersection(record.expected.keys).subtracting(listed(record.imported)).count
    }

    // MARK: How the retrieve is judged

    var inventoryConfirmed: Bool { record.inventoryConfirmed }
    var expectedCount: Int { record.expected.count }
    var localUniqueCount: Int { record.imported.count }

    var needsAttention: Bool {
        if !inventoryConfirmed && record.discovery == "not supported" { return false }
        return !inventoryConfirmed || !Set(missingUIDs).subtracting(listed(attemptReceived)).subtracting(listed(baselineImported ?? []))
            .subtracting(knownUnsendable).subtracting(excludedUIDs).isEmpty
    }

    var unsendableUIDs: [String] { Set(missingUIDs).intersection(expectedAbsent).sorted() }

    var unsendableClasses: [String: Int] {
        Dictionary(grouping: unsendableUIDs, by: { record.sopClasses?[$0] ?? "" }).mapValues { $0.count }
    }

    func retrySeries(afterRound round: Int, cancelled: Bool) -> [String: [String]] {
        guard !cancelled, (0..<2).contains(round), inventoryConfirmed else { return [:] }
        let missing = Set(missingUIDs).subtracting(listed(attemptReceived))
            .subtracting(knownUnsendable).subtracting(record.unoffered ?? []).subtracting(excludedUIDs)
        return Dictionary(grouping: missing.sorted(), by: { record.expected[$0] ?? "" })
            .filter { !$0.key.isEmpty }
    }

    var nothingLeftToAsk: Bool {
        inventoryConfirmed && expectedCount > 0 &&
            Set(missingUIDs).subtracting(listed(attemptReceived)).subtracting(expectedAbsent).isEmpty
    }

    var importedCount: Int { Set(record.expected.keys).intersection(listed(record.imported)).count }
    var missingUIDs: [String] { Set(record.expected.keys).subtracting(listed(record.imported)).sorted() }

    var duplicateUIDs: [String] {
        let counts = (record.derived ?? [:]).isEmpty ? record.received
            : Dictionary(record.received.map { (listed([$0.key]).first ?? $0.key, $0.value) }, uniquingKeysWith: +)
        return Set(counts.filter { $0.value > 1 }.keys).union(record.duplicateInventory).sorted()
    }

    var rejectedUIDs: [String] {
        Set(record.rejected.keys).union(record.httpRejected ?? []).union(record.peerFailed ?? []).sorted()
    }

    var unexpectedUIDs: [String] {
        inventoryConfirmed ? listed(record.imported.union(record.received.keys)).subtracting(record.expected.keys).sorted() : []
    }

    func matchesReportedCount(_ count: Int) -> Bool {
        inventoryConfirmed && (count <= 0 || count == (reportedCount > 0 ? reportedCount : expectedCount))
    }

    var reportedCount: Int { record.reported ?? 0 }
    var unlistedCount: Int { max(reportedCount - expectedCount, 0) }

    var emptySeries: [String] {
        let listed = record.seriesListed ?? [:]
        return (record.seriesReported ?? [:]).filter { $0.value > 0 && (listed[$0.key] ?? 0) == 0 }.keys.sorted()
    }

    var isSatisfied: Bool {
        inventoryConfirmed && expectedCount > 0 && Set(missingUIDs).subtracting(expectedAbsent).isEmpty
    }

    var expectedAbsenceCount: Int { unlistedCount + unsendableUIDs.count }
    var queriedAt: Date { record.queried ?? record.updated }
    var isComplete: Bool { inventoryConfirmed && expectedCount > 0 && missingUIDs.isEmpty }
    var missingSeries: [String: [String]] { Dictionary(grouping: missingUIDs, by: { record.expected[$0] ?? "" }) }

    var summary: String {
        if !inventoryConfirmed {
            let listing = ["failed": " The listing of the server's instances failed.", "cancelled": " The listing of the server's instances was cancelled.",
                           "in progress": " The listing of the server's instances is still in progress.",
                           "not supported": " The server does not implement the listing of its series or instances; the whole study or series was retrieved without error."][record.discovery ?? ""] ?? ""
            return "Inventory unconfirmed: \(localUniqueCount) local unique instances; \(expectedCount) UIDs announced." + listing + " Completeness cannot be established."
        }
        let total = String(expectedCount)
        let leftOut = excludedUIDs
        let state = isComplete ? "Complete" : isSatisfied ? "Complete but for expected absences" :
            !leftOut.isEmpty && leftOut.count == expectedCount ? "Not retrieved: the node's rules leave out every series" :
            !leftOut.isEmpty && Set(missingUIDs).subtracting(leftOut).subtracting(expectedAbsent).isEmpty
            ? "Retrieved but for the series the node's rules leave out; the study is not complete" : "Incomplete"
        var text = "\(state): \(importedCount) of \(total) unique instances imported; \(missingUIDs.count) missing (\(unsendableUIDs.count) the server cannot send), \(duplicateUIDs.count) duplicated, \(rejectedUIDs.count) with recorded rejections, \(record.storageWarnings?.count ?? 0) with storage warnings, \(unexpectedUIDs.count) unexpected."
        let untrusted = Set((record.tlsUntrusted ?? [:]).keys).intersection(missingUIDs)
        if !untrusted.isEmpty {
            text += " \(untrusted.count) not retrieved because the server's certificate is not trusted."
        }
        let byClass = unsendableClasses
        if !byClass.isEmpty {
            let offeredNot = record.unoffered ?? []
            text += " Not sent by the server: " + byClass.sorted { $0.key < $1.key }.map { sopClass, count in
                let notOffered = sopClass.isEmpty ? false : unsendableUIDs.contains { record.sopClasses?[$0] == sopClass && offeredNot.contains($0) }
                return "\(count) of \(sopClass.isEmpty ? "an unknown class" : sopClass)" + (notOffered ? ", a class this retrieve does not offer to receive" : "")
            }.joined(separator: "; ") + "."
        }
        if let excluded = record.excluded, !excluded.isEmpty {
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

    /// The manifest as it is written: the record, `updated` now, and the
    /// reconciliation it leads to, not only its counters.
    mutating func manifest() throws -> Data {
        record.updated = Date()
        let encoded = try JSONEncoder().encode(record)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["missingUIDs"] = missingUIDs
        object["duplicateUIDs"] = duplicateUIDs
        object["rejectedUIDs"] = rejectedUIDs
        object["unexpectedUIDs"] = unexpectedUIDs
        object["emptySeries"] = emptySeries
        object["unlistedCount"] = unlistedCount
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
