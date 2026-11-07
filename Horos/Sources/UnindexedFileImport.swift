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
import IsiXContracts
import IsiXDatabase

/// The database a search and its import work on, handed to their threads.
/// `@unchecked Sendable`: `DicomDatabase` is not Sendable. The threads read
/// its folders, which do not change, and reach its index only through an
/// independent context on that context's queue, and its import lock.
private struct SearchedDatabase: @unchecked Sendable {
    let database: DicomDatabase
}

/// What an import of the files found came to.
private struct UnindexedImportOutcome: Sendable {
    /// The files now in the index.
    let indexed: Int
    /// The files offered: some were indexed, changed, opened or taken away
    /// between the search and the import, and were left alone.
    let offered: Int
}

/// File ▸ Files & Maintenance ▸ Find Unindexed Files…: finds the DICOM files of
/// the data folder of the active local database that its index does not have,
/// says how many, and indexes them where they are once the user agrees.
///
/// The rules (which files are offered, which are left alone and why) are
/// IsiXDatabase's `UnindexedFileRules` and `UnindexedFileSearch`. The search
/// changes nothing and runs on a thread that Activity lists, with its progress
/// and its Cancel button. The import goes through the single entry of the
/// database, with the rebuild's options: the files were already the
/// database's, so they are neither announced nor routed as arrivals. It holds
/// the lock of the incoming import, so that it never indexes a file that pass
/// has just moved in, and checks every file again first.
@MainActor enum UnindexedFileImport {
    /// A search or its import is under way: the command waits for its end.
    private static var running = false

    /// Whether the command can run now: on a local database that can be
    /// written and rebuilt, with no rebuild of the index under way.
    static var isPossible: Bool {
        guard !running, let database = DicomDatabase.activeLocal() else { return false }
        return database.isLocal() && !database.isReadOnly && database.rebuildAllowed() && IndexRebuildsUnderWay.shared.isEmpty
    }

    /// Searches, asks, and imports what the user agreed to.
    static func run() {
        guard isPossible, let database = DicomDatabase.activeLocal() else {
            NSSound.beep()
            return
        }
        running = true
        let searched = SearchedDatabase(database: database)
        let title = NSLocalizedString("Find Unindexed Files", comment: "")
        Task { @MainActor in
            defer { running = false }
            let found = await ActivityThread.run(name: title) { searchFolders(of: searched, on: Thread.current) }
            guard let found, !found.report.cancelled else { return }
            let report = found.report
            guard !report.unindexed.isEmpty else {
                tell(title, NSLocalizedString("Every DICOM file in the database folder is in the database.", comment: "") + leftAlone(report))
                return
            }

            let question = String(format: NSLocalizedString("%ld DICOM file(s) in the database folder are not in the database.", comment: ""), report.unindexed.count)
                + "\n\n" + NSLocalizedString("Import them? They are indexed where they are. As in any import, a file whose image the database already has is deleted, and a file that cannot be read is set aside as the database preferences say.", comment: "")
                + leftAlone(report)
            guard HorosAlertPanel.runInformational(title: title, message: question, defaultButton: NSLocalizedString("Import", comment: ""),
                                                   alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse else { return }

            let files = report.unindexed
            let search = found.search
            let imported = await ActivityThread.run(name: title) { importFiles(files, of: searched, with: search) }
            refreshBrowser(showing: searched.database)
            guard let imported else { return }
            tell(title, String(format: NSLocalizedString("%1$ld of %2$ld files were added to the database.", comment: ""), imported.indexed, imported.offered))
        }
    }

    // MARK: Without asking, for scripts and checks

    /// The files the command would offer now, found on the calling thread.
    static func unindexedFiles() -> [String] {
        guard let database = DicomDatabase.activeLocal() else { return [] }
        return searchFolders(of: SearchedDatabase(database: database), on: Thread.current)?.report.unindexed ?? []
    }

    /// Finds the files and imports them on the calling thread, as the command
    /// does once the user agrees. Returns how many are now in the index.
    static func importUnindexedFiles() -> Int {
        guard isPossible, let database = DicomDatabase.activeLocal() else { return 0 }
        let searched = SearchedDatabase(database: database)
        guard let found = searchFolders(of: searched, on: Thread.current), !found.report.unindexed.isEmpty else { return 0 }
        let imported = importFiles(found.report.unindexed, of: searched, with: found.search)
        refreshBrowser(showing: database)
        return imported?.indexed ?? 0
    }

    // MARK: The search and the import

    /// The search of the data folder of `searched`, with the folders of the
    /// database it never goes into.
    private nonisolated static func definition(of searched: SearchedDatabase) -> UnindexedFileSearch? {
        let database = searched.database
        guard let dataFolder = database.dataDirPath(), !dataFolder.isEmpty else { return nil }
        let skipped = [DatabaseIngest.process.incomingFolderPath(of: database), database.tempDirPath(), database.errorsDirPath(),
                       database.decompressionDirPath(), database.reportsDirPath(), database.roisDirPath()].compactMap { $0 }
        return UnindexedFileSearch(dataFolder: dataFolder, folderSize: Int(BrowserController.defaultFolderSizeForDB()), skippedFolders: skipped)
    }

    /// The complete paths of the files of the index of `searched`, read on an
    /// independent context: the browser's context stays free meanwhile.
    private nonisolated static func indexedPaths(of searched: SearchedDatabase, in search: UnindexedFileSearch) -> Set<String>? {
        guard let worker = searched.database.privateQueueIndependentDatabase() as? DicomDatabase else { return nil }
        var paths: Set<String>?
        worker.performBlockAndWait {
            guard let context = worker.managedObjectContext else { return }
            paths = try? UnindexedFileRules.indexedPaths(in: context, dataFolder: search.dataFolder, folderSize: search.folderSize)
        }
        return paths
    }

    /// Searches the data folder of `searched` on `thread`, which shows its
    /// progress and whose cancelling stops it.
    private nonisolated static func searchFolders(of searched: SearchedDatabase, on thread: Thread) -> (search: UnindexedFileSearch, report: UnindexedFileReport)? {
        guard let search = definition(of: searched) else { return nil }
        thread.status = NSLocalizedString("Scanning database directory...", comment: "")
        guard let indexed = indexedPaths(of: searched, in: search) else { return nil }
        let report = search.search(indexed: indexed, openFiles: OpenFileList.paths(under: search.dataFolder),
                                   isCancelled: { thread.isCancelled },
                                   progress: { done, total in ActivityProgressCount.set(done: done, total: total, setsProgress: true, on: thread) })
        return (search, report)
    }

    /// Indexes the files of `files` that may still be indexed, in place, as
    /// an import that quitting knows of and that the incoming import waits
    /// for. Nil when quitting refused it.
    private nonisolated static func importFiles(_ files: [String], of searched: SearchedDatabase,
                                                with search: UnindexedFileSearch) -> UnindexedImportOutcome? {
        let ingest = DatabaseIngest.process
        return ingest.whileAdmitted {
            let database = searched.database
            let lock = database.importFilesFromIncomingDirLock
            lock?.lock()
            defer { lock?.unlock() }

            guard let before = indexedPaths(of: searched, in: search) else { return UnindexedImportOutcome(indexed: 0, offered: files.count) }
            let still = search.stillUnindexed(files, indexed: before, openFiles: OpenFileList.paths(under: search.dataFolder))
            if !still.isEmpty {
                _ = ingest.indexOnOwnContext(still, preset: .rebuild, of: database) { _, _ in }
            }
            let after = indexedPaths(of: searched, in: search) ?? before
            return UnindexedImportOutcome(indexed: still.filter { after.contains($0) }.count, offered: files.count)
        }
    }

    // MARK: Telling

    /// The lines that say which files were left alone, and why; empty when none was.
    private static func leftAlone(_ report: UnindexedFileReport) -> String {
        var lines: [String] = []
        let busy = report.count(.recentlyChanged) + report.count(.open)
        if busy > 0 {
            lines.append(String(format: NSLocalizedString("%ld file(s) changed in the last few minutes or open in an application were left alone.", comment: ""), busy))
        }
        if report.count(.notDICOM) > 0 {
            lines.append(String(format: NSLocalizedString("%ld file(s) that are not DICOM were left alone.", comment: ""), report.count(.notDICOM)))
        }
        if report.count(.misplaced) > 0 {
            lines.append(String(format: NSLocalizedString("%ld file(s) outside the place where the database would look for them were left alone.", comment: ""), report.count(.misplaced)))
        }
        return lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")
    }

    private static func tell(_ title: String, _ message: String) {
        _ = HorosAlertPanel.runInformational(title: title, message: message, defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil, otherButton: nil)
    }

    /// The browser lists the new studies at once when it shows that database.
    private static func refreshBrowser(showing database: DicomDatabase) {
        guard let browser = DatabaseIngest.process.browser, browser.database === database else { return }
        _ = browser.outlineViewRefresh()
    }
}
