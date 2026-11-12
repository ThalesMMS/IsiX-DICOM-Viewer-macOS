//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

// What the log may write of an error of the DICOMweb client and of a result of
// a STOW-RS send: the kind of the error, an HTTP status, a DICOM reason code.
// The message of the error and the reason of the result are what the user is
// shown, and may end with what the node said, in its own words. What the log
// is told of those words is IsiXDICOMNetwork's `DICOMwebNodeAnswer.logReason`.

extension DICOMwebClient {
    /// What went wrong, for the network log: the kind, the HTTP status and how
    /// many objects a cut response had handed over. Never the message, which
    /// can quote the node's answer.
    @objc(logReasonForError:)
    public static func logReason(for error: NSError?) -> String? {
        guard let error else { return nil }
        let kind = errorKind(for: error)
        var reason: String
        switch kind {
        case .none: return nil
        case .configuration: reason = "Configuration"
        case .credentials: reason = "Credentials"
        case .network: reason = "Network"
        case .tls: reason = "TLS"
        case .timeout: reason = "Timeout"
        case .authentication, .notFound, .redirect, .http: reason = "HTTP \(error.code)"
        case .invalidResponse: reason = "Invalid response"
        case .cancelled: reason = "Cancelled"
        }
        if let handedOver = error.userInfo["HorosDICOMwebObjectsHandedOver"] as? Int, handedOver > 0 {
            reason += " after \(handedOver) objects"
        }
        return reason
    }

    /// `logReason(for:)` of an error there is, as a sentence of a report.
    static func logSentence(for error: NSError) -> String {
        (logReason(for: error) ?? "Failed") + "."
    }
}

extension DICOMwebStoreResult {
    /// What the codes of a result say of it, for the log.
    static func logReason(status: DICOMwebStoreStatus, reasonCode: Int, httpStatus: Int) -> String {
        switch status {
        case .success: return ""
        case .warning: return describe(reason: reasonCode, warning: true)
        case .failure:
            if reasonCode != 0 { return describe(reason: reasonCode, warning: false) }
            return httpStatus != 0 ? "Not stored (HTTP \(httpStatus))." : "Not stored."
        }
    }
}
