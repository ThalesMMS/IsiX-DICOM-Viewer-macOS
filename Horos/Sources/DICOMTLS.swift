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

import CoreGraphics
import Foundation
import IsiXKeychain

/// The files of secure DICOM connections: the TLS identities of the Keychain
/// exported for DCMTK, the random seed, and the folder they are written to.
/// The cipher suites DCMTK knows come from the DCMTK adapter.
///
/// The files are in a folder of the user's own temporary folder (made with
/// mode 0700 on first use). They were in /tmp under fixed names, where another
/// user could put a trusted certificate or a link in place first.
@objc(DICOMTLS)
public final class DICOMTLS: NSObject {

    // MARK: Cipher suites

    /// The TLS cipher suites DCMTK knows, by name.
    @objc public static func availableCipherSuites() -> [String] {
        IsiXDCMTKAssociation.availableCipherSuites
    }

    /// Each suite DCMTK knows, as Locations and the listener's preferences
    /// keep them: {Cipher, Supported = NO}.
    @objc public static func defaultCipherSuites() -> [NSMutableDictionary] {
        availableCipherSuites().map { suite in
            NSMutableDictionary(dictionary: ["Supported": NSNumber(value: false), "Cipher": suite])
        }
    }

    // MARK: Files

    private static let folder = ((NSTemporaryDirectory() as NSString).standardizingPath as NSString).appendingPathComponent("DICOM TLS")

    /// The folder of the TLS files, made again if it was erased; only the user
    /// can write in the folder above it.
    @objc public static func temporaryFolder() -> String {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// The random seed DCMTK's TLS layer reads (TLS_SEED_FILE), as the C
    /// string DCMTK takes, valid for the life of the application.
    @objc public static func seedFilePath() -> UnsafePointer<CChar>? {
        _ = temporaryFolder()
        return seedFile
    }

    nonisolated(unsafe) private static let seedFile =
        UnsafePointer(strdup(((folder as NSString).appendingPathComponent("OsiriXTLSSeed") as NSString).fileSystemRepresentation))

    /// Writes a seed for DCMTK's random generator to `path`: the pointer's
    /// location and the time. The pointer is read through Core Graphics, which
    /// any thread may ask; the associations write the seed on their own.
    @objc public static func writePseudoRandomSeed(toPath path: String) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let seed = String(format: "%f%f%lf", Double(location.x), Double(location.y), Date().timeIntervalSince1970)
        try? seed.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Removes the folder of the TLS files and everything in it.
    @objc public static func eraseKeys() {
        try? FileManager.default.removeItem(atPath: temporaryFolder())
    }

    /// The password the exported private keys are encrypted with: ten letters
    /// and digits drawn once per launch.
    @objc(TLS_PRIVATE_KEY_PASSWORD)
    public static func privateKeyPassword() -> String {
        privateKeyPasswordValue
    }

    private static let privateKeyPasswordValue: String = {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<10).map { _ in letters[Int(arc4random_uniform(UInt32(letters.count)))] })
    }()

    // MARK: Keychain identities

    /// Exports the Keychain identity `label` (its certificate and its private
    /// key, encrypted) to the files certificatePath and keyPath name with `stringID`.
    @objc(generateCertificateAndKeyForLabel:withStringID:)
    public static func generateCertificateAndKey(forLabel label: String?, withStringID stringID: String?) {
        guard let label, let identity = KeychainIdentities.preferredIdentity(forName: label) else { return }
        KeychainExport.exportCertificate(of: identity, toPath: certificatePath(forLabel: label, withStringID: stringID))
        KeychainExport.exportPrivateKey(of: identity, toPath: keyPath(forLabel: label, withStringID: stringID),
                                        password: privateKeyPassword())
    }

    @objc(generateCertificateAndKeyForLabel:)
    public static func generateCertificateAndKey(forLabel label: String?) {
        generateCertificateAndKey(forLabel: label, withStringID: "")
    }

    @objc(generateCertificateAndKeyForServerAddress:port:AETitle:withStringID:)
    public static func generateCertificateAndKey(forServerAddress address: String?, port: Int32, aeTitle: String?, withStringID stringID: String?) {
        generateCertificateAndKey(forLabel: uniqueLabel(forServerAddress: address, port: String(port), aeTitle: aeTitle), withStringID: stringID)
    }

    @objc(generateCertificateAndKeyForServerAddress:port:AETitle:)
    public static func generateCertificateAndKey(forServerAddress address: String?, port: Int32, aeTitle: String?) {
        generateCertificateAndKey(forServerAddress: address, port: port, aeTitle: aeTitle, withStringID: "")
    }

    /// The Keychain label of the client identity for a node: the client prefix,
    /// the address, the port and the AE title, separated by dots.
    @objc(uniqueLabelForServerAddress:port:AETitle:)
    public static func uniqueLabel(forServerAddress address: String?, port: String?, aeTitle: String?) -> String {
        [TLS_KEYCHAIN_IDENTITY_NAME_CLIENT, address ?? "", port ?? "", aeTitle ?? ""].joined(separator: ".")
    }

    @objc(keyPathForLabel:withStringID:)
    public static func keyPath(forLabel label: String?, withStringID stringID: String?) -> String {
        "\((temporaryFolder() as NSString).appendingPathComponent("TLSKey")).\(described(label)).\(described(stringID))"
    }

    @objc(keyPathForLabel:)
    public static func keyPath(forLabel label: String?) -> String {
        keyPath(forLabel: label, withStringID: "")
    }

    @objc(keyPathForServerAddress:port:AETitle:withStringID:)
    public static func keyPath(forServerAddress address: String?, port: Int32, aeTitle: String?, withStringID stringID: String?) -> String {
        keyPath(forLabel: uniqueLabel(forServerAddress: address, port: String(port), aeTitle: aeTitle), withStringID: stringID)
    }

    @objc(keyPathForServerAddress:port:AETitle:)
    public static func keyPath(forServerAddress address: String?, port: Int32, aeTitle: String?) -> String {
        keyPath(forServerAddress: address, port: port, aeTitle: aeTitle, withStringID: "")
    }

    @objc(certificatePathForLabel:withStringID:)
    public static func certificatePath(forLabel label: String?, withStringID stringID: String?) -> String {
        "\((temporaryFolder() as NSString).appendingPathComponent("TLSCert")).\(described(label)).\(described(stringID))"
    }

    @objc(certificatePathForLabel:)
    public static func certificatePath(forLabel label: String?) -> String {
        certificatePath(forLabel: label, withStringID: "")
    }

    @objc(certificatePathForServerAddress:port:AETitle:withStringID:)
    public static func certificatePath(forServerAddress address: String?, port: Int32, aeTitle: String?, withStringID stringID: String?) -> String {
        certificatePath(forLabel: uniqueLabel(forServerAddress: address, port: String(port), aeTitle: aeTitle), withStringID: stringID)
    }

    @objc(certificatePathForServerAddress:port:AETitle:)
    public static func certificatePath(forServerAddress address: String?, port: Int32, aeTitle: String?) -> String {
        certificatePath(forServerAddress: address, port: port, aeTitle: aeTitle, withStringID: "")
    }

    /// The folder the trusted certificates of the Keychain are exported to for
    /// one association (TLS_TRUSTED_CERTIFICATES_DIR followed by `stringID`).
    @objc(trustedCertificatesFolderWithStringID:)
    public static func trustedCertificatesFolder(withStringID stringID: String) -> String {
        (temporaryFolder() as NSString).appendingPathComponent("TLSTrustedCert") + stringID
    }

    /// %@ of a string that may be nil, as the paths were formatted.
    private static func described(_ value: String?) -> String {
        value ?? "(null)"
    }
}
