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

@Test func theAnnouncementKeepsTheKeysOtherInstancesRead() {
    #expect(SharedDatabaseAnnouncement.serviceType == "_osirixdb._tcp.")
    #expect(SharedDatabaseAnnouncement.port == 8780)
    let unset = SharedDatabaseAnnouncement(aeTitle: nil, dicomPort: nil, uid: nil)
    #expect(unset.txtRecord == ["AETitle": "OSIRIX", "port": "11112"])
    let full = SharedDatabaseAnnouncement(aeTitle: "HOROS", dicomPort: "104", uid: "1.2.3",
                                          directTransferVersion: "1", directTransferPort: "8781")
    #expect(full.txtRecord == ["AETitle": "HOROS", "port": "104", "UID": "1.2.3",
                               "HorosDirectTransferVersion": "1", "HorosDirectTransferPort": "8781"])
    let empty = SharedDatabaseAnnouncement(aeTitle: "", dicomPort: "", uid: "",
                                           directTransferVersion: "", directTransferPort: "")
    #expect(empty.txtRecord == ["AETitle": "", "port": "", "UID": ""], "only the direct transfer leaves out empty values")
}

@Test func anAdvertisementGoesWhenItsListenerOrNameChanged() {
    #expect(SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: nil, advertisedName: nil, listenerPort: 0, name: "a"))
    #expect(SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: 8780, advertisedName: "a", listenerPort: 0, name: "a"))
    #expect(!SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: nil, advertisedName: nil, listenerPort: 8780, name: "a"))
    #expect(!SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: 8780, advertisedName: "a", listenerPort: 8780, name: "a"))
    #expect(SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: 8780, advertisedName: "a", listenerPort: 8781, name: "a"))
    #expect(SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: 8780, advertisedName: "a", listenerPort: 8780, name: "b"))
    #expect(SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: 8780, advertisedName: "a", listenerPort: 8780, name: nil),
            "a missing name never matches")
    #expect(SharedDatabaseAnnouncement.mustWithdraw(advertisedPort: 8780, advertisedName: "\u{e9}", listenerPort: 8780,
                                                    name: "e\u{301}"), "names are compared literally")
}

@Test func aTextKeyWithoutAValueIsEmptyText() throws {
    // NSNetService writes an empty value as the bare key, without "=".
    let entries: [String: SharedDatabaseServiceRecord.Value] = [
        "AETitle": .none, "port": .none, "UID": .none, "HorosDirectTransferVersion": .data(Data("4".utf8)), "flag": .none,
    ]
    let decoded = try SharedDatabaseServiceRecord.decode(entries)
    #expect(decoded == ["AETitle": .text(""), "port": .text(""), "UID": .text(""),
                        "HorosDirectTransferVersion": .data(Data("4".utf8)), "flag": SharedDatabaseServiceRecord.Decoded.none])
    #expect(try SharedDatabaseServiceRecord.decode(["UID": .none, "AETitle": .data(Data("PEER".utf8))])
            == ["UID": .text(""), "AETitle": .text("PEER")])
    #expect(throws: SharedDatabaseServiceRecord.Failure.notUTF8(key: "port"), "a bare key does not hide a later invalid one") {
        try SharedDatabaseServiceRecord.decode(["AETitle": .none, "port": .data(Data([0xff]))])
    }
}

@Test func aDiscoveredRecordKeepsItsTextKeysAsText() throws {
    let entries: [String: SharedDatabaseServiceRecord.Value] = [
        "AETitle": .data(Data("PEER".utf8)), "port": .data(Data("11112".utf8)), "UID": .data(Data()),
        "HorosDirectTransferPort": .data(Data("8781".utf8)), "flag": .none,
    ]
    let decoded = try SharedDatabaseServiceRecord.decode(entries)
    #expect(decoded == ["AETitle": .text("PEER"), "port": .text("11112"), "UID": .text(""),
                        "HorosDirectTransferPort": .data(Data("8781".utf8)), "flag": SharedDatabaseServiceRecord.Decoded.none])
    #expect(throws: SharedDatabaseServiceRecord.Failure.notUTF8(key: "AETitle")) {
        try SharedDatabaseServiceRecord.decode(["AETitle": .data(Data([0xff])), "port": .data(Data([0xff]))])
    }
    #expect(try SharedDatabaseServiceRecord.decode([:]).isEmpty)
}

@Test func sourcesAreListedByKind() {
    let items: [[String: String]] = [
        ["type": "dicomDestination", "n": "2"], ["n": "3"],
        ["type": "fixedIP", "n": "4"], ["type": "localPath", "n": "5"], ["type": "other", "n": "6"],
        ["type": "fixedIP", "n": "7"], ["type": "bonjour", "n": "1"],
    ]
    let arranged = DatabaseSourceKind.arranged(items) { $0["type"] }
    #expect(arranged.map { $0["n"]! } == ["5", "4", "7", "2"], "an entry of a kind nothing lists is left out")
}
