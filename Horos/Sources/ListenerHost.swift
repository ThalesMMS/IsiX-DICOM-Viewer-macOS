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
import IsiXDICOMNetwork

/// What the listener of the DCMTK adapter asks the application, on the threads
/// of its connections and associations: the database of each association,
/// where a C-MOVE goes, which commands are answered, how many associations at
/// once, and the threads, activity and notices the user sees.
final class ListenerHost: NSObject, IsiXDCMTKListenerHost, @unchecked Sendable {

    /// The listener's AE title, as configured and trimmed.
    private let aeTitle: [UInt8]

    init(aeTitle: String) {
        self.aeTitle = Array(aeTitle.utf8)
        super.init()
    }

    func database(forCallingAETitle callingAETitle: String) -> any IsiXDCMTKSCPDatabase {
        SCPDatabaseSession(callingAETitle: callingAETitle)
    }

    func moveDestination(forAETitle aeTitle: String) -> IsiXDCMTKMoveDestination? {
        MoveDestinations.destination(forAETitle: aeTitle)
    }

    func answersCommand(_ command: IsiXDCMTKListenerCommand) -> Bool {
        let defaults = UserDefaults.standard
        return ListenerAcceptance.answers(Self.command(command), findEnabled: defaults.bool(forKey: "activateCFINDSCP"),
                                          getEnabled: defaults.bool(forKey: "activateCGETSCP"))
    }

    var maximumConcurrentAssociations: UInt {
        UInt(ListenerLimits.maximumAssociations(configured: UserDefaults.standard.integer(forKey: "maximumNumberOfConcurrentDICOMAssociations")))
    }

    func isListenerAETitle(_ calledAETitle: Data) -> Bool {
        ListenerAETitleRules.matches(called: Array(calledAETitle), configured: aeTitle)
    }

    func finalStatus(ofGet proposed: UInt16, completed: UInt, failed: UInt, warnings: UInt) -> UInt16 {
        UInt16(truncatingIfNeeded: HorosDIMSEPolicy.finalGetStatus(proposed: UInt(proposed), completed: completed, failed: failed,
                                                                   warnings: warnings, cancelled: false))
    }

    func associationEndedWithError(_ error: any Error, message: String) {
        // A remote abort ends only this association: its diagnostic stays in
        // the log, without a notice on the receiving Mac.
        if IsiXDCMTKError.kind(ofError: error) == .peerAbortedAssociation {
            NSLog("%@", message)
            return
        }
        DCMTKQueryRetrieveSCP.displayListenerError(message)
    }

    func startAssociationThread(_ thread: Thread, peer: String) {
        thread.name = NSLocalizedString("DICOM Services...", comment: "")
        thread.status = peer
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    func association(_ peer: String, willServe command: IsiXDCMTKListenerCommand, secure: Bool) {
        Thread.current.status = "\(peer) \(Self.command(command).name)\(secure ? " TLS" : "") SCP..."
    }

    func associationDidEnd() {
        DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
    }

    private static func command(_ command: IsiXDCMTKListenerCommand) -> ListenerCommand {
        switch command {
        case .store: return .store
        case .find: return .find
        case .move: return .move
        case .get: return .get
        default: return .echo
        }
    }
}
