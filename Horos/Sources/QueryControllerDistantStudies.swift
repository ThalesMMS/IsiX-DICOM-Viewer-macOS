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
import IsiXDatabase
import IsiXPreferences

/// A study a node found, kept as the query node the study list, the history
/// and the retrieves read by key-value coding.
///
/// The box never changes once made; the node itself is the Objective-C object
/// the query, the outline and the retrieve already share across threads, each
/// guarding its own state. It is handed from the query's thread to the main
/// thread unchanged.
final class DistantQueryNode: @unchecked Sendable {
    let node: DCMTKStudyQueryNode

    init(_ node: DCMTKStudyQueryNode) {
        self.node = node
    }
}

/// The patient of a history: a local study by its object ID in the database it
/// was selected in, or a study of a node.
struct DistantHistoryPatient: @unchecked Sendable {
    enum Study {
        case local(NSManagedObjectID, in: DicomDatabase)
        case distant(DCMTKStudyQueryNode)
    }

    /// The database is only asked for a private-queue copy of itself, on the
    /// query's thread; the node is shared as `DistantQueryNode` says.
    let study: Study
}

/// The PACS On-Demand queries over the study queries of QueryController and
/// the DCMTK adapter, on the nodes chosen in the PACS On-Demand preferences.
///
/// Each query of the searches runs on an ActivityThread, which the Activity
/// window lists under the name the search gives it; the `…Now` forms run on
/// the calling thread, for the callers that wait for the answer there.
struct QueryControllerDistantStudies: DistantStudyQuerying {
    let preferences: any PreferenceStore

    // MARK: The nodes

    /// The nodes the comparative searches ask: those chosen in the PACS
    /// On-Demand preferences, among the DICOM and DICOMweb nodes, as the
    /// dictionaries QueryController asks.
    func comparativeServers() -> [[String: Any]] {
        let candidates = RISRequestServers.candidates()
        let found = DistantSearch.comparativeNodes(chosen: preferences[NetworkPreferences.pacsOnDemandNodes],
                                                   candidates: candidates.map { ($0["Description"], $0["Address"]) })
        if found.incomplete {
            NSLog("**** comparativeNodesDescription.count != comparativeNodesAddress.count")
        }
        return found.servers.map { candidates[$0] }
    }

    // MARK: DistantStudyQuerying

    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] {
        await ActivityThread.run(name: activity) { studiesNow(matching: filters) }
    }

    func patientStudies(of patient: DistantHistoryPatient, activity: String) async -> [DistantStudySummary] {
        await ActivityThread.run(name: activity) {
            switch patient.study {
            case .distant(let node):
                return patientStudiesNow(of: node)
            case .local(let objectID, let database):
                // The study is read on a private-queue copy of the database, on its queue.
                guard let idatabase = database.privateQueueIndependentDatabase() as? DicomDatabase else { return [] }
                var found: [DistantStudySummary] = []
                idatabase.performBlockAndWait {
                    if let study = idatabase.object(withID: objectID) as? DicomStudy {
                        found = patientStudiesNow(of: study, database: idatabase)
                    }
                }
                return found
            }
        }
    }

    // MARK: On the calling thread

    /// The studies the nodes find for `filters`, asked on this thread.
    func studiesNow(matching filters: [String: PropertyListValue]) -> [DistantStudySummary] {
        let servers = comparativeServers()
        let found = QueryController.queryStudies(forFilters: filters.mapValues(\.object), servers: servers, showErrors: false)
        return Self.summaries(of: (found as? [Any]) ?? [])
    }

    /// The studies of the patient of `study`, a local study or a node's, asked
    /// on this thread by the identity fields the preferences choose.
    func patientStudiesNow(of study: AnyObject, database: DicomDatabase? = nil) -> [DistantStudySummary] {
        let servers = comparativeServers()
        guard !servers.isEmpty else { return [] }

        // A node's study is asked as the DicomStudy the declaration names: the
        // query reads only the patient's name, ID, birth date and study UID,
        // which both answer to the same selectors.
        let asStudy = Unmanaged<DicomStudy>.fromOpaque(Unmanaged.passUnretained(study).toOpaque()).takeUnretainedValue()
        let identity: ComparativePatientIdentity?
        if let node = study as? DCMTKStudyQueryNode {
            identity = node.comparativeIdentity
        } else if let local = study as? DicomStudy, let database {
            identity = PatientHistoryList.comparativeIdentity(of: local, in: database)
        } else {
            identity = nil
        }
        let found = QueryController.queryStudies(forPatient: asStudy,
                                                 usePatientID: preferences[DatabasePreferences.usePatientIDForUID],
                                                 usePatientName: preferences[DatabasePreferences.usePatientNameForUID],
                                                 usePatientBirthDate: preferences[DatabasePreferences.usePatientBirthDateForUID],
                                                 servers: servers, showErrors: false, identity: identity)
        return Self.summaries(of: found ?? [])
    }

    // MARK: Summaries and nodes

    /// The summary of each query node of `found`.
    static func summaries(of found: [Any]) -> [DistantStudySummary] {
        found.compactMap { $0 as? DCMTKStudyQueryNode }.map(summary(of:))
    }

    static func summary(of node: DCMTKStudyQueryNode) -> DistantStudySummary {
        DistantStudySummary(studyInstanceUID: node.studyInstanceUID(), date: node.date() as Date?,
                            files: node.noFiles()?.int32Value ?? 0, rawFiles: node.rawNoFiles()?.int32Value ?? 0,
                            node: DistantQueryNode(node))
    }

    /// The query nodes of `summaries`, in their order.
    static func nodes(of summaries: [DistantStudySummary]) -> [DCMTKStudyQueryNode] {
        summaries.compactMap { ($0.node as? DistantQueryNode)?.node }
    }
}
