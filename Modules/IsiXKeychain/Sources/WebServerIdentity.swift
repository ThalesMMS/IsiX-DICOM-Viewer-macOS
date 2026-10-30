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

/// The identity the web portal and XML-RPC serve HTTPS with: the one the
/// preferences chose, or else a self-signed certificate made the first time
/// either server needs it and kept in the user's Keychain.
public enum WebServerIdentity {
    private static let creation = NSLock()

    /// The identity and the certificate chain its peers are shown, made if
    /// there is none; nil when none could be read or made.
    public static func identityAndChain(createIfMissing: Bool = true) -> (identity: SecIdentity, chain: [SecCertificate])? {
        var identity = KeychainIdentities.preferredIdentity(forName: KeychainIdentities.webServerName)
        if identity == nil && createIfMissing {
            // The portal and XML-RPC start together: the second to come
            // waits for the first one's identity instead of making another.
            creation.lock()
            identity = KeychainIdentities.preferredIdentity(forName: KeychainIdentities.webServerName)
            if identity == nil {
                createSelfSignedIdentity()
                identity = KeychainIdentities.preferredIdentity(forName: KeychainIdentities.webServerName)
            }
            creation.unlock()
        }
        guard let identity else { return nil }
        return (identity, KeychainIdentities.certificateChain(for: identity) ?? [])
    }

    /// The subject of the certificate made here: it says where the
    /// certificate comes from to whoever browses the Keychain.
    static let requestConfiguration = """
        [ req ]
        distinguished_name  = req_distinguished_name
        prompt              = no
        x509_extensions     = server_extensions

        [ req_distinguished_name ]
        C                   = BR
        ST                  = SC
        L                   = Florianopolis
        O                   = Horos Team
        OU                  = Open Source
        CN                  = Horos HTTP Server
        emailAddress        = horos@horosproject.org

        [ server_extensions ]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth

        """

    /// Makes a self-signed identity (`makeSelfSignedIdentity`) and makes it
    /// the identity `name` finds.
    @discardableResult
    public static func createSelfSignedIdentity(forName name: String = KeychainIdentities.webServerName,
                                                openssl: String = "/usr/bin/openssl") -> Bool {
        guard let identity = makeSelfSignedIdentity(openssl: openssl) else { return false }
        return KeychainIdentities.setPreferredIdentity(identity, forName: name) == errSecSuccess
    }

    /// Makes a self-signed RSA 2048/SHA-256 certificate valid for a year with
    /// openssl and imports it with its key into the user's Keychain (or the one
    /// `importOptions` names). The files openssl writes live in a private
    /// temporary folder, removed afterwards.
    public static func makeSelfSignedIdentity(openssl: String = "/usr/bin/openssl",
                                              importOptions: [String: Any] = [:]) -> SecIdentity? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IsiX HTTP Server \(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("Web server identity: %@", String(describing: error))
            return nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = folder.appendingPathComponent("private.pem").path
        let configuration = folder.appendingPathComponent("req.conf").path
        let certificate = folder.appendingPathComponent("certificate.crt").path
        let wrapper = folder.appendingPathComponent("certificate.p12").path
        let password = UUID().uuidString
        try? requestConfiguration.write(toFile: configuration, atomically: false, encoding: .utf8)

        let steps: [[String]] = [
            ["genrsa", "-out", key, "2048"],
            ["req", "-new", "-x509", "-sha256", "-key", key, "-config", configuration, "-out", certificate,
             "-days", "365", "-batch"],
            ["pkcs12", "-export", "-in", certificate, "-inkey", key, "-passout", "env:ISIX_IDENTITY_PASSWORD",
             "-out", wrapper, "-name", "OsiriX HTTP Server"],
        ]
        for arguments in steps {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: openssl)
            task.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["ISIX_IDENTITY_PASSWORD"] = password
            task.environment = environment
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                NSLog("Web server identity: openssl: %@", String(describing: error))
                return nil
            }
        }

        guard let data = FileManager.default.contents(atPath: wrapper) else {
            NSLog("Web server identity import failed: %@", KeychainIdentities.message(for: errSecDecode))
            return nil
        }
        var options = importOptions
        options[kSecImportExportPassphrase as String] = password
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            NSLog("Web server identity import failed: %@", KeychainIdentities.message(for: status))
            return nil
        }
        for item in (items as? [[String: Any]]) ?? [] {
            if let candidate = item[kSecImportItemIdentity as String],
               CFGetTypeID(candidate as CFTypeRef) == SecIdentityGetTypeID() {
                return (candidate as! SecIdentity)
            }
        }
        return nil
    }
}
