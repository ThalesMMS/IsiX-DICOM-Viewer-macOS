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

// Files and media of the browser: ZIP archives expanded with /usr/bin/unzip,
// CDs and DICOMDIRs, aliases, revealing a file in the Finder and ejecting a
// disk.

/// The destination of an alias file; nil when the path is not an alias.
private func aliasDestination(_ path: String?) -> String? {
    guard let path else { return nil }
    let url = URL(fileURLWithPath: path)
    guard (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true else { return nil }
    return (try? URL(resolvingAliasFileAt: url, options: []))?.path
}

extension BrowserController {

    // MARK: ZIP archives

    @objc(unzipFile:withPassword:destination:)
    class func unzipFile(_ file: String!, withPassword pass: String!, destination: String!) -> Bool {
        return BrowserController.unzipFile(file, withPassword: pass, destination: destination, showGUI: true)
    }

    @objc(unzipFile:withPassword:destination:showGUI:)
    class func unzipFile(_ file: String!, withPassword pass: String!, destination: String!, showGUI: Bool) -> Bool {
        return BrowserController.unzipFile(file, withPassword: pass, destination: destination, showGUI: showGUI, terminationStatus: nil)
    }

    /// Expands `file` into `destination`, a new private folder, and answers
    /// whether it holds a file of some content. `status` gets unzip's
    /// termination status, -1 when it did not run. On the main thread with
    /// `showGUI`, a progress window stays responsive while unzip runs; a
    /// cancelled thread stops unzip. An archive unzip expanded whole with
    /// warnings counts as expanded (HorosArchiveImportLedger).
    @objc(unzipFile:withPassword:destination:showGUI:terminationStatus:)
    nonisolated class func unzipFile(_ file: String!, withPassword pass: String!, destination: String!, showGUI: Bool,
                                     terminationStatus status: UnsafeMutablePointer<Int32>!) -> Bool {
        status?.pointee = -1
        if Thread.current.isCancelled { return false }
        let files = FileManager.default
        try? files.removeItem(atPath: destination)
        guard (try? files.createDirectory(atPath: destination, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])) != nil else { return false }

        // Only the main thread may show the progress window.
        nonisolated(unsafe) var wait: WaitRendering?
        nonisolated(unsafe) var session: NSApplication.ModalSession?
        if Thread.isMainThread && showGUI {
            MainActor.assumeIsolated {
                wait = WaitRendering(NSLocalizedString("Decompressing the files...", comment: ""))
                wait?.showWindow(self)
                if let window = wait?.window { session = NSApp.beginModalSession(for: window) }
            }
        }

        var succeeded = false
        let task = Process()
        if let exception = BrowserObjC.attempt({
            task.launchPath = "/usr/bin/unzip"
            task.currentDirectoryPath = files.tmpDirPath()
            if let pass {
                task.arguments = ["-qq", "-o", "-d", destination, "-P", pass, file]
            } else {
                task.arguments = ["-qq", "-o", "-d", destination, file]
            }
            task.standardInput = FileHandle.nullDevice
            task.launch()
            while task.isRunning {
                // The progress window keeps responding while other windows
                // stay modal: waiting for unzip must not stop the event loop.
                if Thread.current.isCancelled {
                    task.terminate()
                    task.waitUntilExit()
                    break
                }
                if session != nil {
                    MainActor.assumeIsolated { _ = NSApp.runModalSession(session!) }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            status?.pointee = task.terminationStatus
            succeeded = !Thread.current.isCancelled
                && ArchiveImportLedger.unzipExpandedWholeArchive(file, status: task.terminationStatus, into: destination)
            if succeeded && task.terminationStatus != 0 {
                NSLog("---- unzip: %@ expanded whole, with warnings (status %d)", (file as NSString).lastPathComponent, task.terminationStatus)
            }
        }) {
            BrowserObjC.log(exception, stack: true, "+[BrowserController unzipFile:withPassword:destination:showGUI:terminationStatus:]")
        }
        if session != nil {
            MainActor.assumeIsolated { NSApp.endModalSession(session!) }
        }
        if wait != nil {
            MainActor.assumeIsolated { wait?.close() }
        }
        guard succeeded else { return false }

        // Something of some content came out.
        var fileExists = false
        if let enumerator = files.enumerator(atPath: destination) {
            while let item = enumerator.nextObject() as? String {
                var isDirectory: ObjCBool = false
                let path = (destination as NSString).appendingPathComponent(item)
                if files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                   ((try? files.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
                    fileExists = true
                    break
                }
            }
        }
        if fileExists && Thread.isMainThread && showGUI {
            MainActor.assumeIsolated { BrowserController.offer(toDeleteZIPFile: file) }
        }
        return fileExists
    }

    /// After an import, deletes the archive if the user says so, or as the
    /// preferences say once the question is suppressed.
    @objc(offerToDeleteZIPFile:)
    class func offer(toDeleteZIPFile file: String!) {
        guard let file, FileManager.default.isWritableFile(atPath: file) else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "HideZIPSuppressionMessage") {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Delete ZIP file", comment: "")
            alert.informativeText = NSLocalizedString("The ZIP file was successfully decompressed and queued for import. Should I delete the ZIP file?", comment: "")
            alert.showsSuppressionButton = true
            alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("No", comment: ""))
            let answer: (NSApplication.ModalResponse) -> Void = { result in
                let deleteArchive = result == .alertFirstButtonReturn
                defaults.set(deleteArchive, forKey: "deleteZIPfile")
                if alert.suppressionButton?.state == .on {
                    defaults.set(true, forKey: "HideZIPSuppressionMessage")
                }
                if deleteArchive {
                    try? FileManager.default.removeItem(atPath: file)
                }
            }
            if let window = BrowserController.currentBrowser()?.window {
                alert.beginSheetModal(for: window, completionHandler: answer)
            } else {
                answer(alert.runModal())
            }
            return
        }
        if defaults.bool(forKey: "deleteZIPfile") {
            try? FileManager.default.removeItem(atPath: file)
        }
    }

    /// Expands an encrypted archive, asking for its password in the CD
    /// password sheet until it opens or the user cancels; NSModalResponseStop
    /// when expanded.
    @objc(askForZIPPassword:destination:)
    @discardableResult
    func askForZIPPassword(_ file: String!, destination: String!) -> Int32 {
        // First without a password.
        guard !BrowserController.unzipFile(file, withPassword: nil, destination: destination) else {
            return Int32(NSApplication.ModalResponse.stop.rawValue)
        }
        self.pathToEncryptedFile = String(format: NSLocalizedString("File: %@", comment: ""), file ?? "(null)")
        self.cDpassword = ""
        var result = NSApplication.ModalResponse.stop
        repeat {
            guard let sheet = horos_CDpasswordWindow else { break }
            window?.beginSheet(sheet, completionHandler: nil)
            result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(self)
        } while result == .stop && !BrowserController.unzipFile(file, withPassword: self.cDpassword, destination: destination)
        return Int32(result.rawValue)
    }

    // MARK: CDs and DICOMDIRs

    @available(*, deprecated)
    @objc(_findFirstDicomdirOnCDMedia:)
    class func _findFirstDicomdirOnCDMedia(_ startDirectory: String!) -> String! {
        return findFirstDicomdir(inFolder: startDirectory)
    }

    /// The first DICOMDIR among the files under the folder.
    @objc(findFirstDicomdirInFolder:)
    nonisolated class func findFirstDicomdir(inFolder startDirectory: String!) -> String! {
        var found: String?
        if let exception = BrowserObjC.attempt({
            let files = (FileManager.default.enumerator(atPath: startDirectory, filesOnly: true).allObjects as? [String]) ?? []
            found = DicomDatabase._findDicomdir(in: (startDirectory as NSString?)?.strings(byAppendingPaths: files))
        }) {
            BrowserObjC.log(exception, "+[BrowserController findFirstDicomdirInFolder:]")
        }
        return found
    }

    @available(*, deprecated)
    @objc(ReadDicomCDRom:)
    func readDicomCDRom(_ sender: Any!) {
    }

    /// Whether the path is on a removable volume that holds a DICOMDIR, or
    /// the encryptedDICOM.zip of a CD burnt by the application.
    @objc(isItCD:)
    nonisolated class func isItCD(_ path: String!) -> Bool {
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
            if let dicomdir = findFirstDicomdir(inFolder: folder), FileManager.default.fileExists(atPath: dicomdir) {
                return true
            }
        }
        return false
    }

    // MARK: Aliases

    @available(*, deprecated)
    @objc(pathResolved:)
    func pathResolved(_ inPath: String!) -> String! {
        return aliasDestination(inPath)
    }

    @available(*, deprecated)
    @objc(isAliasPath:)
    func isAliasPath(_ inPath: String!) -> Bool {
        return aliasDestination(inPath) != nil
    }

    @available(*, deprecated)
    @objc(resolveAliasPath:)
    func resolveAliasPath(_ inPath: String!) -> String! {
        return aliasDestination(inPath) ?? inPath
    }

    /// The folder at the path, made when missing, through an alias or a
    /// symbolic link.
    @available(*, deprecated)
    @objc(folderPathResolvingAliasAndSymLink:)
    func folderPathResolvingAliasAndSymLink(_ path: String!) -> String! {
        let files = FileManager.default
        var folder: String? = path
        guard let path else { return nil }
        if !files.fileExists(atPath: path) {
            if let resolved = aliasDestination(path) {
                folder = resolved
            } else {
                try? files.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            }
        } else {
            // A file in the way: a folder is made; a symbolic link is followed.
            let resolvedPath = (path as NSString).resolvingSymlinksInPath
            if ((try? files.attributesOfItem(atPath: resolvedPath))?[.type] as? String) != FileAttributeType.typeDirectory.rawValue {
                try? files.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            }
            if ((try? files.attributesOfItem(atPath: path))?[.type] as? String) == FileAttributeType.typeSymbolicLink.rawValue {
                folder = try? files.destinationOfSymbolicLink(atPath: path)
            }
            if let resolved = aliasDestination(path) {
                folder = resolved
            }
        }
        return folder
    }

    // MARK: Finder and disks

    @objc(revealInFinder:)
    func revealInFinder(_ sender: Any!) {
        let objects = NSMutableArray()
        let files: NSMutableArray?
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            files = self.files(forDatabaseMatrixSelection: objects)
        } else {
            files = self.files(forDatabaseOutlineSelection: objects)
        }
        if let first = files?.firstObject as? String {
            NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: (first as NSString).deletingLastPathComponent)
        }
    }

    /// Ejects the disk, trying five times a second apart.
    @objc(unmountPath:)
    func unmountPath(_ path: String!) {
        horos_sourcesTableView?.display()
        var attempts = 0
        var success = false
        while !success {
            success = NSWorkspace.shared.unmountAndEjectDevice(atPath: path)
            if !success {
                attempts += 1
                if attempts < 5 {
                    Thread.sleep(forTimeInterval: 1)
                } else {
                    success = true
                }
            }
        }
        horos_sourcesTableView?.display()
        horos_sourcesTableView?.needsDisplay = true
        if attempts == 5 {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Failed", comment: ""),
                                            message: NSLocalizedString("Unable to unmount this disk. This disk is probably in used by another application.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// The eject button of a source: back to the local database, then eject.
    @objc(alternateButtonPressed:)
    func alternateButtonPressed(_ n: Notification!) {
        let row = horos_sourcesTableView?.selectedRow ?? -1
        guard row > 0, let services = bonjourBrowser?.services() as NSArray?, row - 1 < services.count else { return }
        let path = (services[row - 1] as AnyObject).value(forKey: "Path") as? String
        resetToLocalDatabase()
        unmountPath(path)
    }
}
