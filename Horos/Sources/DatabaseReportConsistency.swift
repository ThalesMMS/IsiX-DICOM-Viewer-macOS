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

import CoreData
import Foundation
import IsiXDatabase

/// What the reports of a database's studies have to agree with: their
/// structured reports, and the report files of the database's folder.
struct DatabaseReportConsistency {
    let database: DicomDatabase

    /// Archives again, as a DICOM structured report, every study that has a report.
    func archiveReportsAsDICOMSR() {
        // Find all studies with reportURL
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {

        if let exception = HorosObjCException.caught({
            let predicate = NSPredicate(format: "reportURL != NIL")
            let dbRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
            dbRequest.predicate = predicate

            let studiesArray = ((try? database.managedObjectContext?.fetch(dbRequest)) ?? nil) ?? []

            for case let s as DicomStudy in studiesArray {
                archive(s)
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase checkReportsConsistencyWithDICOMSR]")
        }
        }
    }

    /// reportURL answers nil for a report inside the database while the browser
    /// has no database, as during a rebuild. The archive would take that for a
    /// report that was deleted and drop the link, so that study waits for the next
    /// check.
    private func archive(_ study: DicomStudy?) {
        if study?.reportURL != nil { study?.archiveReportAsDICOMSR() }
    }

    /// Attaches to a study whose own report cannot be reached the report file
    /// of the reports folder that has its name, if there is one.
    func attachExistingReport(to study: NSManagedObject?) {
        // #ifndef OSIRIX_LIGHT (compiled)
        // The stored value and not reportURL, which depends on the browser's database.
        if ReportAttachment.isReachable(stored: study?.primitiveValue(forKey: "reportURL") as? String, inDatabaseAt: database.baseDirPath,
                                        fileExists: FileManager.default.fileExists(atPath:)) {
            return
        }
        if let exception = HorosObjCException.caught({ // is there a report?
            let filenames = DicomDatabaseObjC.array(Reports.getUniqueFilename(study), Reports.getOldUniqueFilename(study))
            for case let filename as String in filenames {
                for `extension` in ReportAttachment.fileExtensions {
                    let reportPath = DicomDatabaseObjC.appending(database.reportsDirPath(), String(format: "%@.%@", filename, `extension`))
                    if DicomDatabaseObjC.fileExists(reportPath) {
                        study?.willChangeValue(forKey: "reportURL")
                        study?.setPrimitiveValue(reportPath.map { ReportAttachment.storedPath($0, inDatabaseAt: database.baseDirPath) }, forKey: "reportURL")
                        study?.didChangeValue(forKey: "reportURL")
                        archive(study as? DicomStudy)
                        return
                    }
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase checkForExistingReportForStudy:]")
        }
    }
}
