//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Cocoa
import IsiXKeychain
import SecurityInterface

/// How the preferences show the Keychain identity an identity preference
/// names: its common name, an icon (gold for a self-signed certificate, blue
/// otherwise) and the system's certificate panel.
enum KeychainCertificatePresentation {
    static func certificateName(forLabel label: String?) -> String? {
        guard let label, let identity = KeychainIdentities.preferredIdentity(forName: label),
              let certificate = KeychainIdentities.certificate(of: identity) else { return nil }
        return KeychainIdentities.commonName(of: certificate)
    }

    static func certificateIcon(forLabel label: String?) -> NSImage? {
        guard let label, let identity = KeychainIdentities.preferredIdentity(forName: label),
              let certificate = KeychainIdentities.certificate(of: identity) else { return nil }
        return NSImage(named: KeychainIdentities.isSelfIssued(certificate) ? "CertSmallRoot.tif" : "CertSmallStd.tif")
    }

    /// Shows the certificate and its chain in the system's panel, modally.
    @MainActor
    static func openCertificatePanel(forLabel label: String?) {
        guard let label, let identity = KeychainIdentities.preferredIdentity(forName: label),
              let certificate = KeychainIdentities.certificate(of: identity) else { return }
        var certificates: [SecCertificate] = [certificate]
        certificates += KeychainIdentities.certificateChain(for: certificate) ?? []
        SFCertificatePanel.shared().runModal(forCertificates: certificates, showGroup: true)
    }
}
