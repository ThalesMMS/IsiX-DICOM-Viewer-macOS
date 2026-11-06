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

/// The entries of `DICOMWEB_SERVERS` as the DICOMweb table writes them.
enum StoredDICOMwebNodes {
    static var cloud: [String: Any] { [
        "Identifier": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "Address": "https://pacs.example/dicom-web",
        "AllowInsecureHTTP": false, "WADOPath": "wado", "QIDOPath": "", "Name": "Cloud", "QR": true,
        "RetrieveSyntax": "*", "Send": true, "SendSyntax": "1.2.840.10008.1.2.4.90", "MaxRequests": 6, "SeriesOrder": 2,
        "ExcludeSeries": ["scout", "localizer"], "AdaptiveRequests": true,
        "TrustedCertificateSHA256": "ab12", "CredentialID": "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
        "ClientIdentity": Data([1, 2, 3]), "ClientIdentityName": "Workstation", "Comment": "kept as written",
    ] }
    static var signedIn: [String: Any] { [
        "Identifier": "A0E1B2C3-D4E5-F607-1829-3A4B5C6D7E8F", "Address": "http://127.0.0.1:8042/dicom-web",
        "AllowInsecureHTTP": true, "WADOPath": "", "QIDOPath": "", "Name": "Signed in", "QR": true,
        "RetrieveSyntax": "1.2.840.10008.1.2.1", "Send": false, "SendSyntax": "*", "MaxRequests": 4, "SeriesOrder": 0,
        "AdaptiveRequests": false, "OIDCIssuer": "https://id.example", "OIDCClientID": "isix", "OIDCScopes": "openid",
        "LegacyCredential": true, "CredentialID": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
    ] }
    static var minimal: [String: Any] { [
        "Identifier": "C56A4180-65AA-42EC-A945-5FD21DEC0538", "Address": "https://minimal.example", "AllowInsecureHTTP": false,
        "WADOPath": "", "QIDOPath": "", "Name": "Minimal", "QR": false, "RetrieveSyntax": "*", "Send": false, "SendSyntax": "*",
        "MaxRequests": 1, "SeriesOrder": 1, "AdaptiveRequests": false,
    ] }

    static var all: [[String: Any]] { [cloud, signedIn, minimal] }
}

struct DICOMwebNodeRecordTests {
    /// The entries the table writes come back with the same keys, values and kinds.
    @Test func storedEntriesComeBackUnchanged() throws {
        for stored in StoredDICOMwebNodes.all {
            let record = try #require(DICOMwebNodeRecord(propertyList: stored))
            #expect(samePropertyList(record.propertyList, stored), "\(stored)")
        }
        let cloud = try #require(DICOMwebNodeRecord(propertyList: StoredDICOMwebNodes.cloud))
        #expect(cloud.maximumRequests == 6 && cloud.seriesOrder == 2 && cloud.excludedSeries == ["scout", "localizer"])
        #expect(cloud.clientIdentityReference == Data([1, 2, 3]) && cloud.unknown == ["Comment": .string("kept as written")])
        #expect(DICOMwebNodeRecord(propertyList: 7) == nil)
    }

    @Test func codableIsTheStoredEntry() throws {
        let records = StoredDICOMwebNodes.all.compactMap(DICOMwebNodeRecord.init(propertyList:))
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = format
            let data = try encoder.encode(records)
            #expect(samePropertyList(try PropertyListSerialization.propertyList(from: data, format: nil), StoredDICOMwebNodes.all))
            #expect(try PropertyListDecoder().decode([DICOMwebNodeRecord].self, from: data) == records)
        }
    }

    /// An entry written by hand, or by an earlier version: what is missing
    /// takes its default, what is out of range is brought back into it.
    @Test func handWrittenEntriesTakeTheDefaults() throws {
        let record = try #require(DICOMwebNodeRecord(propertyList: [
            "Identifier": "not a UUID", "Address": "  https://h.example  ", "Name": 7, "QR": "NO", "Send": "YES",
            "RetrieveSyntax": "1.2.840.10008.1.2", "SendSyntax": "", "MaxRequests": " 40 ", "SeriesOrder": 9,
            "ClientIdentity": Data([1]).base64EncodedString(), "ClientIdentityName": "Mine",
            "OIDCClientID": "orphan", "ExcludeSeries": ["a", 1], "AllowInsecureHTTP": Data(),
        ] as [String: Any]))
        #expect(UUID(uuidString: record.identifier) != nil)
        #expect(record.address == "https://h.example" && record.name == "7")
        #expect(!record.queryRetrieve && record.send && !record.allowInsecureHTTP)
        #expect(record.retrieveSyntax == "*" && record.sendSyntax == "*")
        #expect(record.maximumRequests == 16 && record.seriesOrder == 0 && record.excludedSeries == ["a"])
        #expect(record.clientIdentityReference == Data([1]) && record.clientIdentityName == "Mine")
        // OpenID Connect settings without an issuer are not written back.
        #expect(record.propertyList["OIDCClientID"] == nil && record.propertyList["ClientIdentity"] is Data)

        let empty = try #require(DICOMwebNodeRecord(propertyList: [String: Any]()))
        #expect(empty.queryRetrieve && !empty.send && empty.maximumRequests == 4 && empty.seriesOrder == 0)
        #expect(empty.name.isEmpty && empty.address.isEmpty && empty.clientIdentityReference == nil)
        #expect(DICOMwebNodeRecord(propertyList: ["MaxRequests": 0, "ClientIdentity": Data(), "ClientIdentityName": "x"] as [String: Any])
            .map { $0.maximumRequests == 1 && $0.clientIdentityName.isEmpty } == true)
        #expect(DICOMwebNodeRecord(propertyList: ["MaxRequests": "many", "SeriesOrder": "1"] as [String: Any])
            .map { $0.maximumRequests == 4 && $0.seriesOrder == 1 } == true)
    }

    @Test func aNewNodeIsASourceWithTheDefaults() {
        var record = DICOMwebNodeRecord(name: "DICOMweb Node")
        #expect(UUID(uuidString: record.identifier) != nil && record.queryRetrieve && !record.send)
        record.maximumRequests = 99
        record.seriesOrder = -1
        #expect(record.maximumRequests == 16 && record.seriesOrder == 0)
        let written = record.propertyList
        #expect(written["CredentialID"] == nil && written["LegacyCredential"] == nil && written["ExcludeSeries"] == nil)
        #expect(isBoolean(written["QR"]) && written["MaxRequests"] as? Int == 16)
    }
}
