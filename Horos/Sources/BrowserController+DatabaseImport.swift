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

// Adding files to the browser's database: files and folders dropped or
// chosen, ZIP archives, WADO manifests and URL lists, DICOMDIRs, URLs, and
// copying files into the database folder or linking them. What is done with
// each dropped path, the copy-or-link decision and the extensions are
// IsiXDatabase's DroppedItemsPlan, DatabaseCopyRule and DataFileExtension;
// the files, the threads and the panels are here. The deprecated entry
// points are kept with their selectors for the callers that still use them.

/// The URL import handed to its thread, with what to call on the main thread
/// when it ends.
private final class URLImportJob: NSObject, @unchecked Sendable {
    let operation: URLImportOperation
    let completion: ([Any]?, String?, Bool) -> Void

    init(operation: URLImportOperation, completion: @escaping ([Any]?, String?, Bool) -> Void) {
        self.operation = operation
        self.completion = completion
    }
}

/// The password sheet of an archive and the thread waiting for its answer.
private final class ArchivePasswordRequest: @unchecked Sendable {
    let response = NSCondition()
    let thread: Thread
    var password: String?
    var answered = false
    /// The sheet while it is shown. Main thread only.
    var pendingAlert: NSAlert?

    init(thread: Thread) {
        self.thread = thread
    }

    func answer(_ password: String?) {
        response.lock()
        self.password = password
        answered = true
        response.signal()
        response.unlock()
    }
}

extension BrowserController {

    // MARK: Deprecated entry points

    @available(*, deprecated)
    @discardableResult
    @objc(getNewFileDatabasePath:)
    func getNewFileDatabasePath(_ extension: String!) -> String! {
        return self.database?.uniquePathForNewDataFile(withExtension: `extension`)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(getNewFileDatabasePath:dbFolder:)
    func getNewFileDatabasePath(_ extension: String!, dbFolder: String!) -> String! {
        return DicomDatabase(atPath: dbFolder)?.uniquePathForNewDataFile(withExtension: `extension`)
    }

    /// The deprecated additions to the browser's database, which ran on the
    /// main thread.
    @available(*, deprecated)
    private func deprecatedAdd(_ files: [Any]!, notify: Bool, dicomOnly: Bool, reread: Bool) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("********* We should be on MAIN thread for accessing objects from _database object")
        }
        return self.database?.objects(withIDs: self.database?.addFiles(atPaths: files, postNotifications: notify, dicomOnly: dicomOnly, rereadExistingItems: reread))
    }

    @available(*, deprecated)
    @discardableResult
    @objc(addFilesToDatabase:)
    func addFilesToDatabase(_ newFilesArray: [Any]!) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        if !Thread.isMainThread {
            BrowserObjC.logStackTrace("********* We should be on MAIN thread for accessing objects from _database object")
        }
        return self.database?.objects(withIDs: self.database?.addFiles(atPaths: newFilesArray))
    }

    @available(*, deprecated)
    @discardableResult
    @objc(addFilesToDatabase::)
    func addFilesToDatabase(_ newFilesArray: [Any]!, _ onlyDICOM: Bool) -> [Any]! {
        return deprecatedAdd(newFilesArray, notify: true, dicomOnly: onlyDICOM, reread: false)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(addFilesToDatabase:onlyDICOM:produceAddedFiles:)
    func addFilesToDatabase(_ newFilesArray: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool) -> [Any]! {
        return deprecatedAdd(newFilesArray, notify: produceAddedFiles, dicomOnly: onlyDICOM, reread: false)
    }

    @available(*, deprecated)
    @discardableResult
    @objc(addFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:)
    func addFilesToDatabase(_ newFilesArray: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool, parseExistingObject: Bool) -> [Any]! {
        return deprecatedAdd(newFilesArray, notify: produceAddedFiles, dicomOnly: onlyDICOM, reread: parseExistingObject)
    }

    /// "safeRebuild" was already ignored before the DicomDatabase transition.
    @available(*, deprecated)
    @discardableResult
    @objc(addFilesToDatabase:onlyDICOM:safeRebuild:produceAddedFiles:)
    func addFilesToDatabase(_ newFilesArray: [Any]!, onlyDICOM: Bool, safeRebuild: Bool, produceAddedFiles: Bool) -> [Any]! {
        return deprecatedAdd(newFilesArray, notify: produceAddedFiles, dicomOnly: onlyDICOM, reread: false)
    }

    /// The database of a context or a folder, else the browser's.
    @available(*, deprecated)
    private func deprecatedDatabase(context: NSManagedObjectContext?, folder: String?) -> DicomDatabase? {
        var database = context.flatMap { DicomDatabase(for: $0) }
        if database == nil, let folder { database = DicomDatabase(atPath: folder) }
        return database ?? self.database
    }

    @available(*, deprecated)
    @objc(addFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:context:dbFolder:)
    func addFilesToDatabase(_ newFilesArray: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool, parseExistingObject: Bool,
                            context: NSManagedObjectContext!, dbFolder: String!) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        let database = deprecatedDatabase(context: context, folder: dbFolder)
        return database?.objects(withIDs: database?.addFiles(atPaths: newFilesArray, postNotifications: produceAddedFiles,
                                                             dicomOnly: onlyDICOM, rereadExistingItems: parseExistingObject))
    }

    @available(*, deprecated)
    @objc(subAddFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:context:dbFolder:)
    func subAddFilesToDatabase(_ newFilesArray: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool, parseExistingObject: Bool,
                               context: NSManagedObjectContext!, dbFolder: String!) -> [Any]! {
        return addFilesToDatabase(newFilesArray, onlyDICOM: onlyDICOM, produceAddedFiles: produceAddedFiles,
                                  parseExistingObject: parseExistingObject, context: context, dbFolder: dbFolder)
    }

    @available(*, deprecated)
    @objc(checkForExistingReport:dbFolder:)
    func checkForExistingReport(_ study: NSManagedObject!, dbFolder: String!) {
        BrowserObjC.logStackTrace("****** deprecated function")
        DicomDatabase(for: study.managedObjectContext)?.checkForExistingReport(forStudy: study)
    }

    /// The database the deprecated class methods were meant for: of the
    /// context, of the browser, of the folder, or a new one on them.
    @available(*, deprecated)
    private class func deprecatedDatabase(context: NSManagedObjectContext?, browser: BrowserController?, folder: String?) -> DicomDatabase? {
        var database = context.flatMap { DicomDatabase(for: $0) }
        if database == nil, let browser { database = browser.database }
        if database == nil, let folder { database = DicomDatabase(atPath: folder) }
        if database == nil && (context != nil || folder != nil) {
            database = DicomDatabase(path: folder, context: context)
        }
        if database == nil {
            BrowserObjC.logError("couldn't identify database", "+[BrowserController addFiles:toContext:...]")
        }
        return database
    }

    @available(*, deprecated)
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:)
    class func addFiles(_ newFilesArray: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browserController: BrowserController!,
                        onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        let database = deprecatedDatabase(context: context, browser: browserController, folder: dbFolder)
        return database?.objects(withIDs: database?.addFiles(atPaths: newFilesArray, postNotifications: notifyAddedFiles,
                                                             dicomOnly: onlyDICOM, rereadExistingItems: parseExistingObject))
    }

    @available(*, deprecated)
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:)
    class func addFiles(_ newFilesArray: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browserController: BrowserController!,
                        onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!, generatedByOsiriX: Bool) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        let database = deprecatedDatabase(context: context, browser: browserController, folder: dbFolder)
        return database?.objects(withIDs: database?.addFiles(atPaths: newFilesArray, postNotifications: notifyAddedFiles, dicomOnly: onlyDICOM,
                                                             rereadExistingItems: parseExistingObject, generatedByOsiriX: generatedByOsiriX))
    }

    @available(*, deprecated)
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:mountedVolume:)
    class func addFiles(_ newFilesArray: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browserController: BrowserController!,
                        onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!, generatedByOsiriX: Bool,
                        mountedVolume: Bool) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        let database = deprecatedDatabase(context: context, browser: browserController, folder: dbFolder)
        return database?.objects(withIDs: database?.addFiles(atPaths: newFilesArray, postNotifications: notifyAddedFiles, dicomOnly: onlyDICOM,
                                                             rereadExistingItems: parseExistingObject, generatedByOsiriX: generatedByOsiriX))
    }

    @available(*, deprecated)
    @objc(addFiles:toContext:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:)
    class func addFiles(_ newFilesArray: [Any]!, toContext context: NSManagedObjectContext!, onlyDICOM: Bool, notifyAddedFiles: Bool,
                        parseExistingObject: Bool, dbFolder: String!) -> [Any]! {
        BrowserObjC.logStackTrace("****** deprecated function")
        let database = deprecatedDatabase(context: context, browser: nil, folder: dbFolder)
        return database?.objects(withIDs: database?.addFiles(atPaths: newFilesArray, postNotifications: notifyAddedFiles,
                                                             dicomOnly: onlyDICOM, rereadExistingItems: parseExistingObject))
    }

    /// Rebuilds the thumbnails of the viewers that are shown and not being
    /// dragged in.
    @objc(rebuildViewers:)
    func rebuildViewers(_ vlToRebuild: NSMutableArray!) {
        for case let viewer as ViewerController in vlToRebuild ?? [] {
            if viewer.windowWillClose() == false && viewer.window?.isVisible == true && (viewer.imageView()?.mouseDragging ?? false) == false {
                viewer.buildMatrixPreview(false)
            }
        }
    }

    // MARK: WADO

    /// Downloads the images of a WADO XML manifest (as Weasis writes them).
    /// Called on the XML-RPC connection threads too: it reads the manifest and
    /// hands the download to a thread of its own.
    @objc(asyncWADOXMLDownloadURL:)
    nonisolated class func asyncWADOXMLDownloadURL(_ url: URL!) {
        let manifest = WADOXML()
        manifest.parseURL(url)
        let thread = Thread(target: WADODownload(), selector: #selector(WADODownload.WADODownload(_:)), object: manifest.getWADOUrls())
        thread.name = NSLocalizedString("WADO Retrieve...", comment: "")
        thread.supportsCancel = true
        thread.status = url?.lastPathComponent
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    /// Downloads the URLs of a `.dcmURLs` list, then deletes the list.
    @objc(asyncWADODownload:)
    nonisolated func asyncWADODownload(_ filename: String!) {
        autoreleasepool {
            let urls = NSMutableArray()
            let text = try? NSString(contentsOfFile: filename, usedEncoding: nil)
            for line in DownloadURLList.lines(of: text as String?) {
                // A line that is not a URL ends the list there, as it always did.
                guard let url = NSURL(string: line) else {
                    NSLog("asyncWADODownload: %@ is not a URL; the list ends there", line)
                    break
                }
                urls.add(url)
            }
            WADODownload().WADODownload((urls as? [Any]) ?? [])
            try? FileManager.default.removeItem(atPath: filename)
        }
    }

    /// A thread that downloads a `.dcmURLs` list.
    private func startWADODownload(ofList list: String) {
        let thread = Thread(target: self, selector: #selector(asyncWADODownload(_:)), object: list)
        thread.name = NSLocalizedString("WADO Retrieve...", comment: "")
        thread.supportsCancel = true
        thread.status = (list as NSString).lastPathComponent
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    // MARK: Archives

    /// Expands a ZIP archive into the import folder of the database shown
    /// now, captured before the browser can switch databases. The Activity
    /// task owns the extraction and publishes only a complete folder.
    @objc(expandArchiveIntoIncomingFolder:)
    func expandArchiveIntoIncomingFolder(_ archive: String!) {
        guard let archive, let database = self.database else { return }
        let parameters: NSDictionary = ["archive": (archive as NSString).copy(), "database": database]
        let thread = Thread(target: self, selector: #selector(expandArchiveThread(_:)), object: parameters)
        thread.name = NSLocalizedString("Uncompressing...", comment: "")
        thread.status = (archive as NSString).lastPathComponent
        thread.progress = -1
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    @objc(expandArchiveThread:)
    nonisolated func expandArchiveThread(_ parameters: NSDictionary!) {
        autoreleasepool {
            guard let archive = parameters?["archive"] as? String, let database = parameters?["database"] as? DicomDatabase else { return }
            let thread = Thread.current
            let files = FileManager.default
            // The importer skips hidden folders. Keeping staging on the database's
            // volume makes publication a rename, including for external databases.
            let staging = ((database.incomingDirPath() ?? "") as NSString).appendingPathComponent(".horos-extract-" + UUID().uuidString)

            if let exception = BrowserObjC.attempt({
                if thread.isCancelled { return }
                do {
                    try files.createDirectory(atPath: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } catch {
                    showArchiveImportError(archive)
                    return
                }
                var status: Int32 = -1
                var expanded = BrowserController.unzipFile(archive, withPassword: nil, destination: staging, showGUI: false, terminationStatus: &status)
                var requiresPassword = ArchivePasswordRule.needsPassword(afterStatus: status)
                while !expanded && !thread.isCancelled && requiresPassword {
                    guard let password = passwordForArchive(archive), !thread.isCancelled else { return }
                    expanded = BrowserController.unzipFile(archive, withPassword: password, destination: staging, showGUI: false, terminationStatus: &status)
                    requiresPassword = ArchivePasswordRule.needsPasswordAgain(afterStatus: status)
                }
                if thread.isCancelled { return }
                if !expanded {
                    showArchiveImportError(archive)
                    return
                }
                let destination = ((database.incomingDirPath() ?? "") as NSString).appendingPathComponent("unzip-" + UUID().uuidString)
                do {
                    try files.moveItem(atPath: staging, toPath: destination)
                } catch {
                    NSLog("---- import: archive could not be handed to the import folder (%@)", error.localizedDescription)
                    showArchiveImportError(archive)
                    return
                }
                database.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                DispatchQueue.main.async { BrowserController.offer(toDeleteZIPFile: archive) }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController expandArchiveThread:]")
                showArchiveImportError(archive)
            }
            // A successful move took the folder; only unpublished staging is ours.
            if files.fileExists(atPath: staging) {
                try? files.removeItem(atPath: staging)
            }
        }
    }

    /// Asks for the archive's password in a sheet on the browser and waits for
    /// the answer; nil when cancelled, also when the thread is cancelled
    /// meanwhile, which closes the sheet.
    @discardableResult
    @objc(passwordForArchive:)
    nonisolated func passwordForArchive(_ archive: String!) -> String! {
        let request = ArchivePasswordRequest(thread: Thread.current)
        let name = (archive as NSString?)?.lastPathComponent ?? ""
        DispatchQueue.main.async {
            if request.thread.isCancelled {
                request.answer(nil)
                return
            }
            let alert = NSAlert()
            request.pendingAlert = alert
            alert.messageText = NSLocalizedString("ZIP Password", comment: "")
            alert.informativeText = name
            alert.addButton(withTitle: NSLocalizedString("Extract", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field
            let finish = { (result: NSApplication.ModalResponse) in
                request.pendingAlert = nil
                request.answer(result == .alertFirstButtonReturn && !request.thread.isCancelled ? field.stringValue : nil)
            }
            if let window = self.window {
                alert.beginSheetModal(for: window, completionHandler: finish)
                alert.window.makeFirstResponder(field)
            } else {
                finish(alert.runModal())
            }
        }

        request.response.lock()
        var cancellationSent = false
        while !request.answered {
            if request.thread.isCancelled && !cancellationSent {
                cancellationSent = true
                DispatchQueue.main.async {
                    if let sheet = request.pendingAlert?.window, let parent = sheet.sheetParent {
                        parent.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                    }
                }
            }
            request.response.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        request.response.unlock()
        return request.password
    }

    @objc(showArchiveImportError:)
    nonisolated func showArchiveImportError(_ archive: String!) {
        let name = (archive as NSString?)?.lastPathComponent ?? ""
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Could not decompress archive", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@ could not be prepared for import. The original ZIP file has been preserved.", comment: ""), name)
            if let window = self.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                _ = alert.runModal()
            }
        }
    }

    // MARK: Files and folders

    /// Imports files and folders: each dropped path, and each file of a
    /// dropped folder, is imported, expanded, downloaded or read as a
    /// DICOMDIR (DroppedItemsPlan); the files go to the database, copied or
    /// linked.
    @objc(addFilesAndFolderToDatabase:)
    func addFilesAndFolder(toDatabase filenames: [Any]!) {
        let paths = (filenames ?? []).compactMap { $0 as? String }
        let filesArray = NSMutableArray()
        let plan = DroppedItemsPlan.actions(forDroppedPaths: paths, isArchive: { ArchiveImportLedger.isArchiveName($0) })
        for action in plan {
            autoreleasepool {
                if let exception = BrowserObjC.attempt({ dispatchDroppedAction(action, files: filesArray) }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController addFilesAndFolderToDatabase:]")
                }
            }
        }

        let options = BrowserObjC.dictionary(UserDefaults.standard.object(forKey: "onlyDICOM"), "onlyDICOM", NSNumber(value: true), "async",
                                             NSNumber(value: true), "addToAlbum", NSNumber(value: true), "selectStudy")
        copyFilesIntoDatabaseIfNeeded(filesArray, options: options as? [AnyHashable: Any])
    }

    /// One action of a drop: the files to import are added to `files`.
    private func dispatchDroppedAction(_ action: DroppedAction, files filesArray: NSMutableArray) {
        switch action.item {
        case .wadoManifest:
            BrowserController.asyncWADOXMLDownloadURL(URL(fileURLWithPath: action.path))
        case .wadoURLList:
            startWADODownload(ofList: action.path)
        case .archive:
            expandArchiveIntoIncomingFolder(action.path)
        case .dicomdir:
            addDICOMDIR(action.path, filesArray)
        case .file:
            filesArray.add(action.path)
        case .folder, .ignore:
            break
        }
    }

    /// Adds the files a DICOMDIR lists to `files`.
    @objc(addDICOMDIR::)
    func addDICOMDIR(_ dicomdir: String!, _ files: NSMutableArray!) {
        DicomDirParser(dicomdir).parseArray(files)
    }

    /// The sheet's "Add" and "Cancel" (tag 1 and 0), or files chosen in
    /// Finder: a `.sql` file opens that database, plugins are installed and
    /// the rest is imported.
    @objc(subSelectFilesAndFoldersToAdd:)
    func subSelectFilesAndFolders(toAdd filenames: [Any]!) {
        let paths = (filenames ?? []).compactMap { $0 as? String }
        if paths.count == 1 && (paths[0] as NSString).pathExtension.lowercased() == "sql" {
            guard HorosIsDatabaseFile(paths[0]) else {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Cannot Open Database", comment: ""),
                                                message: NSLocalizedString("This file is not a IsiX DICOM Viewer database. It has not been imported or modified.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
            guard ForeignDatabaseChoice.confirmOpening(path: paths[0]) else { return }
            self.database = DicomDatabase(atPath: paths[0])
            return
        }

        // Plugin bundles of either API go to the plugin installation, which
        // installs a version 1 plugin and refuses a former one with its
        // reason; neither is imported into the database.
        let plugins = paths.filter {
            ["isixplugin", "horosplugin", "osirixplugin"].contains(($0 as NSString).pathExtension.lowercased())
        }
        let others = NSMutableArray(array: paths)
        others.removeObjects(in: plugins)
        addFilesAndFolder(toDatabase: others as? [Any])
        if !plugins.isEmpty {
            AppController.shared()?.installPlugins(plugins)
        }
    }

    @objc(selectFilesAndFoldersToAdd:)
    func selectFilesAndFoldersToAdd(_ sender: Any!) {
        let panel = NSOpenPanel()
        self.window?.makeKeyAndOrderFront(sender)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.begin { result in
            guard result == .OK else { return }
            for url in panel.urls where SandboxFileAccess.remember(url) == false {
                return
            }
            self.subSelectFilesAndFolders(toAdd: panel.urls.map { $0.path })
        }
    }

    // MARK: URLs

    @discardableResult
    @objc(addURLToDatabaseFiles:)
    nonisolated func addURLToDatabaseFiles(_ URLs: [Any]!) -> [Any]! {
        return addURLToDatabaseFiles(URLs, report: nil)
    }

    /// A URL import, waited for on the calling thread, which must not be the
    /// main thread: the UI and AppleScript use -importURLs:completion:, so that
    /// neither blocks the event loop. A HorosURLImportOperation waits for the
    /// downloads, follows cancellation, decides by content where each payload
    /// goes, writes it, hands it to the database it was given and composes the
    /// result.
    @discardableResult
    @objc(addURLToDatabaseFiles:report:)
    nonisolated func addURLToDatabaseFiles(_ URLs: [Any]!, report: AutoreleasingUnsafeMutablePointer<NSString?>?) -> [Any]! {
        if Thread.isMainThread {
            report?.pointee = "Use asynchronous URL import on the main thread."
            return []
        }
        let database = DispatchQueue.main.sync { self.database }
        guard let database else {
            report?.pointee = "No database."
            return []
        }
        let urls = (URLs ?? []).compactMap { $0 as? URL }
        let result = URLImportOperation(urls: urls, database: database).run()
        report?.pointee = result.report as NSString?
        return result.files
    }

    /// Imports URLs on a thread of the Activity list into the database shown
    /// now, which a switch during the import does not change, and calls
    /// `completion` on the main thread with the files, the report and whether
    /// it succeeded.
    @discardableResult
    @objc(importURLs:completion:)
    func importURLs(_ URLs: [Any]!, completion: (([Any]?, String?, Bool) -> Void)!) -> Thread! {
        guard let database = self.database else { return nil }
        let urls = (URLs ?? []).compactMap { $0 as? URL }
        let job = URLImportJob(operation: URLImportOperation(urls: urls, database: database), completion: completion ?? { _, _, _ in })
        let thread = Thread(target: self, selector: #selector(importURLsThread(_:)), object: job)
        thread.name = NSLocalizedString("Import URLs", comment: "")
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
        return thread
    }

    @objc(importURLsThread:)
    nonisolated func importURLsThread(_ parameters: Any!) {
        autoreleasepool {
            guard let job = parameters as? URLImportJob else { return }
            var files: [Any] = []
            var report: String?
            var succeeded = false
            if let exception = BrowserObjC.attempt({
                let result = job.operation.run()
                files = result.files
                report = result.report
                succeeded = result.succeeded
            }) {
                report = exception.reason
            }
            let outcome = (files as NSArray, report, succeeded)
            nonisolated(unsafe) let delivered = outcome
            DispatchQueue.main.async {
                job.completion(delivered.0 as? [Any], delivered.1, delivered.2)
            }
        }
    }

    /// The "Add URL" sheet's buttons: tag 1 imports the URL.
    @objc(addURLToDatabaseEnd:)
    func addURLToDatabaseEnd(_ sender: Any!) {
        let tag = (sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0
        let url = NSURL(string: horos_urlString?.stringValue ?? "")
        if tag == 1 && url == nil {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("URL Error", comment: ""), message: NSLocalizedString("Invalid URL.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        horos_urlWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        if tag == 1, let url {
            UserDefaults.standard.set(horos_urlString?.stringValue, forKey: "LASTURL")
            _ = importURLs([url as URL]) { _, report, succeeded in
                if !succeeded {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("URL Error", comment: ""),
                                                    message: report ?? NSLocalizedString("Nothing was downloaded.", comment: ""),
                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }
        }
    }

    @objc(addURLToDatabase:)
    func addURLToDatabase(_ sender: Any!) {
        horos_urlString?.stringValue = UserDefaults.standard.string(forKey: "LASTURL") ?? ""
        if let sheet = horos_urlWindow {
            self.window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    // MARK: Copying into the database

    @objc(copyFilesThread:)
    nonisolated func copyFilesThread(_ dict: NSDictionary!) {
        _ = self.database?.perform(#selector(DicomDatabase.copyFilesThread(_:)), with: dict)
    }

    /// Copies the linked files of the selection into the database folder.
    @objc(copyToDBFolder:)
    func copyToDBFolder(_ sender: Any!) {
        guard let database = self.database, database.isLocal() else { return }

        var fromThumbnails = false
        if isThumbnailMenuItem(sender) || self.window?.firstResponder === horos_oMatrix {
            fromThumbnails = true
            NSLog("copyToDBFolder from matrix")
        }
        let objects = NSMutableArray()
        let files = (fromThumbnails ? files(forDatabaseMatrixSelection: objects, onlyImages: false)
                                    : files(forDatabaseOutlineSelection: objects, onlyImages: false)) ?? NSMutableArray()

        let splash = Wait(string: NSLocalizedString("Copying linked files into Database...", comment: ""), true)
        splash?.showWindow(self)
        splash?.progress()?.maxValue = Double(objects.count)
        splash?.setCancel(true)

        files.removeDuplicatedStrings(inSyncWithThisArray: objects)

        if let exception = BrowserObjC.attempt({
            for case let image as NSManagedObject in objects {
                if (image.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue == false || image.value(forKey: "inDatabaseFolder") == nil {
                    copyIntoDatabaseFolder(image, database: database)
                }
                splash?.increment(by: 1)
                if splash?.aborted() == true { break }
            }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserController copyToDBFolder:]")
        }
        splash?.close()
    }

    /// Copies a linked image's file into the data folder and points the
    /// image, and the other frames of the same file, at the copy.
    private func copyIntoDatabaseFolder(_ image: NSManagedObject, database: DicomDatabase) {
        guard let source = image.value(forKey: "completePath") as? String else { return }
        let isDICOM = (image.value(forKey: "fileType") as? NSString)?.hasPrefix("DICOM") ?? false
        let pathExtension = DataFileExtension.forLinkedFile(pathExtension: (source as NSString).pathExtension, isDICOM: isDICOM)
        guard let destination = database.uniquePathForNewDataFile(withExtension: pathExtension),
              (try? FileManager.default.copyItem(atPath: source, toPath: destination)) != nil else { return }

        let series = image.value(forKey: "series") as? NSManagedObject
        series?.setValue(NSNumber(value: false), forKey: "mountedVolume")
        for case let frame as NSManagedObject in ((image.value(forKeyPath: "series.images") as? NSSet)?.allObjects ?? []) {
            if BrowserObjC.literallyEqual(frame.value(forKey: "completePath") as? String, source) {
                frame.setValue(NSNumber(value: true), forKey: "inDatabaseFolder")
                frame.setValue((destination as NSString).lastPathComponent, forKey: "path")
                frame.setValue(NSNumber(value: false), forKey: "mountedVolume")
            }
        }
    }

    /// Imports files into the local database, copied into its data folder or
    /// linked where they are, as the "Copy files" preference (or `options`)
    /// says; `COPYDATABASEMODE` may ask. Cancelling empties `filesInput`.
    @objc(copyFilesIntoDatabaseIfNeeded:options:)
    func copyFilesIntoDatabaseIfNeeded(_ filesInput: NSMutableArray!, options: [AnyHashable: Any]!) {
        guard let database = self.database, database.isLocal(), let filesInput, filesInput.count > 0 else { return }
        let options = (options ?? [:]) as NSDictionary
        let defaults = UserDefaults.standard
        var copyEnabled = defaults.bool(forKey: "COPYDATABASE")
        var mode = defaults.integer(forKey: "COPYDATABASEMODE")
        if let value = options["COPYDATABASE"] as? NSNumber { copyEnabled = value.boolValue }
        if let value = options["COPYDATABASEMODE"] as? NSNumber { mode = value.intValue }

        let dataDirectory = database.dataDirPath() ?? ""
        let paths = filesInput.compactMap { $0 as? String }
        let outside = DatabaseCopyRule.filesOutside(dataDirectory: dataDirectory, in: paths)
        let first = paths.first ?? ""

        var copyFiles: Bool
        switch DatabaseCopyRule.decision(copyEnabled: copyEnabled, mode: mode, hasFilesOutside: !outside.isEmpty, firstPath: first,
                                         isOnCD: { path in NSLog("%@", path); return BrowserController.isItCD(path) }) {
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
                filesInput.removeAllObjects()
                return
            default:
                copyFiles = true
            }
        }

        let mountedVolume = (options["mountedVolume"] as? NSNumber)?.boolValue ?? false
        if copyFiles {
            FileManager.default.confirmNoIndexDirectory(atPath: database.dataDirPath())
            if (options["async"] as? NSNumber)?.boolValue == true {
                startCopyFilesThread(database: database, files: filesInput, copy: true, mountedVolume: mountedVolume, options: options,
                                     name: mountedVolume ? NSLocalizedString("Copying and indexing files from CD/DVD...", comment: "")
                                                         : NSLocalizedString("Copying and indexing files...", comment: ""))
            } else {
                copyFilesNow(filesInput, into: database, dataDirectory: dataDirectory)
            }
        } else {
            startCopyFilesThread(database: database, files: filesInput, copy: false, mountedVolume: mountedVolume, options: options,
                                 name: mountedVolume ? NSLocalizedString("Indexing files from CD/DVD...", comment: "")
                                                     : NSLocalizedString("Indexing files...", comment: ""))
        }
    }

    /// The database's -copyFilesThread:, on a thread of the Activity list: it
    /// copies (or not) and indexes on a private-queue context of its own.
    private func startCopyFilesThread(database: DicomDatabase, files: NSMutableArray, copy: Bool, mountedVolume: Bool,
                                      options: NSDictionary, name: String) {
        let parameters = NSMutableDictionary(dictionary: ["filesInput": files, "copyFiles": NSNumber(value: copy),
                                                          "mountedVolume": NSNumber(value: mountedVolume)])
        parameters.addEntries(from: options as? [AnyHashable: Any] ?? [:])
        let thread = Thread(target: database, selector: #selector(DicomDatabase.copyFilesThread(_:)), object: parameters)
        thread.name = name
        thread.status = BrowserObjC.singularPlural(files.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    /// Copies the files into the data folder now, with a progress window;
    /// the copies are not indexed here.
    private func copyFilesNow(_ files: NSMutableArray, into database: DicomDatabase, dataDirectory: String) {
        let splash = Wait(string: NSLocalizedString("Copying into Database...", comment: ""))
        splash?.showWindow(self)
        splash?.progress()?.maxValue = Double(files.count)
        splash?.setCancel(true)

        for case let source as String in files {
            autoreleasepool {
                if let exception = BrowserObjC.attempt({
                    let folder = ((source as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                    guard BrowserObjC.literallyEqual(folder, dataDirectory) == false else { return }
                    guard let file = DicomFile(source) else {
                        NSLog("**** DicomFile *curFile = nil")
                        return
                    }
                    let isDICOM = ((file.dicomElements() as NSDictionary?)?["fileType"] as? NSString)?.hasPrefix("DICOM") ?? false
                    let pathExtension = DataFileExtension.forImportedFile(pathExtension: (source as NSString).pathExtension, isDICOM: isDICOM)
                    guard let destination = database.uniquePathForNewDataFile(withExtension: pathExtension) else { return }
                    _ = try? FileManager.default.copyItem(atPath: source, toPath: destination)
                    if pathExtension == "hdr" {
                        // ANALYZE: the image goes with its header.
                        _ = try? FileManager.default.copyItem(atPath: ((source as NSString).deletingPathExtension as NSString).appendingPathExtension("img") ?? "",
                                                              toPath: ((destination as NSString).deletingPathExtension as NSString).appendingPathExtension("img") ?? "")
                    }
                }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController copyFilesIntoDatabaseIfNeeded:options:]")
                }
            }
            splash?.increment(by: 1)
            if splash?.aborted() == true { break }
        }
        splash?.close()
    }
}
