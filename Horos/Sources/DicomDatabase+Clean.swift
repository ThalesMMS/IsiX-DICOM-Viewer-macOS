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

// DicomDatabase (Clean): the selectors and <Horos/DicomDatabase+Clean.h> of the
// former category, which plugins and the Objective-C still see. The cleanup
// itself is DatabaseCleanupService; the clean lock is stored by DicomDatabase.swift.
//
// They stay dynamic because RemoteDicomDatabase overrides -cleanForFreeSpaceMB:,
// -cleanOldStuff and -initiateCleanUnlessAlreadyCleaning to do nothing. The
// service calls them on its database, so what it does reaches those overrides.

public extension DicomDatabase {

    @objc dynamic func initClean() {
        if isMainDatabase() {
            cleanLock = NSRecursiveLock()
        } else {
            cleanLock = (mainDatabase as? DicomDatabase)?.cleanLock
        }
        DatabaseCleanupService.startTimer()
    }

    // Runs while the database goes away, so nothing here may retain it.
    @objc dynamic func deallocClean() {
        if isMainDatabase() {
            let temp = cleanLock
            temp?.lock() // if currently cleaning, wait until finished
            cleanLock = nil
            temp?.unlock()
        } else {
            cleanLock = nil
        }
    }

    @objc dynamic func initiateCleanUnlessAlreadyCleaning() {
        cleaning.initiateClean()
    }

    @objc(automaticCleanupPreview)
    dynamic func automaticCleanupPreview() -> [String: Any]! {
        return cleaning.preview().dictionary
    }

    @objc dynamic func cleanOldStuff() {
        cleaning.cleanOldStuff()
    }

    @objc dynamic func cleanForFreeSpace() {
        cleaning.cleanForFreeSpace()
    }

    @objc(cleanForFreeSpaceMB:)
    dynamic func cleanForFreeSpaceMB(_ freeMemoryRequested: Int) {
        cleaning.cleanForFreeSpaceMB(freeMemoryRequested)
    }
}

extension DicomDatabase {
    /// The automatic cleanup of this database.
    var cleaning: DatabaseCleanupService {
        DatabaseCleanupService(database: self)
    }
}
