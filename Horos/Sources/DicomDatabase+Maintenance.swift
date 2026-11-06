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
import IsiXContracts

// DicomDatabase (Other): the selectors and <Horos/DicomDatabase+Other.h> of the
// former block of methods, which plugins and the Objective-C still see. The
// work is in DatabaseRebuildService, DatabaseModelUpgrade,
// DatabaseReportConsistency, DatabaseTemplateInstaller and DatabaseStartupRepairs.
//
// They stay dynamic because RemoteDicomDatabase overrides -rebuild: and
// -rebuildAllowed to do nothing. The types call them on their database, so what
// they do reaches those overrides.

public extension DicomDatabase {

    @objc(rebuildAllowed)
    dynamic func rebuildAllowed() -> Bool {
        return true
    }

    @objc(upgradeSqlFileFromModelVersion:)
    dynamic func upgradeSqlFile(fromModelVersion databaseModelVersion: String!) -> Bool {
        return DatabaseModelUpgrade(database: self).run(fromModelVersion: databaseModelVersion)
    }

    // The database preferences run this over every database, through this selector.
    @objc(recomputePatientUIDsInContext:)
    dynamic class func recomputePatientUIDs(in context: NSManagedObjectContext!) {
        DatabaseStartupRepairs.recomputePatientUIDs(in: context)
    }

    @objc(rebuild)
    dynamic func rebuild() {
        self.rebuild(false)
    }

    @objc(rebuild:)
    dynamic func rebuild(_ complete: Bool) {
        NotificationCenter.default.post(name: .OsirixDatabaseObjectsMayBecomeUnavailable, object: self, userInfo: nil)
        rebuildService.rebuild(complete: complete)
    }

    @objc(checkReportsConsistencyWithDICOMSR)
    dynamic func checkReportsConsistencyWithDICOMSR() {
        DatabaseReportConsistency(database: self).archiveReportsAsDICOMSR()
    }

    @objc(checkForExistingReportForStudy:)
    dynamic func checkForExistingReport(forStudy study: NSManagedObject!) {
        DatabaseReportConsistency(database: self).attachExistingReport(to: study)
    }

    @objc(allowAutoroutingWithPostNotifications:rereadExistingItems:)
    dynamic func allowAutorouting(withPostNotifications postNotifications: Bool, rereadExistingItems: Bool) -> Bool {
        return true
    }

    @objc(alertToApplyRoutingRules:toImages:)
    dynamic func alertToApplyRoutingRules(_ routingRules: [Any]!, toImages images: [Any]!) {
        self.applyRoutingRules(nil, toImages: images)
    }

    @objc(dumpSqlFile)
    dynamic func dumpSqlFile() {
        rebuildService.dumpSqlFile()
    }

    @objc(rebuildSqlFile)
    dynamic func rebuildSqlFile() {
        rebuildService.rebuildSqlFile()
    }

    @objc(checkForHtmlTemplates)
    dynamic func checkForHtmlTemplates() {
        DatabaseTemplateInstaller(database: self).install()
    }
}

extension DicomDatabase {
    private var rebuildService: DatabaseRebuildService {
        DatabaseRebuildService(database: self)
    }

    /// The rebuilding of this database, as its consumers see it.
    var rebuilding: any DatabaseRebuilding {
        rebuildService
    }
}
