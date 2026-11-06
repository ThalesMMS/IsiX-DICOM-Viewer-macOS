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
import IsiXPreferences
import Synchronization

/// What the routing queue needs of the app when it drains: the stored nodes,
/// the queued images read again from their database, the send through the
/// process's send queue, and the alerts.
struct DatabaseRoutingDelivery: RoutingDelivery {
    let processGraph: ProcessGraph

    /// Which database an order's images are in: the base folder of the main
    /// database of a local one; nil for a database that is not local, whose
    /// images are not routed.
    static func key(of database: DicomDatabase) -> String? {
        guard database.isLocal() else { return nil }
        let main = database.isMainDatabase() ? database : (database.mainDatabase as? DicomDatabase)
        return main?.baseDirPath
    }

    func nodes() async -> [DICOMNode] {
        DICOMNodeService.store.dicomNodes()
    }

    /// Read on a thread of its own, on a private-queue context of the local
    /// database that queued them; none when that database is closed.
    func currentFiles(of order: RoutingOrder) async -> [RoutedFile] {
        await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: Self.read(order))
            }.start()
        }
    }

    private static func read(_ order: RoutingOrder) -> [RoutedFile] {
        let main = (DicomDatabase.allDatabases() ?? []).lazy.compactMap { $0 as? DicomDatabase }
            .first { $0.isLocal() && $0.baseDirPath == order.database }
        guard let reader = main?.privateQueueIndependentDatabase() as? DicomDatabase else { return [] }
        var files: [RoutedFile] = []
        reader.performBlockAndWait {
            if let exception = HorosObjCException.caught({
                let images = (reader.objects(withIDs: order.files.map(\.id)) ?? []).compactMap { $0 as? DicomImage }
                files = DatabaseRoutingCatalog(database: reader).snapshots(of: images)
            }) {
                LogText.log(exception, stack: true, in: "-[DicomDatabase(Routing) routing]")
            }
        }
        return files
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func sendOptions() async -> DICOMSendOptions {
        DICOMSendOptions(callingAETitle: UserDefaults.defaultAETitle(), associationsPerBatch: 1,
                         mostConcurrentSends: processGraph.preferences[NetworkPreferences.maximumSendGlobalControllerConcurrentThreads])
    }

    func send(_ request: DICOMSendRequest) async -> RoutingSendResult {
        let failures = RoutingStoreFailures()
        switch await processGraph.dicomSendQueue.send(request, through: RoutingStoreTransport(failures: failures)) {
        case .sent: return .sent
        case .cancelled: return .cancelled
        case .failed: return .failed(failures.first ?? RoutingSendFailure(name: "", reason: ""))
        }
    }

    // MARK: Alerts

    /// Whether autorouting problems are shown, and not only logged.
    private var showsErrors: Bool {
        processGraph.preferences[NetworkPreferences.showErrorMessagesForAutorouting]
            && !processGraph.preferences[NetworkPreferences.hidesListenerErrors]
    }

    func reportUnresolvedDestination(_ problem: String) async {
        NSLog("**** Autorouting suspended: %@", problem)
        guard showsErrors else { return }
        showAlert(problem)
    }

    func reportFailedSend(_ failure: RoutingSendFailure, to node: DICOMNode) async {
        let aet = node[DICOMNode.Key.aeTitle]?.text ?? "(null)"
        let address = node[DICOMNode.Key.address]?.text ?? "(null)"
        let port = node[DICOMNode.Key.port]?.text ?? "(null)"
        // Logged whether or not it is shown, so how many alerts a run would
        // raise can be counted without a screen. The log takes the reason that
        // tells the files by their place in the send; the alert names them.
        NSLog("**** Autorouting error reported for %@@%@:%@ - %@", aet, address, port, failure.logReason)
        guard showsErrors else { return }
        showAlert(String(format: "%@\r\r%@\r%@\r\rServer:%@-%@:%@",
                         NSLocalizedString("Autorouting DICOM StoreSCU operation failed.\rI will try again in 30 secs.", comment: ""),
                         failure.name, failure.reason, aet, address, port))
    }

    /// Whether an autorouting alert is open.
    @MainActor private static var alertOpen = false

    /// The alert, on the main thread, without waiting for it: the drain goes
    /// on. It opens from the main run loop, so that the main queue and the main
    /// actor go on while it is open. One at a time: a problem met meanwhile is
    /// only logged, which leaves a single alert whose suppression button stops
    /// the alerts.
    private func showAlert(_ text: String) {
        let graph = processGraph
        onMainRunLoop {
            guard !Self.alertOpen, graph.preferences[NetworkPreferences.showErrorMessagesForAutorouting] else { return }
            Self.alertOpen = true
            defer { Self.alertOpen = false }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Autorouting Error", comment: "")
            alert.informativeText = text
            alert.showsSuppressionButton = true
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                graph.preferences.set(false, for: NetworkPreferences.showErrorMessagesForAutorouting)
            }
        }
    }
}

/// The failures a routed send met, for the alert that names them.
final class RoutingStoreFailures: Sendable {
    private let recorded = Mutex<[RoutingSendFailure]>([])

    func record(_ failure: RoutingSendFailure) {
        recorded.withLock { $0.append(failure) }
    }

    var first: RoutingSendFailure? {
        recorded.withLock { $0.first }
    }
}

/// The C-STORE of a routed send, through `DCMTKStoreSCU`, on a thread the
/// Activity window lists as "Routing..." with its Cancel button. A failure
/// shows no alert of its own: the routing queue reports the first of a
/// destination and logs the rest.
struct RoutingStoreTransport: DICOMSendTransport {
    let failures: RoutingStoreFailures

    func store(_ part: DICOMStorePart) async -> DICOMSendOutcome {
        let count = String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: part.files.count), number: .decimal),
                           part.files.count == 1 ? NSLocalizedString("file", comment: "") : NSLocalizedString("files", comment: ""))
        let status = String(format: NSLocalizedString("Forwarding %@ to %@", comment: ""), count,
                            part.destination.nodeDescription ?? "(null)")
        let failures = self.failures
        return await ActivityThread.run(name: NSLocalizedString("Routing...", comment: "")) {
            let thread = Thread.current
            thread.status = status
            let destination = part.destination
            let storeSCU = DCMTKStoreSCU(callingAET: part.callingAETitle, calledAET: destination.aeTitle,
                                         hostname: destination.address, port: part.port, filesToSend: part.files,
                                         transferSyntax: Int32(truncatingIfNeeded: part.transferSyntax),
                                         compression: part.compression, extraParameters: destination.propertyList)
            let failure = storeSCU.sendReportingFailure()
            if thread.isCancelled { return .cancelled }
            guard let failure else { return .sent }
            failures.record(RoutingSendFailure(name: failure.category.rawValue, reason: failure.reason, logReason: failure.logReason))
            thread.status = NSLocalizedString("Sending failed. Will re-try later...", comment: "")
            return .failed
        }
    }

    /// A routed send is a C-STORE; it never takes these routes.
    func sendByDICOMweb(_ request: DICOMSendRequest) async -> DICOMSendOutcome {
        .failed
    }

    func sendByDirectTransfer(_ request: DICOMSendRequest) async -> DICOMSendOutcome {
        .failed
    }
}
