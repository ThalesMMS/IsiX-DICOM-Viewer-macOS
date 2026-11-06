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

/// The rules of a send and of the listener's move sub-operations. Their
/// comparison with the Objective-C++ they replaced, through DCMTK, is
/// tests/test-store-rules-equivalence.py.
struct StoreRulesTests {
    typealias UID = TransferSyntaxUID

    @Test func settingsNameTheirSyntaxAndQuality() {
        #expect(StoreSendSyntax.network(forSetting: 0) == StoreNetworkSyntax(transferSyntax: UID.explicitLittleEndian, quality: 90))
        #expect(StoreSendSyntax.network(forSetting: 3) == StoreNetworkSyntax(transferSyntax: UID.jpeg2000, quality: 2))
        #expect(StoreSendSyntax.network(forSetting: 8) == StoreNetworkSyntax(transferSyntax: UID.jpegExtended, quality: 70))
        #expect(StoreSendSyntax.network(forSetting: 99) == StoreSendSyntax.network(forSetting: 0))
        #expect(StoreSendSyntax.setting(forListenerTransferSyntax: UID.jpegBaseline) == 5)
        #expect(StoreSendSyntax.setting(forListenerTransferSyntax: "") == 0)
    }

    @Test func eachClassHasAPreferredAndAFallbackContext() throws {
        let contexts = try StoragePresentationPlan.contexts(preferredTransferSyntax: UID.jpegLossless,
                                                            required: ["1.2.3", "1.2.3", "1.2.4"], optional: ["1.2.4", "1.2.5"]).get()
        #expect(contexts.map(\.abstractSyntax) == ["1.2.3", "1.2.3", "1.2.4", "1.2.4", "1.2.5", "1.2.5"])
        #expect(contexts.map(\.identifier) == [1, 3, 5, 7, 9, 11])
        #expect(contexts[0].transferSyntaxes == [UID.jpegLossless])
        #expect(contexts[1].transferSyntaxes == [UID.explicitLittleEndian, UID.explicitBigEndian, UID.implicitLittleEndian])
    }

    @Test func manyClassesCombineAndTooManyAreRefused() throws {
        let classes = (1...65).map { "1.2.826.0.1.3680043.8.498.\($0)" }
        let combined = try StoragePresentationPlan.contexts(preferredTransferSyntax: UID.explicitLittleEndian,
                                                            required: classes, optional: []).get()
        #expect(combined.count == 65 && combined.allSatisfy { $0.transferSyntaxes.count == 3 })
        let implicit = try StoragePresentationPlan.contexts(preferredTransferSyntax: UID.implicitLittleEndian,
                                                            required: classes, optional: []).get()
        #expect(implicit.allSatisfy { $0.transferSyntaxes == [UID.implicitLittleEndian] })
        let tooMany = (1...129).map { "1.2.826.0.1.3680043.8.498.\($0)" }
        #expect(StoragePresentationPlan.contexts(preferredTransferSyntax: UID.explicitLittleEndian, required: tooMany,
                                                 optional: []) == .failure(.tooManyRequiredContexts))
    }

    @Test func conversionFollowsTheAcceptedSyntax() {
        let native = TransferSyntaxTraits(native: true, encapsulated: false, pixelDataCompressed: false)
        let compressed = TransferSyntaxTraits(native: false, encapsulated: true, pixelDataCompressed: true)
        #expect(StoreConversion.of(fileSyntax: UID.explicitLittleEndian, file: native, accepted: native,
                                   networkSyntax: UID.explicitLittleEndian) == .none)
        #expect(StoreConversion.of(fileSyntax: UID.jpeg2000, file: compressed, accepted: native,
                                   networkSyntax: UID.explicitLittleEndian) == .decompress)
        #expect(StoreConversion.of(fileSyntax: UID.explicitLittleEndian, file: native, accepted: compressed,
                                   networkSyntax: UID.jpeg2000) == .compress(warns: false))
        #expect(StoreConversion.of(fileSyntax: UID.jpeg2000Lossless, file: compressed, accepted: compressed,
                                   networkSyntax: UID.jpeg2000) == .compress(warns: false))
        #expect(StoreConversion.of(fileSyntax: UID.jpegBaseline, file: compressed, accepted: compressed,
                                   networkSyntax: UID.jpeg2000) == .compress(warns: true))
        #expect(StoreConversion.of(fileSyntax: UID.jpeg2000, file: compressed, accepted: nil, networkSyntax: UID.jpeg2000) == .none)
    }

    @Test func moveSubOperationsOfferJPEGUnlessTold() {
        #expect(MoveSubOperationSyntaxes.proposed(withoutJPEG: true).count == 5)
        #expect(MoveSubOperationSyntaxes.proposed(withoutJPEG: false).contains(UID.rleLossless))
    }

    @Test func tlsSettingsAreReadOnlyWhenEnabled() {
        let off = TLSNodeSettings(extraParameters: ["TLSAuthenticated": NSNumber(value: true)])
        #expect(off == TLSNodeSettings())
        let on = TLSNodeSettings(extraParameters: [
            "TLSEnabled": NSNumber(value: true), "TLSAuthenticated": "YES", "TLSCertificateVerification": NSNumber(value: 1),
            "TLSCipherSuites": [["Supported": NSNumber(value: true), "Cipher": "A"], ["Supported": NSNumber(value: false), "Cipher": "B"]],
            "TLSUseDHParameterFileURL": NSNumber(value: true), "TLSDHParameterFileURL": "/dh.pem",
        ])
        #expect(on.enabled && on.authenticated && on.storedCertificateVerification == 1)
        #expect(on.cipherSuites == ["A"] && on.dhParameterFile == "/dh.pem")
    }
}
