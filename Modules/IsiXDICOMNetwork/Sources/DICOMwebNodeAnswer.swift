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

/// What a DICOMweb node said about a request it refused, or beside the results
/// of a search: its X-DICOMweb-Error-Code, its Warning and the start of its
/// body, in the two forms they leave the client in. `reason` is for the user,
/// in the node's own words; `logReason` is for the log, which is told what
/// the words were, not what they said.
public enum DICOMwebNodeAnswer {
    /// What the node said about a refused request, on one line: its
    /// X-DICOMweb-Error-Code, its Warning and the start of its body, nil when
    /// it said nothing. DICOM-Swift has already removed from the body every
    /// credential the client sent and the value of every credential-like
    /// header line, and cut it to 4 KiB; control characters and runs of
    /// white space become one space here.
    public static func reason(code: String?, warning: String?, body: String?) -> String? {
        let parts = [line(code).map { "error code " + $0 }, line(warning).map { "Warning: " + $0 }, line(body)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// A text of the node on one line, nil when it has no words.
    static func line(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// What the node said, as the log may write it: its X-DICOMweb-Error-Code
    /// when it has the form of a code, the warn-code of its Warning and which
    /// of the two warnings of a QIDO-RS search it is, if it is one, and how
    /// long each text was. Never the texts: they are the node's own words,
    /// and a node that refuses a query or an instance may quote the name, the
    /// identifier or the date it was sent, while the system log is readable
    /// by every process of the user and travels in sysdiagnose reports. The
    /// user is shown the text, in the message of the error.
    public static func logReason(code: String?, warning: String?, body: String?) -> String? {
        func length(_ text: String) -> String { "\(text.count) character\(text.count == 1 ? "" : "s")" }
        var parts: [String] = []
        if let code = line(code) {
            let isCode = code.count <= 64 && code.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-")
            }
            parts.append("error code " + (isCode ? code : "of " + length(code)))
        }
        if let warning = line(warning) {
            var text = "Warning"
            let digits = warning.prefix(3)
            if digits.count == 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
               warning.dropFirst(3).first.map({ $0 == " " }) ?? true {
                text += " " + digits
            }
            let lower = warning.lowercased()
            if lower.contains("fuzzymatching") {
                text += " (fuzzy matching not supported)"
            } else if lower.contains("additional results") || lower.contains("truncat") {
                text += " (more results than the node returned)"
            }
            parts.append(text + ", " + length(warning))
        }
        if let body = line(body) { parts.append("a body of " + length(body)) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
