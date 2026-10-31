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

/// Gives a database the templates of the HTML export, from the app's resources,
/// without touching those it already has: a person may have edited them.
struct DatabaseTemplateInstaller {
    /// Nothing is installed without a database.
    let database: DicomDatabase?

    func install() {
        guard let database else { return }
        let fileManager = FileManager.default
        let resourcePath = Bundle.main.resourcePath

        /// `[NSFileManager copyItemAtPath:[resourcePath stringByAppendingPathComponent:resource] toPath:path error:NULL]`
        func copyResource(_ resource: String, to path: String?) {
            guard let source = DicomDatabaseObjC.appending(resourcePath, resource), let path else { return }
            try? fileManager.copyItem(atPath: source, toPath: path)
        }

        // directory
        let htmlTemplatesDirectory = database.htmlTemplatesDirPath()
        if DicomDatabaseObjC.fileExists(htmlTemplatesDirectory) == false, let htmlTemplatesDirectory {
            try? fileManager.createDirectory(atPath: htmlTemplatesDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // HTML templates
        for template in ["QTExportPatientsTemplate.html", "QTExportStudiesTemplate.html", "QTExportSeriesTemplate.html"] {
            let templateFile = DicomDatabaseObjC.appending(htmlTemplatesDirectory, template)
            if DicomDatabaseObjC.fileExists(templateFile) == false {
                copyResource(template, to: templateFile)
            }
        }

        // HTML-extra directory
        let htmlExtraDirectory = DicomDatabaseObjC.appending(htmlTemplatesDirectory, "html-extra/")
        if DicomDatabaseObjC.fileExists(htmlExtraDirectory) == false, let htmlExtraDirectory {
            try? fileManager.createDirectory(atPath: htmlExtraDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // CSS file
        let cssFile = DicomDatabaseObjC.appending(htmlExtraDirectory, "style.css")
        if DicomDatabaseObjC.fileExists(cssFile) == false {
            copyResource("QTExportStyle.css", to: cssFile)
        }
    }
}
