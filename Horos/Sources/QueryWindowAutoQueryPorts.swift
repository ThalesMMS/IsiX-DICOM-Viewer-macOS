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

/// The query nodes of the studies the automatic query decides on, by the
/// handle the scheduler knows each one by.
///
/// The nodes are Objective-C objects that the query, the outline and the
/// retrieve already share across threads, each guarding its own state; this
/// only keeps them, under its lock, between the query that found them and the
/// retrieve that asks for them. A run forgets the nodes of the run before it.
final class AutoQueryAnswerNodes: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [Int: DCMTKQueryNode] = [:]
    private var next = 0

    func forgetAll() {
        lock.withLock { nodes.removeAll() }
    }

    /// The node as a value the scheduler can decide on.
    func study(of node: DCMTKQueryNode) -> AutoQueryStudy {
        let handle = lock.withLock { () -> Int in
            next += 1
            nodes[next] = node
            return next
        }
        return AutoQueryStudy(handle: handle, studyInstanceUID: node.uid() ?? "", patientID: node.patientID(),
                              accessionNumber: node.accessionNumber(), modality: node.modality(),
                              studyDescription: node.theDescription(),
                              numberOfImages: node.numberImages().map { Int($0.int32Value) },
                              date: node.date() as Date?, time: node.time() as Date?)
    }

    func node(of study: AutoQueryStudy) -> DCMTKQueryNode? {
        lock.withLock { nodes[study.handle] }
    }
}

/// Answers of a query, handed from the thread that ran it to the window.
/// They are the nodes of `AutoQueryAnswerNodes`, shared the same way.
struct QueryAnswers: @unchecked Sendable {
    let items: [Any]
}

/// The C-FIND of an instance of the automatic query, and of a patient, over
/// the Query window's nodes and the DCMTK adapter.
///
/// The window keeps it, and the scheduler's countdown keeps the window, as
/// the one-second timer of the window used to: the window lives as long as
/// its automatic query.
final class QueryWindowAutoQueryRunner: AutoQueryRunning {
    private let controller: QueryController
    private let answers: AutoQueryAnswerNodes

    init(controller: QueryController, answers: AutoQueryAnswerNodes) {
        self.controller = controller
        self.answers = answers
    }

    func runQuery(of instance: AutoQueryInstance) async throws -> [AutoQueryStudy] {
        let controller = self.controller
        guard let prepared = await controller.prepareAutoQueryRun(of: instance) else { return [] }

        let found = await ActivityThread.run(name: prepared.activityName) {
            QueryAnswers(items: controller.queryAnswers(false, run: prepared.run, showing: !prepared.autoQuery))
        }
        try Task.checkCancellation()

        guard prepared.autoQuery else { return [] }
        await controller.keepAutoQueryAnswers(found, of: instance.id)
        answers.forgetAll()
        return found.items.compactMap { $0 as? DCMTKQueryNode }.map(answers.study(of:))
    }

    func studies(ofPatientID patientID: String) async -> [AutoQueryStudy] {
        // The nodes as the window lists them now, read on the main thread.
        let sources = await controller.currentWindowState().sourcesForPatientQuery()
        let found = await ActivityThread.run(name: NSLocalizedString("Retrieving images...", comment: "")) {
            QueryAnswers(items: QueryController.queryPatientID(patientID, sources: sources))
        }
        return found.items.compactMap { $0 as? DCMTKQueryNode }.map(answers.study(of:))
    }
}

/// The retrieve of what the automatic query chose, over the retrieve of the
/// Query window.
final class QueryWindowAutoRetrieveStarter: AutoRetrieveStarting {
    /// A retrieve waits while more than this many run.
    static let mostRunningRetrieves = 5

    private let controller: QueryController
    private let answers: AutoQueryAnswerNodes
    private let processGraph: ProcessGraph

    init(controller: QueryController, answers: AutoQueryAnswerNodes, processGraph: ProcessGraph) {
        self.controller = controller
        self.answers = answers
        self.processGraph = processGraph
    }

    func mayStartRetrieve() async -> Bool {
        let controller = self.controller, graph = processGraph
        let local = await MainActor.run {
            controller.autoQueryValue && graph.currentBrowser?.database === DicomDatabase.activeLocal()
        }
        guard local else { return false }
        if await controller.retrieves.runningCount > Self.mostRunningRetrieves {
            NSLog("**** numberOfRunningRetrieve > 5... wait for next autoretrieve.")
            return false
        }
        return true
    }

    func retrieveInventory(of study: AutoQueryStudy) async -> AutoQueryRetrieveInventory? {
        guard let node = answers.node(of: study), let inventory = node.retrieveInventory,
              inventory.matchesReportedCount(study.numberOfImages ?? 0) else { return nil }
        _ = node.refreshRetrieveInventory()
        return AutoQueryRetrieveInventory(expected: inventory.expectedCount, imported: inventory.importedCount,
                                          isSatisfied: inventory.isSatisfied)
    }

    /// In transfer by -stringIDForStudy:, shared with the retrieves of the
    /// window: a study is not asked for again while its number stays the same.
    func claimTransfer(of study: AutoQueryStudy, expectedFiles: Int) async -> Bool {
        guard let node = answers.node(of: study) else { return false }
        let key = QueryController.stringID(forStudy: node)
        let files = Int32(truncatingIfNeeded: expectedFiles)
        return RetrieveInTransfer.withLock { inTransfer in
            guard (inTransfer[key] ?? 0) != files else { return false }
            inTransfer[key] = files
            return true
        }
    }

    func startRetrieve(of studies: [AutoQueryStudy], for instance: AutoQueryInstance) async {
        let items = studies.compactMap(answers.node(of:))
        guard !items.isEmpty else { return }
        for item in items {
            item.setShowErrorMessage(false)
        }

        let controller = self.controller
        let retrieving = QueryAnswers(items: items)
        let status = QueryController.singularPluralCount(items.count, NSLocalizedString("study", comment: ""),
                                                         NSLocalizedString("studies", comment: ""))
        let several = items.count > 1
        // Started now and not awaited: the scheduler goes on while it runs.
        Task.detached {
            await controller.retrieves.run {
                await ActivityThread.run(name: NSLocalizedString("Retrieving images...", comment: ""), configure: { thread in
                    thread.status = status
                    if several { thread.progress = 0 }
                }) {
                    controller.performRetrieve(retrieving.items)
                }
            }
        }

        NSLog("______________________________________________")
        NSLog("Will auto-retrieve these items:")
        for item in items {
            NSLog("%@ - %d images", item.uid() ?? "", item.numberImages()?.int32Value ?? 0)
        }
        NSLog("______________________________________________")

        let description = items.count == 1
            ? String(format: NSLocalizedString("Will auto-retrieve %d study", comment: ""), Int32(items.count))
            : String(format: NSLocalizedString("Will auto-retrieve %d studies", comment: ""), Int32(items.count))
        let graph = processGraph
        await MainActor.run {
            graph.appController?.notificationTitle(NSLocalizedString("Q&R Auto-Retrieve", comment: ""), description: description,
                                                   name: "autoquery")
        }
    }
}
