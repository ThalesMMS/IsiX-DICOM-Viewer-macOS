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
@_spi(IsiXHost) import IsiXPluginKit

/// What one refresh of the Modality Worklist window found.
struct ModalityWorklistAnswer: Sendable {
    /// A node that could not be asked, and why.
    struct Failure: Sendable, Equatable {
        var node: String
        var reason: String
    }

    var procedures: [ScheduledProcedure]
    var failures: [Failure]
    /// How many nodes were asked: 0 when Locations has no worklist node.
    var askedNodes: Int
}

/// The Modality Worklist window's work outside the window: the C-FIND of the
/// Modality Worklist model on every node Locations marks for it, and the
/// search of the received studies that match the scheduled steps.
///
/// The C-FIND is the one the plugin API sends (PluginCFind), with the node's
/// entry, so the node's TLS settings and the network timeouts apply as they do
/// to the Query window's associations. The database is only read: the window
/// shows which steps have arrived and changes nothing of the studies.
enum ModalityWorklistService {
    /// Asks every worklist node of Locations, one after the other, on a
    /// thread of its own: an association blocks until the node answers or
    /// the timeout ends.
    static func refresh(filter: ModalityWorklistQuery.Filter) async -> ModalityWorklistAnswer {
        let nodes = ModalityWorklistQuery.nodes(DICOMNodeService.store.dicomNodes())
        return await Task.detached(priority: .userInitiated) {
            ModalityWorklistService.query(nodes: nodes, filter: filter, now: Date())
        }.value
    }

    /// The scheduled steps of `nodes`, merged, and the nodes that failed.
    static func query(nodes: [DICOMNode], filter: ModalityWorklistQuery.Filter, now: Date) -> ModalityWorklistAnswer {
        let keys: [PluginQueryKeys.Key]
        do {
            keys = try ModalityWorklistQuery.keys(for: filter, now: now)
        } catch {
            let reason = NSLocalizedString("A filter holds a backslash or a control character.", comment: "Modality Worklist window, a filter DICOM cannot send")
            return ModalityWorklistAnswer(procedures: [], failures: nodes.map { .init(node: ModalityWorklistQuery.name(of: $0), reason: reason) },
                                          askedNodes: nodes.count)
        }
        var answers: [[ScheduledProcedure]] = []
        var failures: [ModalityWorklistAnswer.Failure] = []
        for node in nodes {
            let name = ModalityWorklistQuery.name(of: node)
            do {
                let identifier = try CFindKeysCoding.identifier(for: keys)
                let matches = try PluginCFind.run(entry: node.propertyList, abstractSyntax: ModalityWorklistQuery.abstractSyntax,
                                                  identifier: identifier)
                answers.append(matches.map { match in
                    ScheduledProcedure(values: CFindKeysCoding.values(of: match, keys: keys, encoding: PluginCFind.encoding(of: match)),
                                       node: name)
                })
            } catch {
                NSLog("Modality Worklist: %@ failed: %@", name, LogText.error(error))
                failures.append(.init(node: name, reason: IsiXUserMessage(for: error)))
            }
        }
        return ModalityWorklistAnswer(procedures: ScheduledProcedure.merged(answers), failures: failures, askedNodes: nodes.count)
    }

    /// The match of each step that has arrived, by the step's identity: the
    /// studies of the local database with one of the steps' Study Instance
    /// UIDs, Accession Numbers or Patient IDs, read on the main thread, which
    /// owns the database's context.
    @MainActor
    static func matches(for procedures: [ScheduledProcedure]) -> [String: WorklistStudyMatch] {
        guard !procedures.isEmpty, let database = BrowserDatabaseSource.process.activeLocalDatabase else { return [:] }
        let values = ModalityWorklistMatching.lookupValues(of: procedures)
        var terms: [NSPredicate] = []
        if !values.studyInstanceUIDs.isEmpty {
            terms.append(NSPredicate(format: "studyInstanceUID IN %@", argumentArray: [values.studyInstanceUIDs]))
        }
        if !values.accessionNumbers.isEmpty {
            terms.append(NSPredicate(format: "accessionNumber IN %@", argumentArray: [values.accessionNumbers]))
        }
        if !values.patientIDs.isEmpty {
            terms.append(NSPredicate(format: "patientID IN %@", argumentArray: [values.patientIDs]))
        }
        guard !terms.isEmpty else { return [:] }
        let found = (database.objects(forEntity: database.studyEntity(),
                                      predicate: NSCompoundPredicate(orPredicateWithSubpredicates: terms)) ?? [])
            .compactMap { $0 as? DicomStudy }
        let studies = found.map { study in
            ReceivedStudy(studyInstanceUID: study.studyInstanceUID, accessionNumber: study.accessionNumber, patientID: study.patientID,
                          date: study.date)
        }
        var matches: [String: WorklistStudyMatch] = [:]
        for procedure in procedures {
            if let match = ModalityWorklistMatching.match(procedure, among: studies) { matches[procedure.id] = match }
        }
        return matches
    }
}
