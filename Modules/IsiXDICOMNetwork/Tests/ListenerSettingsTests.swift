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

/// What the application registers for the listener's keys, as text.
private func registered() -> [String: Any] {
    [
    "STORESCP": "1", "USESTORESCP": "1", "AETITLE": "ISIX", "AEPORT": "11112", "STORESCPEXTRA": "",
    "AETransferSyntax": "+xi", "DICOMTimeout": "40", "DICOMConnectionTimeout": "10", "preferredSyntaxForIncoming": "2",
    "activateCGETSCP": "1", "activateCFINDSCP": "1", "publishDICOMBonjour": "1", "TLSStoreSCPAEPORT": "2762",
    "TLSStoreSCPAETITLE": "ISIX-TLS",
    ]
}

private func settings(_ values: [String: Any] = [:]) -> ListenerSettings {
    ListenerSettings(preferences: MemoryPreferences(values, registered: registered()))
}

@Test func theSettingsAreReadAsTheListenerReadsThem() {
    let read = settings()
    #expect(read.storeSCP && read.usesStoreSCP && !read.tlsListener)
    #expect(read.aeTitle == "ISIX" && read.port == 11112)
    #expect(read.tlsAETitle == "ISIX-TLS" && read.tlsPort == 2762)
    #expect(read.timeout == 40 && read.connectionTimeout == 10 && read.preferredSyntaxForIncoming == 2)
    #expect(read.cgetSCP && read.cfindSCP && read.publishesBonjour)
    #expect(read.tlsCertificateVerification == nil && read.tlsCipherSuites == nil)
    #expect(settings(["AEPORT": "104 "]).port == 104, "the port is the leading integer of its text")
    #expect(settings(["AEPORT": "none"]).port == 0)
}

@Test func aNumberStoredAsTextAndAsANumberIsOneValue() {
    #expect(settings(["AEPORT": "0"]) == settings(["AEPORT": 0]))
    #expect(settings(["AEPORT": "11112"]) == settings(["AEPORT": 11112]))
    #expect(settings(["DICOMTimeout": "0"]) == settings(["DICOMTimeout": 0]))
    #expect(settings(["preferredSyntaxForIncoming": "0"]) == settings(["preferredSyntaxForIncoming": 0]))
    #expect(settings(["STORESCP": "0"]) == settings(["STORESCP": 0]))
    #expect(settings(["STORESCP": "1"]) == settings(["STORESCP": true]))
    #expect(settings(["TLSStoreSCPCertificateVerification": "0"]) == settings(["TLSStoreSCPCertificateVerification": 0]))
    #expect(settings(["TLSStoreSCPAEPORT": "0"]) == settings(["TLSStoreSCPAEPORT": 0]))
    #expect(settings(["STORESCP": "1"]) == settings())
}

@Test func aChangeTheListenerWouldSeeIsAChange() {
    let applied = settings()
    for changed in [["STORESCP": "0"], ["STORESCPTLS": "1"], ["AETITLE": "OTHER"], ["AEPORT": "104"],
                    ["DICOMTimeout": "30"], ["DICOMConnectionTimeout": "5"], ["preferredSyntaxForIncoming": "21"],
                    ["activateCGETSCP": "0"], ["activateCFINDSCP": "0"], ["publishDICOMBonjour": "0"],
                    ["TLSStoreSCPAEPORT": "2763"], ["TLSStoreSCPAETITLE": "OTHER-TLS"], ["STORESCPEXTRA": "-x"],
                    ["AETransferSyntax": "+xe"], ["UseHostNameForAETitle": "1"],
                    ["TLSStoreSCPCertificateVerification": 1], ["TLSStoreSCPCipherSuites": [["Cipher": "A", "Supported": true]]],
                    ["TLSStoreSCPUseDHParameterFileURL": true], ["TLSStoreSCPDHParameterFileURL": "/tmp/dh.pem"]] as [[String: Any]] {
        #expect(settings(changed) != applied, "\(changed)")
    }
    #expect(settings(["TLSStoreSCPCertificateVerification": 0]) != applied, "absent and stored are not the same")
}

@Test func theTitleIsComparedAsTheListenerUsesIt() {
    #expect(settings(["AETITLE": "ABCDEFGHIJKLMNOPQRST"]) == settings(["AETITLE": "ABCDEFGHIJKLMNOP"]),
            "the listener cuts its title at 16 characters")
    #expect(settings(["AETITLE": "ABCDEFGHIJKLMNOPQRST"]).aeTitle == "ABCDEFGHIJKLMNOPQRST", "the stored title is kept as it is")
    #expect(settings(["AETITLE": "ABCDEFGHIJKLMNOP"]) != settings(["AETITLE": "ABCDEFGHIJKLMNO"]))
    #expect(settings(["UseHostNameForAETitle": "1", "AETITLE": "HOST-A"]) == settings(["UseHostNameForAETitle": true, "AETITLE": "HOST-B"]),
            "the host's name is no change of the user's")
    #expect(settings(["TLSStoreSCPAETITLE": "ABCDEFGHIJKLMNOPQRST"]) != settings(["TLSStoreSCPAETITLE": "ABCDEFGHIJKLMNOP"]),
            "the TLS title is compared as stored")
}
