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

/// The Keychain identities (a certificate with its private key) the app's TLS
/// servers and clients present: the web portal and XML-RPC over HTTPS, and
/// DICOM TLS. An identity is found by the name of an identity preference
/// (`SecIdentitySetPreferred`), which the preferences set when the user picks
/// a certificate.
public enum KeychainIdentities {
    /// The identity preference of the web portal and XML-RPC servers.
    public static let webServerName = "org.horosproject.horoswebserver"

    /// The identity a preference names, for any key use; nil when none.
    public static func preferredIdentity(forName name: String) -> SecIdentity? {
        SecIdentityCopyPreferred(name as CFString, nil, nil)
    }

    /// Makes `identity` the one `name` finds, for any key use.
    @discardableResult
    public static func setPreferredIdentity(_ identity: SecIdentity, forName name: String) -> OSStatus {
        let status = SecIdentitySetPreferred(identity, name as CFString, nil)
        if status != errSecSuccess {
            NSLog("Identity preference failed: %@", message(for: status))
        }
        return status
    }

    /// The identities of the Keychain a TLS server may present: those whose
    /// certificate is visible and allows digital signatures (or does not say).
    /// Empty when there is none; nil when the Keychain cannot be read.
    public static func serverIdentities() -> [SecIdentity]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            NSLog("KeychainIdentities.serverIdentities: SecItemCopyMatching failed: %@", message(for: status))
            return nil
        }
        var identities: [SecIdentity] = []
        for item in items {
            guard let reference = item[kSecValueRef as String], CFGetTypeID(reference as CFTypeRef) == SecIdentityGetTypeID() else {
                continue
            }
            let identity = reference as! SecIdentity
            guard let certificate = certificate(of: identity) else { continue }
            if allowsServerUse(certificate) {
                identities.append(identity)
            }
        }
        return identities
    }

    /// A certificate whose values are not marked invisible and whose key usage
    /// is absent, empty, or includes digital signature (bit 0).
    public static func allowsServerUse(_ certificate: SecCertificate) -> Bool {
        let values = SecCertificateCopyValues(certificate, nil, nil) as? [String: Any] ?? [:]
        if let invisible = values[kSecAttrIsInvisible as String] as? Bool, invisible {
            return false
        }
        var usage = 0
        if let keyUsage = values[kSecOIDKeyUsage as String] as? [String: Any] {
            usage = (keyUsage[kSecPropertyKeyValue as String] as? NSNumber)?.intValue ?? 0
        }
        return usage == 0 || usage & 1 != 0
    }

    /// The certificate of an identity.
    public static func certificate(of identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        if status != errSecSuccess {
            NSLog("SecIdentityCopyCertificate: error: %@", message(for: status))
        }
        return certificate
    }

    /// The common name of a certificate's subject.
    public static func commonName(of certificate: SecCertificate) -> String? {
        var name: CFString?
        let status = SecCertificateCopyCommonName(certificate, &name)
        guard status == errSecSuccess else {
            NSLog("KeychainIdentities.commonName: error: %@", message(for: status))
            return nil
        }
        return name as String?
    }

    /// Whether the certificate was issued by its own subject (self-signed).
    public static func isSelfIssued(_ certificate: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) else { return false }
        return CFEqual(subject, issuer)
    }

    /// The chain a TLS peer is shown with the certificate, built by the
    /// system's trust evaluation for an SSL server. An untrusted (self-signed)
    /// certificate still gives its chain: trust is not decided here.
    public static func certificateChain(for certificate: SecCertificate) -> [SecCertificate]? {
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, nil)
        guard SecTrustCreateWithCertificates([certificate] as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return nil
        }
        var error: CFError?
        _ = SecTrustEvaluateWithError(trust, &error)
        return SecTrustCopyCertificateChain(trust) as? [SecCertificate]
    }

    /// The certificate chain of an identity's certificate.
    public static func certificateChain(for identity: SecIdentity) -> [SecCertificate]? {
        certificate(of: identity).flatMap { certificateChain(for: $0) }
    }

    /// The system's message for a Security status.
    public static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Security status \(status)"
    }
}
