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
import IsiXDatabase

// The browser's study list, with the selectors of the former Objective-C
// methods, as the nib, the timers and the plugins send them: building the
// list, the count of the studies of each album and the periodic refresh are
// StudyListContent's (the album catalog and its count scheduler are
// IsiXDatabase's); what stays here asks a remote database for its changes
// and ends the DICOM processes left behind.

/// [set allObjects] as the NSArray it answers, without the copy of every
/// element the Swift overlay makes; the outline reads a row's images with it.
nonisolated func objcAllObjects(_ set: NSSet) -> NSArray? {
    return set.perform(#selector(getter: NSSet.allObjects))?.takeUnretainedValue() as? NSArray
}

extension BrowserController {

    // MARK: The result in the entire database

    /// Shows, under a filtered album, how many studies the search finds in
    /// the whole database or on the nodes when that is more than the list.
    @objc(refreshEntireDBResult)
    func refreshEntireDBResult() {
        studyList.showEntireDatabaseResult(displayed: horos_outlineViewArray?.count ?? 0)
    }

    /// The studies found before the other studies of the same patients were
    /// added; drawn in bold, so asked about for every visible row.
    @objc(rememberOriginalOutlineViewArray:)
    func rememberOriginalOutlineViewArray(_ array: [Any]?) {
        horos_setOriginalOutlineViewArray(array)
    }

    // MARK: The list

    /// Builds the 'root' array of the outline. Answers the exception that
    /// emptied the list.
    @discardableResult
    @objc(outlineViewRefresh)
    func outlineViewRefresh() -> String! {
        return studyList.refresh(whileHidden: false)
    }

    /// With hideListenerError, the server mode, the list of a hidden browser
    /// window is not rebuilt for every change of the database. An order to
    /// select a study, from XML-RPC, a horos:// link or a plugin, finds it in
    /// the list, so it rebuilds the list `whileHidden`: a study imported while
    /// the window was hidden is otherwise not there to be opened.
    @discardableResult
    func refreshStudyList(whileHidden: Bool) -> String! {
        return studyList.refresh(whileHidden: whileHidden)
    }

    /// Tells the list's observers that its rows changed, as a change of its
    /// selection does.
    func announceListSelection() {
        NotificationCenter.default.post(name: NSOutlineView.selectionDidChangeNotification, object: horos_databaseOutline, userInfo: nil)
    }

    // MARK: The number of studies of each album

    /// Counts the studies of the albums again, on a thread, unless a count
    /// is running already (then in 20 seconds) or the server mode hides the
    /// window.
    @objc(refreshAlbums)
    func refreshAlbums() {
        studyList.refreshAlbums()
    }

    /// The periodic refresh: a smart album's list and the albums' counts, the
    /// rest only redrawn (for filters depending on time), and the open query
    /// window.
    @objc(refreshDatabase:)
    func refreshDatabase(_ sender: Any!) {
        studyList.refreshDatabase()
    }

    /// Asks a remote database for its changes.
    func refreshBonjourSource(_ sender: Any!) {
        if let remote = self.database as? RemoteDicomDatabase {
            _ = remote.initiateUpdate()
        }
    }

    /// Ends the DICOM processes whose lock file, in their folder, is more
    /// than an hour old, and removes the lock. In /tmp, another user could
    /// name any of our processes for this to kill.
    @objc(searchDeadProcesses)
    nonisolated func searchDeadProcesses() {
        autoreleasepool {
            if let raised = HorosObjCException.caught({
                let processFolder = String(cString: HorosDICOMProcessFolder())
                for s in (try? FileManager.default.contentsOfDirectory(atPath: processFolder)) ?? [] {
                    guard ProcessLocks.pid(forFileName: s) != nil else { continue }
                    let created = (try? FileManager.default.attributesOfItem(atPath: (processFolder as NSString).appendingPathComponent(s)))?[.creationDate] as? Date
                    let sinceNow = created?.timeIntervalSinceNow ?? 0
                    if ProcessLocks.isStale(sinceNow: sinceNow) {
                        NSLog("****** dead process found lock_process %@", s)
                        NSLog("****** dead process timeIntervalSinceNow %d", ProcessLocks.seconds(sinceNow: sinceNow))
                        let pid = ProcessLocks.pid(forFileName: s) ?? 0
                        if pid != 0 {
                            NSLog("****** kill pid %@", s)
                            kill(pid, 15)
                            unlink(String(format: "%s/lock_process-%d", HorosDICOMProcessFolder(), pid))
                        }
                    }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController searchDeadProcesses]")
            }
        }
    }
}
