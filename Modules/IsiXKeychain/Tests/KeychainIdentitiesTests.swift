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

/// The certificate reading of the TLS identities, on certificates made here
/// with openssl and read from memory: no Keychain is touched. The Keychain
/// itself (preferences, the self-signed identity, the exports DICOM TLS uses)
/// is tests/test-keychain-identities.py, on a disposable Keychain.
struct KeychainIdentitiesTests {

    private func certificate(subject: String, extensions: [String] = []) throws -> SecCertificate {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IsiXKeychainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let der = folder.appendingPathComponent("c.der").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", folder.appendingPathComponent("k.pem").path,
                          "-outform", "DER", "-out", der, "-days", "1", "-sha256", "-subj", subject]
            + extensions.flatMap { ["-addext", $0] }
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: der))
        return try #require(SecCertificateCreateWithData(nil, data as CFData))
    }

    @Test func aCertificateIsReadForItsNameAndIssuer() throws {
        let made = try certificate(subject: "/CN=Synthetic Portal")
        #expect(KeychainIdentities.commonName(of: made) == "Synthetic Portal")
        #expect(KeychainIdentities.isSelfIssued(made))
        let chain = try #require(KeychainIdentities.certificateChain(for: made))
        #expect(chain.count == 1)
        #expect(CFEqual(chain[0], made))
    }

    @Test func aServerCertificateMayBeUsedForSignatures() throws {
        #expect(KeychainIdentities.allowsServerUse(try certificate(subject: "/CN=Any use")))
        #expect(KeychainIdentities.allowsServerUse(try certificate(subject: "/CN=Signing",
                                                                   extensions: ["keyUsage=critical,digitalSignature"])))
        #expect(!KeychainIdentities.allowsServerUse(try certificate(subject: "/CN=Encipherment only",
                                                                    extensions: ["keyUsage=critical,keyEncipherment"])))
    }

    @Test func theSelfSignedCertificateSaysWhereItComesFrom() {
        let configuration = WebServerIdentity.requestConfiguration
        #expect(configuration.contains("CN                  = Horos HTTP Server"))
        #expect(configuration.contains("extendedKeyUsage = serverAuth"))
        #expect(configuration.contains("keyUsage = critical,digitalSignature,keyEncipherment"))
        #expect(KeychainIdentities.webServerName == "org.horosproject.horoswebserver")
    }

    @Test func statusesAreDescribed() {
        #expect(!KeychainIdentities.message(for: errSecItemNotFound).isEmpty)
    }
}
