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

/// What the XML-RPC methods do on the main thread once they have found what
/// was asked for: open it in a viewer, select it in the browser, select an
/// album. Each method is performed on the main thread by the request's thread,
/// and is isolated to the main actor.
extension XMLRPCInterface {

    /// Opens the first of `objectIDs` whose study has a series of images, then
    /// the next if the browser refuses it.
    @objc(_onMainThreadOpenObjectsWithIDs:)
    @MainActor func openObjects(withIDs objectIDs: NSArray?) {
        // XML-RPC already acknowledges an asynchronous request, not a
        // displayed viewer. Keep that contract, but wait for the operator's
        // modal dialog before closing viewers or bringing a new one in front
        // of it. The normal run-loop mode avoids polling inside the modal
        // loop; recheck on delivery because a nested loop or another dialog
        // may still be active.
        if NSApp.modalWindow != nil {
            perform(#selector(openObjects(withIDs:)), with: objectIDs, afterDelay: 0.1, inModes: [.default])
            return
        }
        if UserDefaults.standard.bool(forKey: "CloseAllWindowsBeforeXMLRPCOpen") {
            ViewerController.closeAllWindows()
        }

        BrowserController.currentBrowser()?.lastStudyNotOpenedReason = nil

        var opened = false
        var lastStudy: DicomStudy?
        for object in database?.objects(withIDs: objectIDs as? [Any]) ?? [] {
            let object = object as? NSManagedObject
            let study = self.study(for: object)
            if let study {
                lastStudy = study
            }
            if study?.imageSeries()?.count ?? 0 > 0 {
                // The answer to the caller is sent before this runs, so a
                // refusal here reached nobody: the order was answered with
                // success and no viewer appeared. Try the next match, then
                // say why none opened.
                if BrowserController.currentBrowser()?.display(study, object: object, command: "Open") ?? false {
                    opened = true
                    break
                }
            }
        }

        if !opened {
            reportStudyNotOpened(lastStudy)
        }

        if UserDefaults.standard.bool(forKey: "bringOsiriXToFrontAfterReceivingMessage") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Selects the first of `objectIDs` in the browser; a study already shown
    /// in a viewer brings that viewer to the front instead.
    @objc(_onMainThreadSelectObjectsWithIDs:)
    @MainActor func selectObjects(withIDs objectIDs: NSArray?) {
        BrowserController.currentBrowser()?.lastStudyNotOpenedReason = nil

        let objectIDs = objectIDs ?? []
        let remaining = NSMutableArray(array: objectIDs)

        // Remove the studies already displayed.
        for case let viewer as ViewerController in ViewerController.get2DViewers() ?? [] {
            if let studyID = viewer.currentStudy()?.objectID, objectIDs.contains(studyID) {
                remaining.remove(studyID)
                viewer.window?.makeKeyAndOrderFront(self)
            }
        }

        var selected = remaining.count != objectIDs.count // one was already on screen
        var lastStudy: DicomStudy?
        for object in database?.objects(withIDs: remaining as? [Any]) ?? [] {
            let object = object as? NSManagedObject
            let study = self.study(for: object)
            if let study {
                lastStudy = study
            }
            if study?.imageSeries()?.count ?? 0 > 0 {
                if BrowserController.currentBrowser()?.display(study, object: object, command: "Select") ?? false {
                    selected = true
                    break
                }
            }
        }

        if !selected {
            reportStudyNotOpened(lastStudy)
        }

        if UserDefaults.standard.bool(forKey: "bringOsiriXToFrontAfterReceivingMessage") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opens what a thread is retrieving: imports what has arrived on a
    /// private-queue database, then opens on the main thread. Runs on a thread
    /// of its own.
    @objc(_onMainThreadOpenWithDelayObjectsWithIDs:)
    func openWithDelay(objectsWithIDs objectIDs: NSArray?) {
        autoreleasepool {
            let importer = privateQueueDatabase(DicomDatabase.activeLocal())
            importer?.performBlockAndWait {
                _ = importer?.importFilesFromIncomingDir()
            }
            performSelector(onMainThread: #selector(openObjects(withIDs:)), with: objectIDs, waitUntilDone: false)
        }
    }

    /// Selects the album at `index` of the browser's album list.
    @objc(_onMainThreadSelectAlbumAtIndex:)
    @MainActor func selectAlbum(atIndex index: NSNumber) {
        BrowserController.currentBrowser()?.albumTable?.selectRowIndexes(IndexSet(integer: index.intValue), byExtendingSelection: false)
    }
}
