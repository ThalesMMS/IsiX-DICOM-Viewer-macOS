//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreFoundation
import Foundation
import Testing
import IsiXPreferences
@testable import IsiXDICOMNetwork

/// Whether two property lists are equal as Foundation compares them, and hold
/// the same kinds: a Boolean where there was one, text where there was text.
func samePropertyList(_ left: Any, _ right: Any) -> Bool {
    guard (left as AnyObject).isEqual(right as AnyObject) else { return false }
    return PropertyListValue(left) == PropertyListValue(right) && PropertyListValue(left) != nil
}

/// Whether the value is stored as a Boolean, as the preferences write `true`.
func isBoolean(_ value: Any?) -> Bool {
    guard let value else { return false }
    return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

/// The entries of `SERVERS` as the Locations pane, Bonjour, the send window
/// and earlier versions leave them.
enum StoredDICOMNodes {
    /// "New DICOM node" in Locations, edited, with TLS and the send window's thread count.
    static var locations: [String: Any] { [
        "AETitle": "PACS", "Address": "pacs.example", "Port": "104", "Description": "Archive", "QR": true, "Send": true,
        "Activated": true, "TransferSyntax": Int32(0), "retrieveMode": Int32(0), "WADOTransferSyntax": Int32(-1),
        "TLSEnabled": false, "TLSAuthenticated": false, "TLSCertificateVerification": 0, "TLSUseDHParameterFileURL": false,
        "TLSCipherSuites": [["Cipher": "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "Supported": true] as [String: Any]],
        "SendControllerConcurrentThreads": 2,
    ] }
    /// A WADO node, with its retrieve plan settings.
    static var wado: [String: Any] { [
        "AETitle": "WADO", "Address": "wado.example", "Port": 8080, "Description": "WADO", "retrieveMode": 2,
        "WADOUrl": "wado", "WADOPort": "8080", "WADOhttps": 1, "WADOTransferSyntax": 5, "WADOUsername": "reader",
        "WADOMaxRequests": 10, "WADOSeriesOrder": 1, "WADOAdaptiveRequests": true, "WADOExcludeSeries": ["scout"],
        "Activated": 1, "Send": false, "QR": true,
    ] }
    /// A node Bonjour found, as the node list builds it, with a Horos peer's direct transfer.
    static var bonjour: [String: Any] { [
        "Address": "10.0.0.7", "AETitle": "PEER", "Port": "11112", "QR": true, "retrieveMode": 0, "Send": true,
        "Description": "peer.local. (Bonjour)", "TransferSyntax": 0, "Activated": 1,
        "HorosDirectTransferVersion": 1, "HorosDirectTransferPort": 11113, "icon": "Horos",
    ] }
    /// An entry of an earlier version, from before retrieveMode and Activated.
    static var legacy: [String: Any] { [
        "AETitle": "OLD", "Address": "old.example", "Port": 104, "Description": "Old", "CGET": true, "CMOVE": false,
        "WADO": false, "TransferSyntax": 9,
    ] }
    /// The pilot's DICOMweb mode, which is no DIMSE node.
    static var pilot: [String: Any] { [
        "AETitle": "WEB", "Address": "web.example", "Port": 80, "retrieveMode": 3, "DICOMwebURL": "https://web.example/dicom-web",
    ] }
    /// An entry with a date and data, which no node writes but a property list may hold.
    static var unusual: [String: Any] { [
        "AETitle": "ODD", "Address": "odd.example", "Port": 1.0e2, "Description": "Odd", "Added": Date(timeIntervalSince1970: 1_000),
        "Blob": Data([0, 1, 2]), "Ratio": 0.5,
    ] }

    static var all: [[String: Any]] { [locations, wado, bonjour, legacy, pilot, unusual] }
}

struct PropertyListValueTests {
    @Test func eachKindIsKept() {
        #expect(PropertyListValue(true) == .boolean(true))
        #expect(PropertyListValue(NSNumber(value: false)) == .boolean(false))
        #expect(PropertyListValue(1) == .integer(1))
        #expect(PropertyListValue(Int32(-1)) == .integer(-1))
        #expect(PropertyListValue(1.5) == .real(1.5))
        #expect(PropertyListValue("104") == .string("104"))
        #expect(PropertyListValue(Data([1])) == .data(Data([1])))
        #expect(PropertyListValue(Date(timeIntervalSince1970: 0)) == .date(Date(timeIntervalSince1970: 0)))
        #expect(PropertyListValue([1, "a"] as [Any]) == .array([.integer(1), .string("a")]))
        #expect(PropertyListValue(["a": true] as [String: Any]) == .dictionary(["a": .boolean(true)]))
        #expect(PropertyListValue(NSObject()) == nil)
        #expect(PropertyListValue([NSObject()] as [Any]) == nil)
        #expect(isBoolean(PropertyListValue.boolean(true).object))
        #expect(!isBoolean(PropertyListValue.integer(1).object))
    }

    /// The values the network code read with -boolValue, -integerValue and %@.
    @Test func readAsFoundationReadThem() {
        #expect(PropertyListValue.string("YES").boolValue && PropertyListValue.string(" 1").boolValue)
        #expect(!PropertyListValue.string("NO").boolValue && !PropertyListValue.string("0").boolValue)
        #expect(!PropertyListValue.data(Data([1])).boolValue)
        #expect(PropertyListValue.string(" 104abc").intValue == 104 && PropertyListValue.string("x").intValue == 0)
        #expect(PropertyListValue.real(3.9).intValue == 3 && PropertyListValue.boolean(true).intValue == 1)
        #expect(PropertyListValue.boolean(true).text == "1" && PropertyListValue.integer(104).text == "104")
        #expect(PropertyListValue.real(0.5).text == NSNumber(value: 0.5).description)
        #expect(PropertyListValue.string("Archive").text == "Archive")
    }
}

struct DICOMNodeTests {
    /// Today's entries come back with the same keys, values and kinds.
    @Test func storedEntriesComeBackUnchanged() throws {
        for stored in StoredDICOMNodes.all {
            let node = try #require(DICOMNode(propertyList: stored))
            #expect(samePropertyList(node.propertyList, stored), "\(stored)")
            #expect(isBoolean(node.propertyList["QR"]) == isBoolean(stored["QR"]))
        }
        #expect(isBoolean(DICOMNode(propertyList: StoredDICOMNodes.locations)?.propertyList["Activated"]))
        #expect(!isBoolean(DICOMNode(propertyList: StoredDICOMNodes.bonjour)?.propertyList["Activated"]))
        #expect(DICOMNode(propertyList: StoredDICOMNodes.bonjour)?.propertyList["Port"] as? String == "11112")
        #expect(DICOMNode(propertyList: "not a node") == nil)
        #expect(DICOMNode(propertyList: ["AETitle": NSObject()] as [String: Any]) == nil)
    }

    /// Encoded as property lists, binary and XML, the nodes are the stored
    /// dictionaries, and decode to the same nodes.
    @Test func codableIsTheStoredEntry() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = format
            let nodes = StoredDICOMNodes.all.compactMap(DICOMNode.init(propertyList:))
            let data = try encoder.encode(nodes)
            let written = try PropertyListSerialization.propertyList(from: data, format: nil)
            #expect(samePropertyList(written, StoredDICOMNodes.all))
            let decoded = try PropertyListDecoder().decode([DICOMNode].self, from: data)
            // A real number without a fraction decodes as an integer; no node stores one.
            #expect(decoded.dropLast() == nodes.dropLast())
            #expect(decoded.last?["Ratio"] == .real(0.5) && decoded.last?["Port"] == .integer(100))
        }
    }

    @Test func typedSettingsReadTheEntry() throws {
        let locations = try #require(DICOMNode(propertyList: StoredDICOMNodes.locations))
        #expect(locations.aeTitle == "PACS" && locations.address == "pacs.example" && locations.port == 104)
        #expect(locations.nodeDescription == "Archive" && locations.transferSyntax == 0 && locations.retrieveModeValue == 0)
        #expect(locations.isActivated && locations.sends && locations.queriesAndRetrieves && !locations.usesTLS)
        let wado = try #require(DICOMNode(propertyList: StoredDICOMNodes.wado))
        #expect(wado.port == 8080 && !wado.sends && wado.retrieveModeValue == DICOMRetrieveMode.wado.rawValue)
        // Missing keys: activated, a destination and a source, no retrieve mode yet.
        let bare = DICOMNode(entry: ["AETitle": .string("A")])
        #expect(bare.isActivated && bare.sends && bare.queriesAndRetrieves && bare.retrieveModeValue == nil && bare.port == 0)
        #expect(bare.address == nil && bare.nodeDescription == nil && bare.transferSyntax == nil)
        // Written values keep the kinds the Locations pane writes.
        var edited = bare
        edited.address = "h"
        edited.nodeDescription = "D"
        edited[DICOMNode.Key.port] = .string("4242")
        #expect(edited.propertyList["Address"] as? String == "h" && edited.port == 4242)
        edited.address = nil
        #expect(edited.propertyList["Address"] == nil)
    }

    /// The node list's predicate, as it was written over the dictionaries.
    @Test func listedNodes() {
        func node(_ entry: [String: Any]) -> DICOMNode { DICOMNode(propertyList: entry)! }
        #expect(node(["AETitle": "A"]).isDIMSE)
        #expect(!node(["AETitle": "  "]).isDIMSE && !node([:]).isDIMSE && !node(["AETitle": 5]).isDIMSE)
        #expect(!node(StoredDICOMNodes.pilot).isDIMSE && !node(["AETitle": "A", "retrieveMode": "3"]).isDIMSE)
        #expect(node(["AETitle": "A", "retrieveMode": 2]).isDIMSE)
        #expect(!node(["AETitle": "A", "Activated": false]).isListed(sendOnly: false, queryRetrieveOnly: false))
        #expect(!node(["AETitle": "A", "Activated": "NO"]).isListed(sendOnly: false, queryRetrieveOnly: false))
        #expect(node(["AETitle": "A", "Activated": 1]).isListed(sendOnly: true, queryRetrieveOnly: true))
        #expect(!node(["AETitle": "A", "Send": false]).isListed(sendOnly: true, queryRetrieveOnly: false))
        #expect(node(["AETitle": "A", "Send": false]).isListed(sendOnly: false, queryRetrieveOnly: true))
        #expect(!node(["AETitle": "A", "QR": 0]).isListed(sendOnly: false, queryRetrieveOnly: true))
        #expect(node(["AETitle": "A", "QR": 0]).isListed(sendOnly: true, queryRetrieveOnly: false))
    }

    /// An entry of an earlier version gains Activated and retrieveMode.
    @Test func normalization() throws {
        var legacy = try #require(DICOMNode(propertyList: StoredDICOMNodes.legacy))
        let changed = legacy.normalize()
        #expect(changed)
        #expect(samePropertyList(legacy.propertyList, [
            "AETitle": "OLD", "Address": "old.example", "Port": 104, "Description": "Old", "TransferSyntax": 9,
            "Activated": true, "retrieveMode": 1,
        ] as [String: Any]))
        let again = legacy.normalize()
        #expect(!again)
        var moving = DICOMNode(propertyList: ["AETitle": "M", "Activated": false, "CMOVE": true] as [String: Any])!
        let moved = moving.normalize()
        #expect(moved)
        #expect(samePropertyList(moving.propertyList, ["AETitle": "M", "Activated": false, "retrieveMode": 0] as [String: Any]))
        // A stored retrieve mode keeps the former flags as they are.
        var kept = DICOMNode(propertyList: ["AETitle": "K", "Activated": 1, "retrieveMode": 2, "CGET": true] as [String: Any])!
        let keptChanged = kept.normalize()
        #expect(!keptChanged && kept["CGET"] == .boolean(true))
    }
}

struct DICOMNodeStoreTests {
    @Test func readsAndWritesTheStoredList() throws {
        let preferences = MemoryPreferences(["SERVERS": StoredDICOMNodes.all + ["not a node"]])
        let store = DICOMNodeStore(preferences: preferences)
        let nodes = store.dicomNodes()
        #expect(nodes.map(\.aeTitle) == ["PACS", "WADO", "PEER", "OLD", "WEB", "ODD"])
        store.saveDICOMNodes(nodes)
        #expect(samePropertyList(try #require(preferences.object(forKey: "SERVERS")), StoredDICOMNodes.all))
        #expect(DICOMNodeStore(preferences: MemoryPreferences()).dicomNodes().isEmpty)
        #expect(DICOMNodeStore(preferences: MemoryPreferences(["SERVERS": "text"])).dicomNodes().isEmpty)
    }

    /// The normalized list is written back once, with what is not a node kept
    /// in its place; never when the list came from the launch arguments.
    @Test func normalizedListIsWrittenBackWhenItChanged() throws {
        let stored: [Any] = [StoredDICOMNodes.locations, "not a node", StoredDICOMNodes.legacy]
        let preferences = MemoryPreferences(["SERVERS": stored])
        let store = DICOMNodeStore(preferences: preferences)
        let nodes = store.normalizedDICOMNodes()
        #expect(nodes.map(\.aeTitle) == ["PACS", "OLD"] && nodes[1].retrieveModeValue == 1)
        let written = try #require(preferences.object(forKey: "SERVERS") as? [Any])
        #expect(written.count == 3 && written[1] as? String == "not a node")
        #expect(samePropertyList(written[0], StoredDICOMNodes.locations))
        #expect(samePropertyList(written[2], nodes[1].propertyList))
        #expect(preferences.writes == ["SERVERS"])
        _ = store.normalizedDICOMNodes()
        #expect(preferences.writes == ["SERVERS"])

        let argument = MemoryPreferences(["SERVERS": stored], arguments: ["SERVERS"])
        let fromArguments = DICOMNodeStore(preferences: argument)
        #expect(fromArguments.dicomNodesGivenAsArgument)
        #expect(fromArguments.normalizedDICOMNodes().count == 2 && argument.writes.isEmpty)
    }

    /// One node changes; the others, and what is not a node, are written as they were.
    @Test func oneNodeIsUpdatedInPlace() throws {
        let stored: [Any] = ["not a node", StoredDICOMNodes.legacy, StoredDICOMNodes.locations, StoredDICOMNodes.locations]
        let preferences = MemoryPreferences(["SERVERS": stored])
        let store = DICOMNodeStore(preferences: preferences)
        let updated = store.updateFirstDICOMNode(where: { $0.address == "pacs.example" && $0.nodeDescription == "Archive" }) {
            $0["SendControllerConcurrentThreads"] = .integer(4)
        }
        #expect(updated)
        let written = try #require(preferences.object(forKey: "SERVERS") as? [Any])
        #expect(written.count == 4 && written[0] as? String == "not a node")
        #expect(samePropertyList(written[1], StoredDICOMNodes.legacy) && samePropertyList(written[3], StoredDICOMNodes.locations))
        var expected = StoredDICOMNodes.locations
        expected["SendControllerConcurrentThreads"] = 4
        #expect(samePropertyList(written[2], expected))
        let none = store.updateFirstDICOMNode(where: { $0.address == "elsewhere" }) { $0["X"] = .boolean(true) }
        #expect(!none && preferences.writes == ["SERVERS"])
    }

    @Test func aSyncedListKeepsTheDIMSENodes() throws {
        let preferences = MemoryPreferences(["SERVERS": [StoredDICOMNodes.legacy]])
        let store = DICOMNodeStore(preferences: preferences)
        store.replaceDICOMNodes(withSyncedList: [StoredDICOMNodes.locations, StoredDICOMNodes.pilot, ["Address": "x"], "junk"])
        #expect(samePropertyList(try #require(preferences.object(forKey: "SERVERS")), [StoredDICOMNodes.locations]))
    }

    @Test func listSettings() {
        let store = DICOMNodeStore(preferences: MemoryPreferences(["syncDICOMNodes": true, "searchDICOMBonjour": false,
                                                                   "syncDICOMNodesURL": "https://example/nodes.plist"]))
        #expect(store.syncsDICOMNodes && !store.searchesBonjour)
        #expect(store.syncURL == URL(string: "https://example/nodes.plist"))
        #expect(DICOMNodeStore(preferences: MemoryPreferences()).syncURL == nil)
    }

    @Test func dicomwebList() throws {
        let preferences = MemoryPreferences(["DICOMWEB_SERVERS": StoredDICOMwebNodes.all + [7]])
        let store = DICOMNodeStore(preferences: preferences)
        let nodes = store.dicomwebNodes()
        #expect(nodes.map(\.name) == ["Cloud", "Signed in", "Minimal"])
        store.saveDICOMwebNodes(nodes)
        #expect(samePropertyList(try #require(preferences.object(forKey: "DICOMWEB_SERVERS")), StoredDICOMwebNodes.all))
    }
}
