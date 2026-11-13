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

/// A URL import on its thread, and what it found, handed to the completion
/// on the main thread when it ends.
/// @unchecked Sendable: the thread writes the result once, before it asks the
/// main run loop for the completion, which alone reads it afterwards.
private final class URLImportJob: @unchecked Sendable {
    private let operation: URLImportOperation
    private let completion: ([Any]?, String?, Bool) -> Void
    private var files: [Any] = []
    private var report: String?
    private var succeeded = false

    init(operation: URLImportOperation, completion: @escaping ([Any]?, String?, Bool) -> Void) {
        self.operation = operation
        self.completion = completion
    }

    /// The import, on the calling thread; then the completion, which may
    /// answer with an alert, from the main run loop.
    func run() {
        autoreleasepool {
            if let exception = HorosObjCException.caught({
                let result = operation.run()
                files = result.files
                report = result.report
                succeeded = result.succeeded
            }) {
                report = exception.reason
            }
            onMainRunLoop { self.completion(self.files, self.report, self.succeeded) }
        }
    }
}

/// What is dropped on the browser or chosen in its open panel, and the URLs
/// it is given: each path, and each file of a dropped folder, is imported,
/// expanded (ArchiveImport), downloaded (a WADO manifest or a list of URLs)
/// or read as a DICOMDIR, as IsiXDatabase's DroppedItemsPlan decides; the
/// files go to the local database, copied into its data folder or linked
/// where they are (DatabaseCopyRule), through MediaImportJob and so
/// DatabaseIngest. A `.sql` file opens that database instead, and plugin
/// bundles go to the plugin installation.
///
/// The panels and the sheets are the browser's, on the main thread; the
/// downloads and the indexing run on threads of the Activity list
/// (ActivityThread), under the names Activity has always shown.
@MainActor final class DroppedFilesImport {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: Files and folders

    /// Imports files and folders: each dropped path, and each file of a
    /// dropped folder, is imported, expanded, downloaded or read as a
    /// DICOMDIR (DroppedItemsPlan); the files go to the database, copied or
    /// linked as the preferences say, or as `overrides` say for this import
    /// alone (`COPYDATABASE`, `COPYDATABASEMODE`).
    func add(_ paths: [String], overriding overrides: [AnyHashable: Any] = [:]) {
        var files: [String] = []
        let plan = DroppedItemsPlan.actions(forDroppedPaths: paths, isArchive: { ArchiveImportLedger.isArchiveName($0) })
        for action in plan {
            autoreleasepool {
                if let exception = HorosObjCException.caught({ dispatch(action, into: &files) }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController addFilesAndFolderToDatabase:]")
                }
            }
        }

        importFiles(files, options: MediaImportRequest.dropOptions(preferences: preferences).merging(overrides) { _, override in override })
    }

    /// One action of a drop: the files to import are added to `files`.
    private func dispatch(_ action: DroppedAction, into files: inout [String]) {
        switch action.item {
        case .wadoManifest:
            DroppedFilesImport.downloadWADOManifest(URL(fileURLWithPath: action.path))
        case .wadoURLList:
            DroppedFilesImport.startDownload(ofList: action.path)
        case .archive:
            browser.archiveImport.expandIntoIncomingFolder(action.path)
        case .dicomdir:
            let listed = NSMutableArray()
            browser.addDICOMDIR(action.path, listed)
            files.append(contentsOf: listed.compactMap { $0 as? String })
        case .file:
            files.append(action.path)
        case .folder, .ignore:
            break
        }
    }

    /// The sheet's "Add", or files chosen in Finder: a `.sql` file opens that
    /// database and the rest is imported, except the plugin bundles of either
    /// API, which are answered for the plugin installation to install a
    /// version 1 plugin or refuse a former one with its reason.
    func addOrOpen(_ paths: [String]) -> [String] {
        if paths.count == 1 && (paths[0] as NSString).pathExtension.lowercased() == "sql" {
            guard HorosIsDatabaseFile(paths[0]) else {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Cannot Open Database", comment: ""),
                                                message: NSLocalizedString("This file is not a IsiX DICOM Viewer database. It has not been imported or modified.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return []
            }
            guard ForeignDatabaseChoice.confirmOpening(path: paths[0]) else { return [] }
            browser.database = DicomDatabase(atPath: paths[0])
            return []
        }

        let plugins = paths.filter {
            ["isixplugin", "horosplugin", "osirixplugin"].contains(($0 as NSString).pathExtension.lowercased())
        }
        add(paths.filter { !plugins.contains($0) })
        return plugins
    }

    /// The open panel of "Import Files", whose choice goes to
    /// -subSelectFilesAndFoldersToAdd:.
    func chooseFilesAndFolders(_ sender: Any?) {
        let panel = NSOpenPanel()
        browser.window?.makeKeyAndOrderFront(sender)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.begin { [browser] result in
            guard result == .OK else { return }
            for url in panel.urls where SandboxFileAccess.remember(url) == false {
                return
            }
            browser.subSelectFilesAndFolders(toAdd: panel.urls.map { $0.path })
        }
    }

    // MARK: WADO

    /// Downloads the images of a WADO XML manifest (as Weasis writes them).
    /// Called on the XML-RPC connection threads too: it reads the manifest and
    /// hands the download to a thread of its own.
    nonisolated static func downloadWADOManifest(_ url: URL?) {
        let manifest = WADOXML()
        manifest.parseURL(url)
        let urls = manifest.getWADOUrls().compactMap { $0 as? URL }
        ActivityThread.startListed(name: NSLocalizedString("WADO Retrieve...", comment: ""), configure: { thread in
            thread.status = url?.lastPathComponent
        }) {
            WADODownload().WADODownload(urls)
        }
    }

    /// A thread that downloads the URLs of a `.dcmURLs` list, then deletes the list.
    private static func startDownload(ofList list: String) {
        ActivityThread.startListed(name: NSLocalizedString("WADO Retrieve...", comment: ""), configure: { thread in
            thread.status = (list as NSString).lastPathComponent
        }) {
            autoreleasepool { download(list: list) }
        }
    }

    nonisolated private static func download(list: String) {
        var urls: [URL] = []
        let text = try? NSString(contentsOfFile: list, usedEncoding: nil)
        for line in DownloadURLList.lines(of: text as String?) {
            // A line that is not a URL ends the list there, as it always did.
            guard let url = NSURL(string: line) else {
                NSLog("asyncWADODownload: %@ is not a URL; the list ends there", line)
                break
            }
            urls.append(url as URL)
        }
        WADODownload().WADODownload(urls)
        try? FileManager.default.removeItem(atPath: list)
    }

    // MARK: URLs

    /// A URL import, waited for on the calling thread, which must not be the
    /// main thread: the UI and AppleScript use importURLs(_:completion:), so
    /// that neither blocks the event loop. A URLImportOperation waits for the
    /// downloads, follows cancellation, decides by content where each payload
    /// goes, publishes it to the import folder of the database the browser
    /// shows, imports a DICOM object before answering, and composes the result.
    nonisolated static func importURLsWaiting(_ urls: [URL], shownBy browser: BrowserController) -> (files: [Any], report: String?) {
        if Thread.isMainThread {
            return ([], "Use asynchronous URL import on the main thread.")
        }
        let database = DispatchQueue.main.sync { browser.database }
        guard let database else {
            return ([], NSLocalizedString("No database is open", comment: ""))
        }
        let result = URLImportOperation(urls: urls, database: database).run()
        return (result.files, result.report)
    }

    /// Imports URLs on a thread of the Activity list into the database shown
    /// now, which a switch during the import does not change, and calls
    /// `completion` on the main thread with the files, the report and whether
    /// it succeeded. The thread, or nil without a database.
    func importURLs(_ urls: [URL], completion: @escaping ([Any]?, String?, Bool) -> Void) -> Thread? {
        guard let database = browser.database else { return nil }
        let job = URLImportJob(operation: URLImportOperation(urls: urls, database: database), completion: completion)
        var started: Thread?
        ActivityThread.startListed(name: NSLocalizedString("Import URLs", comment: ""), configure: { started = $0 }) {
            job.run()
        }
        return started
    }

    /// The "Add URL" sheet, with the last URL given.
    func showURLSheet() {
        browser.horos_urlString?.stringValue = preferences[ApplicationPreferences.lastURL] ?? ""
        if let sheet = browser.horos_urlWindow {
            browser.window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// The "Add URL" sheet's buttons: tag 1 imports the URL.
    func endURLSheet(_ sender: Any?) {
        let tag = (sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0
        let url = NSURL(string: browser.horos_urlString?.stringValue ?? "")
        if tag == 1 && url == nil {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("URL Error", comment: ""), message: NSLocalizedString("Invalid URL.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        browser.horos_urlWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        if tag == 1, let url {
            preferences.set(browser.horos_urlString?.stringValue, for: ApplicationPreferences.lastURL)
            _ = importURLs([url as URL]) { _, report, succeeded in
                if !succeeded {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("URL Error", comment: ""),
                                                    message: report ?? NSLocalizedString("Nothing was downloaded.", comment: ""),
                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }
        }
    }

    // MARK: Copying into the database

    /// Imports files into the local database, copied into its data folder or
    /// linked where they are, as the "Copy files" preference (or `options`)
    /// says; `COPYDATABASEMODE` may ask. False when the user cancelled.
    @discardableResult
    func importFiles(_ paths: [String], options: [AnyHashable: Any]) -> Bool {
        guard let database = browser.database, database.isLocal(), !paths.isEmpty else { return true }
        var copyEnabled = preferences[DatabasePreferences.copyToDatabase]
        var mode = preferences[DatabasePreferences.copyToDatabaseMode]
        if let value = options["COPYDATABASE"] as? NSNumber { copyEnabled = value.boolValue }
        if let value = options["COPYDATABASEMODE"] as? NSNumber { mode = value.intValue }

        let dataDirectory = database.dataDirPath() ?? ""
        let outside = DatabaseCopyRule.filesOutside(dataDirectory: dataDirectory, in: paths)
        let first = paths.first ?? ""

        var copyFiles: Bool
        switch DatabaseCopyRule.decision(copyEnabled: copyEnabled, mode: mode, hasFilesOutside: !outside.isEmpty, firstPath: first,
                                         isOnCD: { path in NSLog("%@", path); return ArchiveImport.isOnCD(path) }) {
        case .copy:
            copyFiles = true
            if mode == DatabaseCopyRule.notMainDrive { NSLog("not the main drive!") }
        case .link:
            copyFiles = false
        case .askUser:
            switch HorosAlertPanel.runInformational(title: NSLocalizedString("IsiX DICOM Viewer Database", comment: ""),
                                                    message: NSLocalizedString("Should I copy these files in IsiX DICOM Viewer Database folder, or only copy links to these files?", comment: ""),
                                                    defaultButton: NSLocalizedString("Copy Files", comment: ""),
                                                    alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                    otherButton: NSLocalizedString("Copy Links", comment: "")) {
            case HorosAlertPanel.defaultResponse:
                copyFiles = true
            case HorosAlertPanel.otherResponse:
                copyFiles = false
            case HorosAlertPanel.alternateResponse:
                return false
            default:
                copyFiles = true
            }
        }

        let mountedVolume = (options["mountedVolume"] as? NSNumber)?.boolValue ?? false
        if copyFiles {
            FileManager.default.confirmNoIndexDirectory(atPath: database.dataDirPath())
            if (options["async"] as? NSNumber)?.boolValue == true {
                startImportThread(database: database, files: paths, copy: true, mountedVolume: mountedVolume, options: options,
                                  name: mountedVolume ? NSLocalizedString("Copying and indexing files from CD/DVD...", comment: "")
                                                      : NSLocalizedString("Copying and indexing files...", comment: ""))
            } else {
                // A caller that does not ask for `async` may delete its files on
                // return: the copy ends here. What is in the data folder already stays.
                importJob(database: database, files: outside, copy: true, mountedVolume: mountedVolume, options: options).run()
            }
        } else {
            startImportThread(database: database, files: paths, copy: false, mountedVolume: mountedVolume, options: options,
                              name: mountedVolume ? NSLocalizedString("Indexing files from CD/DVD...", comment: "")
                                                  : NSLocalizedString("Indexing files...", comment: ""))
        }
        return true
    }

    /// The import, on a thread of the Activity list: it copies (or not) and
    /// indexes on a private-queue context of its own.
    private func startImportThread(database: DicomDatabase, files: [String], copy: Bool, mountedVolume: Bool,
                                   options: [AnyHashable: Any], name: String) {
        let job = importJob(database: database, files: files, copy: copy, mountedVolume: mountedVolume, options: options)
        let status = BrowserObjC.singularPlural(files.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
        ActivityThread.startUnlisted(name: name, configure: { thread in
            thread.status = status
            thread.supportsCancel = true
        }) { listInActivity in
            listInActivity()
            job.run()
        }
    }

    private func importJob(database: DicomDatabase, files: [String], copy: Bool, mountedVolume: Bool, options: [AnyHashable: Any]) -> MediaImportJob {
        var parameters: [AnyHashable: Any] = ["filesInput": files, "copyFiles": NSNumber(value: copy), "mountedVolume": NSNumber(value: mountedVolume)]
        parameters.merge(options) { _, given in given }
        return MediaImportJob(database: database, request: MediaImportRequest(options: parameters), ingest: DatabaseIngest.process)
    }
}
