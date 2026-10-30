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

/// The association of one send: its parameters and TLS files, the request,
/// its end, and the exception each failure gives -[DCMTKStoreSCU run:].
final class StoreAssociation {
    private let store: DCMTKStoreSCU
    private var association: IsiXDCMTKAssociation?
    /// The TLS files of this association are named with it.
    private let uniqueStringID = UUID().uuidString

    /// DCMTK's TLS layers of the sends are made and destroyed one at a time,
    /// with the Keychain's identities exported for them.
    private static let secureTransportLock = NSLock()

    init(store: DCMTKStoreSCU) {
        self.store = store
    }

    /// Makes the association for files of the storage SOP classes `classes`
    /// and asks the node for it.
    func open(classes: [String], network: StoreNetworkSyntax) throws -> IsiXDCMTKAssociation {
        let defaults = UserDefaults.standard
        let timeout = Int32(truncatingIfNeeded: max(defaults.integer(forKey: "DICOMTimeout"), 2))
        let parameters = IsiXDCMTKAssociationParameters()
        parameters.callingAETitle = store.callingAET ?? "STORESCU"
        parameters.calledAETitle = store.calledAET ?? "ANY-SCP"
        parameters.peerHost = store.hostname ?? ""
        parameters.peerPort = store.port
        parameters.acseTimeout = timeout
        parameters.dimseTimeout = timeout
        parameters.connectionTimeout = Int(Int32(truncatingIfNeeded: defaults.integer(forKey: "DICOMConnectionTimeout")))
        parameters.reportsFailures = true
        parameters.consoleApplication = "storescu"

        switch StoragePresentationPlan.contexts(preferredTransferSyntax: network.transferSyntax, required: classes,
                                                optional: IsiXDCMTKUIDs.shortStorageSOPClasses) {
        case .success(let contexts):
            parameters.presentationContexts = contexts.map {
                IsiXDCMTKPresentationContext(identifier: UInt8($0.identifier), abstractSyntax: $0.abstractSyntax,
                                             transferSyntaxes: $0.transferSyntaxes)
            }
        case .failure(let failure):
            storeSCUDiagnostic(failure == .tooManyRequiredContexts ? "Too many required presentation contexts" : "Too many presentation contexts")
            parameters.presentationContextsRefused = true
        }

        let made: IsiXDCMTKAssociation
        do {
            if store.tls.enabled {
                Self.secureTransportLock.lock()
                defer { Self.secureTransportLock.unlock() }
                prepareSecureTransport(parameters)
                made = try IsiXDCMTKAssociation(parameters: parameters)
            } else {
                made = try IsiXDCMTKAssociation(parameters: parameters)
            }
        } catch {
            throw Self.setUpFailure(error)
        }
        association = made

        if let refused = made.request() {
            let description = refused.conditionDescription
            let condition = refused.conditionKind == .associationRejected
                ? "Association Rejected \(description)" : "Association Request Failed \(description)"
            throw StoreSendFailure(name: StoreSendFailure.store,
                                   reason: NetworkDiagnosis.explainFailure(toHost: store.hostname ?? "", port: Int(store.port), condition: condition))
        }
        if made.acceptedPresentationContextCount == 0 {
            storeSCUDiagnostic("No Acceptable Presentation Contexts")
            throw StoreSendFailure(name: StoreSendFailure.store, reason: "No acceptable presentation contexts")
        }
        return made
    }

    /// Writes what DCMTK's TLS layer reads: the trusted certificates of the
    /// Keychain and, to authenticate this end, its key and certificate, each
    /// under a name of this association.
    private func prepareSecureTransport(_ parameters: IsiXDCMTKAssociationParameters) {
        let tls = store.tls
        let verification = Int32(TLSVerificationPolicy.normalise(tls.storedCertificateVerification))
        parameters.secureConnection = true
        parameters.seedFile = DICOMTLS.seedFilePath().map { String(cString: $0) }
        parameters.certificateVerification = verification
        parameters.cipherSuites = tls.cipherSuites
        parameters.dhParameterFile = tls.dhParameterFile
        if verification == Int32(TLSVerificationPolicy.verify) || verification == Int32(TLSVerificationPolicy.require) {
            let folder = DICOMTLS.trustedCertificatesFolder(withStringID: uniqueStringID)
            KeychainExport.exportTrustedCertificates(toDirectory: folder)
            let certificates = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            parameters.trustedCertificateFiles = certificates.map { (folder as NSString).appendingPathComponent($0) }
        }
        if tls.authenticated {
            parameters.privateKeyPassword = DICOMTLS.privateKeyPassword()
            // Exported from the Keychain to the disk for DCMTK.
            DICOMTLS.generateCertificateAndKey(forServerAddress: store.hostname, port: store.port, aeTitle: store.calledAET,
                                               withStringID: uniqueStringID)
            parameters.privateKeyFile = DICOMTLS.keyPath(forServerAddress: store.hostname, port: store.port, aeTitle: store.calledAET,
                                                         withStringID: uniqueStringID)
            parameters.certificateFile = DICOMTLS.certificatePath(forServerAddress: store.hostname, port: store.port,
                                                                  aeTitle: store.calledAET, withStringID: uniqueStringID)
        }
    }

    /// The exception of a failure to make the association, as each step named it.
    private static func setUpFailure(_ error: any Error) -> StoreSendFailure {
        let info = (error as NSError).userInfo
        if (info[IsiXDCMTKPeerAddressKey] as? NSNumber)?.boolValue == true {
            return StoreSendFailure(name: StoreSendFailure.network, reason: error.conditionText)
        }
        let secure = (info[IsiXDCMTKSecureTransportKey] as? NSNumber)?.boolValue == true
        let name = secure ? StoreSendFailure.secureStore : StoreSendFailure.store
        guard let operation = info[IsiXDCMTKOperationKey] as? String else {
            return StoreSendFailure(name: name, reason: error.localizedDescription)
        }
        let description = error.conditionDescription
        switch operation {
        case "ASC_setTransportLayer": return StoreSendFailure(name: name, reason: "ASC_setTransportLayer - \(description)")
        case "addPresentationContext": return StoreSendFailure(name: name, reason: "addStoragePresentationContexts \(description)")
        default: return StoreSendFailure(name: name, reason: "\(operation) \(description)")
        }
    }

    /// Releases the association after the files were sent, or aborts it after
    /// `condition`, the failure that ended them; throws the exception that
    /// gives.
    func end(after condition: (any Error)?) throws {
        guard let association else { return }
        guard let condition else {
            if let failed = association.releaseAssociation() {
                storeSCUDiagnostic("Association Release Failed:")
                FileHandle.standardError.write(Data("\(failed.conditionDescription)\n".utf8))
                throw StoreSendFailure(name: StoreSendFailure.store, reason: "Association Release Failed \(failed.conditionDescription)")
            }
            return
        }
        switch condition.conditionKind {
        case .peerRequestedRelease:
            storeSCUDiagnostic("Protocol Error: peer requested release (Aborting)")
            let failure = StoreSendFailure(name: StoreSendFailure.store,
                                           reason: "Protocol Error: peer requested release (Aborting) \(condition.conditionDescription)")
            abort(association)
            throw failure
        case .peerAbortedAssociation:
            return
        default:
            storeSCUDiagnostic("SCU Failed:")
            FileHandle.standardError.write(Data("\(condition.conditionDescription)\n".utf8))
            let failure = StoreSendFailure(name: StoreSendFailure.store, reason: "SCU Failed \(condition.conditionDescription)")
            abort(association)
            throw failure
        }
    }

    private func abort(_ association: IsiXDCMTKAssociation) {
        if let failed = association.closeTransportConnection() {
            storeSCUDiagnostic("Association Abort Failed:")
            FileHandle.standardError.write(Data("\(failed.conditionDescription)\n".utf8))
        }
    }

    /// Destroys the association, the network and the TLS layer, and removes
    /// the TLS files; the exception of a destruction that failed.
    func close() -> StoreSendFailure? {
        var failure: StoreSendFailure?
        func destroy() {
            if let failed = association?.invalidate() {
                let operation = (failed as NSError).userInfo[IsiXDCMTKOperationKey] as? String ?? "ASC_destroyAssociation"
                failure = StoreSendFailure(name: StoreSendFailure.store, reason: "\(operation) \(failed.conditionDescription)")
            }
            association = nil
        }
        guard store.tls.enabled else {
            destroy()
            return failure
        }
        Self.secureTransportLock.lock()
        defer { Self.secureTransportLock.unlock() }
        destroy()
        let files = FileManager.default
        try? files.removeItem(atPath: DICOMTLS.keyPath(forServerAddress: store.hostname, port: store.port, aeTitle: store.calledAET,
                                                       withStringID: uniqueStringID))
        try? files.removeItem(atPath: DICOMTLS.certificatePath(forServerAddress: store.hostname, port: store.port,
                                                               aeTitle: store.calledAET, withStringID: uniqueStringID))
        try? files.removeItem(atPath: DICOMTLS.trustedCertificatesFolder(withStringID: uniqueStringID))
        return failure
    }
}
