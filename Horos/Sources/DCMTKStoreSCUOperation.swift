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
import IsiXPreferences
import os

/** \brief One C-STORE association of a send, as an operation of a queue

 The implementation of DCMTKStoreSCUOperation, declared in
 DCMTKStoreSCUOperation.h: the operation the Send window of the Horos and
 OsiriX SDK queued for each part of a send. The send itself is DCMTKStoreSCU's,
 which the application's own sends go through; this class only reads the node
 and the preferences, as the SDK's did, and tells the user of a failure.
 */
@objc @implementation extension DCMTKStoreSCUOperation {
    private struct Parts {
        var files: [Any]?
        var server: [AnyHashable: Any]?
        var thread: Thread?
    }

    /// The three properties, which the SDK declared atomic: the queue's thread
    /// writes `thread` while the one that made the operation may read it.
    @nonobjc private let parts = OSAllocatedUnfairLock(uncheckedState: Parts())

    var files: [Any]! {
        get { parts.withLockUnchecked { $0.files } }
        set { parts.withLockUnchecked { $0.files = newValue } }
    }

    var server: [AnyHashable: Any]! {
        get { parts.withLockUnchecked { $0.server } }
        set { parts.withLockUnchecked { $0.server = newValue } }
    }

    var thread: Thread! {
        get { parts.withLockUnchecked { $0.thread } }
        set { parts.withLockUnchecked { $0.thread = newValue } }
    }

    @objc(initWithFiles:server:)
    init!(files: [Any]!, server: [AnyHashable: Any]!) {
        super.init()
        self.files = files
        self.server = server
    }

    // -init, which the SDK's class inherited: an operation with nothing to send.
    override init() {
        super.init()
    }

    @objc(showErrorMessage:)
    func showErrorMessage(_ exception: NSException!) {
        let message = String(format: "%@\r\r%@\r%@", NSLocalizedString("DICOM StoreSCU operation failed.", comment: ""),
                             exception?.name.rawValue ?? "(null)", exception?.reason ?? "(null)")
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send Error", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    public override func main() {
        autoreleasepool {
            if isCancelled { return }
            let current = Thread.current
            thread = current
            current.progress = 0

            let server = self.server
            // -intValue of the SDK: a number or its text, and zero for anything else.
            let port = (server?["Port"] as? NSNumber)?.int32Value ?? (server?["Port"] as? NSString)?.intValue ?? 0
            let preferences = PreferencesSource.process.preferences
            let storeSCU = DCMTKStoreSCU(callingAET: UserDefaults.defaultAETitle(), calledAET: server?["AETitle"] as? String,
                                         hostname: server?["Address"] as? String, port: port, filesToSend: files,
                                         transferSyntax: Int32(truncatingIfNeeded: preferences[NetworkPreferences.sendTransferSyntax]),
                                         compression: 1.0, extraParameters: server)
            guard let failure = storeSCU.sendReportingFailure(self) else { return }
            // The exception -run: raises for this failure, made on the main
            // thread, where a subclass's -showErrorMessage: is sent as the
            // SDK's operation sent it.
            let name = failure.category.rawValue, reason = failure.reason
            onMainRunLoop {
                self.showErrorMessage(NSException(name: NSExceptionName(name), reason: reason, userInfo: nil))
            }
        }
    }
}
