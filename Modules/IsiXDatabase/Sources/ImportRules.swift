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

import Foundation

/// What the browser does with each file or folder dropped on it, opened with
/// "Import..." or handed to it by another application.
public enum DroppedItem: Equatable, Sendable {
    /// Left alone: hidden, missing, or an application bundle.
    case ignore
    /// A folder whose files are each looked at in turn.
    case folder
    /// An XML WADO manifest, as Weasis writes them: its images are downloaded.
    case wadoManifest
    /// A `.dcmURLs` list of WADO URLs, one per line: downloaded, then deleted.
    case wadoURLList
    /// A ZIP archive: expanded into the database's import folder.
    case archive
    /// A DICOMDIR: the files it lists are imported.
    case dicomdir
    /// Imported as it is.
    case file
}

/// The decision for one path, without touching the file system: the caller
/// says whether it exists and is a folder, and how to recognise an archive.
public enum DroppedPathRule {
    /// A path dropped or opened by the user. A folder named `.pages` or `.app`
    /// is a document or an application, not a folder of images: the first is
    /// imported as a file, the second ignored.
    public static func item(forDroppedPath path: String, exists: Bool, isDirectory: Bool,
                            isArchive: (String) -> Bool) -> DroppedItem {
        let name = (path as NSString).lastPathComponent
        if isHidden(name) || exists == false { return .ignore }
        let pathExtension = (path as NSString).pathExtension
        if isDirectory && pathExtension != "pages" && pathExtension != "app" { return .folder }
        if pathExtension == "xml" { return .wadoManifest }
        if pathExtension == "dcmURLs" { return .wadoURLList }
        if isArchive(path) { return .archive }
        if isDICOMDIR(name) { return .dicomdir }
        if pathExtension == "app" { return .ignore }
        return .file
    }

    /// A name starting with a dot, or no name at all.
    public static func isHidden(_ name: String) -> Bool {
        let units = name.utf16
        return units.first.map { $0 == UInt16(UInt8(ascii: ".")) } ?? true
    }

    /// `DICOMDIR`, or `DICOMDIR.` as some media name it, in any case.
    public static func isDICOMDIR(_ name: String) -> Bool {
        let upper = (name as NSString).uppercased
        return upper == "DICOMDIR" || upper == "DICOMDIR."
    }
}

/// The walk through a dropped folder, in the order the file system lists it.
///
/// An application bundle inside the folder is skipped: once a folder named
/// `.app` is listed, the files listed after it whose relative path starts with
/// its relative path are ignored, until one that does not.
public struct DroppedFolderWalk: Sendable {
    private var skippedPrefix: String?

    public init() {}

    /// One entry of the folder: `relativePath` as the enumerator lists it,
    /// `path` the full path.
    public mutating func item(forRelativePath relativePath: String, path: String, isRegularFile: Bool,
                              isArchive: (String) -> Bool) -> DroppedItem {
        guard isRegularFile else {
            if (relativePath as NSString).pathExtension == "app" {
                skippedPrefix = relativePath
            }
            return .ignore
        }
        if let prefix = skippedPrefix, relativePath.utf16.starts(with: prefix.utf16) {
            return .ignore
        }
        skippedPrefix = nil
        let name = (path as NSString).lastPathComponent
        if DroppedPathRule.isHidden(name) { return .ignore }
        if (path as NSString).pathExtension == "dcmURLs" { return .wadoURLList }
        if isArchive(path) { return .archive }
        if DroppedPathRule.isDICOMDIR(name) { return .dicomdir }
        return .file
    }
}

/// One thing to do for a dropped path.
public struct DroppedAction: Equatable, Sendable {
    public let item: DroppedItem
    public let path: String

    public init(_ item: DroppedItem, _ path: String) {
        self.item = item
        self.path = path
    }
}

/// Everything to do for the paths dropped together, in order: each path,
/// and for a folder each file in it as the file system lists it. A `.dcmURLs`
/// list found in a folder is the list itself, never the folder: its download
/// deletes the list when done.
public enum DroppedItemsPlan {
    public static func actions(forDroppedPaths paths: [String], fileManager: FileManager = .default,
                               isArchive: (String) -> Bool) -> [DroppedAction] {
        var actions: [DroppedAction] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            let exists = DroppedPathRule.isHidden((path as NSString).lastPathComponent) == false
                && fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            let item = DroppedPathRule.item(forDroppedPath: path, exists: exists, isDirectory: isDirectory.boolValue,
                                            isArchive: isArchive)
            switch item {
            case .ignore:
                continue
            case .folder:
                guard let entries = fileManager.enumerator(atPath: path) else { continue }
                var walk = DroppedFolderWalk()
                while let relativePath = entries.nextObject() as? String {
                    let itemPath = (path as NSString).appendingPathComponent(relativePath)
                    let isRegular = (entries.fileAttributes?[.type] as? String) == FileAttributeType.typeRegular.rawValue
                    let entry = walk.item(forRelativePath: relativePath, path: itemPath, isRegularFile: isRegular,
                                          isArchive: isArchive)
                    if entry != .ignore {
                        actions.append(DroppedAction(entry, itemPath))
                    }
                }
            default:
                actions.append(DroppedAction(item, path))
            }
        }
        return actions
    }
}

/// A `.dcmURLs` list: one URL per line, the lines ending in CR or in LF,
/// whichever the text has more of (at least as many CRs counts as CR).
/// Empty lines are dropped; a CR left before an LF stays in the line.
public enum DownloadURLList {
    public static func lines(of text: String?) -> [String] {
        guard let text = text as NSString? else { return [] }
        let byCR = text.components(separatedBy: "\r")
        let byLF = text.components(separatedBy: "\n")
        let lines = byCR.count >= byLF.count ? byCR : byLF
        return lines.filter { ($0 as NSString).length > 0 }
    }
}

/// When an archive being imported needs a password, from `unzip`'s status.
public enum ArchivePasswordRule {
    /// Without a password, `unzip` reports an encrypted archive as 5 (missing
    /// input) and a refused password as 82. Other failures are errors.
    public static func needsPassword(afterStatus status: Int32) -> Bool {
        return status == 5 || status == 82
    }

    /// After a password was given: also 1, when only the encrypted entries of a
    /// mixed archive fail, and 2, when a wrong password passed ZIP's short
    /// header check and failed decompression or its CRC.
    public static func needsPasswordAgain(afterStatus status: Int32) -> Bool {
        return status == 5 || status == 82 || status == 1 || status == 2
    }
}

/// Whether files imported from outside the database are copied into it or
/// only linked, under the "Copy files" preference (`COPYDATABASE`) and its
/// mode (`COPYDATABASEMODE`).
public enum DatabaseCopyRule {
    /// The modes of `COPYDATABASEMODE`.
    public static let always = 0, cdOnly = 1, notMainDrive = 2, ask = 3

    public enum Decision: Equatable, Sendable {
        case copy
        case link
        /// The user is asked to copy, link or cancel.
        case askUser
    }

    /// The files of `paths` that are not already inside the database's data
    /// folder: their path does not start with the folder's, code unit by code
    /// unit.
    public static func filesOutside(dataDirectory: String, in paths: [String]) -> [String] {
        return paths.filter {
            ($0 as NSString).commonPrefix(with: dataDirectory, options: .literal).utf16.elementsEqual(dataDirectory.utf16) == false
        }
    }

    /// `firstPath` is the first file of the import, which stands for all of
    /// them; `isOnCD` is asked only in the CD mode.
    public static func decision(copyEnabled: Bool, mode: Int, hasFilesOutside: Bool,
                                firstPath: String, isOnCD: (String) -> Bool) -> Decision {
        guard copyEnabled && hasFilesOutside else { return .link }
        switch mode {
        case notMainDrive:
            // "/Volumes/<name>/..." is a file on anything but the boot volume.
            let components = (firstPath as NSString).pathComponents
            return components.count > 1 && (components[1] as NSString).uppercased == "VOLUMES" ? .copy : .link
        case cdOnly:
            return isOnCD(firstPath) ? .copy : .link
        case ask:
            return .askUser
        default:
            return .copy
        }
    }
}

/// The extension a file gets in the database's data folder.
public enum DataFileExtension {
    /// A file copied in by an import: DICOM files, files without an
    /// extension and extensions that are not three or four characters long
    /// become `dcm`.
    public static func forImportedFile(pathExtension: String, isDICOM: Bool) -> String {
        let length = (pathExtension as NSString).length
        if isDICOM || length == 0 || length > 4 || length < 3 { return "dcm" }
        return pathExtension
    }

    /// A linked file copied in on request: DICOM files and files without an
    /// extension become `dcm`.
    public static func forLinkedFile(pathExtension: String, isDICOM: Bool) -> String {
        if isDICOM || (pathExtension as NSString).length == 0 { return "dcm" }
        return pathExtension
    }
}

/// How often an import that reports batch after batch refreshes the study
/// list and the album counts: the first report of a quiet period at once,
/// then at most every `listInterval` and `albumsInterval` seconds, with a
/// last refresh for the end of a burst.
public enum ImportRefreshSchedule {
    public static let listInterval: TimeInterval = 5
    public static let albumsInterval: TimeInterval = 20

    /// Seconds to wait before the refresh; zero or less means now.
    public static func wait(lastRefresh: TimeInterval, interval: TimeInterval, now: TimeInterval) -> TimeInterval {
        return lastRefresh + interval - now
    }
}
