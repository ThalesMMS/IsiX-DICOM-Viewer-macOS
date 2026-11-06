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
import IsiXDatabase
import IsiXPreferences

/// What an import tells the person: the files it refused, which the window
/// reads from the log the database shares with its independent databases; the
/// volume too full to import into, said once per episode on the main thread;
/// the notifications of new images and new studies; and the alerts of reports
/// that could not be read and of a copy from a medium that took less than it
/// was given.
///
/// It reaches nothing global: who notifies, who shows an alert, which list to
/// refresh and whether warnings are hidden come in, from the process graph for the
/// application and from a test as it likes.
struct ImportFeedback: Sendable {
    /// Posts a notification of the system: its title, its text and the name
    /// the person's choice of notifications goes by. On the main actor.
    typealias Notifier = @MainActor @Sendable (_ title: String, _ description: String, _ name: String) -> Void
    /// Shows an alert with one button. From the main run loop, so that the main
    /// queue goes on serving while it is open.
    typealias Alerter = @MainActor @Sendable (_ title: String, _ message: String) -> Void
    /// Refreshes the list of the browser when it shows the database
    /// identified. On the main actor.
    typealias ListRefresher = @MainActor @Sendable (_ database: ObjectIdentifier) -> Void
    /// Whether the warnings of the incoming folder are kept from the person, as
    /// a server unattended asks (hideListenerError). Any thread.
    typealias Silence = @Sendable () -> Bool

    let notifier: Notifier
    let alerter: Alerter
    let refreshList: ListRefresher
    let listenerErrorsHidden: Silence

    init(notifier: @escaping Notifier, alerter: @escaping Alerter, refreshList: @escaping ListRefresher,
         listenerErrorsHidden: @escaping Silence) {
        self.notifier = notifier
        self.alerter = alerter
        self.refreshList = refreshList
        self.listenerErrorsHidden = listenerErrorsHidden
    }

    /// The feedback of the application: the notifications of the application
    /// controller, the alert panel, the browser's list and the preferences.
    init(processGraph: ProcessGraph) {
        self.init(notifier: { title, description, name in
            processGraph.appController?.notificationTitle(title, description: description, name: name)
        }, alerter: { title, message in
            _ = HorosAlertPanel.run(title: title, message: message, defaultButton: NSLocalizedString("OK", comment: ""),
                                    alternateButton: nil, otherButton: nil)
        }, refreshList: { database in
            guard let browser = processGraph.currentBrowser, let shown = browser.database, ObjectIdentifier(shown) == database else { return }
            // At the next pass of the run loop, as -performSelector:withObject:afterDelay:0 did.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { _ = processGraph.currentBrowser?.outlineViewRefresh() }
            }
        }, listenerErrorsHidden: { processGraph.preferences[NetworkPreferences.hidesListenerErrors] })
    }

    /// For the categories of DicomDatabase, which the graph does not reach.
    static var process: ImportFeedback {
        ImportFeedback(processGraph: ProcessGraph.process)
    }

    // MARK: - The full volume

    /// Says whether the volume of `database` is too full to import into, once
    /// per episode: the incoming scheduler and the cleanup workers ask, on any
    /// thread and through any context, and the main database's volume and log
    /// answer, on the main thread.
    func updateStorageAvailabilityWarning(of database: DicomDatabase) {
        if !Thread.isMainThread {
            database.performSelector(onMainThread: #selector(DicomDatabase.updateStorageAvailabilityWarning), with: nil, waitUntilDone: false)
            return
        }
        guard let main = database.isMainDatabase() ? database : database.mainDatabase as? DicomDatabase else { return }
        let storageUnavailable = main.isFileSystemFreeSizeLimitReached()
        let stateChanged = main.importFeedbackLog.recordStorage(unavailable: storageUnavailable)
        if stateChanged {
            let shown = ObjectIdentifier(main)
            MainActor.assumeIsolated { refreshList(shown) }
        }
        if storageUnavailable && stateChanged {
            NSLog("Incoming import paused: database storage is full or unavailable; queued files are preserved")
            if !listenerErrorsHidden() {
                MainActor.assumeIsolated {
                    if let exception = HorosObjCException.caught({
                        notifier(NSLocalizedString("Import Paused", comment: ""),
                                 NSLocalizedString("The database volume is full or unavailable. Incoming files are preserved. Free space or reconnect the volume; IsiX DICOM Viewer will retry automatically.", comment: ""),
                                 "importpaused")
                    }) {
                        // Notification availability must not prevent import retries.
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase updateStorageAvailabilityWarning]")
                    }
                }
            }
        }
    }

    // MARK: - Notifications and alerts of an import

    /// Says, on the main thread, how many images an import added and which new
    /// study it made, as -_notificationImagesAdded: and -_notificationNewStudy: did.
    func notifyImport(imagesAdded: String?, newStudy: String?) {
        let notifier = notifier
        if let imagesAdded {
            onMainRunLoop { notifier(NSLocalizedString("Incoming Files", comment: ""), imagesAdded, "newfiles") }
        }
        if let newStudy {
            onMainRunLoop { notifier(NSLocalizedString("New Study", comment: ""), newStudy, "newstudy") }
        }
    }

    /// Reports an import could not read, after the import, from the main run loop.
    func alertRejectedReports(_ rejectedReports: Int) {
        let message = String(format: NSLocalizedString("%lu report(s) could not be imported because their contents could not be read. Existing reports were preserved.", comment: ""), UInt(rejectedReports))
        let alerter = alerter
        onMainRunLoop { alerter(NSLocalizedString("Report import", comment: ""), message) }
    }

    /// A copy from a folder or a medium that took less than it was given, from
    /// the main run loop too.
    func alertIncompleteImport(_ message: String) {
        let alerter = alerter
        onMainRunLoop { alerter(NSLocalizedString("Import incomplete", comment: ""), message) }
    }
}

// The selectors of the category, which the Objective-C code, the window and
// plugins reach on the database: they read and write the database's log and
// forward to ImportFeedback.
@objc(ImportAlerts) @implementation extension DicomDatabase {

    // The window reads this from the main database, whichever context did the import.
    var lastImportRefusalSummary: String! {
        importFeedbackLog.refusalSummary
    }

    func addImportRefusalSummary(_ summary: String!) {
        importFeedbackLog.addRefusals(summary)
    }

    func setLastImportRefusalSummary(_ summary: String!) {
        importFeedbackLog.setRefusalSummary(summary)
    }

    var incomingImportWaitingForSpace: Bool {
        importFeedbackLog.storageWarningShown
    }

    // Shared by the incoming scheduler and cleanup workers.
    func updateStorageAvailabilityWarning() {
        ImportFeedback.process.updateStorageAvailabilityWarning(of: self)
    }
}
