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

/// The names the Horos and OsiriX SDK's Keychain helper gave, in its logs, to
/// the formats and item types of the Security framework's import and export
/// and to the attributes of an item of the legacy Keychain: the constant's own
/// name, and "Unknown" for a value it did not list.
public enum KeychainLegacyNames {
    public static func name(of format: SecExternalFormat) -> String {
        switch format {
        case .formatUnknown: return "kSecFormatUnknown"
        case .formatOpenSSL: return "kSecFormatOpenSSL"
        case .formatSSH: return "kSecFormatSSH - Not Supported"
        case .formatBSAFE: return "kSecFormatBSAFE"
        case .formatRawKey: return "kSecFormatRawKey"
        case .formatWrappedPKCS8: return "kSecFormatWrappedPKCS8"
        case .formatWrappedOpenSSL: return "kSecFormatWrappedOpenSSL"
        case .formatWrappedSSH: return "kSecFormatWrappedSSH - Not Supported"
        case .formatWrappedLSH: return "kSecFormatWrappedLSH - Not Supported"
        case .formatX509Cert: return "kSecFormatX509Cert"
        case .formatPEMSequence: return "kSecFormatPEMSequence"
        case .formatPKCS7: return "kSecFormatPKCS7"
        case .formatPKCS12: return "kSecFormatPKCS12"
        case .formatNetscapeCertSequence: return "kSecFormatNetscapeCertSequence"
        default: return "Unknown"
        }
    }

    public static func name(of itemType: SecExternalItemType) -> String {
        switch itemType {
        case .itemTypeUnknown: return "kSecItemTypeUnknown"
        case .itemTypePrivateKey: return "kSecItemTypePrivateKey"
        case .itemTypePublicKey: return "kSecItemTypePublicKey"
        case .itemTypeSessionKey: return "kSecItemTypeSessionKey"
        case .itemTypeCertificate: return "kSecItemTypeCertificate"
        case .itemTypeAggregate: return "kSecItemTypeAggregate"
        default: return "Unknown"
        }
    }

    /// The name of a SecKeychainAttrType, a four-character code.
    public static func name(ofAttribute attribute: UInt32) -> String {
        attributeNames[attribute] ?? "Unknown"
    }

    private static let attributeNames: [UInt32: String] = [
        code("cdat"): "kSecCreationDateItemAttr",
        code("mdat"): "kSecModDateItemAttr",
        code("desc"): "kSecDescriptionItemAttr",
        code("icmt"): "kSecCommentItemAttr",
        code("crtr"): "kSecCreatorItemAttr",
        code("type"): "kSecTypeItemAttr",
        code("scrp"): "kSecScriptCodeItemAttr",
        code("labl"): "kSecLabelItemAttr",
        code("invi"): "kSecInvisibleItemAttr",
        code("nega"): "kSecNegativeItemAttr",
        code("cusi"): "kSecCustomIconItemAttr",
        code("acct"): "kSecAccountItemAttr",
        code("svce"): "kSecServiceItemAttr",
        code("gena"): "kSecGenericItemAttr",
        code("sdmn"): "kSecSecurityDomainItemAttr",
        code("srvr"): "kSecServerItemAttr",
        code("atyp"): "kSecAuthenticationTypeItemAttr",
        code("port"): "kSecPortItemAttr",
        code("path"): "kSecPathItemAttr",
        code("vlme"): "kSecVolumeItemAttr",
        code("addr"): "kSecAddressItemAttr",
        code("ssig"): "kSecSignatureItemAttr",
        code("ptcl"): "kSecProtocolItemAttr",
        code("ctyp"): "kSecCertificateType",
        code("cenc"): "kSecCertificateEncoding",
        code("crtp"): "kSecCrlType",
        code("crnc"): "kSecCrlEncoding",
        code("alis"): "kSecAlias",
    ]

    /// The four-character code of `text`, as the Keychain's headers write it.
    static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
