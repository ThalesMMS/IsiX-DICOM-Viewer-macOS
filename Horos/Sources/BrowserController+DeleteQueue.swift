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

// The selectors of the delete queue of the browser, which plugins and the
// timer of the browser call. The queue is DatabaseDeleteQueue, in the folder of
// the database the browser shows, which the browser keeps so that any thread
// reaches it; what is done with it, and the Q&R listener's error file read on
// the same timer, is StudyDeletionJob's.

extension BrowserController {

    @available(*, deprecated)
    @objc(resetListenerTimer)
    func resetListenerTimer() {
        DicomDatabase.syncImportFilesFromIncomingDirTimerWithUserDefaults()
    }

    /// Saves the files still queued, with those of a former saved queue.
    @objc(saveDeleteQueue)
    func saveDeleteQueue() {
        deletion.saveQueue()
    }

    /// Deletes the queued files on the calling thread.
    @objc(emptyDeleteQueueThread)
    nonisolated func emptyDeleteQueueThread() {
        StudyDeletionJob.deleteQueued(of: self)
    }

    /// Empties the queue now, after a deletion in progress.
    @objc(emptyDeleteQueueNow:)
    func emptyDeleteQueueNow(_ sender: Any!) {
        deletion.deleteQueueNow()
    }

    /// The timer's turn, unless the session is inactive or the browser waits
    /// for its running processes.
    @objc(emptyDeleteQueue:)
    func emptyDeleteQueue(_ sender: Any!) {
        if (AppController.shared()?.isSessionInactive ?? false) || BrowserController.horos_waitForRunningProcess { return }
        deletion.timerTurn()
    }

    /// Queues a file for deletion; from any thread.
    @objc(addFileToDeleteQueue:)
    nonisolated func addFile(toDeleteQueue file: String!) {
        if let file { transferState.deleteQueue.add(file) }
    }
}
