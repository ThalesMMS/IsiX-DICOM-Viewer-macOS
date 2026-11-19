/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXKeychain
import Security
import SecurityInterface
import Synchronization

/// The implementation of DDKeychain, declared in DDKeychain.h: the Keychain
/// helper of the Horos and OsiriX SDK's HTTP server. The class is Objective-C
/// for the runtime, so that a plugin built for either SDK finds it by name.
/// Every method forwards to what the application uses itself: the Keychain
/// module (IsiXKeychain) for the identities, their preferences and their
/// exports, and the preferences' presentation of a certificate. The password
/// of the former HTTP server, an item of the legacy file Keychain, is not
/// read nor written.
@objc @implementation extension DDKeychain {
    // MARK: Server

    class func passwordForHTTPServer() -> String! {
        FormerSDKFacade.inert("DDKeychain", "+passwordForHTTPServer",
                              because: "the application's HTTP servers keep no password in the Keychain")
        return nil
    }

    class func setPasswordForHTTPServer(_ password: String!) -> Bool {
        FormerSDKFacade.inert("DDKeychain", "+setPasswordForHTTPServer:",
                              because: "the application's HTTP servers keep no password in the Keychain")
        return false
    }

    /// Makes the self-signed identity of the web server and makes it the one
    /// its preference names.
    class func createNewIdentity() {
        WebServerIdentity.createSelfSignedIdentity()
    }

    /// The web server's identity, then the certificates of its chain that are
    /// not its own; empty when there is no identity. None is made here.
    @objc(SSLIdentityAndCertificates)
    class func sslIdentityAndCertificates() -> [Any]! {
        guard let found = WebServerIdentity.identityAndChain(createIfMissing: false) else { return [] }
        let leaf = KeychainIdentities.certificate(of: found.identity)
        let issuers = found.chain.filter { certificate in leaf.map { !CFEqual($0, certificate) } ?? true }
        return [found.identity] + issuers
    }

    // MARK: Utilities

    class func applicationTemporaryDirectory() -> String! {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriX HTTP Server")
        if !FileManager.default.fileExists(atPath: folder) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    @objc(stringForSecExternalFormat:)
    class func string(for extFormat: SecExternalFormat) -> String! {
        KeychainLegacyNames.name(of: extFormat)
    }

    @objc(stringForSecExternalItemType:)
    class func string(for itemType: SecExternalItemType) -> String! {
        KeychainLegacyNames.name(of: itemType)
    }

    @objc(stringForSecKeychainAttrType:)
    class func string(forSecKeychainAttrType attrType: SecKeychainAttrType) -> String! {
        KeychainLegacyNames.name(ofAttribute: attrType)
    }

    class func string(forError status: OSStatus) -> String! {
        KeychainIdentities.message(for: status)
    }

    // MARK: Keychain Access

    /// The identities a TLS server may present.
    @objc(KeychainAccessCertificatesList)
    class func keychainAccessCertificatesList() -> [Any]! {
        KeychainIdentities.serverIdentities() ?? []
    }

    @objc(KeychainAccessExportTrustedCertificatesToDirectory:)
    class func keychainAccessExportTrustedCertificates(toDirectory directory: String!) {
        guard let directory else { return }
        KeychainExport.exportTrustedCertificates(toDirectory: directory)
    }

    /// Retained: the caller releases it.
    @objc(KeychainAccessPreferredIdentityForName:keyUse:)
    class func keychainAccessPreferredIdentity(forName name: String!, keyUse: Int32) -> Unmanaged<SecIdentity>! {
        guard let name, let identity = KeychainIdentities.preferredIdentity(forName: name) else { return nil }
        return Unmanaged.passRetained(identity)
    }

    @objc(KeychainAccessSetPreferredIdentity:forName:keyUse:)
    class func keychainAccessSetPreferredIdentity(_ identity: SecIdentity!, forName name: String!, keyUse: Int32) {
        guard let identity, let name else { return }
        KeychainIdentities.setPreferredIdentity(identity, forName: name)
    }

    @objc(KeychainAccessCertificateCommonNameForIdentity:)
    class func keychainAccessCertificateCommonName(for identity: SecIdentity!) -> String! {
        guard let identity, let certificate = KeychainIdentities.certificate(of: identity) else { return nil }
        return KeychainIdentities.commonName(of: certificate)
    }

    /// Gold for a self-signed certificate, blue otherwise, as the preferences show it.
    @objc(KeychainAccessCertificateIconForIdentity:)
    class func keychainAccessCertificateIcon(for identity: SecIdentity!) -> NSImage! {
        guard let identity, let certificate = KeychainIdentities.certificate(of: identity) else { return nil }
        return NSImage(named: KeychainIdentities.isSelfIssued(certificate) ? "CertSmallRoot.tif" : "CertSmallStd.tif")
    }

    @objc(KeychainAccessCertificateChainForIdentity:)
    class func keychainAccessCertificateChain(for identity: SecIdentity!) -> [Any]! {
        guard let identity else { return nil }
        return KeychainIdentities.certificateChain(for: identity)
    }

    @objc(KeychainAccessExportCertificateForIdentity:toPath:)
    class func keychainAccessExportCertificate(for identity: SecIdentity!, toPath path: String!) {
        guard let identity, let path else { return }
        KeychainExport.exportCertificate(of: identity, toPath: path)
    }

    @objc(KeychainAccessExportPrivateKeyForIdentity:toPath:cryptWithPassword:)
    class func keychainAccessExportPrivateKey(for identity: SecIdentity!, toPath path: String!, cryptWithPassword password: String!) {
        guard let identity, let path, let password else { return }
        KeychainExport.exportPrivateKey(of: identity, toPath: path, password: password)
    }

    /// Shows the certificate and its chain in the system's panel, modally, on
    /// the main thread.
    @objc(KeychainAccessOpenCertificatePanelForIdentity:)
    class func keychainAccessOpenCertificatePanel(for identity: SecIdentity!) {
        guard let identity, let certificate = KeychainIdentities.certificate(of: identity) else { return }
        let certificates = DDKeychainCertificates([certificate] + (KeychainIdentities.certificateChain(for: certificate) ?? []))
        DDKeychainState.onMainThread {
            SFCertificatePanel.shared().runModal(forCertificates: certificates.list, showGroup: true)
        }
    }

    // MARK: By label

    /// Retained: the caller releases it.
    class func identity(forLabel label: String!) -> Unmanaged<SecIdentity>! {
        guard let label, let identity = KeychainIdentities.preferredIdentity(forName: label) else { return nil }
        return Unmanaged.passRetained(identity)
    }

    class func certificateName(forLabel label: String!) -> String! {
        KeychainCertificatePresentation.certificateName(forLabel: label)
    }

    class func certificateIcon(forLabel label: String!) -> NSImage! {
        KeychainCertificatePresentation.certificateIcon(forLabel: label)
    }

    class func openCertificatePanel(forLabel label: String!) {
        let name = label
        DDKeychainState.onMainThread {
            KeychainCertificatePresentation.openCertificatePanel(forLabel: name)
        }
    }

    // MARK: Other utilities

    /// Bytes of the system's random generator, in hexadecimal. The SDK wrote
    /// the mouse's position and the time, for openssl to seed itself with.
    class func generatePseudoRandomFile(toPath path: String!) {
        guard let path else { return }
        var bytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let text = bytes.map { String(format: "%02x", $0) }.joined()
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Counts one more user of the file at `path`.
    class func lockFile(_ path: String!) {
        guard let path else { return }
        let users = DDKeychainState.lockedFiles.withLock { files -> Int in
            files[path, default: 0] += 1
            return files[path] ?? 0
        }
        NSLog("lockFile: %d %@", Int32(truncatingIfNeeded: users), path)
    }

    /// Counts one user less of the file at `path`, and forgets it at none.
    class func unlockFile(_ path: String!) {
        guard let path else { return }
        let users = DDKeychainState.lockedFiles.withLock { files -> Int? in
            guard let users = files[path] else { return nil }
            files[path] = users - 1 == 0 ? nil : users - 1
            return users - 1
        }
        if let users {
            NSLog("unlockFile: %d %@", Int32(truncatingIfNeeded: users), path)
        }
    }

    class func lockTmpFiles() {
        DDKeychainState.temporaryFiles.lock()
    }

    class func unlockTmpFiles() {
        DDKeychainState.temporaryFiles.unlock()
    }
}

/// What the class keeps between calls: the users of the files it was told
/// about, and the lock of its temporary files.
private enum DDKeychainState {
    static let lockedFiles = Mutex<[String: Int]>([:])
    static let temporaryFiles = NSRecursiveLock()

    /// Runs `body` on the main thread and waits for it: a certificate panel is
    /// modal there.
    static func onMainThread(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}

/// Certificates on their way to the main thread, where the panel shows them.
private struct DDKeychainCertificates: @unchecked Sendable {
    let list: [SecCertificate]
    init(_ list: [SecCertificate]) { self.list = list }
}
