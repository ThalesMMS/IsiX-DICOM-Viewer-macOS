//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// A send to a DICOMweb node as the activity panel shows it (#799): what
/// `SendController` runs, on its own activity thread, when the destination
/// chosen in the Send sheet is a DICOMweb node.
///
/// Progress and status go to the thread, and Cancel in the panel stops the
/// send between requests. At the end the thread says how many instances were
/// stored, and why the first one not stored was not; the instances not
/// stored, or stored with a warning, are listed with their reason in an alert
/// and in the log, and the network log gets a line, as a DIMSE send does. A Send Syntax other than "As stored" is applied by
/// DCMTK (`HorosDICOMWriter`) before the files are posted.
@objc(HorosDICOMwebSendActivity)
public final class DICOMwebSendActivity: NSObject {
    /// Sends `files` to the node `server` names, on `thread`.
    @objc(sendFiles:patientName:toServer:thread:)
    public static func send(files: [String], patientName: String?, to server: [AnyHashable: Any]?, thread: Thread) {
        guard let node = DICOMwebSources.node(forServer: server) else {
            alert(NSLocalizedString("This DICOMweb node is no longer in Locations.", comment: ""))
            return
        }
        thread.name = String(format: NSLocalizedString("Sending to %@ (DICOMweb)...", comment: ""), node.name)
        thread.status = String(format: "%ld %@", files.count,
                               files.count == 1 ? NSLocalizedString("file", comment: "") : NSLocalizedString("files", comment: ""))
        thread.progress = 0

        let log = NSMutableDictionary()
        log["logUID"] = String(format: "%lf", Date().timeIntervalSince1970)
        log["logStartTime"] = Date()
        log["logType"] = "Send"
        log["logCalledAET"] = node.name
        log["logCallingAET"] = UserDefaults.defaultAETitle()
        if let patientName { log["logPatientName"] = patientName }
        func record(_ message: String, sent: Int, failed: Int) {
            log["logNumberTotal"] = files.count
            log["logNumberReceived"] = sent
            log["logNumberError"] = failed
            log["logEndTime"] = Date()
            log["logMessage"] = message
            (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
        }
        record("In Progress", sent: 0, failed: 0)

        let sender = DICOMwebSender(node: node) { source, destination, syntax in
            try HorosDICOMWriter.transcodeFile(atPath: source, toPath: destination, transferSyntax: syntax)
        }
        sender.progress = { status, fraction in
            thread.status = status
            thread.progress = CGFloat(fraction)
        }
        do {
            let report = try sender.send(files: files, cancelled: { thread.isCancelled })
            thread.status = report.statusLine
            thread.progress = 1
            NSLog("DICOMweb send to %@: %@", node.name, report.summary)
            record(report.cancelled ? "Cancelled" : report.isComplete ? "Complete" : "Incomplete",
                   sent: report.sentCount, failed: report.failedCount)
            if !report.isComplete || report.warningCount > 0 {
                let detail = report.detail(limit: 20)
                NSLog("DICOMweb send to %@:\n%@", node.name, detail)
                if report.failedCount > 0 {
                    AppController.shared()?.notificationTitle(NSLocalizedString("DICOMweb Send", comment: ""),
                                                             description: report.summary, name: "send")
                }
                // A send cancelled before anything was stored says so in the panel only.
                if !report.cancelled || report.sentCount > 0 { alert(detail) }
            }
        } catch {
            let message = (error as NSError).localizedDescription
            thread.status = message
            NSLog("DICOMweb send to %@ failed: %@", node.name, message)
            record("Incomplete", sent: 0, failed: files.count)
            alert(message)
        }
    }

    private static func alert(_ message: String) {
        DispatchQueue.main.async {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOMweb Send", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }
}
