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
import IsiXDICOMNetwork
import IsiXKeychain
import Synchronization

/// The "Connecting to..." window of a request made on the main thread, which
/// keeps the main run loop going while the request waits. Off the main
/// thread there is none, and every call does nothing.
final class QueryProgressWindow: @unchecked Sendable {
    private var wait: WaitRendering?

    init?(message: String, showWindow: Bool = false) {
        guard Thread.isMainThread else { return nil }
        MainActor.assumeIsolated {
            let window = WaitRendering(message)
            window?.setCancel(true)
            if showWindow { window?.showWindow(nil) }
            window?.start()
            wait = window
        }
    }

    func run() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { _ = wait?.run() }
    }

    var aborted: Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { wait?.aborted() ?? false }
    }

    func end() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            wait?.end()
            wait = nil
        }
    }
}

/// A failure of an association, as the notices and the log name it.
struct AssociationFailure: Error {
    let name: String
    let reason: String

    static let query = "DICOM Network Failure (query)"
    static let secureQuery = "DICOM Network Failure (TLS query)"
}

/// What the adapter's NSErrors say of a DCMTK condition; Swift sees them as Error.
extension Error {
    /// The DCMTK condition is good(), though not EC_Normal.
    var isGoodCondition: Bool { ((self as NSError).userInfo[IsiXDCMTKConditionGoodKey] as? NSNumber)?.boolValue ?? false }
    var conditionKind: IsiXDCMTKConditionKind { IsiXDCMTKError.kind(ofError: self as NSError) }
    /// "mmmm:cccc text", as the logs and notices give a condition.
    var conditionDescription: String { IsiXDCMTKError.conditionDescription(ofError: self as NSError) }
    var conditionText: String { (self as NSError).userInfo[IsiXDCMTKConditionTextKey] as? String ?? localizedDescription }
}

/// The DIMSE associations of a node: verification, C-FIND, C-MOVE and C-GET,
/// what to say when they fail, and the progress of a retrieve. What DCMTK
/// does for them is in Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.
extension DCMTKQueryNode {
    private static let associationNumber = Atomic<Int32>(0)

    /// Verbose output, as the service class users have always had it on.
    static let verboseAssociations = true

    private static func standardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func errmsg(_ text: String) {
        standardError("DCMTKQueryNode: \(text)\n")
    }

    /// The node's settings as the description of a failure gives them.
    var nodeConfigurationDescription: String {
        DicomNodeConfiguration.description(forServer: extraParameters() as? [String: Any] ?? [:], callingAETitle: callingAETitle)
    }

    // MARK: Verification

    /// Locations' Verify, which reaches it by name through a Foundation-only
    /// runtime bridge: its preference pane lives below this executable.
    @objc(verifyDICOMServer:)
    class func verifyDICOMServer(_ server: [AnyHashable: Any]?) -> Bool {
        if DICOMwebSources.isDICOMwebServer(server) {
            if Thread.isMainThread {
                let success = QueryNodeShared(false)
                let done = DispatchSemaphore(value: 0)
                nonisolated(unsafe) let parameters = server
                let worker = Thread {
                    autoreleasepool {
                        success.modify { $0 = verifyDICOMServer(parameters) }
                        done.signal()
                    }
                }
                let wait = QueryProgressWindow(message: NSLocalizedString("Verifying DICOMweb...", comment: ""), showWindow: true)
                worker.start()
                while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                    wait?.run()
                    if wait?.aborted == true { worker.cancel() }
                }
                wait?.end()
                return success.current
            }
            do {
                try DICOMwebSources.client(forServer: server, timeout: 10).verify()
                return true
            } catch {
                return false
            }
        }
        let address = server?["Address"] as? String ?? "", title = server?["AETitle"] as? String ?? ""
        let port = Self.int32(server?["Port"])
        guard !address.isEmpty, !title.isEmpty, port > 0, port <= 65535 else { return false }
        let node = self.init(dataset: nil, callingAET: UserDefaults.defaultAETitle(), calledAET: title, hostname: address,
                             port: port, transferSyntax: Self.int32(server?["TransferSyntax"]), compression: 0,
                             extraParameters: server)
        return node.setupNetwork(service: .verification, identifier: nil)
    }

    /// -intValue of a property-list value: a number or a text.
    static func int32(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let text = value as? String { return (text as NSString).intValue }
        return 0
    }

    // MARK: The association

    /// The association for `service`, the service itself with `identifier`,
    /// and its release: shared by verification, query and retrieve. Says what
    /// failed in the notices panel, unless verifying or given up, and answers
    /// whether it all went through.
    @discardableResult
    func setupNetwork(service: QueryRetrieveService, identifier: DICOMQueryIdentifier?, destination: String? = nil) -> Bool {
        autoreleasepool {
            var succeed = true
            let completed = catchingExceptions {
                succeed = associate(service: service, identifier: identifier, destination: destination)
            }
            return completed && succeed
        }
    }

    private func associate(service: QueryRetrieveService, identifier: DICOMQueryIdentifier?, destination: String?) -> Bool {
        let verbose = Self.verboseAssociations
        let verifying = service == .verification
        _abortAssociation = false
        let defaults = UserDefaults.standard
        let wait = QueryProgressWindow(message: String(format: NSLocalizedString("Connecting to %@...", comment: ""), _hostname ?? ""))
        let uniqueStringID = "\(getpid()).\(Self.associationNumber.wrappingAdd(1, ordering: .relaxed).oldValue).\(Int32.random(in: 0...Int32.max))"
        let host = _hostname ?? "", called = calledAETitle ?? ""
        var succeed = true
        var association: IsiXDCMTKAssociation?
        do {
            let parameters = IsiXDCMTKAssociationParameters()
            parameters.callingAETitle = callingAETitle
            parameters.calledAETitle = calledAETitle
            parameters.peerHost = host
            parameters.peerPort = _port
            parameters.abstractSyntax = service.rawValue
            if service.isGet { parameters.preferredTransferSyntax = defaults.integer(forKey: "preferredSyntaxForIncoming") }
            parameters.acseTimeout = self.association.acseTimeout
            parameters.dimseTimeout = self.association.dimseTimeout
            parameters.connectionTimeout = defaults.integer(forKey: "DICOMConnectionTimeout")
            parameters.verbose = verbose
            if self.association.secureConnection {
                prepareSecureTransport(parameters, uniqueStringID: uniqueStringID)
            }

            do {
                association = try IsiXDCMTKAssociation(parameters: parameters)
            } catch let error as NSError {
                let name = (error.userInfo[IsiXDCMTKSecureTransportKey] as? NSNumber)?.boolValue == true ? AssociationFailure.secureQuery
                    : (error.userInfo[IsiXDCMTKPeerAddressKey] as? NSNumber)?.boolValue == true ? "DICOM Network Failure" : AssociationFailure.query
                throw AssociationFailure(name: name, reason: error.localizedDescription)
            }
            guard let association else { throw AssociationFailure(name: AssociationFailure.query, reason: "no association") }

            // Asked for on a thread of its own, so that the window can be
            // cancelled and this thread's cancellation stops waiting for it.
            var condition = waitFor(association: association, wait: wait)
            if !association.hasAssociation && condition == nil {
                // No association, and no reason given.
                condition = IsiXDCMTKError.error(for: .illegalParameter)
            }
            // Otherwise the reason the request came back with: overwriting it
            // made a closed port, an unknown host name, a refused association
            // and a blocked local network all report "Illegal parameter".
            if condition != nil { wait?.end() }

            if let failure = condition, !failure.isGoodCondition {
                // The DICOM condition is the same for a closed port, an unknown
                // name, a firewall and a denied Local Network permission:
                // the diagnosis establishes which it was.
                let what = failure.conditionKind == .associationRejected ? "Association Rejected : " : "Association Request Failed : "
                throw AssociationFailure(name: AssociationFailure.query, reason: NetworkDiagnosis.explainFailure(
                    toHost: host, port: Int(_port), condition: what + failure.conditionDescription))
            }
            if association.acceptedPresentationContextCount == 0 {
                Self.errmsg("No Acceptable Presentation Contexts")
                throw AssociationFailure(name: AssociationFailure.query, reason: "No acceptable presentation contexts")
            }

            let dataset = identifier?.dataset()
            switch service {
            case .verification:
                var status: UInt16 = 0xffff
                condition = association.echo(withStatus: &status)
                if condition == nil && status != 0 {
                    throw AssociationFailure(name: "DICOM Verification Failed", reason: String(format: "C-ECHO returned status 0x%04x", status))
                }
                if condition != nil { succeed = false }
            case .findStudyRoot:
                if condition == nil {
                    if let dataset { condition = find(on: association, identifier: dataset, wait: wait) }
                    else { condition = IsiXDCMTKError.error(for: .illegalParameter) }
                    wait?.end()
                }
            case .moveStudyRoot:
                condition = dataset.map { cMove(on: association, identifier: $0, destination: destination) }
                    ?? IsiXDCMTKError.error(for: .illegalParameter)
            case .getStudyRoot, .getPatientStudyOnly:
                condition = dataset.map { cGet(on: association, identifier: $0) } ?? IsiXDCMTKError.error(for: .illegalParameter)
            case .getPatientRoot:
                NSLog("Q/R SCU bad Abstract Sytnax: %@", service.rawValue)
            }

            // Tear down the association.
            if condition == nil {
                if _abortAssociation {
                    if verbose { print("Aborting Association") }
                    if let failure = association.closeTransportConnection() {
                        if verbose { Self.errmsg("Association Abort Failed:\n\(failure.conditionDescription)") }
                        throw AssociationFailure(name: AssociationFailure.query, reason: "Association Abort Failed " + failure.conditionDescription)
                    }
                } else {
                    if verbose { print("Releasing Association") }
                    if let failure = association.releaseAssociation() {
                        if verbose { Self.errmsg("Association Release Failed:\n\(failure.conditionDescription)") }
                        throw AssociationFailure(name: AssociationFailure.query, reason: "Association Release Failed " + failure.conditionDescription)
                    }
                }
            } else if let failure = condition, failure.conditionKind == .peerRequestedRelease {
                Self.errmsg("Protocol Error: peer requested release (Aborting)")
                if verbose { print("Aborting Association") }
                let reason = "Protocol Error: peer requested release (Aborting) " + failure.conditionDescription
                if let abort = association.closeTransportConnection(), verbose { Self.errmsg("Association Abort Failed:\n\(abort.conditionDescription)") }
                throw AssociationFailure(name: AssociationFailure.query, reason: reason)
            } else if let failure = condition, failure.conditionKind == .peerAbortedAssociation {
                if verbose { print("Peer Aborted Association") }
            } else if let failure = condition {
                if verbose {
                    Self.errmsg("SCU Failed:\n\(failure.conditionDescription)")
                    print("Aborting Association")
                }
                let reason = "SCU Failed " + failure.conditionDescription
                if let abort = association.closeTransportConnection(), verbose { Self.errmsg("Association Abort Failed:\n\(abort.conditionDescription)") }
                throw AssociationFailure(name: AssociationFailure.query, reason: reason)
            }
        } catch {
            let failure = error as? AssociationFailure ?? AssociationFailure(name: AssociationFailure.query, reason: "\(error)")
            // The whole configuration, in a fixed order, so the report from a
            // machine that works and the report from one that does not differ
            // only where the configurations do.
            let response = "\(called)  /  \(host):\(_port)\r\r\(failure.name)\r\(failure.reason)\r\r\(nodeConfigurationDescription)"
            if !verifying && !_abortAssociation && !Thread.current.isCancelled {
                if showErrorMessageValue {
                    Self.postNotice(NSLocalizedString("Query Failed (1)", comment: ""), response)
                } else {
                    AppController.shared()?.notificationTitle(NSLocalizedString("Query Failed (1)", comment: ""), description: response, name: "autoquery")
                }
            }
            NSLog("---- DCMTKQueryNode failed: %@", failure.reason)
            succeed = false
            Thread.sleep(forTimeInterval: 0.05)
        }
        wait?.end()
        // The association's network, association and TLS layer are destroyed
        // two minutes after this, when no thread can be using them any more.
        association = nil
        if self.association.secureConnection { removeSecureTransportFiles(uniqueStringID: uniqueStringID) }
        return succeed
    }

    /// Asks for the association on a thread, and waits for it while the
    /// window runs, until it answers or is given up: then DUL_NETWORKCLOSED.
    private func waitFor(association: IsiXDCMTKAssociation, wait: QueryProgressWindow?) -> (any Error)? {
        let lock = NSRecursiveLock()
        let started = DispatchSemaphore(value: 0)
        let outcome = QueryNodeShared<(any Error)?>(nil)
        nonisolated(unsafe) let requested = association
        Thread.detachNewThread { [self] in
            autoreleasepool {
                lock.lock()
                started.signal()
                Thread.current.name = "DCMTKQueryNode ASC_requestAssociation"
                if !_abortAssociation {
                    let condition = requested.request()
                    outcome.modify { $0 = condition }
                }
                // After cancellation, close through the public transport API.
                // DCMTK's A-ABORT handshake otherwise waits up to a minute for an
                // unresponsive peer.
                if _abortAssociation && requested.hasAssociation { _ = requested.closeTransportConnection() }
                lock.unlock()
            }
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.05)
        while !(wait?.aborted ?? false) && !_abortAssociation && !Thread.current.isCancelled && HorosDICOMGlobalAbortRequested() == 0 {
            wait?.run()
            Thread.sleep(forTimeInterval: 0.05)
            if lock.try() {
                lock.unlock()
                break
            }
        }
        if (wait?.aborted ?? false) || _abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 {
            _abortAssociation = true
            return IsiXDCMTKError.error(for: .networkClosed)
        }
        return outcome.current
    }

    /// Writes what DCMTK's TLS layer reads, under a name of this association.
    private func prepareSecureTransport(_ parameters: IsiXDCMTKAssociationParameters, uniqueStringID: String) {
        association.prepareSecureTransport(parameters, host: _hostname, port: _port, aeTitle: calledAETitle, uniqueStringID: uniqueStringID)
    }

    private func removeSecureTransportFiles(uniqueStringID: String) {
        DICOMAssociationSettings.removeSecureTransportFiles(host: _hostname, port: _port, aeTitle: calledAETitle, uniqueStringID: uniqueStringID)
    }

    // MARK: C-FIND

    /// The C-FIND on a thread of its own, waited for as the association is.
    private func find(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset, wait: QueryProgressWindow?) -> (any Error)? {
        let lock = NSRecursiveLock()
        let started = DispatchSemaphore(value: 0)
        let outcome = QueryNodeShared<(any Error)?>(nil)
        nonisolated(unsafe) let found = association
        nonisolated(unsafe) let dataset = identifier
        Thread.detachNewThread { [self] in
            autoreleasepool {
                lock.lock()
                started.signal()
                Thread.current.name = "CFind Thread"
                catchingExceptions { outcome.modify { $0 = findSCU(on: found, identifier: dataset) } }
                lock.unlock()
            }
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.05)
        while !(wait?.aborted ?? false) && !_abortAssociation && !Thread.current.isCancelled && HorosDICOMGlobalAbortRequested() == 0 {
            wait?.run()
            Thread.sleep(forTimeInterval: 0.05)
            if lock.try() {
                lock.unlock()
                break
            }
        }
        if (wait?.aborted ?? false) || _abortAssociation || Thread.current.isCancelled || HorosDICOMGlobalAbortRequested() != 0 {
            _abortAssociation = true
            return IsiXDCMTKError.error(for: .networkClosed)
        }
        return outcome.current
    }

    /// Sends the C-FIND; each match becomes a child. A failure status is said.
    private func findSCU(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset) -> (any Error)? {
        let result = association.find(withIdentifier: identifier) { [self] match in addChild(match) }
        lastQuerySucceededValue = result.conditionGood && result.status == 0x0000
        if result.condition == nil && result.status != 0x0000 && result.status != 0xff00 {
            var response = "\(calledAETitle ?? "(null)")  /  \(_hostname ?? "(null)"):\(_port)\r\r" + result.statusText
            if let detail = result.statusDetail { response += "\r\r\r" + detail }
            if showErrorMessageValue && !_abortAssociation {
                Self.postNotice(NSLocalizedString("Query Failed (2)", comment: ""), response)
            } else {
                AppController.shared()?.notificationTitle(NSLocalizedString("Query Failed (2)", comment: ""), description: response, name: "autoquery")
            }
        }
        return result.condition
    }

    // MARK: C-MOVE and C-GET

    /// The instances a request names at the IMAGE level, nil when it names
    /// none, and the series it names.
    static func requestedInstances(_ request: IsiXDCMTKDataset?) -> (instances: [String]?, series: String) {
        guard let request else { return ([], "") }
        return QueryIdentifiers.requestedInstances(level: request.utf8Value(.queryRetrieveLevel),
                                                   series: request.utf8Value(.seriesInstanceUID),
                                                   sopInstanceUIDs: request.utf8Values(.sopInstanceUID))
    }

    /// The progress of a retrieval, as a fraction of the sub-operations the
    /// peer has accounted for.
    static func reportProgress(accounted: UInt, finished: UInt) {
        let thread = Thread.current
        thread.progress = CGFloat(RetrieveProgress.fraction(accounted: accounted, finished: finished))
        ActivityProgressCount.set(done: Int(finished), total: Int(accounted), on: thread)
    }

    /// Updates `progress` and the bar after a response or a wait.
    private func reportRetrieveProgress(_ progress: inout RetrieveProgress, requested: (instances: [String]?, series: String),
                                        counted: Bool, accounted: UInt, finished: UInt) {
        let shown = progress.update(counted: counted, accounted: accounted, finished: finished) {
            guard let inventory = currentRetrieveInventory(), inventory.inventoryConfirmed else { return nil }
            let arrivals = inventory.arrivals(requested: requested.instances ?? [], series: requested.series)
            guard let received = arrivals.first, let asked = arrivals.last else { return nil }
            return (UInt(max(0, received)), UInt(max(0, asked)))
        }
        if let shown { Self.reportProgress(accounted: shown.accounted, finished: shown.finished) }
    }

    /// The Failed SOP Instance UID List of a response: what the peer said it
    /// cannot send.
    private func recordFailedIdentifiers(_ failed: String?) {
        guard let failed, let inventory = currentRetrieveInventory() else { return }
        for uid in failed.components(separatedBy: "\\") where !uid.isEmpty { inventory.recordPeerFailedUID(uid) }
    }

    /// One C-MOVE, unless this node is already being moved.
    private func cMove(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset, destination: String?) -> (any Error)? {
        let moves = MoveManager.sharedManager() as? MoveManager
        if moves?.containsMove(self) == true { return nil }
        return moveSCU(on: association, identifier: identifier, destination: destination)
    }

    private func moveSCU(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset, destination: String?) -> (any Error)? {
        guard association.acceptsAbstractSyntax(QueryRetrieveService.moveStudyRoot.rawValue) else {
            return IsiXDCMTKError.error(for: .noPresentationContext)
        }
        // Listed among the moves, so that a new query does not let it go.
        let moves = MoveManager.sharedManager() as? MoveManager
        moves?.addMove(self)
        defer { moves?.removeMove(self) }
        let requested = Self.requestedInstances(identifier)
        var progress = RetrieveProgress()
        let result = association.move(withIdentifier: identifier, destination: destination) { counted, accounted, finished in
            reportRetrieveProgress(&progress, requested: requested, counted: counted, accounted: UInt(accounted), finished: UInt(finished))
        }
        // The wait looks at the listing once a second: what arrived since its last look.
        if progress.listingShown { reportRetrieveProgress(&progress, requested: requested, counted: false, accounted: 0, finished: 0) }
        let status = UInt(result.status), completed = UInt(result.completed), failed = UInt(result.failed)
        let warnings = UInt(result.warnings), remaining = UInt(result.remaining)
        countOfSuboperations = completed + failed + warnings + remaining
        countOfSuccessfulSuboperations = completed
        let inventory = currentRetrieveInventory()
        inventory?.record(operation: "C-MOVE", status: status, completed: completed, failed: failed, warnings: warnings, remaining: remaining)
        recordFailedIdentifiers(result.failedSOPInstanceUIDs)
        if Thread.current.isCancelled { reportRetrieveCancellation("C-MOVE", confirmed: result.conditionGood && result.status == 0xfe00) }
        if let condition = result.condition {
            if showErrorMessageValue && !Thread.current.isCancelled {
                Self.postNotice(NSLocalizedString("Move Failed", comment: ""), "\(condition.conditionText)\r\r\(nodeConfigurationDescription)")
            }
        } else {
            let completion = RetrieveCompletion(operation: "C-MOVE", status: status, statusText: result.moveStatusText,
                                                completed: completed, failed: failed, warnings: warnings, remaining: remaining)
            // A C-MOVE that could not send everything ends on a warning, not a
            // failure, and the association is released as if nothing were
            // missing. The counts are the only thing that says otherwise, so
            // they are what is reported - and the retrieval is not turned into
            // an error, because an image-level retrieve cancels its thread on
            // one and would stop fetching the instances that are still to come.
            if !completion.everythingArrived {
                result.printResponse()
                NSLog("---- %@", completion.summary)
                if showErrorMessageValue && inventory?.inventoryConfirmed != true && !Thread.current.isCancelled {
                    Self.postNotice(NSLocalizedString("Move Failed", comment: ""), "\(completion.summary)\r\r\(nodeConfigurationDescription)")
                }
            }
        }
        return result.condition
    }

    /// One C-GET, unless this node is already being moved.
    private func cGet(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset) -> (any Error)? {
        let moves = MoveManager.sharedManager() as? MoveManager
        if moves?.containsMove(self) == true { return nil }
        return getSCU(on: association, identifier: identifier)
    }

    private func getSCU(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset) -> (any Error)? {
        countOfSuboperations = 0
        countOfSuccessfulSuboperations = 0
        guard association.acceptsAbstractSyntax(QueryRetrieveService.getStudyRoot.rawValue) else {
            return IsiXDCMTKError.error(for: .noPresentationContext)
        }
        let moves = MoveManager.sharedManager() as? MoveManager
        moves?.addMove(self)
        defer { moves?.removeMove(self) }
        let requested = Self.requestedInstances(identifier)
        var progress = RetrieveProgress()
        let result = association.get(withIdentifier: identifier, storage: { SCPDatabaseSession(callingAETitle: $0) },
                                     progress: { counted, accounted, finished in
            reportRetrieveProgress(&progress, requested: requested, counted: counted, accounted: UInt(accounted), finished: UInt(finished))
        }, incoming: {
            // The stores land in the incoming folder, as the listener's do.
            DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
        })
        let status = UInt(result.status), completed = UInt(result.completed), failed = UInt(result.failed)
        let warnings = UInt(result.warnings), remaining = UInt(result.remaining)
        countOfSuboperations = completed + failed + warnings + remaining
        countOfSuccessfulSuboperations = completed
        let inventory = currentRetrieveInventory()
        inventory?.record(operation: "C-GET", status: status, completed: completed, failed: failed, warnings: warnings, remaining: remaining)
        recordFailedIdentifiers(result.failedSOPInstanceUIDs)
        // Only C-GET: its stores arrive on this association, so what did not
        // arrive is known here.
        var onlyUnoffered = false
        if result.conditionGood && !Thread.current.isCancelled, let inventory, let instances = requested.instances {
            onlyUnoffered = inventory.recordUnsent(requested: instances, series: requested.series, status: status,
                                                   failed: failed, remaining: remaining)
        }
        if Thread.current.isCancelled { reportRetrieveCancellation("C-GET", confirmed: result.conditionGood && result.status == 0xfe00) }
        var condition = result.condition
        if let failure = result.condition {
            if showErrorMessageValue && !Thread.current.isCancelled {
                Self.postNotice(NSLocalizedString("Get Failed", comment: ""), "\(failure.conditionText)\r\r\(nodeConfigurationDescription)")
            }
        } else {
            let statusText = HorosDIMSEPolicy.cGetStatusDescription(status)
            let completion = RetrieveCompletion(operation: "C-GET", status: status, statusText: statusText,
                                                completed: completed, failed: failed, warnings: warnings, remaining: remaining)
            // Failures that are all instances of classes this retrieve does not
            // offer to receive are expected absences: nothing failed that
            // could have arrived.
            if !completion.everythingArrived && onlyUnoffered {
                NSLog("---- %@: only instances of storage classes this C-GET does not offer", completion.summary)
            } else if !completion.everythingArrived {
                NSLog("---- %@", completion.summary)
                // A completed association with failed sub-operations can be
                // repaired by the bounded inventory retry. A refused request
                // still triggers the fallback.
                let recoverablePartial = inventory?.inventoryConfirmed == true && (result.status == 0xb000 || result.status == 0xa702)
                if !Thread.current.isCancelled && !recoverablePartial {
                    condition = IsiXDCMTKError.receiveFailedError(withText: completion.summary)
                }
                if showErrorMessageValue && inventory?.inventoryConfirmed != true && !Thread.current.isCancelled {
                    Self.postNotice(NSLocalizedString("Get Failed", comment: ""), "\(completion.summary)\r\r\(nodeConfigurationDescription)")
                }
            }
        }
        return condition
    }

    /// The storage SOP classes a C-GET offers to receive, in the Storage SCP role.
    static var storageClassesOfferedByCGET: Set<String> { Set(IsiXDCMTKAssociation.storageSOPClassesOfferedByGet) }
}
