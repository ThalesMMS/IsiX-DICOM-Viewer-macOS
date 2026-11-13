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
import IsiXDatabase
import IsiXDICOMNetwork
import IsiXDICOMFile
import IsiXPreferences
import Synchronization

/// A value handed to another thread that only reads what it is allowed to
/// read there: a database asked for a private-queue copy of itself, or the
/// objects whose object IDs are read.
struct Handed<Value>: @unchecked Sendable {
    let value: Value
}

/// The local studies of a patient's history, read on a private-queue context:
/// their object IDs and what the merge compares, the latest first.
private struct LocalHistory: Sendable {
    var objectIDs: [NSManagedObjectID] = []
    var studies: [LocalHistoryStudy] = []
}

/// The patient's history beside the thumbnails: the studies of the patient of
/// the selected row, local at once and then merged with those the PACS
/// On-Demand nodes find, the table that shows them, its refresh every second,
/// and the study retrieved from it that is waited for.
///
/// The browser's window shows the table, so this lives on the main actor; the
/// local studies are read on a thread of their own and the nodes are asked by
/// the process's PACSOnDemandSearch, where the last history asked wins. The
/// state the nib, the plugins and the other extensions read (the patient
/// shown, the studies, the study waited for) stays the browser's.
@MainActor final class PatientHistoryList {
    private unowned let browser: BrowserController
    private let pacsOnDemand: PACSOnDemandSearch<QueryControllerDistantStudies>
    /// The related-studies limit of the published contract is read from UserDefaults.
    private let preferences: UserDefaults

    init(browser: BrowserController, search: PACSOnDemandSearch<QueryControllerDistantStudies>, preferences: UserDefaults) {
        self.browser = browser
        self.pacsOnDemand = search
        self.preferences = preferences
    }

    private var table: NSTableView? { browser.horos_comparativeTable }

    // MARK: The selection

    /// No row is selected: no history.
    func clear() {
        browser.comparativePatientUID = nil
        browser.comparativeStudies = nil
        table?.reloadData()
        setHeader(NSLocalizedString("History", comment: ""))
    }

    /// Another row is selected: the history of another patient is searched,
    /// or the study selected is selected in the history.
    func selectionChanged(to studySelected: Any?) {
        if ComparativeHistory.patientChanged(selected: rowValue(studySelected, "patientUID"), shown: browser.comparativePatientUID) {
            browser.comparativePatientUID = rowValue(studySelected, "patientUID") as? String
            browser.comparativeStudies = nil
            table?.reloadData()
            setHeader(NSLocalizedString("History", comment: ""))

            search(browser.comparativeSearchObject(studySelected))
        } else if let index = ComparativeHistory.row(of: rowValue(studySelected, "studyInstanceUID"), in: studyUIDs()) {
            table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table?.scrollRowToVisible(table?.selectedRow ?? 0)
        }
    }

    // MARK: The search

    /// Searches the history of the patient of a study (the object ID of a
    /// local study, or a study of a node), while it is still the patient
    /// shown: the local studies, the latest first and within the related
    /// studies limit, shown at once; then, when the nodes are asked, the
    /// distant studies merged with them, shown again.
    func search(_ subject: Any?) {
        guard let database = browser.database else { return }
        let study: AnyObject? = (subject as? NSManagedObjectID).map { database.object(withID: $0) as AnyObject? } ?? subject as AnyObject?
        guard let patientUID = Self.patientUID(of: study), !patientUID.isEmpty, isShown(patientUID) else { return }
        browser.horos_lastRefreshComparativeStudies = Date.timeIntervalSinceReferenceDate

        let patient: DistantHistoryPatient?
        if let study = study as? DicomStudy {
            patient = DistantHistoryPatient(study: .local(study.objectID, in: database))
        } else if let node = study as? DCMTKStudyQueryNode {
            patient = DistantHistoryPatient(study: .distant(node))
        } else {
            patient = nil
        }
        let activity = String(format: NSLocalizedString("Search History: %@", comment: ""), Self.name(of: study) ?? "(null)")
        let limit = AssociationContract.relatedStudiesLimit(in: preferences)
        let handed = Handed(value: database)
        let studyID = (study as? DicomStudy)?.objectID

        Task {
            let local = await ActivityThread.runUnlisted(name: "Search For Comparative Studies") {
                Self.localHistory(of: patientUID, studyID: studyID, in: handed.value, limit: limit)
            }
            guard isShown(patientUID) else { return }
            // Already display the local studies; the merged ones come later.
            let localStudies = local.objectIDs.compactMap { database.object(withID: $0) as Any? }
            display(localStudies)

            guard let patient, asksNodes() else { return }
            let browser = self.browser
            guard let history = await pacsOnDemand.history(
                of: patient, local: local.studies, activity: activity,
                inRetrieveQueue: { Self.isBeingRetrieved($0, by: browser) },
                rawFiles: { positions in await Self.rawFiles(of: positions, in: local.objectIDs, database: handed) },
                stillShown: { await self.isShown(patientUID) }) else { return }

            let merged = members(of: history, local: local.objectIDs, in: database)
            if isShown(patientUID) {
                display(merged)
                browser.checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: nil)
            }
        }
    }

    /// Whether the nodes are asked for the history: PACS On-Demand on, and a
    /// local database that can be written.
    private func asksNodes() -> Bool {
        guard let database = browser.database else { return false }
        return preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes] && !database.isReadOnly && database.isLocal()
    }

    /// Whether the history shown is still the patient's.
    private func isShown(_ patientUID: String) -> Bool {
        DistantSearch.samePatient(browser.horos_comparativePatientUID, patientUID)
    }

    /// The studies of a merged history, the local ones in the main context,
    /// and the retrieves the merge chose started.
    private func members(of history: PatientHistory, local: [NSManagedObjectID], in database: DicomDatabase) -> [Any] {
        let retrieved = QueryControllerDistantStudies.nodes(of: history.retrieved)
        if !retrieved.isEmpty {
            browser.comparativeState.retrieves.startAutoretrieve(retrieved, name: NSLocalizedString("Auto-Retrieving...", comment: ""))
        }
        return history.members.compactMap { member -> Any? in
            switch member {
            case .local(let i): return database.object(withID: local[i]) as Any?
            case .distant(let study): return (study.node as? DistantQueryNode)?.node
            }
        }
    }

    /// The numbers of images of the local studies at `positions`, read in
    /// the main context.
    private static func rawFiles(of positions: [Int], in objectIDs: [NSManagedObjectID],
                                 database: Handed<DicomDatabase>) -> [Int: Int32] {
        var counts: [Int: Int32] = [:]
        for position in positions {
            let study = database.value.object(withID: objectIDs[position]) as? DicomStudy
            counts[position] = study?.rawNoFiles()?.int32Value ?? 0
        }
        return counts
    }

    /// Whether a distant study is in the queue of the studies being retrieved.
    nonisolated private static func isBeingRetrieved(_ study: DistantStudySummary, by browser: BrowserController) -> Bool {
        guard (study.node as? DistantQueryNode) != nil else { return false }
        return browser.comparativeState.retrieves.isRetrieving(studyInstanceUID: study.studyInstanceUID)
    }

    // MARK: Reading the local studies

    nonisolated private static func localHistory(of patientUID: String, studyID: NSManagedObjectID?, in database: DicomDatabase, limit: Int) -> LocalHistory {
        guard let idatabase = database.privateQueueIndependentDatabase() as? DicomDatabase else { return LocalHistory() }
        var history = LocalHistory()
        idatabase.performBlockAndWait {
            let selected = studyID.flatMap { idatabase.object(withID: $0) as? DicomStudy }
            let studies = localStudies(of: patientUID, in: idatabase, limit: limit, selected: selected)
            history = LocalHistory(objectIDs: studies.map(\.objectID),
                                   studies: studies.map { LocalHistoryStudy(studyInstanceUID: $0.studyInstanceUID, date: $0.date) })
        }
        return history
    }

    /// The studies of a patient in `idatabase`, on its queue: the latest
    /// first, at most `comparativeLimit` of them (none at 0).
    nonisolated static func localStudies(of patientUID: String, in idatabase: DicomDatabase, limit comparativeLimit: Int, selected: DicomStudy? = nil) -> [DicomStudy] {
        var found: [DicomStudy] = []
        if let raised = HorosObjCException.caught({
            // The published contract limits this search and keeps the
            // most recent studies: a patient with a long history must
            // not make the browser fetch and hold everything.
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.entity = idatabase.studyEntity()
            request.predicate = NSPredicate(format: "(patientUID ==[cd] %@)", patientUID)
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            if comparativeLimit > 0 {
                request.fetchLimit = comparativeLimit
            }
            found = ((try? idatabase.managedObjectContext.fetch(request)) ?? []).compactMap { $0 as? DicomStudy }
            let preferences = PreferencesSource.process.preferences
            if preferences[DatabasePreferences.usePatientIDForUID], let selected,
               let identity = comparativeIdentity(of: selected, in: idatabase) {
                let headerLimit = 32
                let checked = found.prefix(headerLimit).filter { study in
                    comparativeIdentity(of: study, in: idatabase).map { !identity.hasDifferentIssuer(from: $0) } ?? true
                }
                found = Array(checked) + found.dropFirst(headerLimit)
                if preferences[DatabasePreferences.usePatientNameForUID] || preferences[DatabasePreferences.usePatientBirthDateForUID] {
                    request.predicate = NSPredicate(format: "patientID == %@ AND NOT (patientUID ==[cd] %@)", selected.patientID ?? "", patientUID)
                    request.fetchLimit = headerLimit
                    let candidates = ((try? idatabase.managedObjectContext.fetch(request)) ?? []).compactMap { $0 as? DicomStudy }
                    found += candidates.filter { study in
                        comparativeIdentity(of: study, in: idatabase).map(identity.corroborates) ?? false
                    }
                }
                found.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                if comparativeLimit > 0 { found = Array(found.prefix(comparativeLimit)) }
            }
            if comparativeLimit > 0 && found.count >= comparativeLimit {
                NSLog("Comparative studies: kept the %ld most recent of this patient's studies (%@ = %ld)",
                      comparativeLimit, AssociationContract.relatedStudiesLimitKey, comparativeLimit)
            }
        }) {
            NSLog("*** Comparative Studies exception: %@", raised)
        }
        return found
    }

    nonisolated static func comparativeIdentity(of study: DicomStudy, in database: DicomDatabase) -> ComparativePatientIdentity? {
        guard !Thread.isMainThread, database.isLocal(), let folder = database.dataBaseDirPath,
              (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true,
              let series = (study.series as NSSet?)?.sortedArray(using: (DicomStudy.seriesSortDescriptors() as? [NSSortDescriptor]) ?? []) else { return nil }
        for case let series as DicomSeries in series {
            guard let image = series.images?.first?.base as? DicomImage, image.inDatabaseFolder()?.boolValue == true,
                  let stored = image.path(), !stored.isEmpty, stored == (stored as NSString).lastPathComponent,
                  let path = DicomImage.completePath(forLocalPath: stored, directory: folder) else { continue }
            guard let resources = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey, .isSymbolicLinkKey]),
                  resources.volumeIsLocal == true, resources.isSymbolicLink == false,
                  let dataset = try? IsiXDCMTKDataset.dataset(ofFileAtPath: path, transferSyntax: nil) else { return nil }
            let (_, encodings) = dataset.characterSetEncodings()
            guard dataset.text(.patientID, encodings: encodings, replaceBadCharacters: false) == study.patientID,
                  let name = dataset.text(.patientName, encodings: encodings, replaceBadCharacters: false), !name.isEmpty,
                  DicomFile.nSreplaceBadCharacter(name)?.caseInsensitiveCompare(DicomFile.nSreplaceBadCharacter(study.name) ?? "") == .orderedSame,
                  dataset.latin1Value(.studyInstanceUID) == study.studyInstanceUID else { return nil }
            let birth = dataset.latin1Value(.patientBirthDate).flatMap { DICOMCalendarDate.dicomDate($0) } as Date?
            if let indexed = study.dateOfBirth, let birth, !Calendar(identifier: .gregorian).isDate(indexed, inSameDayAs: birth) { return nil }
            return dataset.comparativePatientIdentity(encodings: encodings, birthDate: birth)
        }
        return nil
    }

    // MARK: On the calling thread

    /// The history of the patient of a study (an object ID of `idatabase`, or
    /// a study of a node), searched on the calling thread inside the block of
    /// `idatabase`, while it is still the patient shown; the table shows it
    /// too. The nodes, when they are asked, are asked at once, whatever the
    /// other histories asked.
    nonisolated static func historyNow(of subject: Any?, in idatabase: DicomDatabase?, browser: BrowserController,
                                       search: PACSOnDemandSearch<QueryControllerDistantStudies>, preferences: UserDefaults, updatesTable: Bool = true) -> [Any]? {
        let study: AnyObject? = (subject as? NSManagedObjectID).map { idatabase?.object(withID: $0) as AnyObject? } ?? subject as AnyObject?
        guard let patientUID = patientUID(of: study), !patientUID.isEmpty else { return nil }
        func stillShown() -> Bool { DistantSearch.samePatient(browser.horos_comparativePatientUID, patientUID) }
        guard !updatesTable || stillShown() else { return nil }
        if updatesTable { browser.horos_lastRefreshComparativeStudies = Date.timeIntervalSinceReferenceDate }

        let local: [DicomStudy] = idatabase.map { localStudies(of: patientUID, in: $0, limit: AssociationContract.relatedStudiesLimit(in: preferences), selected: study as? DicomStudy) } ?? []
        if updatesTable && stillShown() {
            showLater(Handed(value: local as [Any]), browser: browser, check: false)
        }

        let database = browser.database
        guard preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes], database?.isReadOnly != true, database?.isLocal() == true,
              let study else { return local }
        let distant = search.nodes.patientStudiesNow(of: study, database: idatabase)
        let history = search.mergedHistory(local: local.map { LocalHistoryStudy(studyInstanceUID: $0.studyInstanceUID, date: $0.date) },
                                           distant: distant, inRetrieveQueue: { isBeingRetrieved($0, by: browser) },
                                           localRawFiles: { local[$0].rawNoFiles()?.int32Value ?? 0 })
        let retrieved = QueryControllerDistantStudies.nodes(of: history.retrieved)
        if !retrieved.isEmpty {
            browser.comparativeState.retrieves.startAutoretrieve(retrieved, name: NSLocalizedString("Auto-Retrieving...", comment: ""))
        }
        let merged = history.members.compactMap { member -> Any? in
            switch member {
            case .local(let i): return local[i]
            case .distant(let study): return (study.node as? DistantQueryNode)?.node
            }
        }
        if updatesTable && stillShown() {
            showLater(Handed(value: merged), browser: browser, check: true)
        }
        return merged
    }

    /// Shows `studies` in the table on the main thread, after this returns;
    /// the local ones are taken there by object ID.
    nonisolated private static func showLater(_ studies: Handed<[Any]>, browser: BrowserController, check: Bool) {
        Task { @MainActor in
            browser.patientHistory.show(studies.value)
            if check {
                browser.checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: nil)
            }
        }
    }

    // MARK: The table

    /// Shows `newStudies` (local studies of any context, taken in the main
    /// one by object ID, and studies of a node) as the history of the
    /// selected row; none without a selected row.
    func show(_ newStudies: [Any]?) {
        let mainContextStudies: [Any] = (newStudies ?? []).compactMap { (study: Any) -> Any? in
            guard let study = study as? DicomStudy else { return study }
            return browser.database?.object(withID: study.objectID) as Any?
        }
        display(mainContextStudies)
    }

    /// Shows studies of the main context and of the nodes.
    private func display(_ studies: [Any]) {
        if browser.horos_databaseIvar == nil { return }

        let item = browser.selectedOutlineItem()
        let studySelected = browser.studyOfRow(item)
        let table = self.table

        guard item != nil else {
            browser.comparativeStudies = nil
            table?.reloadData()
            return
        }

        browser.horos_dontSelectStudyFromComparativeStudies = true

        browser.comparativeStudies = studies
        table?.reloadData()

        if let name = rowValue(studySelected, "name") as? String {
            setHeader(name)
        }

        let index = ComparativeHistory.row(of: rowValue(studySelected, "studyInstanceUID"), in: studyUIDs())

        browser.horos_dontSelectStudyFromComparativeStudies = false

        table?.selectRowIndexes(IndexSet(integer: index ?? 0), byExtendingSelection: false)

        if let viewers = ViewerController.getDisplayed2DViewers() {
            for case let viewer as ViewerController in viewers {
                viewer.comparativeRefresh(browser.comparativePatientUID)
            }
        }

        table?.scrollRowToVisible(table?.selectedRow ?? 0)
    }

    /// New local studies: those of the patient shown join the history, in
    /// place of the studies of a node with their UIDs, or in date order.
    func add(newStudies: [Any]) {
        if browser.horos_databaseIvar == nil { return }
        let table = self.table

        for newStudy in newStudies {
            guard ComparativeHistory.isShownPatient(shown: browser.comparativePatientUID, patientUID: rowValue(newStudy, "patientUID")) else { continue }

            let current: [Any] = browser.comparativeStudies ?? []
            var updated = current

            var selectedStudy: Any?
            if let row = table?.selectedRow, row >= 0, row < updated.count {
                selectedStudy = updated[row]
            }

            let history = ComparativeHistory.newStudy(rowValue(newStudy, "studyInstanceUID"),
                                                      uids: current.map { rowValue($0, "studyInstanceUID") },
                                                      isQueryNode: { current[$0] is DCMTKStudyQueryNode })
            for index in history.replaced {
                let replaced = current[index] as AnyObject
                if let position = updated.firstIndex(where: { ($0 as AnyObject).isEqual(replaced) }) {
                    updated[position] = newStudy
                }
            }

            if !history.found {
                updated.append(newStudy)
                updated = DistantStudyMerge.latestFirst(updated, date: Self.date(of:))
            }

            browser.comparativeStudies = updated

            table?.reloadData()

            if let selectedStudy,
               let index = ComparativeHistory.row(of: rowValue(selectedStudy, "studyInstanceUID"), in: updated.map { rowValue($0, "studyInstanceUID") }) {
                table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
    }

    // MARK: Retrieving a study of the history

    /// Retrieves a study of the history unless it is being retrieved, and
    /// waits for it to select it, or to open it in `viewer` or the browser,
    /// when asked: the one-second refresh does once it has arrived.
    func retrieve(_ study: DCMTKStudyQueryNode?, select: Bool, open: Bool, showGUI: Bool, viewer: ViewerController?) {
        browser.comparativeState.retrieves.startRetrieve(study, showGUI: showGUI)

        if open || select {
            browser.horos_comparativeStudyWaitedToOpen = open
            browser.horos_comparativeStudyWaitedToSelect = select
            browser.horos_comparativeStudyWaited = study
            browser.horos_comparativeStudyWaitedTime = Date.timeIntervalSinceReferenceDate
            browser.horos_comparativeStudyWaitedViewer = viewer
        }
    }

    /// A double click in the history: the row clicked, not the one still
    /// selected, is retrieved when it is on a node and opened when it is
    /// local; a double click outside the rows opens nothing.
    func doubleClick() {
        browser.checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: nil)

        let row = table?.clickedRow ?? -1
        let studies = browser.comparativeStudies ?? []
        guard row >= 0, row < studies.count else { return }
        let study = studies[row]

        if let node = study as? DCMTKStudyQueryNode, node.isDistant() {
            // Check to see if already in retrieving mode, if not download it
            retrieve(node, select: true, open: false, showGUI: true, viewer: nil)
        } else {
            _ = browser.selectThisStudy(study)
            browser.window?.makeFirstResponder(browser.horos_databaseOutline)
            browser.databaseOpenStudy(study as? NSManagedObject)
        }
    }

    // MARK: Every second

    /// The browser's one-second timer (nil when asked at once): the history
    /// and the selected smart album's distant studies are searched again
    /// when they are due, and the study waited for is selected or opened when
    /// it has arrived.
    func refreshIfNeeded(fromTimer: Bool) {
        if !fromTimer {
            browser.horos_lastRefreshComparativeStudies = 0
        }

        let now = Date.timeIntervalSinceReferenceDate
        if ComparativeHistory.refreshDue(now: now, last: browser.horos_lastRefreshComparativeStudies) {
            if let object = browser.comparativeSearchObject(browser.studyOfRow(browser.selectedOutlineItem())) {
                search(object)
            }
            browser.computeTimeInterval()
        }

        if preferences[NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes], let albumTable = browser.horos_albumTable, albumTable.selectedRow > 0 {
            let albums = browser.albumArray() ?? []
            if albums.count > albumTable.selectedRow, let album = albums[albumTable.selectedRow] as? DicomAlbum, album.smartAlbum?.boolValue ?? false,
               ComparativeHistory.refreshDue(now: now, last: browser.horos_lastRefreshSmartAlbumDistantStudies) {
                browser.search(forSmartAlbumDistantStudies: album.name)
            }
        }

        selectWaitedStudy()
    }

    /// The study retrieved from the history that is waited for: selected, and
    /// opened when asked, once it has arrived; forgotten after ten seconds.
    private func selectWaitedStudy() {
        guard let waited = browser.horos_comparativeStudyWaited else { return }
        guard ComparativeHistory.stillWaiting(now: Date.timeIntervalSinceReferenceDate, since: browser.horos_comparativeStudyWaitedTime) else {
            forgetWaitedStudy()
            return
        }

        DatabaseIngest.process.requestImport()

        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
        // The node answers its UID through a method: the predicate takes what
        // it returns, since the method itself never equals a stored UID.
        request.predicate = comparison("studyInstanceUID", .equalTo, waited.studyInstanceUID())

        var found: [Any]?
        if let raised = HorosObjCException.caught({ found = try? self.browser.database?.managedObjectContext?.fetch(request) }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController refreshComparativeStudiesIfNeeded:]")
        }

        guard let study = found?.first as? DicomStudy, (browser.childrenArray(study)?.count ?? 0) > 0 else { return }
        guard browser.horos_comparativeStudyWaitedToSelect else {
            forgetWaitedStudy()
            return
        }
        guard browser.selectThisStudy(study) else { return }

        browser.horos_comparativeStudyWaited = nil

        if browser.horos_comparativeStudyWaitedToOpen, let viewer = browser.horos_comparativeStudyWaitedViewer {
            if viewer.window?.isVisible ?? false {
                viewer.loadSelectedSeries(study, rightClick: false)
            }
        } else if browser.horos_comparativeStudyWaitedToOpen {
            browser.databaseOpenStudy(study)
        }

        let window = browser.window, searchField = browser.horos_searchField
        if window?.firstResponder !== searchField && window?.firstResponder !== searchField?.currentEditor() {
            window?.makeFirstResponder(browser.horos_databaseOutline)
        }

        browser.horos_comparativeStudyWaitedViewer = nil
    }

    private func forgetWaitedStudy() {
        browser.horos_comparativeStudyWaited = nil
        browser.horos_comparativeStudyWaitedViewer = nil
    }

    // MARK: Helpers

    /// The header of the history's column.
    private func setHeader(_ title: String) {
        table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Cell"))?.headerCell.stringValue = title
    }

    /// The study instance UIDs of the history, nil without one.
    private func studyUIDs() -> [Any?]? {
        browser.comparativeStudies.map { studies in studies.map { rowValue($0, "studyInstanceUID") } }
    }

    nonisolated private static func patientUID(of study: AnyObject?) -> String? {
        if let study = study as? DicomStudy { return study.patientUID }
        return (study as? DCMTKStudyQueryNode)?.patientUID()
    }

    nonisolated private static func name(of study: AnyObject?) -> String? {
        if let study = study as? DicomStudy { return study.name }
        return (study as? DCMTKStudyQueryNode)?.name()
    }

    /// The date a history is ordered by: a local study's, or a node's.
    nonisolated private static func date(of study: Any) -> Date? {
        if let study = study as? DicomStudy { return study.date }
        return (study as? DCMTKStudyQueryNode)?.date() as Date?
    }
}

/// The studies retrieved from the nodes for the history and the smart albums:
/// a study of the history retrieved by a double click (five at a time, never
/// twice at once), and those a smart album or the history retrieve by
/// themselves. Each runs on a thread the Activity window lists, with its
/// Cancel button. The browser keeps one, which any thread asks.
final class DistantStudyRetrieves: Sendable {

    private struct State {
        /// The studies being retrieved from the history, by identity, with their UIDs.
        var retrieving: [ObjectIdentifier: String?] = [:]
        var autoretrieving = false
    }

    private let state = Mutex(State())

    /// At most five retrieves of the history at once.
    private let slots = DispatchSemaphore(value: 5)

    /// Whether the studies a smart album retrieves by itself are being retrieved.
    var isAutoretrieving: Bool { state.withLock { $0.autoretrieving } }

    /// Whether `study` is being retrieved from the history.
    func isRetrieving(_ study: DCMTKStudyQueryNode) -> Bool {
        state.withLock { $0.retrieving[ObjectIdentifier(study)] != nil }
    }

    /// Whether a study of that UID is being retrieved from the history; a
    /// nil UID is never found.
    func isRetrieving(studyInstanceUID uid: String?) -> Bool {
        guard let uid else { return false }
        return state.withLock { $0.retrieving.values.contains { $0 == uid } }
    }

    // MARK: A study of the history

    /// Retrieves `study`, unless it is being retrieved already, on a thread
    /// of its own; `showGUI` shows "Retrieving..." for half a second.
    @MainActor func startRetrieve(_ study: DCMTKStudyQueryNode?, showGUI: Bool) {
        if let study, isRetrieving(study) { return }

        let wait = showGUI ? WaitRendering(NSLocalizedString("Retrieving...", comment: "")) : nil
        wait?.showWindow(nil)

        let handed = study.map(DistantQueryNode.init)
        let status = BrowserObjC.singularPlural(1, NSLocalizedString("study", comment: ""), NSLocalizedString("studies", comment: ""))
        Task {
            await ActivityThread.run(name: NSLocalizedString("Retrieving images...", comment: ""), configure: { $0.status = status }) {
                self.retrieveNow(handed?.node)
            }
        }

        if showGUI {
            Thread.sleep(forTimeInterval: 0.5)
        }
        wait?.close()
    }

    /// The retrieve of a study of the history, on the calling thread: it
    /// waits for one of the five places, and imports what arrived at once.
    func retrieveNow(_ study: DCMTKStudyQueryNode?, in database: DicomDatabase? = nil) {
        autoreleasepool {
            slots.wait()
            defer { slots.signal() }
            guard !Thread.current.isCancelled else { return }

            if let study {
                state.withLock { $0.retrieving[ObjectIdentifier(study)] = .some(study.studyInstanceUID()) }
            }

            // No time for decompression: the files are imported as they arrive while the retrievals
            // running at once last, and until this one ends, also by raising.
            ListenerCompressionSuspension.shared.whileWorking {
                QueryController.retrieveStudies(study.map { [$0] } ?? [], showErrors: false, checkForPreviousAutoRetrieve: false)

                // Imported on a private-queue context, on its queue.
                let idb = (database ?? PreferencesSource.process.processGraph.activeLocalDatabase)?.privateQueueIndependentDatabase() as? DicomDatabase

                idb?.performBlockAndWait { _ = DatabaseIngest.process.importQueueNow(in: idb) }

                // Files the scan moved aside to be converted? Only those, not a selection's conversion.
                if idb?.waitForCompressThread() == true {
                    idb?.performBlockAndWait { _ = DatabaseIngest.process.importQueueNow(in: idb) }
                }
            }

            if let study {
                _ = state.withLock { $0.retrieving.removeValue(forKey: ObjectIdentifier(study)) }
            }
        }
    }

    // MARK: Retrieved by themselves

    /// Retrieves `studies`, studies of a node, on a thread named `name`.
    func startAutoretrieve(_ studies: [Any], name: String) {
        let handed = Handed(value: studies)
        Task {
            await ActivityThread.run(name: name) { self.autoretrieveNow(handed.value) }
        }
    }

    /// The retrieve of the studies a smart album or the history retrieve by
    /// themselves, on the calling thread.
    func autoretrieveNow(_ studies: [Any]) {
        autoreleasepool {
            state.withLock { $0.autoretrieving = true }
            for case let node as DCMTKQueryNode in studies {
                node.isAutoRetrieve = true
            }
            QueryController.retrieveStudies(studies, showErrors: false, checkForPreviousAutoRetrieve: true)
            state.withLock { $0.autoretrieving = false }
        }
    }
}
