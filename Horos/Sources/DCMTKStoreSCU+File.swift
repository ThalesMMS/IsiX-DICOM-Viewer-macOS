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

/// The C-STORE of each file of a send: the file read, turned into the
/// transfer syntax the node accepted for it when needed (a copy, removed once
/// sent), sent, and its outcome added to the report.
struct StoreFileSender {
    let association: IsiXDCMTKAssociation
    let report: StoreReport
    let network: StoreNetworkSyntax
    let temporaryFiles: StoreTemporaryFiles

    /// The error the file ended on, nil when the node took it: the condition
    /// of a file that could not be read or offered, DIMSE_BADMESSAGE for one
    /// the node refused or that did not go through. Throws when the send
    /// cannot go on (the path of a copy would be too long).
    func send(_ path: String) throws -> (any Error)? {
        // A message ID for each file, sent or not, as before.
        let messageID = association.nextMessageID()
        guard let copyPath = temporaryFiles.nextPath() else {
            throw StoreSendFailure(name: NSExceptionName.genericException.rawValue,
                                   reason: "DICOM send temporary path is too long.", recorded: false)
        }

        let file: IsiXDCMTKStoreFile
        do {
            file = try IsiXDCMTKStoreFile(path: path)
        } catch {
            storeSCUDiagnostic("Bad DICOM file: \(path): \(error.conditionText)")
            report.recordUnreadable(path: path, reason: error.conditionText)
            return error
        }
        guard var sopClass = file.sopClassUID, file.sopInstanceUID != nil else {
            storeSCUDiagnostic("No SOP Class & Instance UIDs in file: \(path)")
            // DIMSE_BADDATA printed as "DIMSE Inappropriate data for message",
            // which a user saw and could do nothing with.
            report.recordWithoutIdentity(path: path)
            return IsiXDCMTKError.error(for: .illegalParameter)
        }

        // An uncompressed file of a deflated send looks for a deflated context first.
        var syntax = file.transferSyntax
        if syntax.usesNativeFormat && network.transferSyntax == TransferSyntaxUID.deflatedExplicitLittleEndian {
            syntax = IsiXDCMTKTransferSyntax(uid: TransferSyntaxUID.deflatedExplicitLittleEndian)
        }

        // Converted on the fly when the node accepted the send's syntax and the
        // file is not in it.
        let preferred = association.acceptedPresentationContext(forAbstractSyntax: sopClass, transferSyntax: network.transferSyntax)
        let accepted = preferred == 0 ? nil
            : IsiXDCMTKTransferSyntax(uid: association.acceptedTransferSyntax(ofPresentationContext: preferred) ?? "")
        var converted = false
        switch StoreConversion.of(fileSyntax: syntax.uid, file: syntax.traits, accepted: accepted?.traits,
                                  networkSyntax: network.transferSyntax) {
        case .none:
            break
        case .decompress:
            NSLog("SEND - decompress: %@", (path as NSString).lastPathComponent)
            converted = file.writeCopy(toPath: copyPath, transferSyntax: TransferSyntaxUID.explicitLittleEndian, quality: 0)
        case .compress(let warns):
            if warns {
                print("------ Warning! Recompression: presentation for syntax:\n\(IsiXDCMTKUIDs.name(ofUID: syntax.uid) ?? "(null)") -> "
                      + "\(IsiXDCMTKUIDs.name(ofUID: network.transferSyntax) ?? "(null)")")
            }
            converted = file.writeCopy(toPath: copyPath, transferSyntax: network.transferSyntax, quality: Int32(network.quality))
        }
        defer { if converted { unlink(copyPath) } }

        var sent = file
        if converted {
            guard let copy = try? IsiXDCMTKStoreFile(path: copyPath), let copiedClass = copy.sopClassUID, copy.sopInstanceUID != nil else {
                storeSCUDiagnostic("No SOP Class & Instance UIDs in file: \(copyPath)")
                report.recordWithoutIdentity(path: path)
                return IsiXDCMTKError.error(for: .illegalParameter)
            }
            sent = copy
            sopClass = copiedClass
            syntax = copy.transferSyntax
        }

        let context = association.acceptedPresentationContext(forAbstractSyntax: sopClass,
                                                               transferSyntax: syntax.known ? syntax.uid : nil)
        if context == 0 {
            let modality = IsiXDCMTKUIDs.modality(ofSOPClass: sopClass) ?? IsiXDCMTKUIDs.name(ofUID: sopClass) ?? "unknown SOP class"
            storeSCUDiagnostic("No presentation context for: (\(modality)) \(sopClass)")
            // The negotiation, not the file and not the message: the association
            // is up and the node simply will not take this SOP class in this
            // transfer syntax. A C-ECHO says nothing about that.
            report.recordNoPresentationContext(path: path, sopClassUID: "\(sopClass) (\(modality))",
                                               transferSyntax: IsiXDCMTKUIDs.name(ofUID: syntax.uid) ?? "an unknown transfer syntax")
            return IsiXDCMTKError.error(for: .noPresentationContext)
        }

        let result = association.store(sent, presentationContext: context, messageID: messageID)
        let statusText = String(format: "status 0x%04x (%@)", result.status, result.statusText)
        if result.accepted {
            report.recordSent(path: path, statusText: statusText)
            return nil
        }
        if let failure = result.condition {
            // The transmission itself failed. Nothing after this is worth
            // attempting on the same association.
            report.recordTransportFailure(path: path, reason: failure.conditionText)
        } else {
            // The node answered and refused this instance. The association is
            // still good; the next file may well be accepted.
            report.recordRejected(path: path, statusText: statusText)
        }
        return IsiXDCMTKError.error(for: .badMessage)
    }
}

extension IsiXDCMTKTransferSyntax {
    /// How the syntax holds pixel data, for the rules of IsiXDICOMNetwork.
    var traits: TransferSyntaxTraits {
        TransferSyntaxTraits(native: usesNativeFormat, encapsulated: usesEncapsulatedFormat, pixelDataCompressed: pixelDataCompressed)
    }
}
