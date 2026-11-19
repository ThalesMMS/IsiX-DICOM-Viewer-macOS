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

/// Whether the application may quit now, as the database window sees it, and
/// what that window does before the quit: the viewers closed, the database
/// saved and let go.
///
/// With `asking` false, when the system ends the session and nobody has to be
/// there, the two questions are not put and their operations are cancelled, as
/// the Quit button answers. A full screen window still refuses, and a rebuild
/// of the index is still waited for: quitting then would leave the index half
/// written.
@MainActor struct BrowserQuitAgreement {
    /// Nil before the application has its database window.
    let browser: BrowserController?

    func given(asking: Bool) -> Bool {
        // No database window yet: nothing is under way that a question would
        // protect, and nothing to close or save.
        guard let browser else { return true }
        // Is there a full screen window displayed?
        for window in NSApp.orderedWindows where window is NSFullScreenWindow {
            NSSound.beep()
            return false
        }
        if !DatabaseRebuildService.waitForRebuildsBeforeQuitting() { return false }
        ViewerController.closeAllWindows()

        _ = browser.horos_databaseIvar?.save(nil)

        if asking && (ThreadsManager.default()?.threadsCount() ?? 0) > 0 {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Background Operations", comment: "")
            alert.informativeText = NSLocalizedString("Background operations are currently running. Are you sure you want to quit now? These operations will be cancelled.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))

            // The alert closes by itself once the operations have ended.
            let timer = Timer(timeInterval: 0.3, target: browser, selector: #selector(BrowserController.shouldTerminateCallback(_:)), userInfo: alert, repeats: true)
            RunLoop.current.add(timer, forMode: .modalPanel)

            let response = alert.runModal()

            timer.invalidate()

            if (ThreadsManager.default()?.threadsCount() ?? 0) > 0 && response == .alertFirstButtonReturn {
                return false
            }

            // Quitting cancels these threads and gives them time to end.
        }

        if asking && SendController.sendControllerObjects() > 0 {
            if HorosAlertPanel.runInformational(
                title: NSLocalizedString("DICOM Sending - STORE", comment: ""),
                message: NSLocalizedString("Files are currently being sent to a DICOM node. Are you sure you want to quit now? The sending will be stopped.", comment: ""),
                defaultButton: NSLocalizedString("No", comment: ""), alternateButton: NSLocalizedString("Quit", comment: ""),
                otherButton: nil) == HorosAlertDefaultResponse {
                return false
            }
        }

        browser.database = nil

        return true
    }
}
