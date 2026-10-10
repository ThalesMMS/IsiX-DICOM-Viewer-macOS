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

import Foundation

/// The network log's "Receive" line for one DICOMweb retrieve of a study or
/// series, as a WADO-URI download and a C-STORE received by the listener
/// have theirs: "In Progress" from its start, then "Complete", "Incomplete"
/// or "Cancelled", with what arrived and what is missing. Nothing is written
/// while the network logs are off (`LogManager.addLogLine`).
///
/// The text names the node, never a URL, a UID, a credential or a response
/// body: the reason of a failure is its kind and HTTP status alone.
@objc(HorosDICOMwebRetrieveLog)
public final class DICOMwebRetrieveLog: NSObject {
    private let entry = NSMutableDictionary()
    private var finished = false

    @objc(initWithNode:patientName:studyDescription:)
    public init(node: String?, patientName: String?, studyDescription: String?) {
        super.init()
        entry["logUID"] = UUID().uuidString
        entry["logStartTime"] = Date()
        entry["logType"] = "Receive"
        entry["logCallingAET"] = node.flatMap { $0.isEmpty ? nil : $0 } ?? "DICOMweb"
        entry["logCalledAET"] = UserDefaults.defaultAETitle()
        if let patientName, !patientName.isEmpty { entry["logPatientName"] = patientName }
        if let studyDescription, !studyDescription.isEmpty { entry["logStudyDescription"] = studyDescription }
        entry["logMessage"] = "In Progress"
        write()
    }

    /// Ends the line. `expected` is what the retrieve asked for, or 0 when
    /// that is not known; `missing` is what was asked for and is not here.
    /// The line is "Cancelled" when the operator stopped the retrieve, else
    /// "Incomplete" when it failed or left anything missing.
    @objc(finishWithReceived:expected:missing:cancelled:reason:)
    public func finish(received: Int, expected: Int, missing: Int, cancelled: Bool, reason: String?) {
        guard !finished else { return }
        finished = true
        let received = max(received, 0), missing = max(missing, 0)
        let total = max(expected, received + missing)
        entry["logNumberTotal"] = total
        entry["logNumberReceived"] = received
        entry["logNumberError"] = missing
        entry["logEndTime"] = Date()
        entry["logMessage"] = cancelled ? "Cancelled" : (reason != nil || missing > 0) ? "Incomplete" : "Complete"
        var details = ["DICOMweb", "received=\(received)/\(total)", "missing=\(missing)"]
        if let reason, !reason.isEmpty { details.append(reason) }
        entry["logDetails"] = details.joined(separator: "; ")
        write()
    }

    private func write() {
        (LogManager.currentLogManager() as? LogManager)?.addLogLine(entry)
    }
}
