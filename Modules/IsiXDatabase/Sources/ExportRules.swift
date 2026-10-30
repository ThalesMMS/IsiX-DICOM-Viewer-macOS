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

// The rules of the browser's export and sending functions that need no
// AppKit, database or DICOM toolkit: how names become folder and file names
// (and DICOMDIR components), where a movie export records its files, the
// arguments given to /usr/bin/zip, which series an export leaves out, and
// what the e-mail sheets accept.

/// Folder and file names of the exports.
public enum ExportNaming {

    /// +replaceNotAdmitted:preserveHyphens: — spaces become underscores, and
    /// . , ^ / \ | - : * < > ? # % are removed (the hyphen is kept when asked).
    /// Searched as NSString does with no options, character by character.
    public static func replacingNotAdmitted(_ name: String, preserveHyphens: Bool) -> String {
        let text = NSMutableString(string: name)
        func replace(_ target: String, _ replacement: String) {
            text.replaceOccurrences(of: target, with: replacement, options: [], range: NSRange(location: 0, length: text.length))
        }
        replace(" ", "_")
        for removed in [".", ",", "^", "/", "\\", "|"] { replace(removed, "") }
        if !preserveHyphens { replace("-", "") }
        for removed in [":", "*", "<", ">", "?", "#", "%"] { replace(removed, "") }
        return text as String
    }

    /// A DICOMDIR (ISO 9660) component: the first 7 characters when the text
    /// is longer than 8 (`truncate`), upper-cased, in ASCII with what has no
    /// ASCII form dropped or approximated, then cleaned.
    public static func dicomdirComponent(_ text: String, truncate: Bool) -> String {
        let source = text as NSString
        let short = truncate && source.length > 8 ? source.substring(to: 7) : text
        let ascii = ((short as NSString).uppercased as NSString).data(using: String.Encoding.ascii.rawValue, allowLossyConversion: true) ?? Data()
        let component = NSMutableString(data: ascii, encoding: String.Encoding.ascii.rawValue).map { $0 as String } ?? ""
        return replacingNotAdmitted(component, preserveHyphens: false)
    }

    /// The patient folder of a DICOM export: the patient name (DICOMDIR: its
    /// component), "unnamed"/"UNNAMED" when nothing is left.
    public static func patientFolder(name: String?, addDICOMDIR: Bool) -> String {
        let name = (name ?? "").isEmpty ? "unnamed" : name!
        let component = addDICOMDIR ? dicomdirComponent(name, truncate: true) : replacingNotAdmitted(name, preserveHyphens: true)
        return component.isEmpty ? (addDICOMDIR ? "UNNAMED" : "unnamed") : component
    }

    /// The study folder of a DICOM export: "name - ID" (DICOMDIR: the ID's
    /// component), "unnamed" and "0" standing for what is missing or empty.
    public static func studyFolder(name: String?, id: String?, addDICOMDIR: Bool) -> String {
        let name = (name ?? "").isEmpty ? "unnamed" : name!
        var studyID = replacingNotAdmitted(id ?? "0", preserveHyphens: !addDICOMDIR)
        var studyName = replacingNotAdmitted(name, preserveHyphens: !addDICOMDIR)
        if studyID.isEmpty { studyID = "0" }
        if studyName.isEmpty { studyName = "unnamed" }
        return addDICOMDIR ? dicomdirComponent(studyID, truncate: true) : "\(studyName) - \(studyID)"
    }

    /// The series folder of a DICOM export: "name_number" (DICOMDIR: the
    /// number), "series" for no name and "unnamed" when nothing is left.
    /// `number` is the series number as text ("0" when there is none).
    public static func seriesFolder(name: String?, number: String, addDICOMDIR: Bool) -> String {
        let name = (name ?? "").isEmpty ? "series" : name!
        var seriesName = replacingNotAdmitted(name, preserveHyphens: !addDICOMDIR)
        if seriesName.isEmpty { seriesName = "unnamed" }
        if addDICOMDIR { return dicomdirComponent(number, truncate: false) }
        return replacingNotAdmitted(seriesName, preserveHyphens: true) + "_" + number
    }

    /// The file of an exported image: IM-<series>-<image>.<extension>, or
    /// <series><image> in a DICOMDIR export, numbers on four digits at least.
    public static func imageFile(folder: String, seriesCount: Int32, imageNumber: Int32, pathExtension: String, addDICOMDIR: Bool) -> String {
        addDICOMDIR ? String(format: "%@/%4.4d%4.4d", folder, seriesCount, imageNumber)
                    : String(format: "%@/IM-%4.4d-%4.4d.%@", folder, seriesCount, imageNumber, pathExtension)
    }

    /// The `attempt`th file (2, 3…) of an image whose name is taken; the
    /// first one, renamed afterwards, is attempt 1. A DICOMDIR name leaves
    /// out the series and does not pad the attempt.
    public static func imageFile(folder: String, seriesCount: Int32, imageNumber: Int32, pathExtension: String, addDICOMDIR: Bool, attempt: Int32) -> String {
        addDICOMDIR ? String(format: "%@/%4.4d%d", folder, imageNumber, attempt)
                    : String(format: "%@/IM-%4.4d-%4.4d-%4.4d.%@", folder, seriesCount, imageNumber, attempt, pathExtension)
    }
}

/// Where a movie (QuickTime/HTML) export records the files of each series.
public enum MovieExportPaths {

    /// +setPath:relativeTo:forSeriesId:kind:toSeriesPaths: — the path, less
    /// as many characters as `directory` has and a leading "/", under
    /// paths[seriesID][kind]. Nothing is recorded without a dictionary.
    public static func record(_ path: String, relativeTo directory: String, seriesID: Int32, kind: String, in seriesPaths: NSMutableDictionary?) {
        guard let seriesPaths else { return }
        var relative = (path as NSString).replacingCharacters(in: NSRange(location: 0, length: (directory as NSString).length), with: "") as NSString
        if relative.character(at: 0) == UInt16(UInt8(ascii: "/")) {
            relative = relative.replacingCharacters(in: NSRange(location: 0, length: 1), with: "") as NSString
        }
        let key = NSNumber(value: seriesID)
        let pathsForSeries: NSMutableDictionary
        if let existing = seriesPaths[key] as? NSMutableDictionary {
            pathsForSeries = existing
        } else {
            pathsForSeries = NSMutableDictionary()
            seriesPaths[key] = pathsForSeries
        }
        pathsForSeries[kind] = relative
    }
}

/// The arguments the exports give /usr/bin/zip.
public enum ZipCommand {

    /// Files at the archive's root (-j), in groups of `chunkSize`.
    public static let chunkSize = 1000

    /// The command for one group of files stored without their folders.
    public static func flatArguments(password: String?, archive: String, files: [String]) -> [String] {
        let options = (password ?? "").isEmpty ? ["-q", "-j", archive] : ["-q", "-j", "-e", "-P", password!, archive]
        return options + files
    }

    /// The command for items of one folder, stored under their names, run in
    /// that folder (-r).
    public static func recursiveArguments(password: String?, archive: String, names: [String]) -> [String] {
        let options = (password ?? "").isEmpty ? ["-q", "-r", archive] : ["-q", "-r", "-e", "-P", password!, archive]
        return options + names
    }

    /// The ranges of the groups of `count` files.
    public static func chunks(count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: chunkSize).map { $0..<min($0 + chunkSize, count) }
    }

    /// The names of the items when all exist and share the first one's
    /// folder; nil otherwise (nothing is archived).
    public static func entryNames(_ items: [String], exists: (String) -> Bool) -> [String]? {
        guard let first = items.first else { return nil }
        let parent = (first as NSString).deletingLastPathComponent
        var names: [String] = []
        for item in items {
            guard exists(item), ((item as NSString).deletingLastPathComponent as NSString).isEqual(to: parent) else { return nil }
            names.append((item as NSString).lastPathComponent)
        }
        return names
    }
}

/// The series a DICOM export leaves out unless "Add ROIs" is on: the
/// private SR series, by name or by series number.
public enum ExportSeriesFilter {

    public static let privateSeries: [(name: String, number: String)] = [
        ("OsiriX ROI SR", "5002"), ("OsiriX Report SR", "5003"), ("OsiriX Annotations SR", "5004"),
        ("OsiriX No Autodeletion", "5005"), ("OsiriX WindowsState SR", "5006"),
    ]

    /// One predicate per private series, applied one after the other.
    public static func predicates() -> [NSPredicate] {
        privateSeries.map { NSPredicate(format: "!(series.name CONTAINS[c] %@) AND !(series.id == %@)", $0.name, $0.number) }
    }
}

/// What the e-mail sheets accept.
public enum EmailSheetRules {

    /// The archive password of "Send by e-mail" has 8 characters at least.
    public static let minimumPasswordLength = 8

    public static func acceptsPassword(_ password: String?) -> Bool {
        ((password ?? "") as NSString).length >= minimumPasswordLength
    }

    /// The answer to the notification sheet.
    public enum NotificationRecipients: Equatable {
        /// No user selected and no address typed.
        case noneSelected
        /// The typed address has no "@".
        case missingAt
        /// What comes before the "@" has fewer than 2 characters.
        case nameTooShort
        /// The selected users, and a new user for the typed address, if any.
        case accepted(newUserEmail: String?)
    }

    /// Selected users and a typed address (taken when longer than 3 characters).
    public static func notificationRecipients(selectedUsers: Int, typedAddress: String?) -> NotificationRecipients {
        let typed = (typedAddress ?? "") as NSString
        if selectedUsers == 0 && typed.length <= 3 { return .noneSelected }
        guard typed.length > 3 else { return .accepted(newUserEmail: nil) }
        let at = typed.range(of: "@")
        guard at.location != NSNotFound else { return .missingAt }
        guard (typed.substring(to: at.location) as NSString).length >= 2 else { return .nameTooShort }
        return .accepted(newUserEmail: typed as String)
    }
}
