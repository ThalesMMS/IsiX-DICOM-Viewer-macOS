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

import AppKit

// The "Multi viewport series synchronization" selectors of ViewerController,
// which the toolbar, the menus, the views, the notifications and the plugins
// send: the "Sync" button, the settings one viewer hands on to the others and
// the "Re-sync origin" of a fusion. The work is ViewerSettingsPropagator's and
// ViewerFusion's, made for each call; the state the viewers share is the
// process's ViewerSyncState.

extension ViewerController {

    /// The synchronization of this viewer with the others, for one call: the
    /// "Sync" button and the settings it hands on.
    var settingsPropagator: ViewerSettingsPropagator {
        ViewerSettingsPropagator(viewer: self, processGraph: sessionGraph.processGraph, preferences: sessionGraph.preferences)
    }
}

public extension ViewerController {

    /// The "Sync" item of the viewer's toolbar.
    @objc(findSyncSeriesButton)
    func findSyncSeriesButton() -> Any! {
        settingsPropagator.syncItem
    }

    /// The series lock changed (OsirixSyncSeriesNotification): across studies,
    /// this viewer locks at its offset from the sender's slice location, or
    /// unlocks; within a study, the button shows the view's syncro mode.
    @objc(notificationSyncSeries:)
    func notificationSyncSeries(_ note: Notification!) {
        let sliceLocation = (note?.userInfo?["sliceLocation"] as? NSNumber)?.floatValue ?? 0
        settingsPropagator.seriesLockDidChange(sliceLocation: sliceLocation)
    }

    /// Unlocks the series of different studies, if they are locked.
    @objc(turnOffSyncSeriesBetweenStudies:)
    func turnOffSyncSeriesBetweenStudies(_ sender: Any!) {
        settingsPropagator.unlockSeriesBetweenStudies()
    }

    /// Locks the series of different studies at their current offset.
    @objc(activateSYNCSERIESBetweenStudies)
    static func activateSYNCSERIESBetweenStudies() {
        ViewerSettingsPropagator.lockSeriesBetweenStudies(sync: processGraph.viewerSync, registry: viewerRegistry)
    }

    /// The "Sync" button: across studies it locks or unlocks the series and
    /// tells the others where this one is; within a study it switches the
    /// view's syncro mode (Option: relative, otherwise by location).
    @objc(SyncSeries:)
    func syncSeries(_ sender: Any!) {
        settingsPropagator.toggleSync()
    }

    /// The study of the current movie frame's first image.
    @objc(studyInstanceUID)
    nonisolated func studyInstanceUID() -> String! {
        let files = horos_fileList(at: Int(horos_curMovieIndex))
        return (files?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String
    }

    /// Works out what the "Sync" button does: across studies when the other
    /// displayed viewers are not all of this one's study. Within a study, or on
    /// switching to across studies, the series are unlocked.
    @objc(SetSyncButtonBehavior:)
    func setSyncButtonBehavior(_ sender: Any!) {
        settingsPropagator.updateSyncButtonBehavior()
    }

    /// "Re-sync origin" of a fusion whose settings are not propagated.
    @objc(reSyncOrigin:)
    func reSyncOrigin(_ sender: Any!) {
        fusion.reSyncOrigin()
    }

    /// Hands this viewer's settings on to `vC`; a fused viewer passes them on
    /// to its fusion.
    @objc(propagateSettingsToViewer:)
    func propagateSettings(to vC: ViewerController!) {
        guard let vC else { return }
        settingsPropagator.propagateSettings(to: vC)
    }

    /// Hands this viewer's settings on to every other displayed 2D viewer that
    /// takes them, and refreshes the fusion of the volume renderings fused
    /// with it.
    @objc(propagateSettings)
    func propagateSettings() {
        settingsPropagator.propagateSettings()
    }
}
