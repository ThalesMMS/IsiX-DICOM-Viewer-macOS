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

/// `keyPath type value`, as predicateWithFormat: builds it from a %@ that
/// may be nil.
nonisolated func comparison(_ keyPath: String, _ type: NSComparisonPredicate.Operator, _ value: Any?,
                            options: NSComparisonPredicate.Options = []) -> NSPredicate {
    return NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: keyPath), rightExpression: NSExpression(forConstantValue: value),
                                 modifier: .direct, type: type, options: options)
}

/// What the study list reads of a row: a study of a database or of a node.
enum StudyListItem {
    static func studyInstanceUID(_ item: Any) -> String? {
        if let study = item as? DicomStudy { return study.studyInstanceUID }
        return (item as? DCMTKStudyQueryNode)?.studyInstanceUID()
    }

    static func patientUID(_ item: Any) -> String? {
        if let study = item as? DicomStudy { return study.patientUID }
        return (item as? DCMTKStudyQueryNode)?.patientUID()
    }

    static func patientID(_ item: Any) -> String? {
        if let study = item as? DicomStudy { return study.patientID }
        return (item as? DCMTKQueryNode)?.patientID()
    }

    static func rawFiles(_ item: Any) -> Int32 {
        if let study = item as? DicomStudy { return study.rawNoFiles()?.int32Value ?? 0 }
        return (item as? DCMTKStudyQueryNode)?.rawNoFiles()?.int32Value ?? 0
    }

    static func files(_ item: Any) -> Int32 {
        if let study = item as? DicomStudy { return study.noFiles()?.int32Value ?? 0 }
        return (item as? DCMTKStudyQueryNode)?.noFiles()?.int32Value ?? 0
    }

    static func isExpanded(_ item: Any) -> Bool {
        if let study = item as? DicomStudy { return study.expanded?.boolValue ?? false }
        return (item as? DCMTKStudyQueryNode)?.expanded()?.boolValue ?? false
    }

    /// The rows sorted by `descriptors`, the first that tells two rows apart
    /// deciding, the order of equal rows kept.
    static func sorted(_ items: [Any], by descriptors: [NSSortDescriptor]) -> [Any] {
        guard !descriptors.isEmpty else { return items }
        return items.enumerated().sorted { a, b in
            for descriptor in descriptors {
                switch descriptor.compare(a.element, to: b.element) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// The counts of the albums table as the database switch and the toolbar
/// still reach them: the number of rows counted, and forgetting them.
final class AlbumCountsAccess: Sendable {
    private let catalog: DatabaseAlbumCatalog

    init(catalog: DatabaseAlbumCatalog) {
        self.catalog = catalog
    }

    /// Whether any row is counted: 0 or 1.
    var count: Int { catalog.hasCounts ? 1 : 0 }

    /// Forgets the counts and the smart albums' distant studies.
    func removeAllObjects() {
        catalog.forgetCounts()
    }
}

/// What the browser's study list shows and how its albums table follows:
/// the list built from the database, the album, the time interval, the
/// modality and the search field, with the studies the PACS On-Demand nodes
/// found and a patient's other studies; the albums table, its counts, its
/// editing and the order and columns of the list for each album; and the
/// periodic refresh. The browser's nib actions, its tables' data source and
/// delegate and the selectors the plugins send forward here.
///
/// It lives on the main actor because it is the state of the window; the
/// albums and their counts are kept by the album catalog, which any thread
/// reads, and the counts are made on a thread of their own.
@MainActor final class StudyListContent {
    private unowned let browser: BrowserController
    private let processGraph: ProcessGraph
    private let preferences: any PreferenceStore

    /// The albums of the database shown, their counts and their rules.
    var catalog: DatabaseAlbumCatalog { browser.albumState.catalog }
    private var scheduler: AlbumCountScheduler<DatabaseAlbumCounter> { browser.albumState.countScheduler }

    /// The album whose order and columns the list shows, and the database it
    /// belongs to (compared only).
    private var shownLayout: AlbumLayoutKey?
    private var shownLayoutDatabase: ObjectIdentifier?

    /// What the status line under the list says of the list, as its last
    /// refresh found it.
    private var listDescription = ""
    /// The colour the nib gave the status line, which it has again once the
    /// notice of an opening is gone.
    private var listDescriptionColor: NSColor?

    init(browser: BrowserController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.browser = browser
        self.processGraph = processGraph
        self.preferences = preferences
    }

    private var database: DicomDatabase? { browser.database }
    private var albumTable: NSTableView? { browser.horos_albumTable }

    // MARK: The albums

    /// The database's albums, from the catalog.
    func albums() -> [DicomAlbum] {
        database.map { CoreDataAlbumStore(database: $0).albums(cachedIn: catalog) } ?? []
    }

    /// The rows of the albums table: "Database" first, then the albums.
    func albumRows() -> [Any] {
        guard let database, database.managedObjectContext != nil else { return [] }
        let all: [String: String] = ["name": NSLocalizedString("Database", comment: "")]
        return [all] + albums()
    }

    /// The album at `row` of the albums table; nil for "Database" and past the albums.
    func album(atRow row: Int) -> DicomAlbum? {
        let rows = albumRows()
        return row >= 0 && row < rows.count ? rows[row] as? DicomAlbum : nil
    }

    /// The album selected in the table, found by name in `d`: the browser's
    /// database on the main thread, a private-queue one of it elsewhere when
    /// `d` is nil. Asked on any thread.
    nonisolated static func currentAlbumID(of browser: BrowserController, in d: DicomDatabase?) -> NSManagedObjectID? {
        let database: DicomDatabase? = d ?? (Thread.isMainThread ? browser.database : browser.database?.privateQueueIndependentDatabase() as? DicomDatabase)
        guard let albumName = browser.selectedAlbumName, let database else { return nil }
        return CoreDataAlbumStore(database: database).albumID(named: albumName)
    }

    /// Selects the album's row, when the table has it.
    func selectAlbumRow(_ album: DicomAlbum) {
        if let index = albumRows().firstIndex(where: { ($0 as AnyObject) === album }) {
            albumTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    /// Selects the albums of that name.
    func selectAlbum(named name: String?) {
        for album in database.map({ CoreDataAlbumStore(database: $0).fetchAlbums() }) ?? [] where BrowserObjC.literallyEqual(album.name, name) {
            selectAlbumRow(album)
        }
    }

    /// Adds the default albums the database lacks.
    func addDefaultAlbums() {
        database?.addDefaultAlbums()
        catalog.forgetAlbums()
        _ = albums()
        refreshAlbums()
    }

    // MARK: Editing the albums

    /// The album name sheet, run modally on the browser: whether it ended with OK.
    private func runAlbumNameSheet() -> Bool {
        guard let sheet = browser.horos_newAlbum else { return false }
        browser.window?.beginSheet(sheet, completionHandler: nil)
        let result = NSApplication.shared.runModal(for: sheet)
        sheet.makeFirstResponder(nil)
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        return result == .stop
    }

    /// Asks for a name and adds an album under it.
    func addAlbum() {
        guard runAlbumNameSheet(), let database else { return }
        CoreDataAlbumStore(database: database).addAlbum(named: browser.horos_newAlbumName?.stringValue ?? "")
        refreshAlbums()
        browser.outlineViewRefresh()
    }

    /// Asks for a smart album's name and filter and adds it.
    func addSmartAlbum() {
        let controller = SmartWindowController(database: database, browserWindow: processGraph.browserWindow)
        guard let sheet = controller.window else { return }
        browser.window?.beginSheet(sheet) { returnCode in
            self.smartAlbumSheetEnded(sheet, returnCode: returnCode.rawValue, album: nil)
            _ = controller
        }
    }

    /// The end of the smart album sheet: `album` is the album edited, nil for a new one.
    func smartAlbumSheetEnded(_ sheet: NSWindow, returnCode: Int, album existing: DicomAlbum?) {
        sheet.orderOut(nil)
        guard returnCode == NSApplication.ModalResponse.stop.rawValue, let database else { return }

        let controller = sheet.windowController as? SmartWindowController
        let album = CoreDataAlbumStore(database: database).saveSmartAlbum(existing, name: controller?.name,
                                                                          predicateFormat: controller?.predicate?.predicateFormat)
        albumTable?.reloadData()
        if let album { selectAlbumRow(album) }
        catalog.forgetAlbums()
        if let album { selectAlbumRow(album) }

        browser.outlineViewRefresh()
        refreshAlbums()
    }

    /// Edits the selected album: the smart album sheet for a smart album, the
    /// name sheet for the others.
    func editSelectedAlbum() {
        guard let row = albumTable?.selectedRow, row > 0, let database, database.isLocal(), let album = album(atRow: row) else { return }

        if album.smartAlbum?.boolValue == true {
            let controller = SmartWindowController(database: database, browserWindow: processGraph.browserWindow)
            guard let sheet = controller.window else { return }
            controller.name = album.name
            controller.predicate = NSPredicate(format: album.predicateString ?? "")
            controller.album = album
            browser.window?.beginSheet(sheet) { returnCode in
                self.smartAlbumSheetEnded(sheet, returnCode: returnCode.rawValue, album: album)
                _ = controller
            }
            return
        }

        browser.horos_newAlbumName?.stringValue = album.name ?? ""
        guard runAlbumNameSheet() else { return }
        guard CoreDataAlbumStore(database: database).rename(album, to: browser.horos_newAlbumName?.stringValue ?? "") else { return }
        // An album that is not listed is not selected.
        if let index = albumRows().firstIndex(where: { ($0 as AnyObject) === album }) {
            albumTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            albumTable?.reloadData()
        }
    }

    /// Deletes the album; asks first unless it is an empty album.
    func remove(_ album: DicomAlbum) {
        let isSmart = album.smartAlbum?.boolValue ?? false
        if DatabaseAlbumCatalog.asksBeforeDeleting(isSmart: isSmart, studyCount: album.studies?.count ?? 0) {
            let message = String(format: NSLocalizedString("Are you sure you want to delete the album named %@?", comment: ""), album.name ?? "(null)")
            guard HorosAlertPanel.runInformational(title: NSLocalizedString("Delete Album", comment: ""), message: message,
                                                   defaultButton: NSLocalizedString("OK", comment: ""),
                                                   alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                   otherButton: nil) == HorosAlertPanel.defaultResponse else { return }
        }
        guard let database else { return }
        CoreDataAlbumStore(database: database).delete(album) {
            catalog.forgetAlbums()
            catalog.forgetCounts()
            albumTable?.reloadData()
        }
        refreshAlbums()
        browser.outlineViewRefresh()
    }

    // MARK: The albums table

    /// The cell of a row of the albums table: the album's icon, its name and
    /// its number of studies, which is counted when the row has none yet.
    func willDisplayAlbumCell(_ cell: PrettyCell?, row: Int) {
        let size = CGFloat(browser.fontSize("dbAlbumFont"))
        cell?.font = row == 0 ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)

        let rows = albumRows()
        let item: Any? = row >= 0 && row < rows.count ? rows[row] : nil
        let isSmart = (item as? DicomAlbum)?.smartAlbum?.boolValue ?? false
        let isLocal = database?.isLocal() ?? false
        if isSmart {
            cell?.image = NSImage(named: isLocal ? "small_smartAlbum.tif" : "small_sharedSmartAlbum.tif")
        } else {
            cell?.image = NSImage(named: isLocal ? "small_album.tif" : "small_sharedAlbum.tif")
        }

        if let album = item as? DicomAlbum {
            cell?.title = album.name ?? ""
        } else if let all = item as? [String: String] {
            cell?.title = all["name"] ?? ""
        } else {
            cell?.title = ""
        }

        let noOfStudies: String
        switch catalog.count(atRow: row) {
        case .unknown:
            refreshAlbums()
            // It will be computed in a separate thread, and then displayed later.
            noOfStudies = "#"
        case .failed:
            noOfStudies = "#"
        case .counted(let count):
            noOfStudies = BrowserController.horos_decimalNumberFormatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: count))) ?? "#"
        }
        cell?.rightText = noOfStudies as NSString
    }

    /// Whether a drop on `row` adds to an album: not to the database, nor to
    /// a smart album.
    func acceptsDrop(onRow row: Int) -> Bool {
        guard row != 0, let album = album(atRow: row) else { return false }
        return !(album.smartAlbum?.boolValue ?? false)
    }

    /// Adds the studies of the dragged rows (studies, series or images) to
    /// the album at `row`.
    func acceptDrop(_ info: any NSDraggingInfo, row: Int) -> Bool {
        guard acceptsDrop(onRow: row), let album = album(atRow: row), let database else { return false }

        // One pasteboard item per dragged row: read them all, not the first.
        let xids = BrowserController.databaseObjectXIDs(on: info.draggingPasteboard) ?? []
        var studies: [DicomStudy] = []
        for case let xid as String in xids {
            switch database.object(withID: NSManagedObject.uid(forXid: xid)) {
            case let study as DicomStudy: studies.append(study)
            case let series as DicomSeries: if let study = series.study { studies.append(study) }
            case let image as DicomImage: if let study = image.series?.study { studies.append(study) }
            default: break
            }
        }

        guard !studies.isEmpty else { return false }
        database.addStudies(studies, to: album)
        _ = database.save()
        refreshAlbums()
        return true
    }

    /// Another album is selected: the list shows it, the search and the time
    /// interval are cleared when `clearsSearch`, a smart album asks the nodes,
    /// and the list takes the album's order and columns.
    func albumSelectionChanged(clearsSearch: Bool) {
        let row = albumTable?.selectedRow ?? -1
        let rows = albumRows()

        browser.selectedAlbumName = nil
        if row >= 0 && row < rows.count {
            browser.selectedAlbumName = (rows[row] as? DicomAlbum)?.name ?? (rows[row] as? [String: String])?["name"]
        }

        if clearsSearch {
            // Clear search field
            browser.searchString = nil

            // Clear the time interval
            if (CustomIntervalPanel.sharedCustomIntervalPanel()?.window?.isVisible ?? false) == false {
                browser.timeIntervalType = 0
            }

            browser.modalityFilter = nil
        } else {
            browser.searchString = browser.searchString
        }

        refreshAlbums()

        // Distant Smart Albums
        if preferences[NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes], row > 0,
           let album = album(atRow: row), album.smartAlbum?.boolValue == true {
            browser.search(forSmartAlbumDistantStudies: album.name)
        }

        // outlineview sortdescriptors
        saveLoadSortDescriptors()
    }

    // MARK: The order and the columns of the list for each album

    /// The album a layout belongs to: the whole database or an album.
    private enum AlbumLayoutKey: Equatable {
        case database
        case album(NSManagedObjectID)
    }

    private func layoutKey(of item: Any?) -> AlbumLayoutKey {
        (item as? DicomAlbum).map { .album($0.objectID) } ?? .database
    }

    /// The file of the layouts, in the database's folder.
    private var layoutFilePath: String? {
        database.map { ($0.dataBaseDirPath as NSString).appendingPathComponent("AlbumSortDescriptors.plist") }
    }

    /// The key of a layout in the file: the album's XID, or "Database".
    private func fileKey(_ key: AlbumLayoutKey) -> String? {
        switch key {
        case .database: return AlbumColumnLayout.databaseKey
        case .album(let objectID): return (database?.object(withID: objectID) as? NSManagedObject)?.xid()
        }
    }

    private func readLayoutFile() -> [String: Any]? {
        guard let path = layoutFilePath, let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Keeps the list's order and columns of the album shown, and shows those
    /// of the album selected when it is another one.
    func saveLoadSortDescriptors() {
        guard browser.horos_databaseOutline != nil else { return }

        let shownDatabase = database.map(ObjectIdentifier.init)
        if shownDatabase != shownLayoutDatabase {
            shownLayout = nil
        }
        shownLayoutDatabase = shownDatabase

        let albums = albumRows()
        if albums.isEmpty { return }

        if let shownLayout {
            saveLayout(for: shownLayout)
        }

        // A selected row past the end of the albums, when the table has not
        // been reloaded since the albums changed, is taken as no selection.
        var selectedAlbum: Any?
        let selection = albumTable?.selectedRow ?? 0
        if selection >= 0 && selection < albums.count {
            selectedAlbum = albums[selection]
            if let shownLayout, layoutKey(of: selectedAlbum) == shownLayout {
                return
            }
        }

        shownLayout = database == nil ? nil : layoutKey(of: selectedAlbum)

        if let shownLayout {
            loadLayout(for: shownLayout)
        }
    }

    /// Stores the list's order and visible columns as the layout of `key`,
    /// dropping the layouts of the albums that are gone.
    private func saveLayout(for key: AlbumLayoutKey) {
        guard database != nil, let path = layoutFilePath, let fileKey = fileKey(key) else { return }
        let outline = browser.horos_databaseOutline

        var data: Data?
        do {
            let descriptors: [NSSortDescriptor]? = outline?.sortDescriptors
            data = try descriptors.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        } catch {
            NSLog("Unable to save album sort descriptors: %@", (error as NSError).localizedDescription)
            return
        }
        if let data, RestrictedUnarchiver.sortDescriptors(with: data) == nil { return }

        let columns = (outline?.tableColumns ?? []).filter { !$0.isHidden }
            .map { AlbumColumnLayout.Column(identifier: $0.identifier.rawValue, width: Int($0.width)) }
        let living = Set(albumRows().compactMap { ($0 as? DicomAlbum)?.xid() })
        let file = AlbumColumnLayout.file(readLayoutFile() ?? [:], storing: AlbumColumnLayout(sortDescriptors: data, columns: columns),
                                          under: fileKey, living: living)
        if let written = try? PropertyListSerialization.data(fromPropertyList: file, format: .xml, options: 0) {
            try? written.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Shows the list in the order and with the columns of the album, unless
    /// Command is held.
    func loadLayout(of album: Any?) {
        guard album != nil else { return }
        loadLayout(for: layoutKey(of: album))
    }

    private func loadLayout(for key: AlbumLayoutKey) {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
            return
        }
        guard database != nil, let fileKey = fileKey(key), let layout = AlbumColumnLayout(propertyList: readLayoutFile()?[fileKey]) else { return }

        let outline = browser.horos_databaseOutline
        // The plist is in the database folder, which may come from another
        // computer: the descriptors are decoded securely, as an array of
        // NSSortDescriptors on plain keys with a known comparison, and
        // anything else sorts by name, the default.
        outline?.sortDescriptors = RestrictedUnarchiver.sortDescriptors(with: layout.sortDescriptors)
            ?? [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]

        let tableColumns = outline?.tableColumns ?? []
        let placement = layout.placement(of: tableColumns.map(\.identifier.rawValue))
        for (index, shown) in placement.shown.enumerated() {
            guard let column = tableColumns.first(where: { $0.identifier.rawValue == shown.identifier }) else { continue }
            if outline?.column(withIdentifier: column.identifier) == -1 {
                outline?.addTableColumn(column)
            }
            column.isHidden = false
            column.width = CGFloat(shown.width)
            outline?.moveColumn(outline?.column(withIdentifier: column.identifier) ?? 0, toColumn: index)
        }
        for identifier in placement.hidden {
            tableColumns.first { $0.identifier.rawValue == identifier }?.isHidden = true
        }
    }

    // MARK: The counts of the albums

    /// Counts the studies of the albums again, on a thread, unless a count
    /// is running already (then in 20 seconds) or the server mode hides the
    /// window.
    func refreshAlbums() {
        guard let database else { return }
        // Server Mode: dont refresh albums
        guard !preferences[NetworkPreferences.hidesListenerErrors] || browser.window?.isVisible == true else { return }

        let counter = DatabaseAlbumCounter(database: database, browser: browser, catalog: catalog, preferences: preferences,
                                           search: processGraph.pacsOnDemand, retrieves: browser.comparativeState.retrieves)
        let catalog = self.catalog, scheduler = self.scheduler
        Task {
            await scheduler.request(counter,
                                    progress: { counts in
                                        catalog.updateCounts(counts)
                                        Task { @MainActor in self.albumTable?.reloadData() }
                                    },
                                    deliver: { counts in
                                        catalog.setCounts(counts)
                                        await self.reloadAlbumTable()
                                    },
                                    again: { await self.refreshAlbums() })
        }
    }

    private func reloadAlbumTable() {
        albumTable?.reloadData()
    }

    // MARK: The list

    /// Shows, under a filtered album, how many studies the search finds in
    /// the whole database or on the nodes when that is more than the list.
    func showEntireDatabaseResult(displayed: Int) {
        let shown = EntireDatabaseResult.shownCount(distant: browser.horos_distantEntireDBResultCount,
                                                    local: browser.horos_localEntireDBResultCount,
                                                    displayed: displayed)
        if let shown {
            browser.horos_searchInEntireDBResult?.title = BrowserObjC.singularPlural(Int(shown),
                NSLocalizedString("result in entire DB", comment: "Try to keep this string **short**"),
                NSLocalizedString("results in entire DB", comment: "Try to keep this string **short**"))
            browser.horos_searchInEntireDBResult?.isHidden = false
        } else {
            browser.horos_searchInEntireDBResult?.isHidden = true
        }
    }

    /// Builds the 'root' array of the outline: the studies of the album, the
    /// time interval, the modality and the search, with the distant studies
    /// found for them, sorted, a patient's other studies with each when
    /// asked, and the timeline events. Reselects what was selected and says
    /// what the list shows. Answers the exception that emptied the list.
    ///
    /// With hideListenerError, the server mode, the list of a hidden browser
    /// window is not rebuilt for every change of the database; an order to
    /// select a study rebuilds it `whileHidden`.
    func refresh(whileHidden: Bool) -> String? {
        catalog.forgetAlbums()

        guard let databaseOutline = browser.horos_databaseOutline else { return nil }
        if !BrowserController.horos_loadingIsOver { return nil }
        if !whileHidden && preferences[NetworkPreferences.hidesListenerErrors] {
            if browser.window?.isVisible != true { return nil }
        }

        let database = self.database
        var description = ""
        var exception: String?

        var previousObjects: [Any] = []
        for index in databaseOutline.selectedRowIndexes {
            if let item = databaseOutline.item(atRow: index) {
                previousObjects.append(item)
            }
        }

        if let sourcesTableView = browser.horos_sourcesTableView, sourcesTableView.selectedRow >= 0,
           let bs = browser.sourceIdentifier(atRow: Int32(truncatingIfNeeded: sourcesTableView.selectedRow)) {
            description += String(format: NSLocalizedString("%@: %@ / ", comment: ""),
                                  database?.isLocal() == true ? NSLocalizedString("Local Database", comment: "") : NSLocalizedString("Remote Database", comment: ""),
                                  bs.description)
        }

        // ALBUMS
        var smartAlbumName: String?
        var albumContent: [Any]?
        let selectedAlbumRow = albumTable?.selectedRow ?? 0
        if selectedAlbumRow > 0 {
            if let album = album(atRow: selectedAlbumRow) {
                if album.smartAlbum?.boolValue ?? false {
                    smartAlbumName = album.name
                    albumContent = database?.objects(forEntity: database?.studyEntity(), predicate: CoreDataAlbumStore.filterPredicate(of: album)) ?? []
                    description += String(format: NSLocalizedString("Smart Album selected: %@", comment: ""), smartAlbumName ?? "(null)")
                } else {
                    albumContent = (album.studies ?? []).map { $0 as Any }
                    description += String(format: NSLocalizedString("Album selected: %@", comment: ""), album.name ?? "(null)")
                }
            }
        } else {
            description += NSLocalizedString("No album selected", comment: "")
        }

        // TIME INTERVAL, MODALITY FILTER, SEARCH FIELD
        let timeIntervalStart = browser.horos_timeIntervalStart, timeIntervalEnd = browser.horos_timeIntervalEnd
        if timeIntervalStart != nil || timeIntervalEnd != nil {
            let formatter = UserDefaults.dateTimeFormatter()
            if let start = timeIntervalStart, let end = timeIntervalEnd {
                description += String(format: NSLocalizedString(" / Time Interval: from: %@ to: %@", comment: ""),
                                      formatter?.string(from: start) ?? "(null)", formatter?.string(from: end) ?? "(null)")
            } else {
                description += String(format: NSLocalizedString(" / Time Interval: since: %@", comment: ""),
                                      timeIntervalStart.flatMap { formatter?.string(from: $0) } ?? "(null)")
            }
        }
        let modality = browser.horos_modalityFilterForQueries
        if let modality {
            description += String(format: NSLocalizedString(" / Modality: %@", comment: ""), modality)
        }
        let filterPredicate = browser.filterPredicate
        if filterPredicate != nil {
            description += browser.filterPredicateDescription ?? ""
        }
        let made = StudyListPredicate.make(start: timeIntervalStart, end: timeIntervalEnd, modality: modality,
                                           filter: filterPredicate, test: browser.testPredicate)
        let predicate = made.predicate
        var filtered = made.filtered

        browser.horos_outlineViewArray = nil
        var list: [Any]?
        if let raised = HorosObjCException.caught({
            if let raised = HorosObjCException.caught({ list = self.matchingStudies(albumContent, predicate: predicate, filter: filterPredicate) }) {
                list = []
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
            }

            // Smart Album Distant Studies, if available
            if let merged = self.mergingDistantStudies(into: list ?? [], predicate: predicate, smartAlbum: smartAlbumName,
                                                       filtered: filtered, hasFilter: filterPredicate != nil) {
                list = merged
            }

            let row = albumTable?.selectedRow ?? 0
            if !filtered, catalog.setCount(list?.count ?? 0, atRow: row) {
                albumTable?.reloadData()
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
            list = []
            exception = raised.description
        }

        if (albumTable?.selectedRow ?? 0) > 0 { filtered = true }

        let sortDescriptors = StudyListOrder.descriptors(databaseOutline.sortDescriptors)

        let count = list?.count ?? 0
        if filtered && preferences[DatabasePreferences.keepStudiesOfSamePatientTogether] && count > 0 && count < 500 {
            if let raised = HorosObjCException.caught({
                if preferences[DatabasePreferences.keepStudiesOfSamePatientTogetherAndGrouped] {
                    let sorted = StudyListItem.sorted(list ?? [], by: sortDescriptors)
                    list = groupedByPatient(sorted, in: database)
                    browser.horos_setOriginalOutlineViewArray(sorted)
                } else {
                    let patientPredicates = (list ?? []).map {
                        comparison("patientUID", .beginsWith, StudyListItem.patientUID($0), options: [.caseInsensitive, .diacriticInsensitive])
                    }
                    let patientPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: patientPredicates)
                    browser.horos_setOriginalOutlineViewArray(list)
                    list = (database?.objects(forEntity: database?.studyEntity(), predicate: patientPredicate))
                        .map { StudyListItem.sorted($0, by: sortDescriptors) }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
            }
        } else {
            browser.horos_setOriginalOutlineViewArray(nil)
            list = list.map { StudyListItem.sorted($0, by: sortDescriptors) }
        }

        let timelineEvents = browser.surgicalProcedureTimelineEvents() as? [[String: Any]] ?? []
        let listedStudies = SurgicalProcedureOutline.studies(list ?? [], hidingReportsOf: timelineEvents)

        var images: Int = 0
        for obj in listedStudies {
            images += Int(StudyListItem.files(obj))
        }

        let formatter = BrowserController.horos_decimalNumberFormatter
        description += String(format: NSLocalizedString(" / Result = %@ studies (%@ images)", comment: ""),
                              formatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: listedStudies.count))) ?? "(null)",
                              formatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: images))) ?? "(null)")

        if !timelineEvents.isEmpty {
            list = SurgicalProcedureOutline.array(insertingEvents: timelineEvents, intoStudies: listedStudies)
        }

        browser.horos_storeOutlineViewArray(list)
        let shown = list ?? []

        databaseOutline.reloadData()
        browser.horos_comparativeTable?.reloadData()

        if let raised = HorosObjCException.caught({
            for obj in shown where StudyListItem.isExpanded(obj) {
                databaseOutline.expandItem(obj)
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
        }

        if !previousObjects.isEmpty {
            // The selected rows are found again by what they are, not by object
            // identity: refreshing a remote index replaces the objects, and
            // -rowForItem: then answers -1, which as an index is NSUIntegerMax. The
            // selection was lost on every refresh and the first patient took its
            // place. A row that really is gone is simply not selected.
            var currentItems: [Any] = []
            for row in 0..<max(databaseOutline.numberOfRows, 0) {
                currentItems.append(databaseOutline.item(atRow: row) ?? NSNull())
            }
            let rows = OutlineSelectionRestore.rows(matching: OutlineSelectionRestore.identifiers(for: previousObjects), in: currentItems)
            if !rows.isEmpty {
                databaseOutline.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        if !shown.isEmpty {
            browser.announceListSelection()
        }

        if database?.incomingImportWaitingForSpace == true {
            description = NSLocalizedString("IMPORT PAUSED: free space or reconnect storage; incoming files are preserved. / ", comment: "") + description
        }

        // A refused file is the reason a study arrives with images missing, and it
        // used to be said in the log only - which is where "rejected with no visible
        // error" comes from. The whole sentence is in the tooltip.
        if let summary = database?.lastImportRefusalSummary, !summary.isEmpty {
            description = NSLocalizedString("LAST IMPORT: ", comment: "") + summary + " / " + description
        }
        listDescription = description
        showDescription()

        return exception
    }

    /// Writes the status line under the list: the notice of a study that is
    /// opening and waits for a node, then what the last refresh said of the
    /// list. The opening calls this when its notice comes or goes, so that it
    /// shows at once and does not wait for a refresh, nor is lost to one.
    /// The line is dim; with a notice it takes the colour of the labels, so
    /// that the answer to a double click is not missed.
    func showDescription() {
        let notice = browser.viewerOpener.openingNotice
        let description = (notice ?? "") + listDescription
        guard let line = browser.horos_databaseDescription else { return }
        line.toolTip = description
        line.stringValue = description
        if listDescriptionColor == nil { listDescriptionColor = line.textColor }
        line.textColor = notice == nil ? listDescriptionColor : .labelColor
    }

    /// The studies of the album, or of the whole database, the list's
    /// predicate keeps, with those of the other databases the search finds.
    /// Under an album, a search also counts what it finds in the whole database.
    private func matchingStudies(_ albumContent: [Any]?, predicate: NSPredicate, filter filterPredicate: NSPredicate?) -> [Any]? {
        let database = self.database
        browser.horos_searchInEntireDBResult?.isHidden = true

        var list: [Any]?
        if let albumContent {
            list = albumContent.filter { predicate.evaluate(with: $0) }

            if let filterPredicate {
                // Entire DB Result
                browser.horos_distantEntireDBResultCount = 0
                var all: [Any]?
                do {
                    all = try database?.objects(forEntity: database?.studyEntity(), predicate: nil, error: ())
                } catch {
                    NSLog("**** executeFetchRequest: %@", error as NSError)
                }
                browser.horos_localEntireDBResultCount = Int32(truncatingIfNeeded: all.map { $0.filter { filterPredicate.evaluate(with: $0) }.count } ?? 0)
                showEntireDatabaseResult(displayed: list?.count ?? 0)
            }
        } else {
            do {
                let all = try database?.objects(forEntity: database?.studyEntity(), predicate: nil, error: ())
                list = all.map { $0.filter { predicate.evaluate(with: $0) } }
            } catch {
                NSLog("**** executeFetchRequest: %@", error as NSError)
                list = nil
            }
        }

        guard let filterPredicate, let local = list else { return list }
        let federated = BrowserController.federatedStudies(matching: filterPredicate, excludingDatabasePath: database?.baseDirPath,
                                                           applyingUser: nil) ?? []
        guard !federated.isEmpty else { return list }
        let localKeys: [String?] = local.map { study in
            FederatedSearch.identityKey(patientUID: StudyListItem.patientUID(study), studyUID: StudyListItem.studyInstanceUID(study),
                                        originPath: database?.baseDirPath)
        }
        let federatedKeys: [String?] = federated.map { study in
            let origin = (study as? NSManagedObject).flatMap { $0.managedObjectContext }.flatMap { DicomDatabase(for: $0) }
            return FederatedSearch.identityKey(patientUID: StudyListItem.patientUID(study), studyUID: StudyListItem.studyInstanceUID(study),
                                               originPath: origin?.baseDirPath)
        }
        return local + DistantStudyMerge.federated(localKeys: localKeys, federatedKeys: federatedKeys).map { federated[$0] }
    }

    /// The list with the studies the PACS On-Demand nodes found for the
    /// smart album or the search shown merged in, the retrieves the merge
    /// chose started; nil when the distant studies are not for this list.
    private func mergingDistantStudies(into local: [Any], predicate: NSPredicate, smartAlbum smartAlbumName: String?,
                                       filtered: Bool, hasFilter: Bool) -> [Any]? {
        let distantSummaries = processGraph.pacsOnDemand.listStudies.studies
        let useDistantArray = DistantStudiesInList.apply(
            hasDistantStudies: distantSummaries != nil, smartAlbum: smartAlbumName, distantAlbum: browser.smartAlbumDistantName,
            start: browser.horos_timeIntervalStart, end: browser.horos_timeIntervalEnd,
            distantStart: browser.distantTimeIntervalStart, distantEnd: browser.distantTimeIntervalEnd,
            hasFilter: hasFilter, searchType: browser.horos_searchType, distantSearchType: browser.distantSearchType,
            searchString: browser.horos_searchString, distantSearchString: browser.distantSearchString)
        guard useDistantArray, let distantSummaries else { return nil }

        let distant = QueryControllerDistantStudies.nodes(of: distantSummaries).filter { predicate.evaluate(with: $0) }
        let summaries = QueryControllerDistantStudies.summaries(of: distant)

        // Merge local and distant studies; autoretrieve?
        let retrieves = browser.comparativeState.retrieves
        var autoretrieve = false
        if !retrieves.isAutoretrieving {
            autoretrieve = DatabaseAlbumCatalog.retrievesAutomatically(preferences[WebPortalPreferences.smartAlbumStudiesDICOMNodes], album: smartAlbumName)
        }

        let merge = DistantStudyMerge.list(
            localUIDs: local.map(StudyListItem.studyInstanceUID), distantUIDs: distant.map(StudyListItem.studyInstanceUID),
            preferMoreImages: preferences[WebPortalPreferences.prefersStudyWithMoreImages],
            autoretrieve: autoretrieve,
            retrievePartial: preferences[NetworkPreferences.automaticallyRetrievePartialStudies],
            inRetrieveQueue: { retrieves.isRetrieving(studyInstanceUID: StudyListItem.studyInstanceUID(distant[$0])) },
            localRawFiles: { StudyListItem.rawFiles(local[$0]) },
            distantRawFiles: { StudyListItem.rawFiles(distant[$0]) },
            distantFiles: { StudyListItem.files(distant[$0]) })

        var list = local
        for replacement in merge.replaced {
            list[replacement.row] = distant[replacement.distant]
        }

        // filtered == NO, we want only if ALL studies are displayed (not limited by Search String or Time Interval, for example
        if let smartAlbumName, !filtered, BrowserObjC.literallyEqual(browser.smartAlbumDistantName, smartAlbumName) {
            catalog.setDistantStudies(merge.added.map { summaries[$0] }, of: smartAlbumName)
        }

        let studyToAutoretrieve = merge.retrieved.map { distant[$0] }
        if !retrieves.isAutoretrieving && !studyToAutoretrieve.isEmpty {
            retrieves.startAutoretrieve(studyToAutoretrieve, name: NSLocalizedString("Auto-Retrieving...", comment: ""))
        }

        return list + merge.added.map { distant[$0] }
    }

    /// Each study of `sorted` followed by the other studies of its patient
    /// the list does not have, the latest first, within the related studies
    /// limit.
    private func groupedByPatient(_ sorted: [Any], in database: DicomDatabase?) -> [Any] {
        let limit = (preferences as? UserDefaults).map(AssociationContract.relatedStudiesLimit(in:)) ?? AssociationContract.defaultRelatedStudiesLimit
        var relatedStudies: [Int: [Any]] = [:]
        let rows = StudyListOrder.groupedByPatient(uids: sorted.map(StudyListItem.studyInstanceUID), limit: limit) { index in
            var found: [Any]?
            if HorosObjCException.caught({
                let obj = sorted[index]
                let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    comparison("patientID", .equalTo, StudyListItem.patientID(obj)),
                    comparison("studyInstanceUID", .notEqualTo, StudyListItem.studyInstanceUID(obj))])
                let all = database?.objects(forEntity: database?.studyEntity(), predicate: predicate) ?? []
                found = StudyListItem.sorted(all, by: [NSSortDescriptor(key: "date", ascending: false)])
            }) != nil {
                // object has become unavailable, who cares, we just won't be showing it anymore
                return nil
            }
            relatedStudies[index] = found
            return found?.map(StudyListItem.studyInstanceUID)
        }
        return rows.compactMap { row in
            switch row {
            case .study(let index): return sorted[index]
            case .related(let index, let other): return relatedStudies[index]?[other]
            }
        }
    }

    // MARK: The periodic refresh

    /// The periodic refresh: a smart album's list and the albums' counts, the
    /// rest only redrawn (for filters depending on time), and the open query
    /// window. Nothing while the session is inactive, a process runs, or the
    /// list is being edited.
    func refreshDatabase() {
        if processGraph.isSessionInactive || BrowserController.horos_waitForRunningProcess { return }
        if database == nil { return }
        if browser.horos_DatabaseIsEdited { return }
        if let outline = browser.horos_databaseOutline, outline.editedRow != -1 { return }

        let rows = albumRows()
        let selectedRow = albumTable?.selectedRow ?? 0
        if selectedRow < 0 || selectedRow >= rows.count { return }

        if (rows[selectedRow] as? DicomAlbum)?.smartAlbum?.boolValue ?? false {
            if let raised = HorosObjCException.caught({
                _ = self.refresh(whileHidden: false)
                self.refreshAlbums()
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController refreshDatabase:]")
            }
        } else {
            //For filters depending on time....
            refreshAlbums()
            browser.horos_databaseOutline?.reloadData()
            browser.horos_comparativeTable?.reloadData()
        }

        if let query = QueryController.current() {
            query.refresh(browser)
        } else if let query = QueryController.currentAuto() {
            query.refresh(browser)
        }
    }
}
