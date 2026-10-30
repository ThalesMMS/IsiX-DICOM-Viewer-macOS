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

// DicomDatabase (ImportAlerts): what an import tells the user. The files it
// refused, which the window reads from the main database whichever context
// did the import; the volume too full to import into, said once per episode
// on the main thread; the notifications of new images and new studies; and
// the alerts of reports that could not be read and of a copy from a medium
// that took less than it was given.

@objc(ImportAlerts) @implementation extension DicomDatabase {

    /// The main database, where the refusals and the storage state are kept.
    private final var mainDicomDatabase: DicomDatabase? {
        return self.mainDatabase as? DicomDatabase
    }

    // The window reads this from the main database, whichever context did the import.
    var lastImportRefusalSummary: String! {
        if !self.isMainDatabase() {
            return mainDicomDatabase?.lastImportRefusalSummary
        }
        return DicomDatabaseObjC.synchronized(self) { storedImportRefusalSummary }
    }

    func addImportRefusalSummary(_ summary: String!) {
        guard let summary, (summary as NSString).length != 0 else { return }
        if !self.isMainDatabase() {
            mainDicomDatabase?.addImportRefusalSummary(summary)
            return
        }
        DicomDatabaseObjC.synchronized(self) {
            if let current = storedImportRefusalSummary, (current as NSString).length != 0 {
                storedImportRefusalSummary = current + "; " + summary
            } else {
                storedImportRefusalSummary = summary
            }
        }
    }

    func setLastImportRefusalSummary(_ summary: String!) {
        if !self.isMainDatabase() {
            mainDicomDatabase?.setLastImportRefusalSummary(summary)
            return
        }
        DicomDatabaseObjC.synchronized(self) {
            if storedImportRefusalSummary == summary { return }
            storedImportRefusalSummary = summary
        }
    }

    var incomingImportWaitingForSpace: Bool {
        return self.isMainDatabase() ? incomingImportSpaceWarningShown : (mainDicomDatabase?.incomingImportWaitingForSpace ?? false)
    }

    // Shared by the incoming scheduler and cleanup workers. Own episode state on the
    // main database/main thread so independent contexts cannot duplicate warnings.
    func updateStorageAvailabilityWarning() {
        if !Thread.isMainThread {
            self.performSelector(onMainThread: #selector(DicomDatabase.updateStorageAvailabilityWarning), with: nil, waitUntilDone: false)
            return
        }
        if !self.isMainDatabase() {
            mainDicomDatabase?.updateStorageAvailabilityWarning()
            return
        }
        let storageUnavailable = self.isFileSystemFreeSizeLimitReached()
        let stateChanged = incomingImportSpaceWarningShown != storageUnavailable
        incomingImportSpaceWarningShown = storageUnavailable
        if stateChanged {
            nonisolated(unsafe) let database = self
            MainActor.assumeIsolated {
                if let browser = BrowserController.currentBrowser(), browser.database === database {
                    browser.perform(#selector(BrowserController.outlineViewRefresh), with: nil, afterDelay: 0)
                }
            }
        }
        if storageUnavailable && stateChanged {
            NSLog("Incoming import paused: database storage is full or unavailable; queued files are preserved")
            if !UserDefaults.standard.bool(forKey: "hideListenerError") {
                if let exception = DicomDatabaseObjC.attempt({
                    AppController.shared()?.notificationTitle(NSLocalizedString("Import Paused", comment: ""),
                        description: NSLocalizedString("The database volume is full or unavailable. Incoming files are preserved. Free space or reconnect the volume; IsiX DICOM Viewer will retry automatically.", comment: ""),
                        name: "importpaused")
                }) {
                    // Notification availability must not prevent import retries.
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase updateStorageAvailabilityWarning]")
                }
            }
        }
    }

    // MARK: - Notifications and alerts of an import

    /// Says, on the main thread, how many images an import added and which new
    /// study it made, as -_notificationImagesAdded: and -_notificationNewStudy: did.
    final func notifyImport(imagesAdded: String?, newStudy: String?) {
        if let imagesAdded {
            self.performSelector(onMainThread: #selector(DicomDatabase.notificationImagesAdded(_:)), with: imagesAdded, waitUntilDone: false)
        }
        if let newStudy {
            self.performSelector(onMainThread: #selector(DicomDatabase.notificationNewStudy(_:)), with: newStudy, waitUntilDone: false)
        }
    }

    @objc(_notificationImagesAdded:)
    private func notificationImagesAdded(_ message: String) {
        AppController.shared()?.notificationTitle(NSLocalizedString("Incoming Files", comment: ""), description: message, name: "newfiles")
    }

    @objc(_notificationNewStudy:)
    private func notificationNewStudy(_ message: String) {
        AppController.shared()?.notificationTitle(NSLocalizedString("New Study", comment: ""), description: message, name: "newstudy")
    }

    /// Reports an import could not read, after the import, on the main thread.
    final func alertRejectedReports(_ rejectedReports: Int) {
        let message = String(format: NSLocalizedString("%lu report(s) could not be imported because their contents could not be read. Existing reports were preserved.", comment: ""), UInt(rejectedReports))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Report import", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    /// A copy from a folder or a medium that took less than it was given, on the main thread.
    final func alertIncompleteImport(_ message: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Import incomplete", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }
}
