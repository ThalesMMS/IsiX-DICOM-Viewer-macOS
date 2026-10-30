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

/// What DICOM TLS hands to DCMTK, which reads PEM files: an identity's
/// certificate and private key, and the certificates the system trusts.
public enum KeychainExport {
    /// Writes the identity's certificate, PEM-encoded, to `path`. A file
    /// already there is kept.
    public static func exportCertificate(of identity: SecIdentity, toPath path: String) {
        if FileManager.default.fileExists(atPath: path) { return }
        guard let certificate = KeychainIdentities.certificate(of: identity) else { return }
        var data: CFData?
        let status = SecItemExport(certificate, .formatX509Cert, .pemArmour, nil, &data)
        guard status == errSecSuccess, let data = data as Data? else {
            NSLog("SecItemExport : error : %@", KeychainIdentities.message(for: status))
            return
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Writes the identity's private key, PEM-encoded and encrypted with
    /// `password`, to `path`. A file already there is kept.
    ///
    /// The Security framework exports a private key only inside a PKCS#12
    /// file; openssl takes the key out of it. The password reaches openssl
    /// through its environment, not its arguments, which every user of the
    /// machine can read while it runs, and the PKCS#12 file is removed.
    public static func exportPrivateKey(of identity: SecIdentity, toPath path: String, password: String,
                                        openssl: String = "/usr/bin/openssl") {
        if FileManager.default.fileExists(atPath: path) { return }
        var key: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &key)
        guard keyStatus == errSecSuccess, key != nil else {
            NSLog("SecIdentityCopyPrivateKey : error : %@", KeychainIdentities.message(for: keyStatus))
            return
        }
        let passphrase = password as CFString
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.passphrase = Unmanaged.passUnretained(passphrase as AnyObject)
        var data: CFData?
        let status = withExtendedLifetime(passphrase) {
            SecItemExport(identity, .formatPKCS12, [], &parameters, &data)
        }
        guard status == errSecSuccess, let data = data as Data? else {
            NSLog("SecItemExport : error : %@", KeychainIdentities.message(for: status))
            return
        }
        let p12 = path + ".p12"
        do {
            try data.write(to: URL(fileURLWithPath: p12), options: .atomic)
        } catch {
            NSLog("KeychainExport.exportPrivateKey: %@", String(describing: error))
            return
        }
        defer { try? FileManager.default.removeItem(atPath: p12) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: openssl)
        task.arguments = ["pkcs12", "-nocerts", "-in", p12, "-out", path,
                          "-passin", "env:HOROS_TLS_KEY_PASSWORD", "-passout", "env:HOROS_TLS_KEY_PASSWORD"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOROS_TLS_KEY_PASSWORD"] = password
        task.environment = environment
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("KeychainExport.exportPrivateKey: openssl: %@", String(describing: error))
        }
    }

    /// Writes the certificates of the user's, the administrator's and the
    /// system's trust settings, one PEM file each (`<domain>_<index>.pem`),
    /// into `directory`, which is made for them. A directory already there is
    /// taken as done and left as it is.
    public static func exportTrustedCertificates(toDirectory directory: String) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        let domains: [SecTrustSettingsDomain] = [.user, .admin, .system]
        for (domainIndex, domain) in domains.enumerated() {
            var certificates: CFArray?
            let status = SecTrustSettingsCopyCertificates(domain, &certificates)
            if status != errSecSuccess {
                NSLog("SecTrustSettingsCopyCertificates: %@", KeychainIdentities.message(for: status))
            }
            guard let list = certificates as? [SecCertificate] else { continue }
            for (index, certificate) in list.enumerated() {
                var data: CFData?
                let exportStatus = SecItemExport(certificate, .formatX509Cert, .pemArmour, nil, &data)
                guard exportStatus == errSecSuccess, let data = data as Data? else {
                    NSLog("SecItemExport : error : %@", KeychainIdentities.message(for: exportStatus))
                    continue
                }
                let path = (directory as NSString).appendingPathComponent("\(domainIndex)_\(index).pem")
                if !FileManager.default.fileExists(atPath: path) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
    }
}
