/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase
import IsiXPreferences

// The PACS On-Demand searches of the browser: the nodes asked, and the
// studies of the search field, of the time interval and of a smart album
// found on them, and a patient's history. The browser asks them through the
// typed entries; the viewers, XML-RPC, the web portal and the plugins send
// them by the selectors of the former Objective-C methods, which unpack their
// arguments and call the same entries. Each search checks what the browser
// shows, hands the question to the process's PACSOnDemandSearch
// (IsiXDatabase), where the last question of each search wins, and returns;
// the main thread shows what is found. The history is PatientHistoryList's;
// the count of a smart album with the studies of the nodes is
// DatabaseAlbumCounter's.

extension BrowserController {

    /// The PACS On-Demand searches of the process.
    nonisolated var pacsOnDemand: PACSOnDemandSearch<QueryControllerDistantStudies> {
        PreferencesSource.process.processGraph.pacsOnDemand
    }

    nonisolated private var preferences: UserDefaults {
        PreferencesSource.process.preferences
    }

    // MARK: The nodes

    /// The nodes the comparative searches ask: those chosen in the PACS
    /// On-Demand preferences, among the DICOM and DICOMweb nodes.
    @discardableResult
    @objc(comparativeServers)
    nonisolated class func comparativeServers() -> [Any]! {
        PreferencesSource.process.processGraph.pacsOnDemand.nodes.comparativeServers()
    }

    /// The localized name of a search type of the search field.
    @discardableResult
    @objc(stringForSearchType:)
    nonisolated class func string(forSearchType curSearchType: Int32) -> String! {
        guard let name = DistantSearch.searchTypeName(curSearchType) else { return "" }
        return Bundle.main.localizedString(forKey: name, value: nil, table: nil)
    }

    /// Whether the list asks the nodes: PACS On-Demand on, with `key`, for a
    /// database that can be written (and, unless `remoteToo`, a local one).
    nonisolated private func listAsksNodes(_ key: PreferenceKey<Bool>, remoteToo: Bool = false) -> Bool {
        guard let database = self.database, !database.isReadOnly, remoteToo || database.isLocal() else { return false }
        return preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes] && preferences[key]
    }

    /// Hands `answer`, once the nodes found it, to `show` on the main thread.
    private func whenAnswered(_ answer: @escaping @Sendable () async -> DistantListAnswer?,
                              _ show: @escaping @MainActor @Sendable (DistantListAnswer) -> Void) {
        Task {
            if let found = await answer() { show(found) }
        }
    }

    // MARK: The search field

    /// -searchForSearchField: of the former Objective-C method, with the
    /// "searchString", "searchType" and "selectedAlbumIndex" of `dict`.
    @objc(searchForSearchField:)
    nonisolated func search(forSearchField dict: NSDictionary!) {
        searchDistantNodes(forSearch: dict?.object(forKey: "searchString") as? String,
                           type: BrowserObjC.intValue(dict?.object(forKey: "searchType")),
                           selectedAlbumIndex: BrowserObjC.intValue(dict?.object(forKey: "selectedAlbumIndex")))
    }

    /// Asks the nodes for the search field's string when it is still the
    /// field's string by the time the nodes are free and this is the last
    /// search of the list. Shows the studies found in the list (album row 0,
    /// "Database", selected) or the count of the entire database's result (an
    /// album).
    nonisolated func searchDistantNodes(forSearch searchString: String?, type searchType: Int32, selectedAlbumIndex: Int32) {
        guard listAsksNodes(NetworkPreferences.pacsOnDemandForSearchField) else { return }
        Task { @MainActor in
            self.askNodes(forSearch: searchString, type: searchType, selectedAlbumIndex: selectedAlbumIndex)
        }
    }

    private func askNodes(forSearch searchString: String?, type searchType: Int32, selectedAlbumIndex: Int32) {
        let stillAsked: @MainActor @Sendable () -> Bool = {
            searchType == self.horos_searchType && BrowserObjC.literallyEqual(searchString, self.horos_searchString)
        }
        guard stillAsked() else { return }
        NSLog("Search For %@: %@", BrowserController.string(forSearchType: searchType) ?? "", LogText.shape(of: searchString)) // typed: a name, an identifier

        let length = (searchString as NSString?)?.length ?? 0
        let fieldLength = (horos_searchString as NSString?)?.length ?? 0
        guard length > 2 || (fieldLength >= 2 && horos_searchType == Int32(StudySearchRules.modalitySearchType)) else { return }

        let activity = String(format: NSLocalizedString("Search %@: %@", comment: ""),
                              BrowserController.string(forSearchType: searchType) ?? "", searchString ?? "(null)")
        let search = pacsOnDemand, modality = horos_modalityFilterForQueries
        whenAnswered({
            await search.studies(forSearch: searchString ?? "", type: searchType, modality: modality, activity: activity,
                                 stillAsked: { await stillAsked() })
        }) { answer in
            if selectedAlbumIndex == 0 {
                search.listStudies.replace(with: answer.studies)
            } else {
                self.horos_distantEntireDBResultCount = Int32(truncatingIfNeeded: answer.studies?.count ?? 0)
            }
            self.horos_distantSearchString = searchString
            self.horos_distantSearchType = searchType

            if stillAsked() {
                if selectedAlbumIndex == 0 { self._refreshDatabaseDisplay() } else { self.refreshEntireDBResult() }
            }
        }
    }

    // MARK: The time interval

    /// -searchForTimeIntervalFromTo: of the former Objective-C method, with
    /// the "from" and "to" dates of `dict`.
    @objc(searchForTimeIntervalFromTo:)
    nonisolated func searchForTimeIntervalFrom(to dict: NSDictionary!) {
        searchDistantNodes(from: dict?.object(forKey: "from") as? Date, to: dict?.object(forKey: "to") as? Date)
    }

    /// Asks the nodes for the time interval when it is still the browser's by
    /// the time the nodes are free and this is the last search of the list,
    /// and shows the studies found in the list.
    nonisolated func searchDistantNodes(from: Date?, to: Date?) {
        guard listAsksNodes(NetworkPreferences.pacsOnDemandForSearchField, remoteToo: true) else { return }
        Task { @MainActor in
            self.askNodes(from: from, to: to)
        }
    }

    private func askNodes(from: Date?, to: Date?) {
        let stillAsked: @MainActor @Sendable () -> Bool = {
            let start = self.horos_timeIntervalStart, end = self.horos_timeIntervalEnd
            return from != nil && start != nil && from == start && (to == nil || (end != nil && to == end))
        }
        guard stillAsked() else { return }
        NSLog("Search time interval: %@ to %@", from.map { $0 as NSDate } ?? "(null)" as NSString, to.map { $0 as NSDate } ?? "(null)" as NSString)

        let search = pacsOnDemand, modality = horos_modalityFilterForQueries
        whenAnswered({
            await search.studies(from: from, to: to, modality: modality, activity: NSLocalizedString("Search Time Interval...", comment: ""),
                                 stillAsked: { await stillAsked() })
        }) { answer in
            search.listStudies.replace(with: answer.studies)
            self.horos_distantTimeIntervalStart = from
            self.horos_distantTimeIntervalEnd = to

            if stillAsked() {
                self._refreshDatabaseDisplay()
            }
        }
    }

    // MARK: Smart albums

    /// Asks the nodes for the smart album selected: the searches of the list
    /// asked before are cancelled, and the last one shows what it found.
    @objc(searchForSmartAlbumDistantStudies:)
    nonisolated func search(forSmartAlbumDistantStudies albumName: String!) {
        guard listAsksNodes(NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes), let albumName, !albumName.isEmpty else { return }
        Task { @MainActor in
            self.askNodes(forSmartAlbum: albumName)
        }
    }

    private func askNodes(forSmartAlbum albumName: String) {
        let stillAsked: @MainActor @Sendable () -> Bool = { BrowserObjC.literallyEqual(albumName, self.selectedAlbumName) }
        guard stillAsked() else { return }
        NSLog("Search album: %@", LogText.shape(of: albumName)) // named by its owner, after a patient as readily as anything

        horos_lastRefreshSmartAlbumDistantStudies = Date.timeIntervalSinceReferenceDate

        let search = pacsOnDemand
        let activity = String(format: NSLocalizedString("Search Smart Album...", comment: ""), albumName)
        whenAnswered({
            await search.studies(forSmartAlbum: albumName, activity: activity, stillAsked: { await stillAsked() })
        }) { answer in
            search.listStudies.replace(with: answer.studies)
            self.horos_smartAlbumDistantName = albumName

            if stillAsked() {
                self._refreshDatabaseDisplay()
            }
        }
    }

    // MARK: Comparative studies

    /// A patient's history, searched for the history list.
    @objc(searchForComparativeStudies:)
    nonisolated func search(forComparativeStudies studySelectedID: Any!) {
        if self.database == nil { return }
        let subject = HistorySubject(studySelectedID)
        Task { @MainActor in
            self.patientHistory.search(subject.value)
        }
    }
}

/// What -searchForComparativeStudies: was given, handed to the main thread:
/// the object ID of a local study, or a study of a node, shared as
/// DistantQueryNode says.
private struct HistorySubject: @unchecked Sendable {
    let value: Any?

    init(_ value: Any?) {
        self.value = value
    }
}
