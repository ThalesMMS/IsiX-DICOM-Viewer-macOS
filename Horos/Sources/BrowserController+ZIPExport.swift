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

// ZIP archives of the exports, made with /usr/bin/zip: plain or encrypted
// archives of files and folders, and the protected attachment of "Send by
// e-mail".

extension BrowserController {

    /// The files, at the archive's root, in groups of a thousand.
    @objc(encryptFiles:inZIPFile:password:)
    nonisolated class func encryptFiles(_ srcFiles: [Any]!, inZIPFile destFile: String!, password: String!) {
        if !AppController.hasMacOSXSnowLeopard() && Thread.isMainThread && ((password as NSString?)?.length ?? 0) > 0 {
            MainActor.assumeIsolated { zipEncryptionUnsupportedAlert() }
            return
        }
        if let destFile {
            try? FileManager.default.removeItem(atPath: destFile)
        }

        nonisolated(unsafe) var wait: WaitRendering?
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                wait = WaitRendering(NSLocalizedString("Compressing the files...", comment: ""))
                wait?.showWindow(self)
            }
        }
        if let exception = BrowserObjC.attempt({
            let files = (srcFiles ?? []).compactMap { $0 as? String }
            for chunk in ZipCommand.chunks(count: files.count) {
                let task = Process()
                task.launchPath = "/usr/bin/zip"
                task.arguments = ZipCommand.flatArguments(password: password, archive: destFile ?? "", files: Array(files[chunk]))
                task.launch()
                while task.isRunning { Thread.sleep(forTimeInterval: 0.01) }
            }
        }) {
            BrowserObjC.log(exception, stack: true, "+[BrowserController encryptFiles:inZIPFile:password:]")
        }
        if wait != nil {
            MainActor.assumeIsolated { wait?.close() }
        }
    }

    @objc(encryptFileOrFolder:inZIPFile:password:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!) {
        BrowserController.encryptFileOrFolder(srcFolder, inZIPFile: destFile, password: password, deleteSource: true, showGUI: true)
    }

    @objc(encryptFileOrFolder:inZIPFile:password:deleteSource:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!, deleteSource: Bool) {
        BrowserController.encryptFileOrFolder(srcFolder, inZIPFile: destFile, password: password, deleteSource: deleteSource, showGUI: true)
    }

    @objc(encryptFileOrFolder:inZIPFile:password:deleteSource:showGUI:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!, deleteSource: Bool, showGUI: Bool) {
        _ = BrowserController.encryptFileOrFolder(srcFolder, inZIPFile: destFile, password: password, deleteSource: deleteSource,
                                                  showGUI: showGUI, error: nil)
    }

    /// ZIP encryption leaves entry names readable: the archive is wrapped in
    /// a generic entry, Images.zip, so patient and study names are inside the
    /// encrypted payload. A password is required.
    @objc(prepareProtectedEmailAttachment:destination:password:error:)
    nonisolated class func prepareProtectedEmailAttachment(_ source: String!, destination: String!, password: String!,
                                                           error: NSErrorPointer) -> Bool {
        error?.pointee = nil
        guard ((password as NSString?)?.length ?? 0) > 0 else {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                     userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("A password is required for email attachments.", comment: "")])
            return false
        }
        let files = FileManager.default
        let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent("horos-email-" + UUID().uuidString)
        defer { try? files.removeItem(atPath: temporary) }
        do {
            try files.createDirectory(atPath: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let payload = (temporary as NSString).appendingPathComponent("Images.zip")
            try files.copyItem(atPath: source, toPath: payload)
            return BrowserController.encryptFileOrFolder(payload, inZIPFile: destination, password: password, deleteSource: false,
                                                         showGUI: false, error: error)
        } catch let failure {
            error?.pointee = failure as NSError
            return false
        }
    }

    @objc(encryptFileOrFolder:inZIPFile:password:deleteSource:showGUI:error:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!, deleteSource: Bool,
                                               showGUI: Bool, error: NSErrorPointer) -> Bool {
        let items: [Any] = ((srcFolder as NSString?)?.length ?? 0) > 0 ? [srcFolder!] : []
        return BrowserController.encryptFilesOrFolders(items, inZIPFile: destFile, password: password, deleteSource: deleteSource,
                                                       showGUI: showGUI, error: error)
    }

    /// The items, which must share one folder, each under its own name; the
    /// archive is published only when zip succeeded, and the sources are then
    /// removed if asked.
    @objc(encryptFilesOrFolders:inZIPFile:password:deleteSource:showGUI:error:)
    nonisolated class func encryptFilesOrFolders(_ srcItems: [Any]!, inZIPFile destFile: String!, password: String!, deleteSource: Bool,
                                                 showGUI: Bool, error: NSErrorPointer) -> Bool {
        error?.pointee = nil
        let items = (srcItems ?? []).compactMap { $0 as? String }
        guard let srcFolder = items.first, (srcFolder as NSString).length > 0, let destFile, (destFile as NSString).length > 0 else {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                                     userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("A source and destination are required for ZIP export.", comment: "")])
            return false
        }
        if !AppController.hasMacOSXSnowLeopard() && Thread.isMainThread && ((password as NSString?)?.length ?? 0) > 0 {
            MainActor.assumeIsolated { zipEncryptionUnsupportedAlert() }
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: nil)
            return false
        }

        var succeeded = false
        var archiveFailed = false
        BrowserObjC.synchronized(destFile as NSString) {
            let archive: ExportArchive
            do {
                archive = try ExportArchive(destinationPath: destFile)
            } catch let failure {
                error?.pointee = failure as NSError
                archiveFailed = true
                return
            }
            nonisolated(unsafe) var wait: WaitRendering?
            if Thread.isMainThread && showGUI {
                MainActor.assumeIsolated {
                    wait = WaitRendering(NSLocalizedString("Compressing the files...", comment: ""))
                    wait?.showWindow(self)
                }
            }
            Thread.current.status = NSLocalizedString("Compressing the files...", comment: "")

            if let exception = BrowserObjC.attempt({
                guard let names = ZipCommand.entryNames(items, exists: { FileManager.default.fileExists(atPath: $0) }), !names.isEmpty else { return }
                let task = Process()
                task.launchPath = "/usr/bin/zip"
                task.currentDirectoryPath = (srcFolder as NSString).deletingLastPathComponent
                task.arguments = ZipCommand.recursiveArguments(password: password, archive: archive.archivePath, names: names)
                task.launch()
                while task.isRunning { Thread.sleep(forTimeInterval: 0.1) }
                if task.terminationStatus == 0 {
                    do {
                        try archive.commit()
                        succeeded = true
                    } catch let failure {
                        error?.pointee = failure as NSError
                    }
                }
                if succeeded && deleteSource {
                    for item in items { try? FileManager.default.removeItem(atPath: item) }
                }
            }) {
                BrowserObjC.log(exception, stack: true, "+[BrowserController encryptFilesOrFolders:inZIPFile:password:deleteSource:showGUI:error:]")
            }
            if wait != nil {
                MainActor.assumeIsolated { wait?.close() }
            }
        }
        if archiveFailed { return false }
        if !succeeded, let error, error.pointee == nil {
            error.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("ZIP export could not be completed. The uncompressed source files were kept.", comment: ""),
                                               NSFilePathErrorKey: destFile])
        }
        return succeeded
    }

    /// Before MacOS 10.6 zip could not encrypt: the archive is not made.
    @MainActor private static func zipEncryptionUnsupportedAlert() {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("ZIP Encryption", comment: ""),
                                        message: NSLocalizedString("ZIP encryption requires MacOS 10.6 or higher. The ZIP file will be generated, but NOT encrypted with a password.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }
}
