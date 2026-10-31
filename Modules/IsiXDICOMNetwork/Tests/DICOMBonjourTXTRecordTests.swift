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
import IsiXPreferences
@testable import IsiXDICOMNetwork

@Test func eachTransferSyntaxTagHasTheNamePeersRead() {
    let names = [0: "LittleEndianImplicit", 21: "JPEGProcess14SV1TransferSyntax", 26: "JPEG2000LosslessOnly",
                 27: "JPEG2000", 22: "RLELossless", 23: "JPEGLSLossless", 24: "JPEGLSLossy",
                 1: "LittleEndianExplicit", 2: "LittleEndianExplicit", 25: "LittleEndianExplicit", -1: "LittleEndianExplicit"]
    for (tag, name) in names {
        #expect(DICOMBonjourTXTRecord.syntaxName(tag) == name, "\(tag)")
        let record = DICOMBonjourTXTRecord(serverDescription: nil, aeTitle: "ISIX", uid: nil, cget: true, wadoPort: nil,
                                           wadoUsesHTTPS: false, preferredSyntax: tag)
        #expect(record.entries["preferredSyntax"] == name, "\(tag)")
    }
    #expect(DICOMBonjourTXTRecord.serviceType == "_dicom._tcp.")
}

@Test func theRecordCarriesWhatIsSetAndOnlyThat() {
    let bare = DICOMBonjourTXTRecord(serverDescription: "", aeTitle: nil, uid: nil, cget: false, wadoPort: nil,
                                     wadoUsesHTTPS: true, preferredSyntax: 2)
    #expect(bare.entries == ["CGET": "NO", "preferredSyntax": "LittleEndianExplicit"])
    let full = DICOMBonjourTXTRecord(serverDescription: "Reading room", aeTitle: "ISIX", uid: "serial|user", cget: true,
                                     wadoPort: 3333, wadoUsesHTTPS: false, preferredSyntax: 26)
    #expect(full.entries == ["serverDescription": "Reading room", "AETitle": "ISIX", "UID": "serial|user", "CGET": "YES",
                             "WADO": "YES", "WADOPort": "3333", "WADOURL": "/wado", "WADOProtocol": "http",
                             "preferredSyntax": "JPEG2000LosslessOnly"])
    let secure = DICOMBonjourTXTRecord(serverDescription: nil, aeTitle: "", uid: "", cget: true, wadoPort: 8443,
                                       wadoUsesHTTPS: true, preferredSyntax: 0)
    #expect(secure.entries["WADOProtocol"] == "https" && secure.entries["AETitle"] == "" && secure.entries["UID"] == "")
}

@Test func thePreferencesGiveTheRecord() {
    let registered: [String: Any] = ["AETITLE": "ISIX", "activateCGETSCP": "1", "httpWebServer": "0", "wadoServer": true,
                                     "preferredSyntaxForIncoming": "2"]
    func record(_ values: [String: Any]) -> [String: String] {
        DICOMBonjourTXTRecord(preferences: MemoryPreferences(values, registered: registered), serverDescription: "Mac",
                              uid: "u", webPortalPort: 3333).entries
    }
    #expect(record([:]) == ["serverDescription": "Mac", "AETitle": "ISIX", "UID": "u", "CGET": "YES",
                            "preferredSyntax": "LittleEndianExplicit"])
    #expect(record(["httpWebServer": true])["WADOPort"] == "3333", "the portal and WADO both on")
    #expect(record(["httpWebServer": true, "wadoServer": false])["WADO"] == nil, "WADO off")
    #expect(record(["httpWebServer": "1", "encryptedWebServer": "1"])["WADOProtocol"] == "https")
    #expect(record(["activateCGETSCP": 0, "preferredSyntaxForIncoming": 27])["CGET"] == "NO")
    #expect(record(["preferredSyntaxForIncoming": "27"])["preferredSyntax"] == "JPEG2000")
    #expect(record(["AETITLE": 104])["AETitle"] == "104", "a number stored as the title is its text")
}
