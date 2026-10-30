/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The extensions that decide which reader the import tries on a file that is
/// not DICOM, and the limits it keeps to.
public enum ImportFormats {
    /// What NSImage (and libtiff, for a TIFF) reads, bmp included: it was the
    /// one common raster format missing from the list, so a bitmap could not
    /// be imported at all while a GIF could.
    public static let imageExtensions: Set<String> = ["tiff", "tif", "stk", "png", "jpg", "jpeg", "jp2", "pdf",
                                                      "pct", "gif", "bmp"]
    /// What libtiff opens, its pages counted.
    public static let tiffExtensions: Set<String> = ["tiff", "tif", "stk"]
    /// The movies AVFoundation reads, a frame an image.
    public static let movieExtensions: Set<String> = ["mov", "mpg", "mpeg", "avi"]

    /// The most frames kept of a movie.
    public static let movieFrameLimit = 1200
    /// The most pages kept of a PDF.
    public static let pdfPageLimit = 50

    /// The identifiers of a file that is not DICOM, from the name it arrived
    /// with: the trailing number is the image's, the rest names the series and
    /// the study; without one the name is all four.
    public struct NameIdentifiers: Equatable {
        public let imageID: String
        public let sopUID: String
        public let seriesID: String
        public let studyID: String
    }

    /// The identifiers of `name` (without its extension) for an image or a
    /// movie file read through NSImage or libtiff; `fullName` (with it) when
    /// the name does not end in a number.
    public static func identifiers(ofName name: NSString, fullName: String) -> NameIdentifiers {
        guard let number = FileNameNumbering.trailingNumber(of: name) else {
            return NameIdentifiers(imageID: fullName, sopUID: fullName, seriesID: fullName, studyID: fullName)
        }
        let stem = name.substring(to: number.start)
        return NameIdentifiers(imageID: number.digits, sopUID: stem + number.digits, seriesID: stem, studyID: stem)
    }
}
