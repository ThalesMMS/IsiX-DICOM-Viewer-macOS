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

/// Which files of an export folder a DICOMDIR written into it indexes.
public enum DicomDirExportRules {

    /// The DICOMDIR's own name in the folder.
    public static let dicomDirName = "DICOMDIR"

    /// Whether the file at `relativePath`, as DCMTK lists the folder (slashes,
    /// relative to it), is a source instance to index: index files, macOS
    /// metadata and the staging folders of a zip export are not.
    public static func indexes(relativePath: String) -> Bool {
        let path = relativePath as NSString
        let name = path.lastPathComponent as NSString
        if path.isEqual(to: "DICOMDIR") || path.isEqual(to: "DICOMDIR.BAK") { return false }
        if name.isEqual(to: ".DS_Store") || name.hasPrefix("._") { return false }
        if let first = path.pathComponents.first, (first as NSString).hasPrefix(".horos-zip-") { return false }
        return true
    }
}
