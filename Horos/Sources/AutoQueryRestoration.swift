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
import IsiXPreferences

/// Restarts the saved auto-query when the browser comes up, or when first-use
/// setup finishes, whichever finds a database open first.
@MainActor
enum AutoQueryRestoration {
    static func resume(database: DicomDatabase?, defaults: UserDefaults, notifier: AppController?, sender: NSObject) {
        // Query.xib schedules its log fetch for the next run-loop turn.
        // Wait until first-use setup has opened a database for that fetch.
        guard !DatabaseFirstUse.hasPendingChoice, database?.managedObjectContext != nil else { return }

        if defaults[NetworkPreferences.restartsAutoQueryAndRetrieve]
            && NetworkPreferences.holdsValue(NetworkPreferences.autoQueryInstances, in: defaults) {
            guard QueryController.currentAuto() == nil else { return }
            notifier?.notificationTitle(NSLocalizedString("Auto-Query", comment: ""),
                                        description: NSLocalizedString("DICOM Auto-Query is restarting...", comment: ""), name: "autoquery")
            NSLog("-------- automatically restart DICOM AUTO-QUERY --------")

            let restarting = WaitRendering(NSLocalizedString("Restarting Auto Query/Retrieve...", comment: ""))
            restarting?.showWindow(sender)
            // The controller keeps itself: +currentAutoQueryController answers it.
            if let controller = QueryController(autoQuery: true) { _ = Unmanaged.passRetained(controller) }
            QueryController.currentAuto()?.switchAutoRetrieving(sender)
            Thread.sleep(forTimeInterval: 0.5)
            restarting?.close()
        } else {
            defaults.set(false, for: NetworkPreferences.autoRetrieving)
        }
    }
}
