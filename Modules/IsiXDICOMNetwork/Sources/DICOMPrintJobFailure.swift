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

/// Why a DICOM print job failed, read from what its print.sh wrote. The
/// script's EXIT trap writes `IsiXPrintJob: step=<setup|layout|send> status=<n>`.
/// HorosStoredPrint writes one line for the page that stopped the batch, with
/// the stage that failed (`stage=load|connect|job`) and the failure status the
/// printer answered with (`dimse=0x....`) when it sent one, or
/// `cannot initialize printer` when the printer settings could not be used.
/// Its warnings do not count as failures. The sentence shown to the user is
/// the app's, which holds the localized strings.
public enum DICOMPrintJobFailure: Equatable, Sendable {
    /// /bin/bash could not run the script.
    case launch
    /// The job folder could not be prepared.
    case setup
    /// dcmpsprt failed, or the helper could not read what it wrote.
    case layout
    /// The helper could not set up the printer from print.cfg.
    case printerSettings
    /// No association with the printer.
    case unreachable
    /// The printer refused the job with this DIMSE status.
    case refused(Int)
    /// The job stopped while being sent, without a failure status from the printer.
    case interrupted
    /// The script reported no step: it ended some other way.
    case status(Int32)

    /// The failure that `output`, everything the script wrote, and its exit
    /// `status` describe. The last step line and the last failure line of the
    /// helper win, since the script reports its step once, on exit.
    public static func classify(output: String, status: Int32) -> DICOMPrintJobFailure {
        var step: String? = nil
        var report: Substring? = nil
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("IsiXPrintJob: ") {
                step = field("step", in: line).map(String.init)
            } else if line.hasPrefix("HorosStoredPrint: ") && !line.hasPrefix("HorosStoredPrint: warning:") {
                report = line
            }
        }
        switch step {
        case "setup": return .setup
        case "layout": return .layout
        case "send":
            guard let report else { return .status(status) }
            if report.contains("cannot initialize printer") { return .printerSettings }
            switch field("stage", in: report) {
            case "load": return .layout
            case "connect": return .unreachable
            case "job":
                if let dimse = field("dimse", in: report), dimse.hasPrefix("0x"),
                   let code = Int(dimse.dropFirst(2), radix: 16) {
                    return .refused(code)
                }
                return .interrupted
            default: return .status(status)
            }
        default: return .status(status)
        }
    }

    /// The value of `key=value` among the words of a report line; a word may
    /// end the line's fields with `;`, as HorosStoredPrint writes them.
    private static func field(_ key: String, in line: Substring) -> Substring? {
        for word in line.split(separator: " ") {
            let word = word.hasSuffix(";") ? word.dropLast() : word
            if word.hasPrefix(key + "=") { return word.dropFirst(key.count + 1) }
        }
        return nil
    }
}
