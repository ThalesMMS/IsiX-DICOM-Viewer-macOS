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
import IsiXContracts
import IsiXDICOMFile
import IsiXDatabase
import IsiXPreferences
import Synchronization

/// An archive and the database it goes into, captured when the import began
/// and handed to the thread that expands it.
/// @unchecked Sendable: the thread only asks the database for its import
/// folder and to import it, which DatabaseIngest does from any thread.
private struct ArchiveExpansion: @unchecked Sendable {
    let archive: String
    let database: DicomDatabase
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

/// Numbers the web portal's temporary recompressed files, from 1.
private let wadoTemporaryFileNumber = Mutex<Int>(1)

/// Archives brought to the browser: a ZIP archive dropped or chosen is
/// expanded, with its password when it has one, into the import folder of
/// the database shown when it came, and DatabaseIngest imports that folder
/// as every other; a CD or a mounted DMG is told by its DICOMDIR or by the
/// encrypted archive a burnt CD holds. The compression and the decompression
/// of the browser's selection go to the database's file conversion, and the
/// web portal's files in another transfer syntax are recompressed through
/// the DCMTK adapter.
///
/// The expansion runs on a thread of the Activity list (ActivityThread),
/// which shows it with its Cancel button; the password sheet and the alerts
/// are shown from the main run loop (onMainRunLoop), never inside a block of
/// the main queue. A partial expansion is never published: it is made in a
/// hidden folder beside the import folder and moved in whole.
@MainActor final class ArchiveImport {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: Archives

    /// Expands a ZIP archive into the import folder of the database shown
    /// now, captured before the browser can switch databases. The Activity
    /// task owns the extraction and publishes only a complete folder.
    func expandIntoIncomingFolder(_ archive: String) {
        guard let database = browser.database else { return }
        let expansion = ArchiveExpansion(archive: archive, database: database)
        ActivityThread.startListed(name: NSLocalizedString("Uncompressing...", comment: ""), configure: { thread in
            thread.status = (archive as NSString).lastPathComponent
            thread.progress = -1
        }) { [self] in
            autoreleasepool { expand(expansion) }
        }
    }

    nonisolated private func expand(_ expansion: ArchiveExpansion) {
        let archive = expansion.archive, database = expansion.database
        let thread = Thread.current
        let files = FileManager.default
        // The importer skips hidden folders. Keeping staging on the database's
        // volume makes publication a rename, including for external databases.
        let folder = DatabaseIngest.process.admissionFolder(of: database)
        let staging = folder.hiddenPath(named: "horos-extract-" + UUID().uuidString)

        if let exception = HorosObjCException.caught({
            if thread.isCancelled { return }
            do {
                try files.createDirectory(atPath: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                showImportError(archive)
                return
            }
            var status: Int32 = -1
            var expanded = ArchiveImport.unzip(archive, password: nil, into: staging, showingProgress: false, status: &status)
            var requiresPassword = ArchivePasswordRule.needsPassword(afterStatus: status)
            while !expanded && !thread.isCancelled && requiresPassword {
                guard let password = password(forArchive: archive), !thread.isCancelled else { return }
                expanded = ArchiveImport.unzip(archive, password: password, into: staging, showingProgress: false, status: &status)
                requiresPassword = ArchivePasswordRule.needsPasswordAgain(afterStatus: status)
            }
            if thread.isCancelled { return }
            if !expanded {
                showImportError(archive)
                return
            }
            let destination = folder.path(named: "unzip-" + UUID().uuidString)
            do {
                try files.moveItem(atPath: staging, toPath: destination)
            } catch {
                NSLog("---- import: archive could not be handed to the import folder (%@)", error.localizedDescription)
                showImportError(archive)
                return
            }
            DatabaseIngest.process.requestImport(of: database)
            // Without a browser window the offer is a modal, which must not run inside the main queue.
            onMainRunLoop { ArchiveImport.offerToDelete(archive, in: self.browser.window, preferences: self.preferences) }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserController expandArchiveThread:]")
            showImportError(archive)
        }
        // A successful move took the folder; only unpublished staging is ours.
        if files.fileExists(atPath: staging) {
            try? files.removeItem(atPath: staging)
        }
    }

    /// Asks for the archive's password in a sheet on the browser and waits for
    /// the answer; nil when cancelled, also when the thread is cancelled
    /// meanwhile, which closes the sheet.
    nonisolated private func password(forArchive archive: String) -> String? {
        let request = ArchivePasswordRequest(thread: Thread.current)
        let name = (archive as NSString).lastPathComponent
        // A cancellation that overtakes this block is seen by its first check, and
        // the block below closes the sheet of one that comes later.
        onMainRunLoop {
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
            if let window = self.browser.window {
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

    nonisolated private func showImportError(_ archive: String) {
        let name = (archive as NSString).lastPathComponent
        onMainRunLoop {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Could not decompress archive", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@ could not be prepared for import. The original ZIP file has been preserved.", comment: ""), name)
            if let window = self.browser.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                _ = alert.runModal()
            }
        }
    }

    // MARK: Encrypted archives of a CD

    /// Expands an encrypted archive, asking for its password in the CD
    /// password sheet until it opens or the user cancels; NSModalResponseStop
    /// when expanded.
    func askForPassword(_ file: String?, destination: String?) -> Int32 {
        // First without a password.
        guard !BrowserController.unzipFile(file, withPassword: nil, destination: destination) else {
            return Int32(NSApplication.ModalResponse.stop.rawValue)
        }
        browser.pathToEncryptedFile = String(format: NSLocalizedString("File: %@", comment: ""), file ?? "(null)")
        browser.cDpassword = ""
        var result = NSApplication.ModalResponse.stop
        repeat {
            guard let sheet = browser.horos_CDpasswordWindow else { break }
            browser.window?.beginSheet(sheet, completionHandler: nil)
            result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(browser)
        } while result == .stop && !BrowserController.unzipFile(file, withPassword: browser.cDpassword, destination: destination)
        return Int32(result.rawValue)
    }

    // MARK: Compression of the selection

    /// Compresses or decompresses the DICOM files of the selection in the
    /// background, through the database's file conversion; a database of
    /// another computer is refused.
    func convertSelection(_ sender: Any?, mode: FileConversionMode) {
        guard let database = browser.database, database.isLocal() else {
            let message = mode == .compress ? NSLocalizedString("Cannot compress images in a distant database.", comment: "")
                                            : NSLocalizedString("Cannot decompress images in a distant database.", comment: "")
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Non-Local Database", comment: ""), message: message,
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let files = selectedDICOMFiles(sender)
        DCMPix.purgeCachedDictionaries()
        DatabaseIngest.process.fileConverting(of: database).convertLater(files, mode: mode, into: nil)
    }

    /// The DICOM files of the selection, each once: thumbnails when the menu
    /// or the focus is theirs, else the list.
    private func selectedDICOMFiles(_ sender: Any?) -> [String] {
        let objects = NSMutableArray()
        let files: NSMutableArray?
        if browser.isThumbnailMenuItem(sender) || browser.window?.firstResponder === browser.horos_oMatrix {
            files = browser.files(forDatabaseMatrixSelection: objects)
        } else {
            files = browser.files(forDatabaseOutlineSelection: objects)
        }
        guard let files else { return [] }
        files.removeDuplicatedStrings(inSyncWithThisArray: objects)
        var result: [String] = []
        for index in 0 ..< files.count where index < objects.count {
            if (objects[index] as? DicomImage)?.fileType()?.hasPrefix("DICOM") == true {
                result.append("\(files[index])")
            }
        }
        return result
    }
}

extension ArchiveImport {

    // MARK: Extraction

    /// The answer to the offer to delete an imported archive, which is kept
    /// once the question is suppressed.
    nonisolated private static let deletesImportedArchive = PreferenceKey<Bool>("deleteZIPfile")
    nonisolated private static let suppressesDeletionQuestion = PreferenceKey<Bool>("HideZIPSuppressionMessage")

    /// Expands `file` into `destination`, a new private folder, and answers
    /// whether it holds a file of some content. `status` gets unzip's
    /// termination status, -1 when it did not run. On the main thread with
    /// `showingProgress`, a progress window stays responsive while unzip
    /// runs; a cancelled thread stops unzip. An archive unzip expanded whole
    /// with warnings counts as expanded (HorosArchiveImportLedger).
    nonisolated static func unzip(_ file: String!, password: String!, into destination: String!, showingProgress: Bool,
                                  status: UnsafeMutablePointer<Int32>?) -> Bool {
        status?.pointee = -1
        if Thread.current.isCancelled { return false }
        let files = FileManager.default
        try? files.removeItem(atPath: destination)
        guard (try? files.createDirectory(atPath: destination, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])) != nil else { return false }

        // Only the main thread may show the progress window.
        let progress: UnzipProgressWindow? = Thread.isMainThread && showingProgress
            ? MainActor.assumeIsolated { UnzipProgressWindow() }
            : nil

        // The password is typed on unzip's own terminal, never passed as -P,
        // which every process could read (ps).
        var succeeded = false
        do {
            let exitStatus = try ProtectedZipArchiver.extract(file, to: destination, password: password, in: files.tmpDirPath()) {
                // The progress window keeps responding while other windows
                // stay modal: waiting for unzip must not stop the event loop.
                if Thread.current.isCancelled { return false }
                if let progress {
                    MainActor.assumeIsolated { progress.keepResponding() }
                }
                return true
            }
            status?.pointee = exitStatus
            succeeded = !Thread.current.isCancelled
                && ArchiveImportLedger.unzipExpandedWholeArchive(file, status: exitStatus, into: destination)
            if succeeded && exitStatus != 0 {
                NSLog("---- unzip: %@ expanded whole, with warnings (status %d)", (file as NSString).lastPathComponent, exitStatus)
            }
        } catch {
            NSLog("---- unzip: %@ could not run: %@", (file as NSString).lastPathComponent, error.localizedDescription)
        }
        if let progress {
            MainActor.assumeIsolated { progress.close() }
        }
        guard succeeded else { return false }

        // Something of some content came out.
        if let enumerator = files.enumerator(atPath: destination) {
            while let item = enumerator.nextObject() as? String {
                var isDirectory: ObjCBool = false
                let path = (destination as NSString).appendingPathComponent(item)
                if files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                   ((try? files.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
                    return true
                }
            }
        }
        return false
    }

    /// After an import, deletes the archive if the user says so, in a sheet
    /// on `window` or alone, or as the preferences say once the question is
    /// suppressed.
    static func offerToDelete(_ file: String?, in window: NSWindow?, preferences: any PreferenceStore) {
        guard let file, FileManager.default.isWritableFile(atPath: file) else { return }
        if !preferences[suppressesDeletionQuestion] {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Delete ZIP file", comment: "")
            alert.informativeText = NSLocalizedString("The ZIP file was successfully decompressed and queued for import. Should I delete the ZIP file?", comment: "")
            alert.showsSuppressionButton = true
            alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("No", comment: ""))
            let answer: (NSApplication.ModalResponse) -> Void = { result in
                let deleteArchive = result == .alertFirstButtonReturn
                preferences.set(deleteArchive, for: deletesImportedArchive)
                if alert.suppressionButton?.state == .on {
                    preferences.set(true, for: suppressesDeletionQuestion)
                }
                if deleteArchive {
                    try? FileManager.default.removeItem(atPath: file)
                }
            }
            if let window {
                alert.beginSheetModal(for: window, completionHandler: answer)
            } else {
                answer(alert.runModal())
            }
            return
        }
        if preferences[deletesImportedArchive] {
            try? FileManager.default.removeItem(atPath: file)
        }
    }
}

extension ArchiveImport {

    // MARK: CDs and DICOMDIRs

    /// The first DICOMDIR among the files under the folder.
    nonisolated static func firstDicomdir(inFolder startDirectory: String?) -> String? {
        var found: String?
        if let exception = HorosObjCException.caught({
            let files = (FileManager.default.enumerator(atPath: startDirectory, filesOnly: true).allObjects as? [String]) ?? []
            found = MediaScanRules.dicomdir(in: (startDirectory as NSString?)?.strings(byAppendingPaths: files) ?? [])
        }) {
            BrowserObjC.log(exception, "+[BrowserController findFirstDicomdirInFolder:]")
        }
        return found
    }

    /// Whether the path is on a removable volume that holds a DICOMDIR, or
    /// the encryptedDICOM.zip of a CD burnt by the application.
    nonisolated static func isOnCD(_ path: String?) -> Bool {
        guard let path else { return false }
        let components = (path as NSString).pathComponents
        guard components.count > 2, (components[1] as NSString).uppercased == "VOLUMES" else { return false }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: []) ?? []
        for volume in volumes {
            let mediaPath = volume.path
            guard (mediaPath as NSString).isEqual(to: (mediaPath as NSString).commonPrefix(with: path, options: .caseInsensitive)) else { continue }
            guard (try? volume.resourceValues(forKeys: [.volumeIsRemovableKey]))?.volumeIsRemovable == true else { continue }
            let folder = FileManager.default.enumerator(atPath: mediaPath) == nil ? "/Volumes/Untitled" : mediaPath
            // encryptedDICOM.zip: see BurnerWindowController.
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            where ((item as NSString).lastPathComponent as NSString).isEqual(to: "encryptedDICOM.zip") {
                return true
            }
            if let dicomdir = firstDicomdir(inFolder: folder), FileManager.default.fileExists(atPath: dicomdir) {
                return true
            }
        }
        return false
    }

    // MARK: Compression and transfer syntaxes

    /// The compression of the Compression preferences for the modality, and
    /// its quality in `quality` when the choice has one. The Decompress
    /// service chooses through the same CompressionChoice, with the settings
    /// the application sends it.
    nonisolated static func compression(forModality modality: String?, quality: UnsafeMutablePointer<Int32>?, resolution: Int32,
                                        preferences: any PreferenceStore) -> Int32 {
        let choice = CompressionChoice.choice(forModality: modality, resolution: Int(resolution),
                                              resolutionLimit: preferences[DatabasePreferences.compressionResolutionLimit],
                                              settings: preferences.object(forKey: DatabasePreferences.compressionSettings.name) as? [Any],
                                              lowResolutionSettings: preferences.object(forKey: DatabasePreferences.compressionSettingsLowRes.name) as? [Any])
        if let quality, let chosen = choice.quality {
            quality.pointee = chosen
        }
        return Int32(truncatingIfNeeded: choice.compression)
    }

    /// The name of a transfer syntax: a pure lookup, called from the loading
    /// threads too. Any thread.
    nonisolated static func name(ofTransferSyntax string: String?) -> String {
        let uid = string as NSString?
        if uid?.isEqual(to: "1.2.840.10008.1.2") == true { return NSLocalizedString("Uncompressed", comment: "") }
        if uid?.isEqual(to: "1.2.840.10008.1.2.1") == true { return NSLocalizedString("Uncompressed", comment: "") }
        if uid?.isEqual(to: "1.2.840.10008.1.2.2") == true { return NSLocalizedString("Uncompressed BigEndian", comment: "") }
        if let string, let name = IsiXDCMTKTranscoding.name(ofUID: string) { return name }
        return NSLocalizedString("Unknown UID", comment: "")
    }

    /// The file in a transfer syntax, recompressed by DCMTK when it is in
    /// another the syntax cannot be served from; the original file when the
    /// copy cannot be made. nil when DCMTK cannot load the file. On the
    /// calling thread (the web portal's).
    nonisolated static func file(_ file: String?, inSyntax syntax: String?, quality: Int32) -> Data? {
        guard let file else { return nil }
        let number = wadoTemporaryFileNumber.withLock { next in
            defer { next += 1 }
            return next
        }
        let temporary = FileManager.default.tmpDirPath().appendingFormat("/wado-recompress-%ld.dcm", number) as String
        try? FileManager.default.removeItem(atPath: temporary)

        let outcome = IsiXDCMTKTranscoding.transcodeFile(atPath: file, toTransferSyntax: syntax ?? "", quality: quality,
                                                         destination: temporary,
                                                         servesOriginal: { original, requested in
            TransferSyntaxServing.servesOriginal(original: original, requested: requested)
        }, error: nil)
        switch outcome {
        case .unreadable:
            return nil
        case .servesOriginal:
            return NSData(contentsOfFile: file) as Data?
        case .saveFailed:
            NSLog("getDICOMFile:(NSString*) file inSyntax:(NSString*) syntax quality: (int) quality failed")
        case .written, .cannotWrite:
            break
        @unknown default:
            break
        }
        let data = NSData(contentsOfFile: temporary) as Data?
        try? FileManager.default.removeItem(atPath: temporary)
        return data ?? NSData(contentsOfFile: file) as Data? // Original file
    }
}

/// The progress window of an expansion on the main thread, kept responsive
/// while unzip runs: a modal session over it, which other modal windows do
/// not stop.
@MainActor private final class UnzipProgressWindow {
    private let wait: WaitRendering?
    private let session: NSApplication.ModalSession?

    init() {
        let wait: WaitRendering? = WaitRendering(NSLocalizedString("Decompressing the files...", comment: ""))
        wait?.showWindow(nil)
        self.wait = wait
        session = wait?.window.map { NSApp.beginModalSession(for: $0) }
    }

    /// One turn of the modal session's event loop.
    func keepResponding() {
        if let session { _ = NSApp.runModalSession(session) }
    }

    func close() {
        if let session { NSApp.endModalSession(session) }
        wait?.close()
    }
}
