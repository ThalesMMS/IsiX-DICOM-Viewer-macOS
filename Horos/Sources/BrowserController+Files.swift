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

// Files and media of the browser: aliases, revealing a file in the Finder
// and ejecting a disk. ZIP archives, CDs and DICOMDIRs are ArchiveImport
// (ArchiveImport.swift); their selectors stay here as forwarding methods.

/// The destination of an alias file; nil when the path is not an alias.
private func aliasDestination(_ path: String?) -> String? {
    guard let path else { return nil }
    let url = URL(fileURLWithPath: path)
    guard (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true else { return nil }
    return (try? URL(resolvingAliasFileAt: url, options: []))?.path
}

extension BrowserController {

    // MARK: ZIP archives (ArchiveImport)

    @objc(unzipFile:withPassword:destination:)
    class func unzipFile(_ file: String!, withPassword pass: String!, destination: String!) -> Bool {
        return BrowserController.unzipFile(file, withPassword: pass, destination: destination, showGUI: true)
    }

    @objc(unzipFile:withPassword:destination:showGUI:)
    class func unzipFile(_ file: String!, withPassword pass: String!, destination: String!, showGUI: Bool) -> Bool {
        return BrowserController.unzipFile(file, withPassword: pass, destination: destination, showGUI: showGUI, terminationStatus: nil)
    }

    /// Expands `file` into `destination` (ArchiveImport.unzip); on the main
    /// thread with `showGUI`, offers to delete an archive that expanded.
    @objc(unzipFile:withPassword:destination:showGUI:terminationStatus:)
    nonisolated class func unzipFile(_ file: String!, withPassword pass: String!, destination: String!, showGUI: Bool,
                                     terminationStatus status: UnsafeMutablePointer<Int32>!) -> Bool {
        let expanded = ArchiveImport.unzip(file, password: pass, into: destination, showingProgress: showGUI, status: status)
        if expanded && Thread.isMainThread && showGUI {
            MainActor.assumeIsolated { BrowserController.offer(toDeleteZIPFile: file) }
        }
        return expanded
    }

    @objc(offerToDeleteZIPFile:)
    class func offer(toDeleteZIPFile file: String!) {
        ArchiveImport.offerToDelete(file, in: BrowserController.currentBrowser()?.window, preferences: PreferencesSource.process.preferences)
    }

    @objc(askForZIPPassword:destination:)
    @discardableResult
    func askForZIPPassword(_ file: String!, destination: String!) -> Int32 {
        return archiveImport.askForPassword(file, destination: destination)
    }

    // MARK: CDs and DICOMDIRs (ArchiveImport)

    @available(*, deprecated)
    @objc(_findFirstDicomdirOnCDMedia:)
    class func _findFirstDicomdirOnCDMedia(_ startDirectory: String!) -> String! {
        return findFirstDicomdir(inFolder: startDirectory)
    }

    @objc(findFirstDicomdirInFolder:)
    nonisolated class func findFirstDicomdir(inFolder startDirectory: String!) -> String! {
        return ArchiveImport.firstDicomdir(inFolder: startDirectory)
    }

    @available(*, deprecated)
    @objc(ReadDicomCDRom:)
    func readDicomCDRom(_ sender: Any!) {
    }

    @objc(isItCD:)
    nonisolated class func isItCD(_ path: String!) -> Bool {
        return ArchiveImport.isOnCD(path)
    }

    // MARK: Aliases

    @available(*, deprecated)
    @objc(pathResolved:)
    func pathResolved(_ inPath: String!) -> String! {
        return aliasDestination(inPath)
    }

    @available(*, deprecated)
    func isAliasPath(_ inPath: String!) -> Bool {
        return aliasDestination(inPath) != nil
    }

    @available(*, deprecated)
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
