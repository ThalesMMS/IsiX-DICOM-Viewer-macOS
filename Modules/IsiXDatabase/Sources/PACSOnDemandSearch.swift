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
import IsiXPreferences
import Synchronization

// The PACS On-Demand searches of the browser: the studies the chosen nodes
// find for the search field, the time interval and a smart album, which the
// study list shows beside its own, and a patient's history, local and distant.
// The nodes are asked through the DistantStudyQuerying port, which the app
// implements over its DCMTK query; what is asked and how the answers merge is
// decided here.

// MARK: - The port

/// A study a PACS On-Demand node answered, as the searches compare and order it.
public struct DistantStudySummary: Sendable {
    public let studyInstanceUID: String?
    public let date: Date?
    /// The study's number of images, and the number the node reported before
    /// any frame was counted (the noFiles and rawNoFiles of a study).
    public let files: Int32
    public let rawFiles: Int32
    /// What the querying side keeps of the study, handed back unchanged: the
    /// object the study list and the history show.
    public let node: any Sendable

    public init(studyInstanceUID: String?, date: Date?, files: Int32, rawFiles: Int32, node: any Sendable) {
        self.studyInstanceUID = studyInstanceUID
        self.date = date
        self.files = files
        self.rawFiles = rawFiles
        self.node = node
    }
}

/// The C-FIND of the PACS On-Demand nodes chosen in the preferences.
///
/// Each query blocks a thread of its own, which the Activity window lists
/// under `activity`; cancelling the task that waits cancels that thread,
/// which the query checks as it goes. A node that fails answers nothing.
public protocol DistantStudyQuerying: Sendable {
    /// The patient a history asks about, as the querying side identifies it.
    associatedtype Patient: Sendable

    /// The studies the nodes find for `filters`, keyed as the browser's
    /// distant searches key them ("PatientsName", "modality", "date"...).
    func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary]

    /// The studies of `patient` on the nodes, by the identity fields the
    /// preferences choose; none when they cannot identify the patient.
    func patientStudies(of patient: Patient, activity: String) async -> [DistantStudySummary]
}

// MARK: - What is asked

extension DistantSearch {
    /// The filters of a search of the search field, and the patient name a
    /// second query asks with its last space made the component separator
    /// (nil when there is no second query).
    public static func searchQuery(_ search: String, type: Int32, modality: String?)
        -> (filters: [String: PropertyListValue], alternateName: String?) {
        let built = searchFilters(search, type: type, modality: modality)
        return (PropertyListValue.dictionary(built.filters as? [String: Any] ?? [:]) ?? [:],
                alternatePatientName(built.name, type: type))
    }

    /// The filters of a time interval; nil without a start.
    public static func intervalQuery(from: Date?, to: Date?, modality: String?) -> [String: PropertyListValue]? {
        guard let built = intervalFilters(from: from, to: to, modality: modality) else { return nil }
        return PropertyListValue.dictionary(built as? [String: Any] ?? [:])
    }

    /// The filters of a smart album: the first activated entry of the
    /// "smartAlbumStudiesDICOMNodes" preference with its name, as it is
    /// stored; nil when none.
    public static func smartAlbumQuery(_ entries: [PropertyListValue]?, album: String?) -> [String: PropertyListValue]? {
        for case .dictionary(let entry) in entries ?? [] {
            if (entry["activated"]?.boolValue ?? false) && literallySame(album, entry["name"]?.stringValue) {
                return entry
            }
        }
        return nil
    }

    /// The nodes of `candidates` the comparative searches use, in the order
    /// of `chosen` (each with a "server" holding its "Description" and
    /// "Address"), by their positions; none when a chosen node lacks one of
    /// them.
    public static func comparativeNodes(chosen: [PropertyListValue]?,
                                        candidates: [(description: Any?, address: Any?)]) -> (servers: [Int], incomplete: Bool) {
        var descriptions: [PropertyListValue] = [], addresses: [PropertyListValue] = []
        for case .dictionary(let node) in chosen ?? [] {
            guard case .dictionary(let server)? = node["server"] else { continue }
            if let description = server["Description"] { descriptions.append(description) }
            if let address = server["Address"] { addresses.append(address) }
        }
        if descriptions.count != addresses.count { return ([], true) }
        var servers: [Int] = []
        for x in descriptions.indices {
            for (index, candidate) in candidates.enumerated()
            where literallySame(descriptions[x].stringValue, candidate.description as? String)
                && literallySame(addresses[x].stringValue, candidate.address as? String) {
                servers.append(index)
            }
        }
        return (servers, false)
    }
}

/// NSString's -isEqualToString:, with nil never equal.
private func literallySame(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

// MARK: - How the answers merge

/// A local study of a patient's history, as the merge compares and orders it.
/// Its number of images is asked only when the merge compares it, since
/// counting them reads every series of the study.
public struct LocalHistoryStudy: Sendable, Equatable {
    public let studyInstanceUID: String?
    public let date: Date?

    public init(studyInstanceUID: String?, date: Date?) {
        self.studyInstanceUID = studyInstanceUID
        self.date = date
    }
}

/// A patient's history, local and distant studies merged, the latest first.
public struct PatientHistory: Sendable {
    public enum Member: Sendable {
        /// The local study at this position of the local studies merged.
        case local(Int)
        case distant(DistantStudySummary)
    }

    public let members: [Member]
    /// The distant studies to retrieve, in the order they were met.
    public let retrieved: [DistantStudySummary]
}

/// What a search of the list found: no studies at all when it could not be
/// asked (a smart album without an activated entry).
public struct DistantListAnswer: Sendable {
    public let studies: [DistantStudySummary]?
}

extension DistantStudyMerge {
    /// The studies a second patient-name query adds to the first: those whose
    /// UID the first did not find, after the first.
    public static func secondPass(_ found: [DistantStudySummary], adding more: [DistantStudySummary]) -> [DistantStudySummary] {
        found + missing(from: found.map(\.studyInstanceUID), in: more.map(\.studyInstanceUID)).map { more[$0] }
    }

    /// The history of `local` and `distant` merged as `history` decides, the
    /// latest first (a study without a date last), studies of the same date
    /// in the order the merge left them. `localRawFiles` gives the number of
    /// images of a local study the merge compares.
    public static func patientHistory(local: [LocalHistoryStudy], distant: [DistantStudySummary], preferMoreImages: Bool,
                                      retrievePartial: Bool, inRetrieveQueue: (DistantStudySummary) -> Bool,
                                      localRawFiles: (Int) -> Int32) -> PatientHistory {
        let merge = history(localUIDs: local.map(\.studyInstanceUID), distantUIDs: distant.map(\.studyInstanceUID),
                            preferMoreImages: preferMoreImages, retrievePartial: retrievePartial,
                            inRetrieveQueue: { inRetrieveQueue(distant[$0]) },
                            localRawFiles: localRawFiles, distantRawFiles: { distant[$0].rawFiles },
                            distantFiles: { distant[$0].files })
        let members = merge.members.map { member -> (PatientHistory.Member, Date?) in
            switch member {
            case .local(let i): return (.local(i), local[i].date)
            case .distant(let d): return (.distant(distant[d]), distant[d].date)
            }
        }
        return PatientHistory(members: latestFirst(members, date: { $0.1 }).map { $0.0 }, retrieved: merge.retrieved.map { distant[$0] })
    }

    /// `items` the latest first, as a descending sort descriptor on the date
    /// orders them: an item without a date after every dated one, items of the
    /// same date in their order.
    public static func latestFirst<Item>(_ items: [Item], date: (Item) -> Date?) -> [Item] {
        items.enumerated().sorted { a, b in
            switch (date(a.element), date(b.element)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

// MARK: - The distant studies of the list

/// The distant studies the study list shows beside its own: those of the last
/// search of the list that answered, of the search field, the time interval or
/// a smart album; nil when there are none to show. The list reads them on
/// whatever thread refreshes it, so they are kept under a lock of their own.
public final class DistantListStudies: Sendable {
    private let state = Mutex<[DistantStudySummary]?>(nil)

    public init() {}

    public var studies: [DistantStudySummary]? {
        state.withLock { $0 }
    }

    public func replace(with studies: [DistantStudySummary]?) {
        state.withLock { $0 = studies }
    }
}

// MARK: - The searches

/// The PACS On-Demand searches of the process: the list's (search field, time
/// interval, smart album) and the history's.
///
/// Each search is a question, and the last question of each search wins: a
/// new one cancels the question of the same search that the nodes are
/// answering, and a question superseded while it waits is never asked. The
/// nodes answer one question at a time, the list's and the history's in the
/// order they were asked. When its turn comes, a question is asked only while
/// `stillAsked` says the browser still shows what it asks about, and its answer
/// is handed back only while it is still the last of its search. Quitting
/// cancels every question at once (`cancelAll`), from any thread.
public actor PACSOnDemandSearch<Nodes: DistantStudyQuerying> {
    /// The querying side, whose nodes the web portal asks too.
    public nonisolated let nodes: Nodes
    /// The distant studies the study list shows now.
    public nonisolated let listStudies = DistantListStudies()
    private nonisolated let preferences: any PreferenceStore

    private enum Search: Hashable {
        case list
        case history
    }

    /// The questions asked: the last of each search, and the one the nodes
    /// are answering with its query. Under a lock of its own, so that
    /// `cancelAll` can supersede and cancel them without waiting for the actor.
    private struct Ledger {
        var lastQuestion = 0
        var latest: [Search: Int] = [:]
        var answering: [Search: (question: Int, query: Task<[DistantStudySummary], Never>)] = [:]
    }

    private nonisolated let ledger = Mutex(Ledger())
    private var nodesBusy = false
    private var waitingForNodes: [CheckedContinuation<Void, Never>] = []

    public init(nodes: Nodes, preferences: any PreferenceStore) {
        self.nodes = nodes
        self.preferences = preferences
    }

    // MARK: The list

    /// The studies the nodes find for a search of the search field; a patient
    /// name of several words is asked a second time with "^" before its last
    /// word, and what that adds joins the answer. A series description, which
    /// a study query cannot ask, finds none. Nil when superseded or no longer
    /// asked.
    public func studies(forSearch search: String, type: Int32, modality: String?, activity: String,
                        stillAsked: @escaping @Sendable () async -> Bool) async -> DistantListAnswer? {
        let query = DistantSearch.searchQuery(search, type: type, modality: modality)
        let nodes = self.nodes
        let found = await ask(.list, activity: activity, stillAsked: stillAsked) {
            guard type != DistantSearch.seriesDescriptionType else { return [] }
            let first = await nodes.studies(matching: query.filters, activity: activity)
            guard let name = query.alternateName else { return first }
            var filters = query.filters
            filters["PatientsName"] = .string(name)
            return DistantStudyMerge.secondPass(first, adding: await nodes.studies(matching: filters, activity: activity))
        }
        return found.map { DistantListAnswer(studies: $0) }
    }

    /// The studies the nodes find for a time interval, with the modality
    /// filter; nil without a start, when superseded or no longer asked.
    public func studies(from: Date?, to: Date?, modality: String?, activity: String,
                        stillAsked: @escaping @Sendable () async -> Bool) async -> DistantListAnswer? {
        guard let filters = DistantSearch.intervalQuery(from: from, to: to, modality: modality) else { return nil }
        let nodes = self.nodes
        let found = await ask(.list, activity: activity, stillAsked: stillAsked) {
            await nodes.studies(matching: filters, activity: activity)
        }
        return found.map { DistantListAnswer(studies: $0) }
    }

    /// The studies the nodes find for a smart album, with the filters of its
    /// entry in the preferences. Nil when superseded or no longer asked.
    public func studies(forSmartAlbum album: String, activity: String,
                        stillAsked: @escaping @Sendable () async -> Bool) async -> DistantListAnswer? {
        let filters = smartAlbumFilters(album)
        let nodes = self.nodes
        let found = await ask(.list, activity: activity, stillAsked: stillAsked) {
            guard let filters else { return [] }
            return await nodes.studies(matching: filters, activity: activity)
        }
        return found.map { DistantListAnswer(studies: filters == nil ? nil : $0) }
    }

    /// The filters of a smart album's entry in the preferences; nil when it
    /// has no activated one.
    public nonisolated func smartAlbumFilters(_ album: String?) -> [String: PropertyListValue]? {
        DistantSearch.smartAlbumQuery(preferences[WebPortalPreferences.smartAlbumStudiesDICOMNodes], album: album)
    }

    // MARK: The history

    /// The history of `patient`: its distant studies merged with `local`, the
    /// latest first. Nil when superseded or no longer shown. `rawFiles` gives
    /// the numbers of images of the local studies at the positions it is
    /// given, those a distant study of the same UID is compared with.
    public func history(of patient: Nodes.Patient, local: [LocalHistoryStudy], activity: String,
                        inRetrieveQueue: @escaping @Sendable (DistantStudySummary) -> Bool,
                        rawFiles: @escaping @Sendable ([Int]) async -> [Int: Int32],
                        stillShown: @escaping @Sendable () async -> Bool) async -> PatientHistory? {
        let nodes = self.nodes
        guard let distant = await ask(.history, activity: activity, stillAsked: stillShown, {
            await nodes.patientStudies(of: patient, activity: activity)
        }) else { return nil }

        var compared: [Int: Int32] = [:]
        if preferences[WebPortalPreferences.prefersStudyWithMoreImages] {
            let distantUIDs = distant.map(\.studyInstanceUID)
            let shared = local.indices.filter { i in distantUIDs.contains { literallySame($0, local[i].studyInstanceUID) } }
            if !shared.isEmpty { compared = await rawFiles(shared) }
        }
        return mergedHistory(local: local, distant: distant, inRetrieveQueue: inRetrieveQueue,
                             localRawFiles: { compared[$0] ?? 0 })
    }

    /// `local` and `distant` merged as the preferences choose: a distant study
    /// with more images than the study of the same UID takes its place, and is
    /// retrieved when partial studies are retrieved automatically.
    public nonisolated func mergedHistory(local: [LocalHistoryStudy], distant: [DistantStudySummary],
                                          inRetrieveQueue: (DistantStudySummary) -> Bool,
                                          localRawFiles: (Int) -> Int32) -> PatientHistory {
        DistantStudyMerge.patientHistory(local: local, distant: distant,
                                         preferMoreImages: preferences[WebPortalPreferences.prefersStudyWithMoreImages],
                                         retrievePartial: preferences[NetworkPreferences.automaticallyRetrievePartialStudies],
                                         inRetrieveQueue: inRetrieveQueue, localRawFiles: localRawFiles)
    }

    // MARK: The questions

    /// Supersedes every question asked so far, of the list and of the
    /// history, and cancels the queries the nodes are answering: none of them
    /// hands anything back, and the waiting ones are never asked. Any thread.
    public nonisolated func cancelAll() {
        let queries = ledger.withLock { ledger -> [Task<[DistantStudySummary], Never>] in
            ledger.lastQuestion += 1
            for search in [Search.list, .history] { ledger.latest[search] = ledger.lastQuestion }
            defer { ledger.answering.removeAll() }
            return ledger.answering.values.map(\.query)
        }
        for query in queries { query.cancel() }
    }

    /// Asks `query` as the last question of `search`, when the nodes are free
    /// and it still is: nil when superseded or no longer asked.
    private func ask(_ search: Search, activity: String, stillAsked: @Sendable () async -> Bool,
                     _ query: @escaping @Sendable () async -> [DistantStudySummary]) async -> [DistantStudySummary]? {
        let (question, earlier) = ledger.withLock { ledger in
            ledger.lastQuestion += 1
            ledger.latest[search] = ledger.lastQuestion
            return (ledger.lastQuestion, ledger.answering[search]?.query)
        }
        earlier?.cancel()

        await waitForNodes()
        defer { freeNodes() }

        guard isLast(question, of: search), await stillAsked(), isLast(question, of: search) else { return nil }
        let running = Task { await query() }
        let registered = ledger.withLock { ledger -> Bool in
            guard ledger.latest[search] == question else { return false }
            ledger.answering[search] = (question, running)
            return true
        }
        if !registered { running.cancel() }
        let found = await running.value
        ledger.withLock { ledger in
            if ledger.answering[search]?.question == question { ledger.answering[search] = nil }
        }
        return isLast(question, of: search) ? found : nil
    }

    private nonisolated func isLast(_ question: Int, of search: Search) -> Bool {
        ledger.withLock { $0.latest[search] == question }
    }

    private func waitForNodes() async {
        guard nodesBusy else {
            nodesBusy = true
            return
        }
        await withCheckedContinuation { waitingForNodes.append($0) }
    }

    private func freeNodes() {
        if waitingForNodes.isEmpty {
            nodesBusy = false
        } else {
            waitingForNodes.removeFirst().resume()
        }
    }
}
