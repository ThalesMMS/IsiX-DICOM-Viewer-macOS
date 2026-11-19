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
@testable import IsiXDICOMNetwork

/// A database folder of its own, removed at the end.
private final class Folder {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("isix-retrieve-listing-\(UUID().uuidString)", isDirectory: true).path
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// A retrieve from a node that lists no series or instances: how the listing
/// ended is kept, the node's own counters judge a transfer that ended clean,
/// and that verdict keeps the study from being retrieved again.
struct RetrieveListingTests {
    private let uids = (1...5).map { "7.2.\($0)" }

    /// A DIMSE retrieve of study 7.1 whose listing named nothing.
    private func begin(_ store: RetrieveInventoryStore, _ folder: Folder, listing: RetrieveListing?, status: UInt16? = nil,
                       reported: Int = 5, instances: [RetrieveListedInstance] = []) -> RetrieveInventory {
        store.begin(study: "7.1", series: "", endpoint: "PACS@peer:11112", database: folder.path, instances: instances,
                    confirmed: false, reported: reported, listing: listing, listingStatus: status)
    }

    /// The listener stores `uids` of the study, and the node ends its C-MOVE
    /// in success having completed as many sub-operations.
    private func arrive(_ store: RetrieveInventoryStore, _ inventory: RetrieveInventory, _ uids: [String], status: UInt = 0,
                        failed: UInt = 0, warnings: UInt = 0, remaining: UInt = 0, completed: UInt? = nil) {
        for uid in uids { store.storeCompleted(uid: uid, status: 0, study: "7.1", series: "7.3") }
        inventory.record(operation: "C-MOVE", status: status, completed: completed ?? UInt(uids.count), failed: failed,
                         warnings: warnings, remaining: remaining)
    }

    private func manifest(_ inventory: RetrieveInventory) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inventory.path))) as? [String: Any])
    }

    @Test func aStatusThatRefusesTheRequestIsNotAFailureOfTheListing() {
        for status: UInt16 in [0x0122, 0x0118, 0x0211, 0x0124, 0xA900, 0xC000, 0xC311, 0xCFFF] {
            #expect(RetrieveListing.refuses(findStatus: status), "\(status)")
        }
        // Success, pending, a cancellation, out of resources and what the
        // service does not define are not refusals of the request.
        for status: UInt16 in [0x0000, 0xFF00, 0xFF01, 0xFE00, 0xA700, 0x0110, 0xB000, 0xD000] {
            #expect(!RetrieveListing.refuses(findStatus: status), "\(status)")
        }
        #expect(RetrieveListing.text(ofStatus: 0xA900) == "0xA900" && RetrieveListing.text(ofStatus: 0x122) == "0x0122")
    }

    @Test func theListingSaysHowItEnded() {
        func outcome(_ listed: Int, confirmed: Bool = false, refused: Bool = false, failed: Bool = false,
                     cancelled: Bool = false) -> RetrieveListing {
            RetrieveListing.beforeTransfer(listed: listed, confirmed: confirmed, refused: refused, failedOtherwise: failed,
                                           cancelled: cancelled)
        }
        #expect(outcome(12, confirmed: true) == .confirmed)
        // No series, or series and no instance in any, with every C-FIND in success.
        #expect(outcome(0) == .empty && outcome(0, confirmed: true) == .empty)
        #expect(outcome(0, refused: true) == .notImplemented)
        // A level that failed might have named instances: the refusal of another does not excuse it.
        #expect(outcome(0, failed: true) == .failed && outcome(0, refused: true, failed: true) == .failed)
        #expect(outcome(0, refused: true, cancelled: true) == .cancelled)
        // An instance without its UID or series.
        #expect(outcome(3) == .failed)
        #expect(outcome(3, refused: true) == .notImplemented)
    }

    @Test(arguments: [(RetrieveListing.notImplemented, UInt16(0xA900)), (RetrieveListing.empty, UInt16(0))])
    func aCleanRetrieveFromANodeThatListsNothingIsJudgedByItsCounters(listing: RetrieveListing, status: UInt16) throws {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = begin(store, folder, listing: listing, status: listing == .notImplemented ? status : nil)
        inventory.updateImportedUIDs([])
        #expect(!inventory.inventoryConfirmed && inventory.expectedCount == 0 && inventory.listing == listing)
        arrive(store, inventory, uids)
        // What arrived is waited for although nothing is listed, and is not
        // judged before it is in the index.
        #expect(inventory.receivedAwaitingImportCount == 5)
        #expect(!inventory.judgeByPeerCounters() && inventory.needsAttention && !inventory.judgedByPeerCounters)
        var looks = 0
        #expect(inventory.waitForReceivedImports(refreshing: {
            looks += 1
            if looks == 2 { inventory.updateImportedUIDs(uids) }
        }, patience: 5, cancelled: { false }))
        #expect(inventory.receivedAwaitingImportCount == 0)
        #expect(inventory.judgeByPeerCounters() && inventory.judgedByPeerCounters)
        #expect(!inventory.needsAttention && !inventory.inventoryConfirmed && !inventory.isComplete)
        #expect(inventory.summary.contains("Completeness was judged by the server's counters, not by an inventory: 5 sub-operations completed"))
        #expect(!inventory.summary.contains("Completeness cannot be established"))
        #expect(inventory.summary.contains(listing == .empty ? "without naming any" : "refused the listing of its series or instances (C-FIND status 0xA900)"))
        inventory.finish()

        let written = try manifest(inventory)
        #expect(written["discovery"] as? String == listing.rawValue)
        #expect(written["listingStatus"] as? Int == (listing == .notImplemented ? 0xA900 : nil))
        let verdict = try #require(written["completeness"] as? [String: Any])
        #expect(verdict["judgedBy"] as? String == "peer counters")
        #expect(verdict["operations"] as? Int == 1 && verdict["completed"] as? Int == 5 && verdict["received"] as? Int == 5)
        #expect(verdict["indexed"] as? Int == 5 && verdict["reported"] as? Int == 5)
        #expect(written["inventoryConfirmed"] as? Bool == false)
    }

    @Test func aListingThatFailedKeepsTheRetrieveReported() throws {
        for listing in [RetrieveListing.failed, .cancelled, nil] {
            let folder = Folder(), store = RetrieveInventoryStore()
            let inventory = begin(store, folder, listing: listing)
            arrive(store, inventory, uids)
            inventory.updateImportedUIDs(uids)
            #expect(!inventory.judgeByPeerCounters() && inventory.needsAttention, "\(String(describing: listing))")
            #expect(inventory.summary.hasSuffix("Completeness cannot be established."))
            // With nothing listed and no word of the node, nothing is waited for.
            #expect(inventory.receivedAwaitingImportCount == 0)
            inventory.finish()
            #expect(try manifest(inventory)["completeness"] == nil)
        }
    }

    @Test func aListingThatNamedInstancesIsNotLeftToTheCounters() {
        let folder = Folder(), store = RetrieveInventoryStore()
        // One series answered and another was refused: what the study holds is not known.
        let inventory = begin(store, folder, listing: .notImplemented, status: 0xA900,
                              instances: uids.prefix(2).map { RetrieveListedInstance(sopInstanceUID: $0, seriesInstanceUID: "7.3") })
        arrive(store, inventory, uids)
        inventory.updateImportedUIDs(uids)
        #expect(inventory.expectedCount == 2 && !inventory.inventoryConfirmed)
        #expect(!inventory.judgeByPeerCounters() && inventory.needsAttention)
        #expect(inventory.summary.contains("2 UIDs announced. The server refused the listing of its series or instances (C-FIND status 0xA900). Completeness cannot be established."))
        inventory.finish()
    }

    @Test func subOperationsThatFailedWarnedOrWereLeftKeepTheRetrieveReported() {
        let cases: [(String, (RetrieveInventoryStore, RetrieveInventory) -> Void)] = [
            ("failed", { self.arrive($0, $1, Array(self.uids.prefix(3)), status: 0xB000, failed: 2) }),
            ("failed under a success status", { self.arrive($0, $1, Array(self.uids.prefix(3)), failed: 2) }),
            ("warned", { self.arrive($0, $1, self.uids, warnings: 1, completed: 4) }),
            ("left", { self.arrive($0, $1, Array(self.uids.prefix(4)), remaining: 1) }),
            ("refused whole", { self.arrive($0, $1, [], status: 0xC000) }),
            ("nothing completed", { self.arrive($0, $1, []) }),
            // The node counted five and three arrived: the rest went elsewhere.
            ("fewer arrived than counted", { self.arrive($0, $1, Array(self.uids.prefix(3)), completed: 5) }),
            ("one operation of two failed", {
                self.arrive($0, $1, Array(self.uids.prefix(2)), status: 0xB000, failed: 1)
                self.arrive($0, $1, Array(self.uids.suffix(3)))
            }),
            ("refused here", {
                self.arrive($0, $1, self.uids)
                $0.storeCompleted(uid: "7.2.9", status: 0xA900, study: "7.1", series: "7.3")
            }),
            ("no operation", { store, _ in for uid in self.uids { store.storeCompleted(uid: uid, status: 0, study: "7.1", series: "7.3") } }),
        ]
        for (name, transfer) in cases {
            let folder = Folder(), store = RetrieveInventoryStore()
            let inventory = begin(store, folder, listing: .notImplemented, status: 0xA900)
            transfer(store, inventory)
            inventory.updateImportedUIDs(uids + ["7.2.9"])
            #expect(!inventory.judgeByPeerCounters() && inventory.needsAttention && !inventory.judgedByPeerCounters, "\(name)")
            #expect(inventory.summary.hasSuffix("Completeness cannot be established."), "\(name)")
            inventory.finish()
        }
    }

    @Test func anInstanceThatArrivedAndIsNotInTheIndexKeepsTheRetrieveReported() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = begin(store, folder, listing: .empty)
        arrive(store, inventory, uids)
        inventory.updateImportedUIDs(Array(uids.dropLast()))
        #expect(inventory.receivedAwaitingImportCount == 1)
        // The wait gives up on it, and the retrieve is then not judged complete.
        #expect(!inventory.waitForReceivedImports(refreshing: {}, patience: 0.3, cancelled: { false }))
        #expect(!inventory.judgeByPeerCounters() && inventory.needsAttention)
        inventory.finish()
    }

    @Test func aCopySentTwiceCountsForEachSubOperation() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = begin(store, folder, listing: .empty, reported: 0)
        // The node holds two files of one instance and counts six sub-operations.
        arrive(store, inventory, uids + [uids[0]])
        inventory.updateImportedUIDs(uids)
        #expect(inventory.judgeByPeerCounters())
        inventory.finish()
    }

    @Test func theVerdictStandsWhileTheNodeReportsTheSameCountAndWhatArrivedIsHere() throws {
        let folder = Folder()
        do {
            let store = RetrieveInventoryStore()
            let inventory = begin(store, folder, listing: .notImplemented, status: 0xC000, reported: 7)
            // The node counts seven and sends five, in success: nothing else to ask it for.
            arrive(store, inventory, uids)
            inventory.updateImportedUIDs(uids)
            #expect(!inventory.standsByPeerCounters(reported: 7))
            #expect(inventory.judgeByPeerCounters())
            inventory.finish()
            #expect(inventory.standsByPeerCounters(reported: 7) && inventory.standsByPeerCounters(reported: 0))
            #expect(!inventory.standsByPeerCounters(reported: 8) && !inventory.standsByPeerCounters(reported: 5))
            // The inventory itself stays what it was: unconfirmed, matching no count.
            #expect(!inventory.matchesReportedCount(7) && !inventory.isSatisfied)
            #expect(AutoQueryRetrieveInventory.judgedByPeerCounters(inventory, reported: 7)
                    == AutoQueryRetrieveInventory(expected: 5, imported: 5, isSatisfied: true))
            #expect(AutoQueryRetrieveInventory.judgedByPeerCounters(inventory, reported: 8) == nil)
        }

        // Read back from its manifest once no one holds it, as after a relaunch.
        let later = RetrieveInventoryStore()
        let loaded = try #require(later.load(study: "7.1", series: "", endpoint: "PACS@peer:11112", database: folder.path))
        #expect(loaded.judgedByPeerCounters && loaded.standsByPeerCounters(reported: 7) && !loaded.needsAttention)
        // An instance that was here has gone: the study is asked for again.
        loaded.updateImportedUIDs(Array(uids.dropLast()))
        #expect(!loaded.standsByPeerCounters(reported: 7))
        #expect(AutoQueryRetrieveInventory.judgedByPeerCounters(loaded, reported: 7) == nil)
        loaded.updateImportedUIDs(uids + ["7.2.8"])
        #expect(loaded.standsByPeerCounters(reported: 7))

        // A new attempt is judged anew: the verdict of the last one is not its own.
        let again = later.begin(study: "7.1", series: "", endpoint: "PACS@peer:11112", database: folder.path, instances: [],
                                confirmed: false, reported: 7, listing: .notImplemented, listingStatus: 0xC000)
        #expect(again === loaded && !again.judgedByPeerCounters && again.needsAttention)
        again.record(operation: "C-MOVE", status: 0xB000, completed: 3, failed: 2, warnings: 0, remaining: 0)
        #expect(!again.judgeByPeerCounters() && !again.standsByPeerCounters(reported: 7))
        again.finish()
    }

    @Test func aNodeThatGaveNoCountIsHeldToWhatArrived() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let inventory = begin(store, folder, listing: .empty, reported: 0)
        arrive(store, inventory, uids)
        inventory.updateImportedUIDs(uids)
        #expect(inventory.judgeByPeerCounters())
        inventory.finish()
        #expect(inventory.standsByPeerCounters(reported: 0) && inventory.standsByPeerCounters(reported: 5))
        #expect(!inventory.standsByPeerCounters(reported: 6))
    }

    @Test func aConfirmedListingIsJudgedByItsInventory() {
        let folder = Folder(), store = RetrieveInventoryStore()
        let rows = uids.map { RetrieveListedInstance(sopInstanceUID: $0, seriesInstanceUID: "7.3") }
        let inventory = store.begin(study: "7.1", series: "", endpoint: "PACS@peer:11112", database: folder.path, instances: rows,
                                    confirmed: true, reported: 5, listing: .confirmed)
        arrive(store, inventory, Array(uids.prefix(4)))
        inventory.updateImportedUIDs(Array(uids.prefix(4)))
        // The node says it completed all it had; the listing says one is missing.
        #expect(!inventory.judgeByPeerCounters() && inventory.needsAttention && inventory.missingUIDs == ["7.2.5"])
        #expect(inventory.discoveryState == "confirmed" && !inventory.standsByPeerCounters(reported: 5))
        inventory.finish()
    }
}
