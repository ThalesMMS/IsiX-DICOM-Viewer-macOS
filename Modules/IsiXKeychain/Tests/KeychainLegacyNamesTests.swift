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
import Security
import Testing
@testable import IsiXKeychain

/// The names the former SDK's Keychain helper logged, against the Security
/// framework's own constants.
struct KeychainLegacyNamesTests {
    @Test func aFormatAndAnItemTypeAreNamedByTheirConstant() {
        #expect(KeychainLegacyNames.name(of: SecExternalFormat.formatX509Cert) == "kSecFormatX509Cert")
        #expect(KeychainLegacyNames.name(of: SecExternalFormat.formatPKCS12) == "kSecFormatPKCS12")
        #expect(KeychainLegacyNames.name(of: SecExternalFormat.formatSSH) == "kSecFormatSSH - Not Supported")
        #expect(KeychainLegacyNames.name(of: SecExternalFormat.formatSSHv2) == "Unknown")
        #expect(KeychainLegacyNames.name(of: SecExternalItemType.itemTypeCertificate) == "kSecItemTypeCertificate")
        #expect(KeychainLegacyNames.name(of: SecExternalItemType.itemTypeAggregate) == "kSecItemTypeAggregate")
    }

    @Test func anAttributeIsNamedByItsFourCharacterCode() {
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.labelItemAttr.rawValue) == "kSecLabelItemAttr")
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.accountItemAttr.rawValue) == "kSecAccountItemAttr")
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.serviceItemAttr.rawValue) == "kSecServiceItemAttr")
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.creationDateItemAttr.rawValue) == "kSecCreationDateItemAttr")
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.crlType.rawValue) == "kSecCrlType")
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.crlEncoding.rawValue) == "kSecCrlEncoding")
        #expect(KeychainLegacyNames.name(ofAttribute: SecItemAttr.alias.rawValue) == "kSecAlias")
        #expect(KeychainLegacyNames.name(ofAttribute: 0) == "Unknown")
    }
}
