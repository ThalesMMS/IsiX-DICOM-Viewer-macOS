/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// What the scan of a medium decides without reading a file: which files it
/// opens, which DICOMDIR it reads, and how a DICOMDIR record becomes an entry
/// of the database (its file, file type and series identity).
///
/// The strings are compared as Foundation compares them (literal, UTF-16), as
/// the scan always did.
public enum MediaScanRules {

    /// Extensions of files the scan does not open, compared lowercased.
    static let skippedExtensions: [String] = ["jpg", "tif", "jpeg", "tiff", "mp4", "mov", "avi",
                                              "html", "doc", "docx", "txt", "exe"]

    /// Whether the scan leaves `path` unopened: a picture, a movie, a document
    /// or an executable by its extension, anything under a Weasis folder,
    /// hidden files and the content of a macOS application.
    public static func skipsWhenScanning(_ path: String) -> Bool {
        let path = path as NSString
        let fileExtension = (path.pathExtension as NSString).lowercased
        if skippedExtensions.contains(where: { (fileExtension as NSString).isEqual(to: $0) }) { return true }
        let lowercased = path.lowercased as NSString
        if lowercased.range(of: "/weasis/").location != NSNotFound { return true } // Don't scan Weasis
        if lowercased.range(of: "/.").location != NSNotFound { return true } // Don't scan hidden files
        if lowercased.range(of: ".app").location != NSNotFound { return true } // The content of a macOS application
        return false
    }

    /// Whether a file the scan recognised as DICOM is itself a DICOMDIR, which
    /// is not imported as an image.
    public static func isDicomdirName(_ path: String) -> Bool {
        (((path as NSString).lastPathComponent as NSString).lowercased as NSString).range(of: "dicomdir").length != 0
    }

    /// The DICOMDIR of a medium: the shortest of the paths whose file name is
    /// DICOMDIR or DICOMDIR. in any case; the first one listed among equals.
    public static func dicomdir(in paths: [String]) -> String? {
        var candidate: String? = nil
        for path in paths {
            let name = ((path as NSString).lastPathComponent as NSString).uppercased as NSString
            if name.isEqual(to: "DICOMDIR") || name.isEqual(to: "DICOMDIR.") {
                if candidate == nil || (candidate! as NSString).length > (path as NSString).length {
                    candidate = path
                }
            }
        }
        return candidate
    }

    /// The listed path a DICOMDIR reference that does not exist means: the
    /// first of `paths` equal to it, ignoring case and the extension of both.
    public static func listedPath(matching path: String, in paths: [String]) -> String? {
        let cut = (path as NSString).deletingPathExtension
        for listed in paths
        where ((listed as NSString).deletingPathExtension as NSString).compare(cut, options: .caseInsensitive) == .orderedSame {
            return listed
        }
        return nil
    }

    /// Whether the entry at `index` is the only one of its series: no other
    /// entry has the same series ID. An entry without one is alone.
    public static func isOnlyEntryOfItsSeries(at index: Int, seriesIDs: [String?]) -> Bool {
        guard let seriesID = seriesIDs[index] else { return true }
        for (other, otherID) in seriesIDs.enumerated() where other != index {
            if let otherID, (otherID as NSString).isEqual(to: seriesID) { return false }
        }
        return true
    }

    // MARK: - A DICOMDIR record as a database entry

    /// The longest path a referenced file may have (MAXPATHLEN).
    public static let maximumPathLength = 1024

    /// The file a Referenced File ID (0004,1500) names, its components
    /// separated by backslashes, under the folder of the DICOMDIR.
    public static func referencedFilePath(_ fileID: String, basePath: String) -> String {
        (basePath as NSString).appendingPathComponent(fileID.replacingOccurrences(of: "\\", with: "/"))
    }

    /// Whether a referenced file's path is short enough to be imported.
    public static func acceptsReferencedFilePath(_ path: String) -> Bool {
        (path as NSString).length < maximumPathLength
    }

    /// "DICOMMPEG2" for both MPEG-2 syntaxes, Main Level and High Level, which
    /// the viewer decodes neither of; "DICOM" otherwise.
    public static func fileType(forTransferSyntax transferSyntax: String?) -> String {
        guard let syntax = transferSyntax as NSString? else { return "DICOM" }
        return syntax.isEqual(to: "1.2.840.10008.1.2.4.100") || syntax.isEqual(to: "1.2.840.10008.1.2.4.101")
            ? "DICOMMPEG2" : "DICOM"
    }

    /// The series of an entry. A multi-frame file is a series of its own,
    /// "<series UID>-<SOP instance UID>", so that its frames do not merge with
    /// another file's; a missing UID reads "(null)", as Foundation formats nil.
    public static func seriesDICOMUID(seriesInstanceUID: String?, sopInstanceUID: String?,
                                      numberOfFrames: Int) -> String? {
        guard numberOfFrames > 1 else { return seriesInstanceUID }
        return "\(seriesInstanceUID ?? "(null)")-\(sopInstanceUID ?? "(null)")"
    }

    /// The series ID: the series number, zero-padded to eight digits, a space
    /// and the series UID ("(null)" when there is none); the series UID alone
    /// when there is no series number.
    public static func seriesID(seriesNumber: String?, seriesDICOMUID: String?) -> String? {
        guard let seriesNumber else { return seriesDICOMUID }
        return String(format: "%8.8d %@", (seriesNumber as NSString).intValue, seriesDICOMUID ?? "(null)")
    }
}
