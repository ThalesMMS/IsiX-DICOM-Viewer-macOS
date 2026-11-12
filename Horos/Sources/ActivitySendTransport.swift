//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMNetwork

/// The sends of `DICOMSendQueue`, each on a thread of its own that the
/// Activity window lists, with its name, progress and Cancel button: the
/// C-STORE of each part through `DCMTKStoreSCU`, the STOW-RS of a DICOMweb
/// node through `DICOMwebSendActivity`, and the direct transfer of a Horos
/// peer through `DirectTransferService`. Each is blocking work, which the
/// queue awaits without holding a thread of its own; Cancel in the window
/// stops it, and cancelling the queue's task cancels the thread.
struct ActivitySendTransport: DICOMSendTransport {
    func store(_ part: DICOMStorePart) async -> DICOMSendOutcome {
        let name = String(format: "%@ %@", NSLocalizedString("Sending...", comment: ""), part.patientName ?? "(null)")
        return await ActivityThread.run(name: name) {
            let thread = Thread.current
            thread.progress = 0
            thread.status = Self.count(part.files.count)

            let destination = part.destination
            let storeSCU = DCMTKStoreSCU(callingAET: part.callingAETitle, calledAET: destination.aeTitle,
                                         hostname: destination.address, port: part.port, filesToSend: part.files,
                                         transferSyntax: Int32(truncatingIfNeeded: part.transferSyntax),
                                         compression: part.compression, extraParameters: destination.propertyList)
            let failure = storeSCU.sendReportingFailure()
            if let failure {
                Self.report(failure)
            }
            if thread.isCancelled { return .cancelled }
            return failure == nil ? .sent : .failed
        }
    }

    func sendByDICOMweb(_ request: DICOMSendRequest) async -> DICOMSendOutcome {
        await ActivityThread.run(name: NSLocalizedString("Sending...", comment: "")) {
            let thread = Thread.current
            thread.progress = 0
            thread.status = Self.count(request.fileCount)
            DICOMwebSendActivity.send(files: request.allFiles, patientName: request.batches.first?.patientName,
                                      to: request.destination.propertyList, thread: thread)
            return thread.isCancelled ? .cancelled : .sent
        }
    }

    func sendByDirectTransfer(_ request: DICOMSendRequest) async -> DICOMSendOutcome {
        await ActivityThread.run(name: NSLocalizedString("Sending...", comment: "")) {
            let thread = Thread.current
            thread.progress = 0
            thread.status = Self.count(request.fileCount)

            let files = request.allFiles
            let destination = request.destination
            NSLog("Horos direct transfer selected: %lu files on one connection (no patient identifiers in the log)",
                  UInt(files.count))
            let sent = DirectTransferService.shared.send(files: files, toHost: destination.address ?? "",
                                                         port: destination["HorosDirectTransferPort"]?.intValue ?? 0,
                                                         token: destination["HorosDirectTransferToken"]?.stringValue ?? "",
                                                         activityThread: thread)
            if sent { return .sent }
            if thread.isCancelled { return .cancelled }
            NSLog("Horos direct transfer unavailable; falling back to DICOM C-STORE")
            thread.progress = 0
            thread.status = NSLocalizedString("Using DICOM transfer...", comment: "")
            return .failed
        }
    }

    /// N2LocalizedSingularPluralCount of files.
    private static func count(_ files: Int) -> String {
        String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: files), number: .decimal),
               files == 1 ? NSLocalizedString("file", comment: "") : NSLocalizedString("files", comment: ""))
    }

    /// The alert a part that did not send all its files shows, as its
    /// operation showed it.
    private static func report(_ failure: StoreSendFailure) {
        let message = String(format: "%@\r\r%@\r%@", NSLocalizedString("DICOM StoreSCU operation failed.", comment: ""),
                             failure.category.rawValue, failure.reason)
        onMainRunLoop {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send Error", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }
}
