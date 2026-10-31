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

import Foundation
import IsiXDICOMNetwork
import IsiXKeychain
import IsiXPreferences
import Synchronization

/// The DICOM listener (Query/Retrieve SCP) on one port, plain or TLS. It reads
/// the Listener preferences, opens the port through the DCMTK adapter
/// (IsiXDCMTKListener), says in the Listener preferences whether it listens,
/// and serves associations until it is aborted. Its thread is the one that
/// calls -run; -abort may come from any other.
/// @usableFromInline because plugins built against the former SDK look up its
/// Objective-C class: without it, the class symbol of an internal Swift class is
/// private external, which a Release build, having no testability, leaves
/// unexported. The attribute gives it public linkage and changes nothing else.
@objc(DCMTKQueryRetrieveSCP) @usableFromInline
final class DCMTKQueryRetrieveSCP: NSObject, @unchecked Sendable {

    /// Whether a listener is in its loop, the plain one and the TLS one.
    private static let serving = Mutex((plain: false, tls: false))

    /// Where a port that cannot be opened, a set-up that fails and an
    /// association that ends in error are said.
    static let notices = ApplicationNetworkNotices.process

    /// The suffix of the TLS files the listener writes.
    private static let tlsStringID = "StoreSCPTLS"

    private let listenerPort: Int32
    private let listenerAETitle: String?
    private let secure: Bool
    private let stateLock = NSLock()
    private var aborted = false
    private var isRunning = false

    /// Whether a listener of the application, or another one it was told of
    /// (NinjaSTORESCP), receives what a C-MOVE sends here.
    @objc(storeSCP)
    static func store() -> Bool {
        let listening = serving.withLock { $0.plain || $0.tls }
        return listening || PreferencesSource.process.preferences[NetworkPreferences.externalStoreSCP]
    }

    /// `params`: "TLSEnabled" (NSNumber) makes it the TLS listener.
    @objc(initWithPort:aeTitle:extraParamaters:)
    init(port: Int32, aeTitle: String?, extraParamaters params: [AnyHashable: Any]?) {
        listenerPort = port
        listenerAETitle = aeTitle
        secure = (params?["TLSEnabled"] as? NSNumber)?.boolValue ?? false
        super.init()
    }

    @objc func port() -> Int32 { listenerPort }
    @objc func aeTitle() -> String? { listenerAETitle }
    @objc func running() -> Bool { stateLock.withLock { isRunning } }

    @objc func abort() {
        NSLog("---- store-SCP abort !")
        stateLock.withLock { aborted = true }
    }

    private var isAborted: Bool { stateLock.withLock { aborted } }

    /// Opens the port and serves associations until -abort; returns when the
    /// listener has stopped, its associations ended, or when it could not start.
    @objc func run() {
        let preferences = PreferencesSource.process.preferences
        // One process, a thread per association, always: the mode that forked a
        // process per association is gone. SingleProcessMultiThreadedListener is
        // no longer read.
        if !NetworkPreferences.isOn(NetworkPreferences.singleProcessMultiThreadedListener, in: preferences, whenAbsent: true) {
            NSLog("--- DICOM listener: SingleProcessMultiThreadedListener is off, and ignored: the listener serves each association on a thread of its own")
        }
        let timeout = ListenerLimits.timeout(configured: preferences[NetworkPreferences.dicomTimeout])
        let configuredConnection = preferences[NetworkPreferences.dicomConnectionTimeout]
        if configuredConnection > 0 { NSLog("--- DICOMConnectionTimeout: %d", Int32(truncatingIfNeeded: configuredConnection)) }

        let settings = IsiXDCMTKListenerSettings()
        settings.port = listenerPort
        settings.aeTitle = ListenerAETitleRules.trimmed(listenerAETitle)
        settings.preferredTransferSyntax = preferences[NetworkPreferences.preferredSyntaxForIncoming]
        settings.timeout = Int32(truncatingIfNeeded: timeout)
        settings.connectionTimeout = Int32(truncatingIfNeeded: ListenerLimits.connectionTimeout(configured: configuredConnection, timeout: timeout))
        settings.maxAssociations = Int32(ListenerLimits.configuredMaximumAssociations)
        settings.secureConnection = secure
        settings.seedFile = DICOMTLS.seedFilePath().map { String(cString: $0) }
        guard let listener = IsiXDCMTKListener(settings: settings, host: ListenerHost(aeTitle: settings.aeTitle)) else {
            ListenerStatus.setNotListening(reason: ListenerStatus.internalErrorReason("DCMTK"), tls: secure)
            return
        }

        guard IsiXDCMTKListener.dataDictionaryLoaded else {
            FileHandle.standardError.write(Data("Warning: no data dictionary loaded, check environment variable: DCMDICTPATH\n".utf8))
            ListenerStatus.setNotListening(reason: ListenerStatus.missingDictionaryReason, tls: secure)
            return
        }
        // The listening socket is an IPv6 one that serves both families, and
        // binding it succeeds while another application holds the port's IPv4
        // address: both would listen, and every IPv4 connection would go to the
        // other one.
        let service = secure ? "DICOM TLS listen" : "DICOM listen"
        if ListenerStatus.isIPv4PortTaken(Int(listenerPort)) {
            Self.notices.listenBindFailed(service: service, port: Int(listenerPort), errno: EADDRINUSE)
            return
        }
        do {
            try listener.openNetwork()
        } catch {
            let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
            Self.notices.listenBindFailed(service: service, port: Int(listenerPort), errno: Int32(truncatingIfNeeded: code))
            return
        }

        // Every way out of the set-up closes the port opened above and frees the
        // TLS layer: the port was otherwise left listening, accepting connections
        // nothing answered, until the application quit.
        if secure, let message = setUpTLS(listener) {
            Self.displayListenerError(message)
            _ = listener.close()
            ListenerStatus.setNotListening(reason: ListenerStatus.tlsSettingsReason, tls: true)
            return
        }
        if let message = configure(listener, aeTitle: settings.aeTitle) {
            Self.displayListenerError(message)
            ListenerStatus.setNotListening(reason: ListenerStatus.settingsReason, tls: secure)
            _ = listener.close()
            return
        }

        Self.serving.withLock { if secure { $0.tls = true } else { $0.plain = true } }
        // The port is open and the configuration accepted: from here associations are answered.
        ListenerStatus.setListening(port: Int(listenerPort), tls: secure)
        // A stop asked for while the network was being set up still stops the loop.
        stateLock.withLock { isRunning = true }

        listener.serve(until: { [unowned self] in self.isAborted })

        if isAborted { NSLog("---- store-SCP aborted") }
        ListenerStatus.setEnded(tls: secure)
        // The associations end, then the port closes.
        _ = listener.close()
        Self.serving.withLock { if secure { $0.tls = false } else { $0.plain = false } }
        stateLock.withLock { isRunning = false }

        if secure {
            let files = FileManager.default
            try? files.removeItem(atPath: DICOMTLS.keyPath(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER, withStringID: Self.tlsStringID))
            try? files.removeItem(atPath: DICOMTLS.certificatePath(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER, withStringID: Self.tlsStringID))
            try? files.removeItem(atPath: DICOMTLS.trustedCertificatesFolder(withStringID: Self.tlsStringID))
        }
    }

    /// The TLS layer: the trusted certificates of the Keychain when peers are
    /// verified, the server identity, the cipher suites of the Listener
    /// preferences. nil, or what the user is told.
    private func setUpTLS(_ listener: IsiXDCMTKListener) -> String? {
        let preferences = PreferencesSource.process.preferences
        let advice = " You can turn OFF TLS Listener in Preferences->Listener."
        do {
            try listener.createTLSLayer()
        } catch {
            return "unable to create TLS transport layer"
        }
        // An unknown stored value becomes the strictest.
        let stored = preferences[NetworkPreferences.tlsListenerCertificateVerification]?.intValue ?? 0
        let verification = TLSVerificationPolicy.normalise(Int(stored))
        if verification == TLSVerificationPolicy.verify || verification == TLSVerificationPolicy.require {
            let folder = DICOMTLS.trustedCertificatesFolder(withStringID: Self.tlsStringID)
            KeychainExport.exportTrustedCertificates(toDirectory: folder)
            let certificates = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            do {
                try listener.addTrustedCertificateFiles(certificates.map { (folder as NSString).appendingPathComponent($0) })
            } catch {
                let file = (error as NSError).userInfo[IsiXDCMTKListenerFileKey] as? String ?? ""
                return "DICOM Network Failure (storescp TLS) : Unable to load certificate file \(file).\(advice)"
            }
        }
        // The certificate and key of the Keychain's server identity, written to disk.
        DICOMTLS.generateCertificateAndKey(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER, withStringID: Self.tlsStringID)
        let key = DICOMTLS.keyPath(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER, withStringID: Self.tlsStringID)
        let certificate = DICOMTLS.certificatePath(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER, withStringID: Self.tlsStringID)
        do {
            try listener.setPrivateKeyFile(key, certificateFile: certificate, password: DICOMTLS.privateKeyPassword())
        } catch {
            switch (error as NSError).userInfo[IsiXDCMTKOperationKey] as? String {
            case "setPrivateKeyFile":
                return "DICOM Network Failure (storescp TLS) : Unable to load private TLS key from \(key).\(advice)"
            case "setCertificateFile":
                return "DICOM Network Failure (storescp TLS) : Unable to load certificate from \(certificate).\(advice)"
            default:
                return "DICOM Network Failure (storescp TLS) : Unable to load certificate from private key '\(key)' and certificate '\(certificate)' do not match.\(advice)"
            }
        }
        let suites = (preferences[NetworkPreferences.tlsListenerCipherSuites] ?? []).compactMap { suite -> String? in
            guard case .dictionary(let suite) = suite, suite["Supported"]?.boolValue == true else { return nil }
            return suite["Cipher"]?.stringValue
        }
        do {
            try listener.setCipherSuites(suites, verification: Int32(verification))
        } catch {
            return "DICOM Network Failure (storescp TLS): \((error as NSError).userInfo[IsiXDCMTKConditionTextKey] as? String ?? "")"
        }
        do {
            try listener.attachTLSLayer()
        } catch {
            return "DICOM Network Failure (storescp TLS) : ASC_setTransportLayer - \(IsiXDCMTKError.conditionDescription(ofError: error)).\(advice)"
        }
        return nil
    }

    /// The AE title, then DCMTK's configuration and the association profile.
    /// nil, or what the user is told.
    private func configure(_ listener: IsiXDCMTKListener, aeTitle: String) -> String? {
        if let problem = ListenerAETitleRules.problem(with: aeTitle) { return problem + ListenerAETitleRules.turnOffAdvice }
        do {
            try listener.configure()
        } catch {
            let message = (error as NSError).localizedDescription
            if (error as NSError).userInfo[IsiXDCMTKOperationKey] as? String == "DcmAssociationConfiguration" { return message }
            return message + ListenerAETitleRules.turnOffAdvice
        }
        return nil
    }

    /// Shown in the notices panel, from the main thread.
    static func displayListenerError(_ message: String) {
        notices.listenerFailed(message)
    }
}

/// The folder where the per-association processes of earlier versions and the
/// application exchanged their lock, state and error files: the user's own
/// temporary folder. The listener no longer forks; the application still
/// clears files an earlier version left there.
@_cdecl("HorosDICOMProcessFolder")
public func HorosDICOMProcessFolder() -> UnsafePointer<CChar> {
    UnsafePointer(dicomProcessFolderPath.pointer)
}

/// The C copy of the folder's path, made once and never written or freed,
/// so only its address goes from thread to thread.
private let dicomProcessFolderPath = DICOMProcessFolderPath()

private struct DICOMProcessFolderPath: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CChar> =
        strdup(((NSTemporaryDirectory() as NSString).standardizingPath as NSString).fileSystemRepresentation)
}
