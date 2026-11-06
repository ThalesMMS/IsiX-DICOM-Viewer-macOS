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
import Testing
import IsiXContracts
@testable import IsiXDICOMNetwork

/// What is here, as the local database would answer: the instances of each
/// series of each study, counted on every read.
private final class StandInLocalSeries: LocalSeriesReading, @unchecked Sendable {
    private let lock = NSLock()
    private var series: [LocalSeriesSnapshot] = []
    private var failing = false
    private(set) var reads = 0

    func set(_ series: [LocalSeriesSnapshot], failing: Bool = false) {
        lock.withLock { self.series = series; self.failing = failing }
    }

    func series(ofStudyInstanceUID studyInstanceUID: String) throws -> [LocalSeriesSnapshot] {
        try lock.withLock {
            reads += 1
            if failing { throw CocoaError(.fileReadUnknown) }
            return series.filter { $0.studyInstanceUID == studyInstanceUID }
        }
    }

    func fileCount(ofStudy study: LocalRecordIdentifier, seriesInstanceUID: String?) throws -> Int { 0 }
}

/// A database folder of its own, removed at the end.
private final class Folder {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("isix-retrieve-inventory-\(UUID().uuidString)", isDirectory: true).path
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

private func listing(_ count: Int, study: String = "1.2", series: String = "1.3") -> [RetrieveListedInstance] {
    (1...count).map { RetrieveListedInstance(sopInstanceUID: "\(study).\($0)", seriesInstanceUID: series) }
}

/// The retrieve inventory: what the node listed, what arrived and what is
/// here, and from them what a retrieve still asks for and how it is judged.
struct RetrieveInventoryTests {

    @Test func completenessFollowsWhatIsHereNotWhatArrived() throws {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = store.begin(study: "1.1", series: "", endpoint: "PACS@localhost:104", database: folder.path,
                                    instances: listing(10), confirmed: true)
        for i in 1...8 { inventory.record(uid: "1.2.\(i)", status: 0) }
        inventory.record(uid: "1.2.1", status: 0)
        inventory.record(uid: "1.2.9", status: 0xa900)
        inventory.updateImportedUIDs((1...8).map { "1.2.\($0)" } + ["9.8", "9.9"])
        #expect(inventory.importedCount == 8 && inventory.localUniqueCount == 10 && !inventory.isComplete && inventory.needsAttention)
        #expect(inventory.missingUIDs == ["1.2.10", "1.2.9"] && inventory.duplicateUIDs == ["1.2.1"])
        #expect(inventory.rejectedUIDs == ["1.2.9"] && inventory.unexpectedUIDs == ["9.8", "9.9"])
        // A second pass asks only for what neither arrived nor is here.
        #expect(inventory.retrySeries(afterRound: 0, cancelled: false) == ["1.3": ["1.2.10", "1.2.9"]])
        #expect(inventory.retrySeries(afterRound: 2, cancelled: false).isEmpty)
        #expect(inventory.retrySeries(afterRound: 0, cancelled: true).isEmpty)
        inventory.finish()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inventory.path))) as? [String: Any]
        #expect(manifest?["missingUIDs"] as? [String] == inventory.missingUIDs)
        #expect(manifest?["unlistedCount"] as? Int == 0)
    }

    @Test func anInstanceWithoutItsUIDOrSeriesLeavesTheListingUnconfirmed() {
        let folder = Folder(), store = RetrieveInventoryStore()
        var rows = listing(3)
        rows.append(RetrieveListedInstance(sopInstanceUID: "1.2.9", seriesInstanceUID: ""))
        let inventory = store.begin(study: "2.1", series: "", endpoint: "PACS", database: folder.path, instances: rows, confirmed: true)
        #expect(!inventory.inventoryConfirmed && inventory.expectedCount == 3 && inventory.needsAttention)
        #expect(inventory.retrySeries(afterRound: 0, cancelled: false).isEmpty)
        inventory.finish()
    }

    @Test func everyRetrieveOfTheSameStudySharesOneInventoryUntilNoOneHoldsIt() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let first = store.begin(study: "5.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(3), confirmed: true)
        let second = store.begin(study: "5.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(3), confirmed: true)
        #expect(first === second)
        #expect(store.load(study: "5.1", series: "", endpoint: "PACS", database: folder.path) === first)
        #expect(store.load(study: "5.1", series: "1.3", endpoint: "PACS", database: folder.path) == nil)
        first.finish()
        second.finish()
        weak var released: RetrieveInventory?
        autoreleasepool {
            let temporary = store.begin(study: "4.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(3), confirmed: true)
            released = temporary
            temporary.record(uid: "1.2.1", status: 0)
            temporary.finish()
        }
        #expect(released == nil)
        // Read again from its manifest, with what it had received.
        let again = store.load(study: "4.1", series: "", endpoint: "PACS", database: folder.path)
        #expect(again?.expectedCount == 3 && again?.inventoryConfirmed == true)
    }

    @Test func storesTheListenerCompletesReachOnlyTheInventoriesThatReceive() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let receiving = store.begin(study: "3.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(3), confirmed: true)
        let other = store.begin(study: "3.2", series: "", endpoint: "PACS", database: folder.path,
                                instances: listing(3, study: "3.2"), confirmed: true)
        other.finish()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            store.storeCompleted(uid: "1.2.1", status: 0, study: "3.1", series: "1.3")
        }
        store.storeCompleted(uid: "3.2.1", status: 0, study: "3.2", series: "1.3")
        #expect(receiving.duplicateUIDs == ["1.2.1"] && receiving.receivedAwaitingImportCount == 1)
        #expect(other.receivedAwaitingImportCount == 0)
        // A failed store of a listed instance counts without its study.
        store.storeCompleted(uid: "1.2.2", status: 0xa700, study: "", series: "")
        #expect(receiving.rejectedUIDs == ["1.2.2"])
        receiving.finish()
    }

    @Test func aRefreshReadsWhatIsHereOnlyAfterTheDatabaseChanged() throws {
        let folder = Folder(), store = RetrieveInventoryStore(), local = StandInLocalSeries()
        let inventory = store.begin(study: "1.2", series: "1.3", endpoint: "PACS", database: folder.path, instances: listing(3), confirmed: true)
        #expect(inventory.beginImportRefresh() && !inventory.beginImportRefresh())
        store.databaseChanged()
        #expect(inventory.beginImportRefresh() && !inventory.beginImportRefresh())
        inventory.invalidateImportRefresh()
        #expect(inventory.beginImportRefresh())

        local.set([LocalSeriesSnapshot(studyInstanceUID: "1.2", seriesInstanceUID: "1.3", sopInstanceUIDs: ["1.2.1", "1.2.2"]),
                   LocalSeriesSnapshot(studyInstanceUID: "1.2", seriesInstanceUID: "1.4", sopInstanceUIDs: ["1.2.3"])])
        #expect(try inventory.refreshImported(from: local))
        // Only its series is read as here.
        #expect(inventory.importedCount == 2 && inventory.missingUIDs == ["1.2.3"])
        #expect(try !inventory.refreshImported(from: local))
        local.set([], failing: true)
        #expect(throws: CocoaError.self) { try inventory.refreshImported(from: local) }
        #expect(inventory.importedCount == 2)
        inventory.finish()
    }

    @Test func whatThePeerCannotSendIsAnExpectedAbsenceNotAskedForAgain() {
        let folder = Folder(), store = RetrieveInventoryStore()
        var rows = listing(4)
        rows[3].offered = false
        rows[3].sopClassUID = "1.2.840.10008.5.1.4.1.1.4.1"
        let inventory = store.begin(study: "6.1", series: "", endpoint: "PACS", database: folder.path, instances: rows, confirmed: true)
        inventory.record(uid: "1.2.1", status: 0)
        // The C-GET asked for three, one failed and none was refused here.
        #expect(!inventory.recordUnsent(requested: ["1.2.1", "1.2.2", "1.2.3"], series: "", status: 0xB000, failed: 2, remaining: 0))
        #expect(inventory.recordUnsent(requested: ["1.2.4"], series: "", status: 0xB000, failed: 1, remaining: 0))
        inventory.updateImportedUIDs(["1.2.1", "1.2.2", "1.2.3"])
        #expect(inventory.unsendableUIDs == ["1.2.4"] && inventory.isSatisfied && !inventory.isComplete)
        #expect(inventory.nothingLeftToAsk && inventory.expectedAbsenceCount == 1)
        #expect(inventory.unsendableClasses == ["1.2.840.10008.5.1.4.1.1.4.1": 1])
        #expect(inventory.summary.hasPrefix("Complete but for expected absences: 3 of 4 unique instances imported"))
        inventory.forgetPeerFailures()
        #expect(inventory.unsendableUIDs.isEmpty && !inventory.isSatisfied)
        inventory.finish()
    }

    @Test func theProgressOfAnOperationCountsWhatArrivedOfWhatItAskedFor() {
        let folder = Folder(), store = RetrieveInventoryStore()
        var rows = listing(4)
        rows[2].seriesInstanceUID = "1.4"
        rows[3].seriesInstanceUID = "1.4"
        let inventory = store.begin(study: "7.1", series: "", endpoint: "PACS", database: folder.path, instances: rows, confirmed: true)
        inventory.record(uid: "1.2.1", status: 0)
        inventory.record(uid: "1.2.3", status: 0)
        #expect(inventory.arrivals(requested: [], series: "") == [2, 4])
        #expect(inventory.arrivals(requested: [], series: "1.4") == [1, 2])
        #expect(inventory.arrivals(requested: ["1.2.1"], series: "") == [1, 1])
        inventory.exclude(series: ["1.4": ["Scout", "no scouts"]])
        #expect(inventory.scopeExpectedCount == 2 && inventory.arrivals(requested: [], series: "") == [1, 2])
        #expect(inventory.unreceivedSeries == ["1.3": ["1.2.2"]])
        inventory.finish()
    }

    @Test func aCopyUnderANewUIDStandsForTheInstanceItCameFrom() {
        let folder = Folder(), store = RetrieveInventoryStore()
        var rows = listing(2)
        rows[0].sopClassUID = "1.2.840.10008.5.1.4.1.1.2"
        rows[0].instanceNumber = " 7 "
        let inventory = store.begin(study: "8.1", series: "", endpoint: "PACS", database: folder.path, instances: rows, confirmed: true)
        inventory.record(uid: "9.9.1", status: 0, series: "1.3", sopClass: "1.2.840.10008.5.1.4.1.1.2", instanceNumber: "7")
        inventory.record(uid: "9.9.2", status: 0, sources: ["1.2.2"])
        inventory.updateImportedUIDs(["9.9.1", "9.9.2"])
        #expect(inventory.isComplete && inventory.unexpectedUIDs.isEmpty)
        #expect(inventory.sourceUIDs(ofDerived: ["9.9.1", "9.9.2", "x"]) == ["1.2.1", "1.2.2"])
        inventory.finish()
    }

    @Test func theWaitEndsOnceWhatArrivedIsHere() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = store.begin(study: "9.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(2), confirmed: true)
        inventory.updateImportedUIDs([])
        inventory.record(uid: "1.2.1", status: 0)
        inventory.record(uid: "1.2.2", status: 0)
        var refreshes = 0
        #expect(inventory.waitForReceivedImports(refreshing: {
            refreshes += 1
            if refreshes == 3 { inventory.updateImportedUIDs(["1.2.1", "1.2.2"]) }
        }, patience: 5, cancelled: { false }))
        #expect(refreshes == 3 && inventory.isComplete)
        inventory.updateImportedUIDs([])
        #expect(!inventory.waitForReceivedImports(refreshing: {}, patience: 5, cancelled: { true }))
        inventory.finish()
    }

    // Each look asks for a pass, which starts at once and ends quickly with
    // nothing to do. An instance that never reaches the index must still end
    // the wait: that pass is not an import worth waiting for.
    @Test func thePassEachLookAsksForDoesNotHoldTheWait() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = store.begin(study: "9.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(1), confirmed: true)
        inventory.updateImportedUIDs([])
        inventory.record(uid: "1.2.1", status: 0)
        var passEnds = 0.0
        var gaveUp = false
        let start = ProcessInfo.processInfo.systemUptime
        #expect(!inventory.waitForReceivedImports(refreshing: {
            passEnds = ProcessInfo.processInfo.systemUptime + 0.05
        }, importInProgress: {
            ProcessInfo.processInfo.systemUptime < passEnds
        }, patience: 0.5, cancelled: {
            gaveUp = ProcessInfo.processInfo.systemUptime - start > 5
            return gaveUp
        }))
        #expect(!gaveUp)
        inventory.finish()
    }

    @Test func anImportThatOutlastsTheLookKeepsTheWait() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = store.begin(study: "9.1", series: "", endpoint: "PACS", database: folder.path, instances: listing(1), confirmed: true)
        inventory.updateImportedUIDs([])
        inventory.record(uid: "1.2.1", status: 0)
        let start = ProcessInfo.processInfo.systemUptime
        var imported = false
        #expect(inventory.waitForReceivedImports(refreshing: {
            if ProcessInfo.processInfo.systemUptime - start > 1 {
                inventory.updateImportedUIDs(["1.2.1"])
                imported = true
            }
        }, importInProgress: { true }, patience: 0.3, cancelled: { false }))
        #expect(imported)
        inventory.finish()
    }

    @Test func aManifestOfAnUnknownVersionIsNotRead() throws {
        let folder = Folder(), store = RetrieveInventoryStore()
        let path = RetrieveInventoryStore.path(study: "10.1", series: "", endpoint: "PACS", database: folder.path)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(#"{"version":2,"study":"10.1","series":"","expected":{},"inventoryConfirmed":true}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        #expect(store.load(study: "10.1", series: "", endpoint: "PACS", database: folder.path) == nil)
    }
}
